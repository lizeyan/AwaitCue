import Foundation

/// Safari 原生消息在进入 AwaitCue relay 前的稳定错误分类。
public enum SafariBridgeMessageError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidEvent
    case imagePayloadForbidden
    case messageTooLarge
}

/// 把 Safari Web Extension 事件收敛成现有浏览器 relay 可以消费的 JSON payload。
public enum SafariBridgeMessageCodec {
    public static let maximumMessageSize = 24 * 1_024
    public static let browserBundleIdentifier = "com.apple.Safari"

    private static let forbiddenImageKeys: Set<String> = [
        "image",
        "imagedataurl",
        "pixels",
        "screenshot",
    ]

    /// 验证消息只包含页面内容，并补充由 Safari native extension 确认的浏览器身份。
    public static func makeRelayPayload(
        messageData: Data,
        profileIdentifier: String?
    ) throws -> Data {
        guard messageData.count <= maximumMessageSize else {
            throw SafariBridgeMessageError.messageTooLarge
        }
        let rawObject: Any
        do {
            rawObject = try JSONSerialization.jsonObject(with: messageData)
        } catch {
            throw SafariBridgeMessageError.invalidJSON
        }
        guard var object = rawObject as? [String: Any],
              let type = object["type"] as? String,
              !type.isEmpty
        else {
            throw SafariBridgeMessageError.invalidEvent
        }
        guard !containsForbiddenImageKey(object) else {
            throw SafariBridgeMessageError.imagePayloadForbidden
        }

        object["browserBundleIdentifier"] = browserBundleIdentifier
        object["safariProfileIdentifier"] = nil
        if let profileIdentifier, !profileIdentifier.isEmpty {
            object["safariProfileIdentifier"] = profileIdentifier
        }

        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw SafariBridgeMessageError.invalidJSON
        }
        guard payload.count <= maximumMessageSize else {
            throw SafariBridgeMessageError.messageTooLarge
        }
        return payload
    }

    /// 递归检查可以阻止把图片藏在 evidence 或其他嵌套对象中绕过 DOM-only 契约。
    private static func containsForbiddenImageKey(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if forbiddenImageKeys.contains(key.lowercased()) {
                    return true
                }
                if containsForbiddenImageKey(child) {
                    return true
                }
            }
            return false
        }
        if let array = value as? [Any] {
            return array.contains(where: containsForbiddenImageKey)
        }
        return false
    }
}
