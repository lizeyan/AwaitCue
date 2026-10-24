import AppKit
import SwiftUI
import Testing
@testable import AwaitCueApp

@Suite("macOS 设置窗口用户链路", .serialized)
struct SettingsWindowE2ETests {
    @MainActor
    @Test("用户点击设置后看到屏内且尺寸可用的设置窗口")
    func settingsActionPresentsUsableWindow() throws {
        let controller = makeController()
        let clock = ContinuousClock()
        let startedAt = clock.now
        controller.present()
        let presentationDuration = startedAt.duration(to: clock.now)

        let window = try settingsWindow()
        defer { window.performClose(nil) }
        #expect(window.isVisible)
        #expect(window.styleMask.contains(.resizable))
        #expect(window.contentLayoutRect.width >= 760)
        #expect(window.contentLayoutRect.height >= 560)
        #expect(window.contentMinSize.width >= 720)
        #expect(window.contentMinSize.height >= 520)
        let visibleFrame = try #require(window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        #expect(visibleFrame.intersects(window.frame))
        #expect(presentationDuration < .seconds(1))
    }

    @MainActor
    @Test("重复点击设置只置前同一个窗口")
    func repeatedSettingsActionReusesWindow() throws {
        let controller = makeController()
        controller.present()
        let original = try settingsWindow()
        defer { original.performClose(nil) }
        original.orderOut(nil)
        #expect(!original.isVisible)

        controller.present()

        let visibleWindows = NSApp.windows.filter { $0.title == "AwaitCue 设置" && $0.isVisible }
        #expect(visibleWindows.count == 1)
        #expect(visibleWindows.first === original)
    }

    @MainActor
    @Test("用户关闭设置后下一次点击可以显示全新窗口")
    func closingSettingsAllowsOpeningAgain() throws {
        let controller = makeController()
        controller.present()
        let first = try settingsWindow()
        first.performClose(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        controller.present()

        let second = try settingsWindow()
        defer { second.performClose(nil) }
        #expect(second.isVisible)
        #expect(second !== first)
    }

    @MainActor
    private func makeController() -> SettingsWindowController {
        SettingsWindowController(rootView: { AnyView(Text("设置测试内容")) })
    }

    @MainActor
    private func settingsWindow() throws -> NSWindow {
        try #require(NSApp.windows.first { $0.title == "AwaitCue 设置" && $0.isVisible })
    }
}
