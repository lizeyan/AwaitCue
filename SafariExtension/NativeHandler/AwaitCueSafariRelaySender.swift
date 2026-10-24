#if canImport(AwaitCueBrowserBridge)
import AwaitCueBrowserBridge
#endif
#if canImport(AwaitCueSafariBridge)
import AwaitCueSafariBridge
#endif
import Foundation

enum AwaitCueSafariRelaySenderError: Error {
    case appGroupUnavailable
}

/// Safari native app extension 通过 App Group 中的 descriptor 连接现有 AwaitCue loopback relay。
actor AwaitCueSafariRelaySender: SafariRelayPayloadSending {
    static let shared = AwaitCueSafariRelaySender()
    static let appGroupIdentifier = AwaitCueSafariBridgeConfiguration.appGroupIdentifier

    func send(_ payload: Data) async throws {
        do {
            try await sendOnce(payload)
        } catch {
            // 主应用升级或重启后 descriptor/token 会变化；仅重读 descriptor 一次，避免无限阻塞 Safari。
            try await sendOnce(payload)
        }
    }

    private func sendOnce(_ payload: Data) async throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw AwaitCueSafariRelaySenderError.appGroupUnavailable
        }
        let descriptor = try NativeBridgeDescriptor.read(
            from: containerURL.appendingPathComponent(
                AwaitCueSafariBridgeConfiguration.descriptorFilename
            )
        )
        let client = NativeBridgeClient(descriptor: descriptor)
        try await client.connect()
        defer { client.stop() }
        try await client.sendPayload(payload)
    }
}
