import AppKit
import AwaitCueBrowserBridge
import Darwin
import Foundation

@main
struct AwaitCueNativeHostMain {
    static func main() async {
        do {
            let browserBundleIdentifier = try launchingBrowserBundleIdentifier()
            let descriptor = try NativeBridgeDescriptor.read(from: descriptorURL())
            let client = NativeBridgeClient(descriptor: descriptor)
            try await client.connect()

            // FileHandle stdin 读取不能可靠响应 Swift Task 取消；任一方向结束时直接终止专用 host 进程，
            // 才能保证菜单栏 relay 关闭后 Chromium 立即收到 native port disconnect 并清理 capture。
            Task {
                do {
                    try await forwardStandardInput(
                        to: client,
                        browserBundleIdentifier: browserBundleIdentifier
                    )
                    client.stop()
                    Foundation.exit(EXIT_SUCCESS)
                } catch {
                    writeDiagnostic(stage: "stdin", error: error)
                    client.stop()
                    writeErrorFrame(code: "native_bridge_input_failed")
                    Foundation.exit(EXIT_FAILURE)
                }
            }
            try await forwardAppMessages(from: client)
            writeDiagnostic(stage: "relay_eof")
            client.stop()
            Foundation.exit(EXIT_SUCCESS)
        } catch {
            writeDiagnostic(stage: "startup", error: error)
            writeErrorFrame(code: errorCode(error))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    /// Chrome stdin 可以任意分片到达，必须先解码完整消息再转发给菜单栏应用。
    private static func forwardStandardInput(
        to client: NativeBridgeClient,
        browserBundleIdentifier: String
    ) async throws {
        let inputReader = FileDescriptorChunkReader(fileDescriptor: STDIN_FILENO)
        var decoder = NativeMessagingFrameDecoder(
            maximumMessageSize: NativeMessagingFrameCodec.maximumIncomingMessageSize
        )
        while let chunk = try inputReader.readChunk(maximumCount: 65_536), !chunk.isEmpty {
            for payload in try decoder.append(chunk) {
                try await client.sendPayload(
                    try payloadByAddingBrowserIdentity(
                        payload,
                        browserBundleIdentifier: browserBundleIdentifier
                    )
                )
            }
        }
        client.stop()
    }

    /// 菜单栏应用返回的是 JSON payload；native host 只负责重新添加 Chromium 帧前缀。
    private static func forwardAppMessages(from client: NativeBridgeClient) async throws {
        let outputWriter = FileDescriptorChunkWriter(fileDescriptor: STDOUT_FILENO)
        for await payload in client.incomingMessages {
            try outputWriter.write(NativeMessagingFrameCodec.encodePayload(payload))
        }
    }

    private static func descriptorURL() -> URL {
#if DEBUG
        // 真实进程 E2E 必须连接测试进程临时启动的 relay，而不能误连用户正在运行的 AwaitCue。
        // 该覆盖仅编译进 Debug 构建，正式分发版本始终使用 Application Support 中的 descriptor。
        if let path = ProcessInfo.processInfo.environment["AWAITCUE_E2E_DESCRIPTOR_PATH"],
           !path.isEmpty
        {
            return URL(fileURLWithPath: path)
        }
#endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("AwaitCue", isDirectory: true)
            .appendingPathComponent("native-bridge.json")
    }

    /// Native host 的父应用由操作系统提供，比扩展自报 user-agent 更适合作为 Chrome/Arc 身份边界。
    private static func launchingBrowserBundleIdentifier() throws -> String {
#if DEBUG
        // XCTest 直接启动 host 时父进程不是浏览器；显式测试变量只允许映射到受支持的 Chromium 身份。
        if let requestedBundleIdentifier = ProcessInfo.processInfo.environment[
            "AWAITCUE_E2E_BROWSER_BUNDLE_ID"
        ],
            let browserBundleIdentifier = BrowserParentIdentity.canonicalBundleIdentifier(
                requestedBundleIdentifier
            )
        {
            return browserBundleIdentifier
        }
#endif
        let parentPID = getppid()
        if let parentBundleIdentifier = NSRunningApplication(
            processIdentifier: parentPID
        )?.bundleIdentifier,
           let browserBundleIdentifier = BrowserParentIdentity.canonicalBundleIdentifier(
            parentBundleIdentifier
           )
        {
            return browserBundleIdentifier
        }
        var pathBuffer = [CChar](
            repeating: 0,
            count: 4 * Int(MAXPATHLEN)
        )
        let pathLength = pathBuffer.withUnsafeMutableBufferPointer { buffer in
            proc_pidpath(parentPID, buffer.baseAddress, UInt32(buffer.count))
        }
        if pathLength > 0 {
            let pathBytes = pathBuffer.prefix(Int(pathLength)).map {
                UInt8(bitPattern: $0)
            }
            let executableURL = URL(
                fileURLWithPath: String(decoding: pathBytes, as: UTF8.self)
            )
            if let browserBundleIdentifier = BrowserParentIdentity.bundleIdentifier(
                containingExecutableAt: executableURL
            ) {
                return browserBundleIdentifier
            }
        }
        throw NativeHostError.untrustedBrowserParent
    }

    /// 给浏览器发往应用的每条事件覆盖写入操作系统验证过的 browser bundle。
    private static func payloadByAddingBrowserIdentity(
        _ payload: Data,
        browserBundleIdentifier: String
    ) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw NativeHostError.invalidBrowserPayload
        }
        object["browserBundleIdentifier"] = browserBundleIdentifier
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func writeErrorFrame(code: String) {
        let payload = Data(#"{"type":"error","code":"\#(code)"}"#.utf8)
        if let frame = try? NativeMessagingFrameCodec.encodePayload(payload) {
            try? FileHandle.standardOutput.write(contentsOf: frame)
        }
    }

    /// 只记录失败阶段和错误类型；不得把浏览器消息、页面地址、token 或 descriptor 内容写入日志。
    private static func writeDiagnostic(stage: String, error: (any Error)? = nil) {
        let errorType = error.map { String(reflecting: type(of: $0)) } ?? "none"
        let line = "AwaitCueNativeHost stage=\(stage) errorType=\(errorType)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }

    private static func errorCode(_ error: any Error) -> String {
        if let nativeHostError = error as? NativeHostError {
            return switch nativeHostError {
            case .untrustedBrowserParent: "untrusted_browser_parent"
            case .invalidBrowserPayload: "invalid_browser_payload"
            }
        }
        if let bridgeError = error as? NativeBridgeError {
            return switch bridgeError {
            case .invalidDescriptor: "invalid_descriptor"
            case .listenerFailed: "unexpected_listener_failure"
            case .connectionFailed: "relay_connection_failed"
            case .authenticationRejected: "relay_authentication_rejected"
            case .disconnected: "relay_disconnected"
            }
        }
        return "native_app_unavailable"
    }

}

private enum NativeHostError: Error {
    case untrustedBrowserParent
    case invalidBrowserPayload
}
