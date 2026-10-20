import Foundation
@preconcurrency import Network
import Testing
@testable import AwaitCueBrowserBridge

@Suite("本地 Native Messaging relay")
struct LocalNativeBridgeTests {
    @Test("descriptor 以仅当前用户可读写的权限落盘并可恢复")
    func descriptorRoundTripUsesPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("native-bridge.json")
        let descriptor = NativeBridgeDescriptor(port: 41_001, token: "private-token")

        try descriptor.write(to: url)

        #expect(try NativeBridgeDescriptor.read(from: url) == descriptor)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("客户端认证后支持双向长度帧消息")
    func authenticatedClientAndServerExchangeFrames() async throws {
        let server = NativeBridgeServer(token: "integration-token")
        let descriptor = try await server.start()
        defer { server.stop() }

        let client = NativeBridgeClient(descriptor: descriptor)
        try await client.connect()
        defer { client.stop() }

        var serverMessages = server.incomingMessages.makeAsyncIterator()
        var clientMessages = client.incomingMessages.makeAsyncIterator()
        let fromExtension = Data(#"{"type":"pong"}"#.utf8)
        let fromApp = Data(#"{"type":"ping"}"#.utf8)

        try await client.sendPayload(fromExtension)
        #expect(await serverMessages.next() == fromExtension)

        try await server.broadcastPayload(fromApp)
        #expect(await clientMessages.next() == fromApp)
    }

    @Test("错误 token 的客户端不会向应用交付消息")
    func invalidAuthenticationIsRejected() async throws {
        let server = NativeBridgeServer(token: "correct-token")
        let descriptor = try await server.start()
        defer { server.stop() }
        let invalidClient = NativeBridgeClient(
            descriptor: NativeBridgeDescriptor(port: descriptor.port, token: "wrong-token")
        )

        await #expect(throws: NativeBridgeError.authenticationRejected) {
            try await invalidClient.connect()
        }
    }

    @Test("损坏 descriptor、无效端口和未连接发送返回稳定错误")
    func rejectsInvalidDescriptorAndDisconnectedUse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidURL = directory.appendingPathComponent("invalid.json")
        try Data("not-json".utf8).write(to: invalidURL)
        #expect(throws: NativeBridgeError.invalidDescriptor) {
            try NativeBridgeDescriptor.read(from: invalidURL)
        }

        let disconnectedClient = NativeBridgeClient(
            descriptor: NativeBridgeDescriptor(port: 1, token: "token"),
            connectionTimeout: 0.05
        )
        await #expect(throws: NativeBridgeError.connectionFailed) {
            try await disconnectedClient.connect()
        }

        await #expect(throws: NativeBridgeError.disconnected) {
            try await NativeBridgeClient(
                descriptor: NativeBridgeDescriptor(port: 1, token: "token")
            ).sendPayload(Data())
        }
    }

    @Test("未发送认证帧的本地连接会在 deadline 后被回收")
    func unauthenticatedPeerTimesOut() async throws {
        let server = NativeBridgeServer(token: "timeout-token", authenticationTimeout: 0.03)
        let descriptor = try await server.start()
        defer { server.stop() }
        let port = try #require(NWEndpoint.Port(rawValue: descriptor.port))
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        connection.start(queue: DispatchQueue(label: "org.awaitcue.test.unauthenticated"))

        try await Task.sleep(for: .milliseconds(100))

        #expect(server.peerCount == 0)
        connection.cancel()
    }

    @Test("接受 TCP 但不回应认证的本地服务会触发客户端 deadline")
    func silentLocalPeerTimesOutDuringAuthentication() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "org.awaitcue.test.silent-peer")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        let port = try await waitForListenerPort(listener)
        let client = NativeBridgeClient(
            descriptor: NativeBridgeDescriptor(port: port.rawValue, token: "token"),
            connectionTimeout: 0.03
        )

        await #expect(throws: NativeBridgeError.connectionFailed) {
            try await client.connect()
        }
    }

    @Test("应用未消费消息时 bounded stream 会断开过量发送方")
    func serverStopsPeerWhenIncomingBufferOverflows() async throws {
        let server = NativeBridgeServer(token: "bounded-token")
        let descriptor = try await server.start()
        defer { server.stop() }
        let client = NativeBridgeClient(descriptor: descriptor)
        try await client.connect()
        defer { client.stop() }

        for index in 0 ..< 80 {
            try? await client.sendPayload(Data("payload-\(index)".utf8))
        }
        try await waitUntil { server.peerCount == 0 }

        #expect(server.peerCount == 0)
    }
}

private func waitForListenerPort(_ listener: NWListener) async throws -> NWEndpoint.Port {
    try await withCheckedThrowingContinuation { continuation in
        let gate = TestContinuationGate(continuation)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port {
                    gate.resume(returning: port)
                }
            case .failed:
                gate.resume(throwing: NativeBridgeError.listenerFailed)
            default:
                break
            }
        }
    }
}

private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
    for _ in 0 ..< 200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("异步条件未在预期时间内成立")
}

private final class TestContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(throwing: error)
    }
}
