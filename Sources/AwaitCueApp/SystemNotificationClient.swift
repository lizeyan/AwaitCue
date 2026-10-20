import AwaitCueCore
import Foundation
import UserNotifications

/// 把 Core 返回的通知副作用交给 macOS User Notifications。
struct SystemNotificationClient: Sendable {
    /// 请求 AwaitCue 所需的提醒、声音和角标权限。
    func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            ) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// 提交已经通过生命周期与适合打断判断的本地通知。
    func deliver(_ hook: Hook, identifier: HookID) async throws {
        let content = UNMutableNotificationContent()
        content.title = hook.title
        content.body = targetDescription(hook.target)
        content.sound = .default
        content.categoryIdentifier = "AWAITCUE_HOOK_READY"
        content.userInfo = ["hookID": identifier.rawValue.uuidString]
        let request = UNNotificationRequest(
            identifier: identifier.rawValue.uuidString,
            content: content,
            trigger: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // Xcode 16 的 UserNotifications 类型尚未完整标注 Sendable；不跨 await 保存 center 可兼容该 SDK。
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// 清除应用仍未交付的全部通知，用于“删除所有本地数据”。
    func removeAllPendingNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    private func targetDescription(_ target: HookTarget) -> String {
        switch target {
        case let .window(window):
            window.initialTitle.isEmpty ? window.applicationBundleIdentifier : window.initialTitle
        case let .browser(browser):
            browser.initialTitle.isEmpty ? browser.host : browser.initialTitle
        }
    }
}
