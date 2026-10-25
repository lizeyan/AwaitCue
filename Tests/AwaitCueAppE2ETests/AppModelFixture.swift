import Foundation
@preconcurrency import UserNotifications
@testable import AwaitCueApp

@MainActor
struct IsolatedApplicationModelFixture {
    let model: AwaitCueApplicationModel
    let directory: URL
    let defaults: UserDefaults
    private let suiteName: String

    init(
        screenCapturePermission: (any ScreenCapturePermissionProviding)? = nil,
        globalHotKeyFactory: GlobalHotKeyFactory? = nil
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        suiteName = "org.awaitcue.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let environment = [
            "AWAITCUE_E2E": "1",
            "AWAITCUE_E2E_DATA_DIRECTORY": directory.path,
            "AWAITCUE_E2E_SKIP_KEYCHAIN": "1",
        ]
        let notificationClient = SystemNotificationClient(center: SilentNotificationCenter())
        if let globalHotKeyFactory {
            model = AwaitCueApplicationModel(
                environment: environment,
                defaults: defaults,
                notificationClient: notificationClient,
                screenCapturePermission: screenCapturePermission,
                globalHotKeyFactory: globalHotKeyFactory
            )
        } else {
            model = AwaitCueApplicationModel(
                environment: environment,
                defaults: defaults,
                notificationClient: notificationClient,
                screenCapturePermission: screenCapturePermission
            )
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

struct SilentNotificationCenter: AwaitCueNotificationCenter {
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {}
    func setCategories(_ categories: Set<UNNotificationCategory>) {}
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func currentAuthorizationStatus() async -> UNAuthorizationStatus { .authorized }
    func add(_ request: UNNotificationRequest) async throws {}
    func removeAllPendingNotificationRequests() {}
    func removeAllDeliveredNotifications() {}
}
