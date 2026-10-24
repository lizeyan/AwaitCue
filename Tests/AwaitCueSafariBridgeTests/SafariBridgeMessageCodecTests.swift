import Foundation
import Testing
@testable import AwaitCueSafariBridge

@Suite("Safari DOM-only 原生消息")
struct SafariBridgeMessageCodecTests {
    @Test("containing app 与 native extension 使用同一 App Group descriptor")
    func sharedDescriptorIdentityIsStable() {
        #expect(AwaitCueSafariBridgeConfiguration.appGroupIdentifier == "group.org.awaitcue.shared")
        #expect(AwaitCueSafariBridgeConfiguration.descriptorFilename == "native-bridge.json")
    }

    @Test("页面内容事件补充 Safari 身份后可以转发")
    func DOMEventCanBeForwarded() throws {
        let input = Data(#"""
        {
            "type":"evidenceChanged",
            "extensionInstallationID":"installation-1",
            "evidence":{
                "hookID":"hook-1",
                "url":"https://example.com/build/1",
                "title":"Build 1",
                "text":"CN 全流量部署完成",
                "aria":["status success"],
                "stateClasses":["status-success"],
                "fingerprint":"dom-fingerprint"
            }
        }
        """#.utf8)

        let output = try SafariBridgeMessageCodec.makeRelayPayload(
            messageData: input,
            profileIdentifier: "profile-1"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )

        #expect(object["browserBundleIdentifier"] as? String == "com.apple.Safari")
        #expect(object["safariProfileIdentifier"] as? String == "profile-1")
        #expect(object["type"] as? String == "evidenceChanged")
    }

    @Test("默认 Profile 不信任网页消息自带的 Safari Profile 身份")
    func defaultProfileRemovesUntrustedIdentity() throws {
        let input = Data(
            #"{"type":"ready","extensionInstallationID":"installation-1","safariProfileIdentifier":"spoofed"}"#.utf8
        )

        let output = try SafariBridgeMessageCodec.makeRelayPayload(
            messageData: input,
            profileIdentifier: nil
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
        #expect(object["safariProfileIdentifier"] == nil)
    }

    @Test("Safari 消息拒绝图片和截图字段")
    func imagePayloadsAreRejected() throws {
        for forbiddenKey in ["image", "imageDataURL", "screenshot", "pixels"] {
            let input = try JSONSerialization.data(withJSONObject: [
                "type": "evidenceChanged",
                "evidence": [
                    "hookID": "hook-1",
                    forbiddenKey: "forbidden",
                ],
            ])

            #expect(throws: SafariBridgeMessageError.imagePayloadForbidden) {
                try SafariBridgeMessageCodec.makeRelayPayload(
                    messageData: input,
                    profileIdentifier: nil
                )
            }
        }
    }

    @Test("Safari 原生消息保持既有 24 KiB 上限")
    func oversizedPayloadIsRejected() throws {
        let input = try JSONSerialization.data(withJSONObject: [
            "type": "evidenceChanged",
            "evidence": ["text": String(repeating: "x", count: 24 * 1_024)],
        ])

        #expect(throws: SafariBridgeMessageError.messageTooLarge) {
            try SafariBridgeMessageCodec.makeRelayPayload(
                messageData: input,
                profileIdentifier: nil
            )
        }
    }

    @Test("native handler 成功转发后只返回确定性确认")
    func bridgeForwardsDOMPayload() async throws {
        let sender = RecordingSafariRelaySender()
        let bridge = SafariNativeMessageBridge(sender: sender)
        let reply = await bridge.handle(
            messageData: Data(#"{"type":"ready","extensionInstallationID":"installation-1"}"#.utf8),
            profileIdentifier: "profile-1"
        )

        #expect(reply == .accepted)
        let payloads = await sender.payloads
        #expect(payloads.count == 1)
        let object = try #require(
            JSONSerialization.jsonObject(with: payloads[0]) as? [String: Any]
        )
        #expect(object["browserBundleIdentifier"] as? String == "com.apple.Safari")
    }

    @Test("图片消息在进入 relay 前即被拒绝")
    func bridgeDoesNotForwardImagePayload() async {
        let sender = RecordingSafariRelaySender()
        let bridge = SafariNativeMessageBridge(sender: sender)
        let reply = await bridge.handle(
            messageData: Data(#"{"type":"evidenceChanged","screenshot":"forbidden"}"#.utf8),
            profileIdentifier: nil
        )

        #expect(reply == .rejected(code: "image_payload_forbidden"))
        let payloads = await sender.payloads
        #expect(payloads.isEmpty)
    }

    @Test("native bridge 把协议和 relay 失败收敛为稳定错误码")
    func bridgeMapsInvalidAndUnavailableMessages() async throws {
        let recording = RecordingSafariRelaySender()
        let bridge = SafariNativeMessageBridge(sender: recording)
        #expect(await bridge.handle(
            messageData: Data("not-json".utf8),
            profileIdentifier: nil
        ) == .rejected(code: "invalid_message"))
        #expect(await bridge.handle(
            messageData: Data("{}".utf8),
            profileIdentifier: nil
        ) == .rejected(code: "invalid_message"))
        let oversized = try JSONSerialization.data(withJSONObject: [
            "type": "ready",
            "text": String(repeating: "x", count: 24 * 1_024),
        ])
        #expect(await bridge.handle(
            messageData: oversized,
            profileIdentifier: nil
        ) == .rejected(code: "message_too_large"))

        let unavailable = SafariNativeMessageBridge(sender: FailingSafariRelaySender())
        #expect(await unavailable.handle(
            messageData: Data(#"{"type":"ready","extensionInstallationID":"1"}"#.utf8),
            profileIdentifier: nil
        ) == .rejected(code: "relay_unavailable"))
    }

    @Test("Safari dispatcher 转发命令、打开设置并读取启用状态")
    func dispatcherUsesInjectedSafariServices() async throws {
        let services = StubSafariServicesCaller()
        let dispatcher = SafariExtensionCommandDispatcher(
            extensionIdentifier: "org.awaitcue.fixture",
            services: services
        )

        try await dispatcher.dispatch(Data(#"{"type":"ping","requestID":"1"}"#.utf8))
        try await dispatcher.showPreferences()
        #expect(try await dispatcher.isEnabled())
        #expect(services.dispatchedIdentifier == "org.awaitcue.fixture")
        #expect(services.dispatchedUserInfo?["type"] as? String == "ping")
        #expect(services.preferencesIdentifier == "org.awaitcue.fixture")
        #expect(services.stateIdentifier == "org.awaitcue.fixture")
    }

    @Test("Safari dispatcher 保留系统错误并拒绝非对象命令")
    func dispatcherPreservesErrorsAndRejectsInvalidPayload() async {
        let services = StubSafariServicesCaller(error: StubSafariServicesError.failure)
        let dispatcher = SafariExtensionCommandDispatcher(services: services)

        await #expect(throws: SafariBridgeMessageError.invalidEvent) {
            try await dispatcher.dispatch(Data("[]".utf8))
        }
        await #expect(throws: StubSafariServicesError.failure) {
            try await dispatcher.dispatch(Data(#"{"type":"ping"}"#.utf8))
        }
        await #expect(throws: StubSafariServicesError.failure) {
            try await dispatcher.showPreferences()
        }
        await #expect(throws: StubSafariServicesError.failure) {
            try await dispatcher.isEnabled()
        }
    }
}

private actor RecordingSafariRelaySender: SafariRelayPayloadSending {
    private(set) var payloads: [Data] = []

    func send(_ payload: Data) async throws {
        payloads.append(payload)
    }
}

private struct FailingSafariRelaySender: SafariRelayPayloadSending {
    func send(_ payload: Data) async throws {
        throw StubSafariServicesError.failure
    }
}

private enum StubSafariServicesError: Error, Equatable {
    case failure
}

private final class StubSafariServicesCaller: SafariServicesCalling, @unchecked Sendable {
    private let error: StubSafariServicesError?
    private let lock = NSLock()
    private(set) var dispatchedIdentifier: String?
    private(set) var dispatchedUserInfo: [String: Any]?
    private(set) var preferencesIdentifier: String?
    private(set) var stateIdentifier: String?

    init(error: StubSafariServicesError? = nil) {
        self.error = error
    }

    func dispatch(
        extensionIdentifier: String,
        userInfo: [String: Any],
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        lock.withLock {
            dispatchedIdentifier = extensionIdentifier
            dispatchedUserInfo = userInfo
        }
        completion(error)
    }

    func showPreferences(
        extensionIdentifier: String,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        lock.withLock { preferencesIdentifier = extensionIdentifier }
        completion(error)
    }

    func getExtensionEnabled(
        extensionIdentifier: String,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        lock.withLock { stateIdentifier = extensionIdentifier }
        completion(error == nil, error)
    }
}
