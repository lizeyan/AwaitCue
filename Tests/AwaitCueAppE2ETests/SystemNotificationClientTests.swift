import AwaitCueCore
import Foundation
import Testing
@preconcurrency import UserNotifications
@testable import AwaitCueApp

@Suite("macOS 通知用户链路")
struct SystemNotificationClientTests {
    @Test("已授权时通知保留 Hook 标题、Target、分类和稳定 ID")
    func authorizedDeliveryBuildsUserVisibleNotification() async throws {
        let center = RecordingNotificationCenter(authorizationStatus: .authorized)
        let client = SystemNotificationClient(center: center)
        let hook = fixtureHook

        try await client.deliver(hook, identifier: hook.id)

        let request = try #require(center.addedRequestSnapshots.first)
        #expect(request.identifier == hook.id.rawValue.uuidString)
        #expect(request.title == "部署完成")
        #expect(request.body == "Build dashboard")
        #expect(request.categoryIdentifier == "AWAITCUE_HOOK_READY")
        #expect(request.hookID == hook.id.rawValue.uuidString)
        #expect(center.categoryActionIdentifiers == [
            "AWAITCUE_OPEN_TARGET",
            "AWAITCUE_SNOOZE",
            "AWAITCUE_COMPLETE",
        ])
    }

    @Test("通知权限拒绝时不提交请求并返回稳定错误")
    func deniedDeliveryDoesNotSubmitNotification() async {
        let center = RecordingNotificationCenter(authorizationStatus: .denied)
        let client = SystemNotificationClient(center: center)

        await #expect(throws: SystemNotificationClientError.permissionMissing) {
            try await client.deliver(fixtureHook, identifier: fixtureHook.id)
        }
        #expect(center.addedRequestSnapshots.isEmpty)
    }

    @Test("通知按钮映射为打开、稍后提醒和完成 Hook")
    func actionIdentifiersMapToHookActions() throws {
        let hookID = HookID(rawValue: UUID())
        #expect(
            SystemNotificationClient.action(
                responseIdentifier: UNNotificationDefaultActionIdentifier,
                hookIDString: hookID.rawValue.uuidString
            ) == .open(hookID)
        )
        #expect(
            SystemNotificationClient.action(
                responseIdentifier: "AWAITCUE_SNOOZE",
                hookIDString: hookID.rawValue.uuidString
            ) == .snooze(hookID)
        )
        #expect(
            SystemNotificationClient.action(
                responseIdentifier: "AWAITCUE_COMPLETE",
                hookIDString: hookID.rawValue.uuidString
            ) == .complete(hookID)
        )
        #expect(
            SystemNotificationClient.action(
                responseIdentifier: "UNKNOWN",
                hookIDString: hookID.rawValue.uuidString
            ) == nil
        )
        #expect(
            SystemNotificationClient.action(
                responseIdentifier: "AWAITCUE_COMPLETE",
                hookIDString: "invalid"
            ) == nil
        )
    }

    @Test("删除全部本地数据时同时清除待发送和已交付通知")
    func removingNotificationsClearsBothStores() async {
        let center = RecordingNotificationCenter(authorizationStatus: .authorized)
        let client = SystemNotificationClient(center: center)

        client.removeAllPendingNotifications()

        #expect(center.removedPendingCount == 1)
        #expect(center.removedDeliveredCount == 1)
    }

    private var fixtureHook: Hook {
        let now = Date(timeIntervalSince1970: 100)
        return Hook(
            id: HookID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!),
            title: "部署完成",
            target: .browser(
                BrowserTarget(
                    browserBundleIdentifier: "com.google.Chrome",
                    nativeWindowIdentifier: 42,
                    extensionInstallationID: "installation-1",
                    tabIdentifier: 7,
                    host: "example.com",
                    initialURL: URL(string: "https://example.com/build")!,
                    initialTitle: "Build dashboard",
                    normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1),
                    observationMode: .dom
                )
            ),
            trigger: .delay(DelayDefinition(minimumDelay: 300)),
            state: .waitingInterruptible,
            createdAt: now,
            updatedAt: now
        )
    }
}

private final class RecordingNotificationCenter: AwaitCueNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    let authorizationStatus: UNAuthorizationStatus
    private var storedCategoryActionIdentifiers: [String] = []
    private var storedRequestSnapshots: [NotificationRequestSnapshot] = []
    private var storedRemovedPendingCount = 0
    private var storedRemovedDeliveredCount = 0

    init(authorizationStatus: UNAuthorizationStatus) {
        self.authorizationStatus = authorizationStatus
    }

    var categoryActionIdentifiers: [String] {
        lock.withLock { storedCategoryActionIdentifiers }
    }

    var addedRequestSnapshots: [NotificationRequestSnapshot] {
        lock.withLock { storedRequestSnapshots }
    }

    var removedPendingCount: Int {
        lock.withLock { storedRemovedPendingCount }
    }

    var removedDeliveredCount: Int {
        lock.withLock { storedRemovedDeliveredCount }
    }

    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {}

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        lock.withLock {
            storedCategoryActionIdentifiers = categories.first?.actions.map(\.identifier) ?? []
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationStatus == .authorized
    }

    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatus
    }

    func add(_ request: UNNotificationRequest) async throws {
        let snapshot = NotificationRequestSnapshot(
            identifier: request.identifier,
            title: request.content.title,
            body: request.content.body,
            categoryIdentifier: request.content.categoryIdentifier,
            hookID: request.content.userInfo["hookID"] as? String
        )
        lock.withLock { storedRequestSnapshots.append(snapshot) }
    }

    func removeAllPendingNotificationRequests() {
        lock.withLock { storedRemovedPendingCount += 1 }
    }

    func removeAllDeliveredNotifications() {
        lock.withLock { storedRemovedDeliveredCount += 1 }
    }
}

private struct NotificationRequestSnapshot: Sendable {
    let identifier: String
    let title: String
    let body: String
    let categoryIdentifier: String
    let hookID: String?
}
