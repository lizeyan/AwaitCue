import AwaitCueCore
import Foundation
import Testing
@testable import AwaitCueApp

@Suite("App SwiftUI 视图构造", .serialized)
struct ApplicationViewConstructionTests {
    @MainActor
    @Test("真实设置、创建和菜单 View 可由隔离模型构造")
    func userFacingViewsConstructWithoutSystemState() throws {
        let fixture = try IsolatedApplicationModelFixture()
        defer { fixture.cleanup() }
        fixture.model.pendingTarget = .browser(
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
        )

        _ = AwaitCueSettingsView(model: fixture.model).body
        _ = HookCreationView(model: fixture.model).body
        _ = AwaitCueMenuView(model: fixture.model, openSettings: {}).body
    }
}
