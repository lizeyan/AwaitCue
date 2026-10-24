import Foundation

/// Safari native app extension 只依赖这个单向发送接口，不需要了解 relay 的 TCP 或认证细节。
public protocol SafariRelayPayloadSending: Sendable {
    func send(_ payload: Data) async throws
}

/// 返回给 Safari background script 的最小确认，不回传页面内容或本地错误细节。
public enum SafariBridgeReply: Equatable, Sendable {
    case accepted
    case rejected(code: String)

    public var propertyList: [String: Any] {
        switch self {
        case .accepted:
            ["accepted": true]
        case let .rejected(code):
            ["accepted": false, "error": code]
        }
    }
}

/// 校验 Safari Web Extension 消息并转发到 AwaitCue 菜单栏进程。
public struct SafariNativeMessageBridge: Sendable {
    private let sender: any SafariRelayPayloadSending

    public init(sender: any SafariRelayPayloadSending) {
        self.sender = sender
    }

    /// DOM-only 校验发生在 relay 之前，保证任何 transport adapter 都无法把浏览器截图带进主应用。
    public func handle(
        messageData: Data,
        profileIdentifier: String?
    ) async -> SafariBridgeReply {
        let payload: Data
        do {
            payload = try SafariBridgeMessageCodec.makeRelayPayload(
                messageData: messageData,
                profileIdentifier: profileIdentifier
            )
        } catch let error as SafariBridgeMessageError {
            return .rejected(code: Self.errorCode(error))
        } catch {
            return .rejected(code: "invalid_message")
        }

        do {
            try await sender.send(payload)
            return .accepted
        } catch {
            return .rejected(code: "relay_unavailable")
        }
    }

    private static func errorCode(_ error: SafariBridgeMessageError) -> String {
        switch error {
        case .invalidJSON, .invalidEvent:
            "invalid_message"
        case .imagePayloadForbidden:
            "image_payload_forbidden"
        case .messageTooLarge:
            "message_too_large"
        }
    }
}
