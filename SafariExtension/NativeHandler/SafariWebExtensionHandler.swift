#if canImport(AwaitCueSafariBridge)
import AwaitCueSafariBridge
#endif
import Foundation
import SafariServices

/// Safari Web Extension JavaScript 与 AwaitCue 菜单栏进程之间的原生消息入口。
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let bridge = SafariNativeMessageBridge(
        sender: AwaitCueSafariRelaySender.shared
    )

    func beginRequest(with context: NSExtensionContext) {
        let box = ExtensionRequestContextBox(context)
        guard let input = context.inputItems.first as? NSExtensionItem,
              let userInfo = input.userInfo,
              let rawMessage = userInfo[SFExtensionMessageKey],
              JSONSerialization.isValidJSONObject(rawMessage),
              let messageData = try? JSONSerialization.data(withJSONObject: rawMessage)
        else {
            Self.complete(box, reply: .rejected(code: "invalid_message"))
            return
        }
        let profileIdentifier = userInfo[SFExtensionProfileKey] as? String
        Task {
            let reply = await Self.bridge.handle(
                messageData: messageData,
                profileIdentifier: profileIdentifier
            )
            Self.complete(box, reply: reply)
        }
    }

    private static func complete(
        _ box: ExtensionRequestContextBox,
        reply: SafariBridgeReply
    ) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply.propertyList]
        box.context.completeRequest(returningItems: [response])
    }
}

/// NSExtensionContext 没有 Sendable 标注；这里只跨任务传递一次并执行系统规定的线程安全完成回调。
private final class ExtensionRequestContextBox: @unchecked Sendable {
    let context: NSExtensionContext

    init(_ context: NSExtensionContext) {
        self.context = context
    }
}
