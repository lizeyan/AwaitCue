import Foundation
@preconcurrency import Network

/// 菜单栏应用与 Chromium 启动的 native host 之间的本地 relay 描述。
public struct NativeBridgeDescriptor: Codable, Equatable, Sendable {
    public let port: UInt16
    public let token: String

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    /// 以原子写入和 0600 权限保存随机 token，避免其他本地账号读取 relay 凭据。
    public func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    /// 从 native host 与应用约定的位置恢复 relay 描述。
    public static func read(from url: URL) throws -> NativeBridgeDescriptor {
        do {
            return try JSONDecoder().decode(NativeBridgeDescriptor.self, from: Data(contentsOf: url))
        } catch {
            throw NativeBridgeError.invalidDescriptor
        }
    }
}

/// 本地 relay 建立或认证失败的稳定错误分类。
public enum NativeBridgeError: Error, Equatable, Sendable {
    case invalidDescriptor
    case listenerFailed
    case connectionFailed
    case authenticationRejected
    case disconnected
}

/// 只监听 loopback 的本地 relay server，由菜单栏应用持有。
public final class NativeBridgeServer: @unchecked Sendable {
    public let incomingMessages: AsyncStream<Data>

    private let token: String
    private let authenticationTimeout: TimeInterval
    private let queue = DispatchQueue(label: "org.awaitcue.native-bridge.server")
    private let incomingContinuation: AsyncStream<Data>.Continuation
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: NativeBridgePeer] = [:]

    public init(
        token: String = UUID().uuidString,
        authenticationTimeout: TimeInterval = 5
    ) {
        self.token = token
        self.authenticationTimeout = authenticationTimeout
        let stream = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        incomingMessages = stream.stream
        incomingContinuation = stream.continuation
    }

    /// 启动 loopback listener，并返回 native host 需要读取的端口和随机 token。
    public func start() async throws -> NativeBridgeDescriptor {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NativeBridgeDescriptor, any Error>) in
            let gate = ContinuationGate(continuation)
            queue.async { [weak self] in
                guard let self else {
                    gate.resume(throwing: NativeBridgeError.listenerFailed)
                    return
                }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port else { return }
                            gate.resume(
                                returning: NativeBridgeDescriptor(port: port.rawValue, token: self.token)
                            )
                        case .failed:
                            gate.resume(throwing: NativeBridgeError.listenerFailed)
                        default:
                            break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.start(queue: self.queue)
                } catch {
                    gate.resume(throwing: NativeBridgeError.listenerFailed)
                }
            }
        }
    }

    /// 向当前所有已认证 native host 发送一个 JSON payload。
    public func broadcastPayload(_ payload: Data) async throws {
        let currentPeers: [NativeBridgePeer] = queue.sync {
            peers.values.filter(\.isAuthenticated)
        }
        for peer in currentPeers {
            try await peer.send(payload)
        }
    }

    /// 停止 listener 和全部已认证连接。
    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            let currentPeers = Array(peers.values)
            peers.removeAll()
            currentPeers.forEach { $0.stop() }
            incomingContinuation.finish()
        }
    }

    /// 仅供模块测试确认未认证连接会被及时回收。
    var peerCount: Int {
        queue.sync { peers.count }
    }

    private func accept(_ connection: NWConnection) {
        let peer = NativeBridgePeer(
            connection: connection,
            expectedToken: token,
            authenticationTimeout: authenticationTimeout,
            queue: queue,
            onPayload: { [weak self] payload in
                guard let self else { return false }
                return Self.accepted(self.incomingContinuation.yield(payload))
            },
            onStop: { [weak self] identifier in self?.peers[identifier] = nil }
        )
        peers[ObjectIdentifier(peer)] = peer
        peer.start()
    }

    private static func accepted(_ result: AsyncStream<Data>.Continuation.YieldResult) -> Bool {
        if case .enqueued = result { return true }
        return false
    }
}

/// Native host 使用的本地 relay client；连接成功前必须完成 token 握手。
public final class NativeBridgeClient: @unchecked Sendable {
    public let incomingMessages: AsyncStream<Data>

