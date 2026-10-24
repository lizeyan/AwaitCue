import AppKit
import AwaitCueCore
import AwaitCueSelection
import SwiftUI
import Testing
@testable import AwaitCueApp

@Suite("macOS 创建 Hook 用户链路", .serialized)
struct HookCreationWindowE2ETests {
    @MainActor
    @Test("用户完成框选后看到屏内且尺寸可用的创建窗口")
    func selectionPresentsUsableCreationWindow() throws {
        let controller = HookCreationWindowController(
            rootView: { AnyView(Text("创建 Hook 测试内容")) },
            onUserClose: {}
        )
        let coordinator = HookCreationPresentationCoordinator()
        coordinator.attach(controller)
        var storedTarget: HookTarget?
        let clock = ContinuousClock()
        let startedAt = clock.now
        coordinator.selectionCompleted(fixtureTarget) { storedTarget = $0 }
        let presentationDuration = startedAt.duration(to: clock.now)
        defer { coordinator.finish { storedTarget = nil } }

        let window = try #require(NSApp.windows.first { $0.title == "创建 Hook" })
        #expect(storedTarget == fixtureTarget)
        #expect(window.isVisible)
        #expect(window.contentLayoutRect.width >= 520)
        #expect(window.contentLayoutRect.height >= 620)
        let visibleFrame = try #require(window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        #expect(visibleFrame.intersects(window.frame))
        #expect(presentationDuration < .seconds(1))
    }

    @MainActor
    @Test("重复触发同一个待创建 Hook 只置前一个窗口")
    func pendingTargetReusesAndRestoresCreationWindow() throws {
        let controller = makeController()
        let coordinator = HookCreationPresentationCoordinator()
        coordinator.attach(controller)
        coordinator.selectionCompleted(fixtureTarget) { _ in }
        defer { coordinator.finish {} }
        let original = try creationWindow()
        original.orderOut(nil)
        #expect(!original.isVisible)

        coordinator.presentExisting()

        let visibleWindows = NSApp.windows.filter { $0.title == "创建 Hook" && $0.isVisible }
        #expect(visibleWindows.count == 1)
        #expect(visibleWindows.first === original)
    }

    @MainActor
    @Test("用户关闭创建窗口后下一次框选可以显示全新窗口")
    func userCloseAllowsNextSelectionToPresentAgain() throws {
        var userCloseCount = 0
        let controller = HookCreationWindowController(
            rootView: { AnyView(Text("创建 Hook 测试内容")) },
            onUserClose: { userCloseCount += 1 }
        )
        let coordinator = HookCreationPresentationCoordinator()
        coordinator.attach(controller)
        coordinator.selectionCompleted(fixtureTarget) { _ in }
        let first = try creationWindow()
        first.performClose(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(userCloseCount == 1)

        coordinator.selectionCompleted(fixtureTarget) { _ in }
        defer { coordinator.finish {} }

        let second = try creationWindow()
        #expect(second.isVisible)
        #expect(second !== first)
    }

    @MainActor
    @Test("创建或取消导致的程序关闭不会冒充用户取消")
    func programmaticDismissDoesNotReportUserClose() throws {
        var userCloseCount = 0
        let controller = HookCreationWindowController(
            rootView: { AnyView(Text("创建 Hook 测试内容")) },
            onUserClose: { userCloseCount += 1 }
        )
        let coordinator = HookCreationPresentationCoordinator()
        coordinator.attach(controller)
        coordinator.selectionCompleted(fixtureTarget) { _ in }
        _ = try creationWindow()

        var didClearTarget = false
        coordinator.finish { didClearTarget = true }

        #expect(didClearTarget)
        #expect(userCloseCount == 0)
        #expect(!NSApp.windows.contains { $0.title == "创建 Hook" && $0.isVisible })
    }

    @MainActor
    @Test("框选失败后用户立即看到原因而不是无声结束")
    func selectionFailurePresentsVisibleReason() throws {
        let controller = makeController()
        let coordinator = HookCreationPresentationCoordinator()
        coordinator.attach(controller)

        coordinator.selectionFailed(message: "框选必须完全位于网页内容区域内。")

        let window = try #require(NSApp.windows.first {
            $0.title == "无法创建 Hook" && $0.isVisible
        })
        defer { window.performClose(nil) }
        #expect(window.accessibilityLabel()?.contains("框选必须完全位于网页内容区域内。") == true)
        #expect(window.contentLayoutRect.width >= 420)
        #expect(window.contentLayoutRect.height >= 180)
        let visibleFrame = try #require(window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        #expect(visibleFrame.intersects(window.frame))
    }

    @MainActor
    private func makeController() -> HookCreationWindowController {
        HookCreationWindowController(
            rootView: { AnyView(Text("创建 Hook 测试内容")) },
            onUserClose: {}
        )
    }

    @MainActor
    private func creationWindow() throws -> NSWindow {
        try #require(NSApp.windows.first { $0.title == "创建 Hook" && $0.isVisible })
    }

    private var fixtureTarget: HookTarget {
        .window(
            WindowTarget(
                applicationBundleIdentifier: "org.awaitcue.e2e.fixture",
                windowIdentifier: 42,
                initialTitle: "AwaitCue E2E fixture",
                normalizedRegion: NormalizedRegion(x: 0.1, y: 0.1, width: 0.8, height: 0.6)
            )
        )
    }
}
