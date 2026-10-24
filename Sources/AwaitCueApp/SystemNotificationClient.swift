import AwaitCueCore
import Foundation
@preconcurrency import UserNotifications

enum SystemNotificationClientError: Error {
    case permissionMissing
}

enum SystemNotificationAction: Equatable, Sendable {
    case open(HookID)
    case snooze(HookID)
    case complete(HookID)
}

/// UserNotifications 系统边界；生产 adapter 调系统，行为测试记录最终请求。
protocol AwaitCueNotificationCenter: Sendable {
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
    func setCategories(_ categories: Set<UNNotificationCategory>)
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func currentAuthorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest) async throws
    func removeAllPendingNotificationRequests()
    func removeAllDeliveredNotifications()
}

/// 把 Core 返回的通知副作用交给 macOS User Notifications。
final class SystemNotificationClient: @unchecked Sendable {
    let actions: AsyncStream<SystemNotificationAction>

    private let delegate: AwaitCueNotificationDelegate
    private let center: any AwaitCueNotificationCenter

    convenience init() {
        self.init(center: SystemUserNotificationCenter())
    }

    init(center: any AwaitCueNotificationCenter) {
        let stream = AsyncStream<SystemNotificationAction>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        actions = stream.stream
        delegate = AwaitCueNotificationDelegate(continuation: stream.continuation)
        self.center = center
        center.setDelegate(delegate)
        center.setCategories([Self.makeHookReadyCategory()])
    }

    /// 请求 AwaitCue 所需的提醒、声音和角标权限。
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
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
        try await center.add(request)
    }

    private var isAuthorized: Bool {
        get async {
            let allowed = switch await center.currentAuthorizationStatus() {
            case .authorized, .provisional, .ephemeral: true
            case .notDetermined, .denied: false
            @unknown default: false
            }
            return allowed
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

    /// 把系统 action identifier 收敛为 App 可以处理的稳定 Hook 动作。
    static func action(
        responseIdentifier: String,
        hookIDString: String
    ) -> SystemNotificationAction? {
        guard let uuid = UUID(uuidString: hookIDString) else { return nil }
        let hookID = HookID(rawValue: uuid)
        return switch responseIdentifier {
        case UNNotificationDefaultActionIdentifier, NotificationIdentifier.open:
            .open(hookID)
        case NotificationIdentifier.snooze:
            .snooze(hookID)
        case NotificationIdentifier.complete:
            .complete(hookID)
        default:
            nil
        }
    }
}

private final class SystemUserNotificationCenter: AwaitCueNotificationCenter, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        center.delegate = delegate
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: options) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            // Xcode 16 的 UserNotifications 类型尚未完整标注 Sendable；回调只传递完成事实。
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func removeAllPendingNotificationRequests() {
        center.removeAllPendingNotificationRequests()
    }

    func removeAllDeliveredNotifications() {
        center.removeAllDeliveredNotifications()
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
        guard let hookIDString = response.notification.request.content.userInfo["hookID"] as? String
        else { return }
        let action = SystemNotificationClient.action(
            responseIdentifier: response.actionIdentifier,
            hookIDString: hookIDString
        )
        if let action {
            continuation.yield(action)
        }
    }
}
