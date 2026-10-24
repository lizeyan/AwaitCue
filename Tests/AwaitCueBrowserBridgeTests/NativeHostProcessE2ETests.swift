import AwaitCueBrowserBridge
import Foundation
import Testing

@Suite("Native Host 进程端到端", .serialized)
struct NativeHostProcessE2ETests {
    @Test("浏览器帧与 App 广播可以穿过真实 Native Host 双向传输")
    func nativeHostForwardsBothDirections() async throws {
        let server = NativeBridgeServer()
        let descriptor = try await server.start()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let descriptorURL = temporaryDirectory.appendingPathComponent("native-bridge.json")
        try descriptor.write(to: descriptorURL)

        let process = Process()
        guard let executableURL = nativeHostExecutableURL() else {
            throw NativeHostProcessTestError.executableMissing
        }
        process.executableURL = executableURL
        process.environment = ProcessInfo.processInfo.environment.merging([
            "AWAITCUE_E2E_DESCRIPTOR_PATH": descriptorURL.path,
            "AWAITCUE_E2E_BROWSER_BUNDLE_ID": "com.google.Chrome",
        ]) { _, override in override }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Native host 只输出脱敏的失败阶段和错误类型；测试失败时保留它们可直接定位启动边界。
        process.standardError = FileHandle.standardError
        try process.run()
        defer {
            process.terminate()
            server.stop()
        }

        let ready = Data(#"{"type":"ready","extensionInstallationID":"fixture"}"#.utf8)
        try input.fileHandleForWriting.write(
            contentsOf: NativeMessagingFrameCodec.encodePayload(ready)
        )
        let browserPayload = try await firstValue(from: server.incomingMessages)
        let browserObject = try #require(
            JSONSerialization.jsonObject(with: browserPayload) as? [String: Any]
        )
        #expect(browserObject["type"] as? String == "ready")
        #expect(browserObject["browserBundleIdentifier"] as? String == "com.google.Chrome")

        let ping = Data(#"{"type":"ping","requestID":"fixture"}"#.utf8)
        #expect(try await server.broadcastPayload(ping) == 1)
        let appPayload = try await readNativeMessage(from: output.fileHandleForReading)
        #expect(appPayload == ping)

        // 同一 native port 必须连续接收第二条 App 命令；真实流程会先 ping，再 resolveSelection。
        let selection = Data(#"{"type":"resolveSelection","requestID":"selection-1"}"#.utf8)
        #expect(try await server.broadcastPayload(selection) == 1)
        let secondAppPayload = try await readNativeMessage(from: output.fileHandleForReading)
        #expect(secondAppPayload == selection)
    }

    private func nativeHostExecutableURL() -> URL? {
        let buildDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).appendingPathComponent(".build", isDirectory: true)
        let debugExecutable = buildDirectory
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("AwaitCueNativeHost")
        if FileManager.default.isExecutableFile(atPath: debugExecutable.path) {
            return debugExecutable
        }
        var directory = Bundle.main.bundleURL
        for _ in 0 ..< 6 {
            let candidate = directory.appendingPathComponent("AwaitCueNativeHost")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        if let enumerator = FileManager.default.enumerator(
            at: buildDirectory,
            includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let candidate as URL in enumerator
            where candidate.lastPathComponent == "AwaitCueNativeHost"
                && FileManager.default.isExecutableFile(atPath: candidate.path)
            {
                return candidate
            }
        }
        return nil
    }

    private func firstValue(from stream: AsyncStream<Data>) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                for await value in stream { return value }
                throw NativeHostProcessTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw NativeHostProcessTestError.timedOut
            }
            let value = try await group.next().orThrow(NativeHostProcessTestError.streamEnded)
            group.cancelAll()
            return value
        }
    }

    private func readNativeMessage(from handle: FileHandle) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let reader = FileDescriptorChunkReader(fileDescriptor: handle.fileDescriptor)
                var decoder = NativeMessagingFrameDecoder()
                while let chunk = try reader.readChunk(maximumCount: 65_536) {
                    if let payload = try decoder.append(chunk).first { return payload }
                }
                throw NativeHostProcessTestError.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw NativeHostProcessTestError.timedOut
            }
            let value = try await group.next().orThrow(NativeHostProcessTestError.streamEnded)
            group.cancelAll()
            return value
        }
    }
}

private enum NativeHostProcessTestError: Error {
    case executableMissing
    case streamEnded
    case timedOut
}

private extension Optional {
    func orThrow(_ error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}
