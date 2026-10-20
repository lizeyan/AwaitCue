import AwaitCueCore
import Foundation
import UserNotifications

/// 把 Core 返回的通知副作用交给 macOS User Notifications。
actor SystemNotificationClient {
    private let center = UNUserNotificationCenter.current()

    /// 请求 AwaitCue 所需的提醒、声音和角标权限。
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// 提交已经通过生命周期与适合打断判断的本地通知。
    func deliver(_ hook: Hook, identifier: HookID) async throws {
        let content = UNMutableNotificationContent()
        content.title = hook.title
        content.body = targetDescription(hook.target)
        content.sound = .default
        content.categoryIdentifier = "AWAITCUE_HOOK_READY"
        content.userInfo = ["hookID": identifier.rawValue.uuidString]
        try await center.add(
            UNNotificationRequest(
                identifier: identifier.rawValue.uuidString,
                content: content,
                trigger: nil
            )
        )
    }

    /// 清除应用仍未交付的全部通知，用于“删除所有本地数据”。
    func removeAllPendingNotifications() {
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
