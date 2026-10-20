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

            async let input: Void = forwardStandardInput(
                to: client,
                browserBundleIdentifier: browserBundleIdentifier
            )
            async let output: Void = forwardAppMessages(from: client)
            _ = try await (input, output)
        } catch {
            writeErrorFrame(code: "native_app_unavailable")
            Foundation.exit(EXIT_FAILURE)
        }
    }

    /// Chrome stdin 可以任意分片到达，必须先解码完整消息再转发给菜单栏应用。
    private static func forwardStandardInput(
        to client: NativeBridgeClient,
        browserBundleIdentifier: String
    ) async throws {
        var decoder = NativeMessagingFrameDecoder(
            maximumMessageSize: NativeMessagingFrameCodec.maximumIncomingMessageSize
        )
        while let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
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
        for await payload in client.incomingMessages {
            try FileHandle.standardOutput.write(contentsOf: NativeMessagingFrameCodec.encodePayload(payload))
        }
    }

    private static func descriptorURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("AwaitCue", isDirectory: true)
            .appendingPathComponent("native-bridge.json")
    }

    /// Native host 的父应用由操作系统提供，比扩展自报 user-agent 更适合作为 Chrome/Arc 身份边界。
    private static func launchingBrowserBundleIdentifier() throws -> String {
        guard
            let parentBundleIdentifier = NSRunningApplication(
                processIdentifier: getppid()
            )?.bundleIdentifier,
            let browserBundleIdentifier = canonicalBrowserBundleIdentifier(parentBundleIdentifier)
        else {
            throw NativeHostError.untrustedBrowserParent
        }
        return browserBundleIdentifier
    }

    /// Chrome helper 的 bundle ID 带额外后缀；按最长主 bundle 前缀归一化，避免 Beta 被稳定版前缀吞掉。
    private static func canonicalBrowserBundleIdentifier(_ bundleIdentifier: String) -> String? {
        supportedBrowserBundleIdentifiers.first { candidate in
            bundleIdentifier == candidate || bundleIdentifier.hasPrefix(candidate + ".")
        }
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

    private static let supportedBrowserBundleIdentifiers = [
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome",
        "com.microsoft.edgemac.Canary",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.chromium.Chromium",
    ]
}

private enum NativeHostError: Error {
    case untrustedBrowserParent
    case invalidBrowserPayload
}