    private let descriptor: NativeBridgeDescriptor
    private let connectionTimeout: TimeInterval
    private let queue = DispatchQueue(label: "org.awaitcue.native-bridge.client")
    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let decoder = FrameAccumulator()
    private var connection: NWConnection?

    public init(
        descriptor: NativeBridgeDescriptor,
        connectionTimeout: TimeInterval = 5
    ) {
        self.descriptor = descriptor
        self.connectionTimeout = connectionTimeout
        let stream = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        incomingMessages = stream.stream
        incomingContinuation = stream.continuation
    }

    /// 连接 loopback server 并等待明确的认证结果。
    public func connect() async throws {
        let port = try NWEndpoint.Port(rawValue: descriptor.port)
            .orThrow(NativeBridgeError.invalidDescriptor)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.connection = connection
        do {
            try await waitUntilReady(connection)
            let authentication = try JSONEncoder().encode(
                BridgeControl(type: "authenticate", token: descriptor.token)
            )
            try await sendFrame(authentication, over: connection)
            let response = try await receiveOnePayload(
                from: connection,
                accumulator: decoder,
                queue: queue,
                timeout: connectionTimeout
            )
            let control = try? JSONDecoder().decode(BridgeControl.self, from: response)
            guard control?.type == "authenticated" else {
                throw NativeBridgeError.authenticationRejected
            }
        } catch {
            connection.cancel()
            self.connection = nil
            if let bridgeError = error as? NativeBridgeError,
               bridgeError == .disconnected
            {
                // 认证完成前的断开对调用方都属于连接失败，避免 callback 与 deadline 的竞态泄漏。
                throw NativeBridgeError.connectionFailed
            }
            throw error
        }
        for payload in decoder.drainPending() {
            guard Self.accepted(incomingContinuation.yield(payload)) else {
                stop()
                throw NativeBridgeError.disconnected
            }
        }
        receiveLoop(connection)
    }

    /// 向菜单栏应用发送一条原始 JSON payload。
    public func sendPayload(_ payload: Data) async throws {
        guard let connection else { throw NativeBridgeError.disconnected }
        try await sendFrame(payload, over: connection)
    }

    public func stop() {
        connection?.cancel()
        connection = nil
        incomingContinuation.finish()
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for payload in try self.decoder.append(data) {
                        guard Self.accepted(self.incomingContinuation.yield(payload)) else {
                            self.stop()
                            return
                        }
                    }
                } catch {
                    self.stop()
                    return
                }
            }
            if error != nil || isComplete {
                self.stop()
            } else {
                self.receiveLoop(connection)
            }
        }
    }

    private static func accepted(_ result: AsyncStream<Data>.Continuation.YieldResult) -> Bool {
        if case .enqueued = result { return true }
        return false
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let gate = ContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(returning: ())
                case .failed:
                    gate.resume(throwing: NativeBridgeError.connectionFailed)
                case .cancelled:
                    gate.resume(throwing: NativeBridgeError.connectionFailed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            // 失效 descriptor 指向的本地端口可能长期停留在 preparing，必须主动结束 native host。
            queue.asyncAfter(deadline: .now() + connectionTimeout) {
                if gate.resume(throwing: NativeBridgeError.connectionFailed) {
                    connection.cancel()
                }
            }
        }
    }
}

private final class NativeBridgePeer: @unchecked Sendable {
    private let connection: NWConnection
    private let expectedToken: String
    private let authenticationTimeout: TimeInterval
    private let queue: DispatchQueue
    private let onPayload: @Sendable (Data) -> Bool
    private let onStop: @Sendable (ObjectIdentifier) -> Void
    private let decoder = FrameAccumulator()
    private(set) var isAuthenticated = false
    private var isStopped = false

