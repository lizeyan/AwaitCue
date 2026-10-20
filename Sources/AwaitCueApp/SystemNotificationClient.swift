import AwaitCueCore
import Foundation
@preconcurrency import UserNotifications

enum SystemNotificationClientError: Error {
    case permissionMissing
}

enum SystemNotificationAction: Sendable {
    case open(HookID)
    case snooze(HookID)
    case complete(HookID)
}

/// 把 Core 返回的通知副作用交给 macOS User Notifications。
final class SystemNotificationClient: @unchecked Sendable {
    let actions: AsyncStream<SystemNotificationAction>

    private let delegate: AwaitCueNotificationDelegate

    init() {
        let stream = AsyncStream<SystemNotificationAction>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        actions = stream.stream
        delegate = AwaitCueNotificationDelegate(continuation: stream.continuation)
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([Self.makeHookReadyCategory()])
    }

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
        guard await isAuthorized else {
            throw SystemNotificationClientError.permissionMissing
        }
        let content = UNMutableNotificationContent()
        content.title = hook.title
        content.body = targetDescription(hook.target)
        content.sound = .default
        content.categoryIdentifier = NotificationIdentifier.category
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

    private var isAuthorized: Bool {
        get async {
            await withCheckedContinuation { continuation in
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    let allowed = switch settings.authorizationStatus {
                    case .authorized, .provisional, .ephemeral: true
                    case .notDetermined, .denied: false
                    @unknown default: false
                    }
                    continuation.resume(returning: allowed)
                }
            }
        }
    }

    private static func makeHookReadyCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: NotificationIdentifier.category,
            actions: [
                UNNotificationAction(
                    identifier: NotificationIdentifier.open,
                    title: "打开目标"
                ),
                UNNotificationAction(
                    identifier: NotificationIdentifier.snooze,
                    title: "稍后提醒"
                ),
                UNNotificationAction(
                    identifier: NotificationIdentifier.complete,
                    title: "完成",
                    options: [.destructive]
                ),
            ],
            intentIdentifiers: []
        )
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

private enum NotificationIdentifier {
    static let category = "AWAITCUE_HOOK_READY"
    static let open = "AWAITCUE_OPEN_TARGET"
    static let snooze = "AWAITCUE_SNOOZE"
    static let complete = "AWAITCUE_COMPLETE"
}

private final class AwaitCueNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<SystemNotificationAction>.Continuation

    init(continuation: AsyncStream<SystemNotificationAction>.Continuation) {
        self.continuation = continuation
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let hookIDString = response.notification.request.content.userInfo["hookID"] as? String,
              let uuid = UUID(uuidString: hookIDString)
        else {
            return
        }
        let hookID = HookID(rawValue: uuid)
        let action: SystemNotificationAction? = switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, NotificationIdentifier.open:
            .open(hookID)
        case NotificationIdentifier.snooze:
            .snooze(hookID)
        case NotificationIdentifier.complete:
            .complete(hookID)
        default:
            nil
        }
        if let action {
            continuation.yield(action)
        }
    }
}