    init(
        connection: NWConnection,
        expectedToken: String,
        authenticationTimeout: TimeInterval,
        queue: DispatchQueue,
        onPayload: @escaping @Sendable (Data) -> Bool,
        onStop: @escaping @Sendable (ObjectIdentifier) -> Void
    ) {
        self.connection = connection
        self.expectedToken = expectedToken
        self.authenticationTimeout = authenticationTimeout
        self.queue = queue
        self.onPayload = onPayload
        self.onStop = onStop
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
            if case .cancelled = state { self?.stop() }
        }
        connection.start(queue: queue)
        receiveLoop()
        queue.asyncAfter(deadline: .now() + authenticationTimeout) { [weak self] in
            guard let self, !self.isAuthenticated else { return }
            self.stop()
        }
    }

    func send(_ payload: Data) async throws {
        try await sendFrame(payload, over: connection)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        connection.cancel()
        onStop(ObjectIdentifier(self))
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for payload in try self.decoder.append(data) {
                        try self.handle(payload)
                    }
                } catch {
                    self.stop()
                    return
                }
            }
            if error != nil || isComplete {
                self.stop()
            } else {
                self.receiveLoop()
            }
        }
    }

    private func handle(_ payload: Data) throws {
        if !isAuthenticated {
            let control = try JSONDecoder().decode(BridgeControl.self, from: payload)
            guard control.type == "authenticate", control.token == expectedToken else {
                let rejected = try JSONEncoder().encode(BridgeControl(type: "authenticationRejected"))
                let frame = try NativeMessagingFrameCodec.encodePayload(rejected)
                // 必须等拒绝帧真正写入后再断开，否则客户端只会看到模糊的 disconnected。
                connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
                    self?.stop()
                })
                return
            }
            isAuthenticated = true
            let accepted = try JSONEncoder().encode(BridgeControl(type: "authenticated"))
            connection.send(content: try NativeMessagingFrameCodec.encodePayload(accepted), completion: .idempotent)
            return
        }
        guard onPayload(payload) else {
            throw NativeBridgeError.disconnected
        }
    }
}

private struct BridgeControl: Codable {
    let type: String
    let token: String?

    init(type: String, token: String? = nil) {
        self.type = type
        self.token = token
    }
}

private final class FrameAccumulator: @unchecked Sendable {
    private var decoder = NativeMessagingFrameDecoder()
    private var pending: [Data] = []

    func append(_ data: Data) throws -> [Data] {
        try decoder.append(data)
    }

    func next(appending data: Data) throws -> Data? {
        pending.append(contentsOf: try decoder.append(data))
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    func drainPending() -> [Data] {
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}

private func sendFrame(_ payload: Data, over connection: NWConnection) async throws {
    let frame = try NativeMessagingFrameCodec.encodePayload(payload)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        connection.send(content: frame, completion: .contentProcessed { error in
            if error == nil {
                continuation.resume(returning: ())
            } else {
                continuation.resume(throwing: NativeBridgeError.disconnected)
            }
        })
    }
}

private func receiveOnePayload(
    from connection: NWConnection,
    accumulator: FrameAccumulator,
    queue: DispatchQueue,
    timeout: TimeInterval
) async throws -> Data {
    while true {
        let chunk: Data = try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    gate.resume(returning: data)
                } else if error != nil || isComplete {
                    gate.resume(throwing: NativeBridgeError.disconnected)
                } else {
                    gate.resume(returning: Data())
                }
            }
            // 对端接受 TCP 却不返回认证结果时，同样不能让浏览器 native host 永久挂起。
            queue.asyncAfter(deadline: .now() + timeout) {
                if gate.resume(throwing: NativeBridgeError.connectionFailed) {
                    connection.cancel()
                }
            }
        }
        if let payload = try accumulator.next(appending: chunk) {
            return payload
        }
    }
}

private extension Optional {
    func orThrow(_ error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}

/// Network.framework 的状态回调可能重复到达；该容器保证 continuation 只完成一次。
private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: Value) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<Value, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return false }
        pending.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: any Error) -> Bool {
        let pending = lock.withLock { () -> CheckedContinuation<Value, any Error>? in
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return false }
        pending.resume(throwing: error)
        return true
    }
}
