import AwaitCueCapture
import AwaitCueCore
import CoreGraphics
import Testing
@testable import AwaitCueSelection

@Suite("单窗口 Target 解析")
struct WindowSelectionResolverTests {
    @Test("按鼠标按下位置选择最前窗口并生成精确 WindowTarget")
    func resolvesFrontmostWindowAtSelectionAnchor() throws {
        let resolver = WindowSelectionResolver(
            coordinateConverter: SelectionCoordinateConverter(
                primaryDisplayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            )
        )
        let frontWindow = fixtureWindow(
            bundleIdentifier: "com.example.front",
            windowIdentifier: 41,
            title: "Front",
            frame: CGRect(x: 100, y: 100, width: 400, height: 300)
        )
        let backWindow = fixtureWindow(
            bundleIdentifier: "com.example.back",
            windowIdentifier: 42,
            title: "Back",
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        let selection = try resolver.resolve(
            appKitSelectionRect: CGRect(x: 150, y: 550, width: 100, height: 100),
            appKitAnchor: CGPoint(x: 160, y: 640),
            windowsFrontToBack: [frontWindow, backWindow]
        )

        #expect(selection.window == frontWindow)
        #expect(selection.screenCaptureRect == CGRect(x: 150, y: 150, width: 100, height: 100))
        #expect(
            selection.windowTarget
                == WindowTarget(
                    applicationBundleIdentifier: "com.example.front",
                    windowIdentifier: 41,
                    initialTitle: "Front",
                    normalizedRegion: NormalizedRegion(
                        x: 0.125,
                        y: 1.0 / 6.0,
                        width: 0.25,
                        height: 1.0 / 3.0
                    )
                )
        )
    }

    @Test("框选越过按下时窗口边界不会改绑到后方窗口")
    func crossingAnchoredWindowDoesNotRebindToBackgroundWindow() {
        let resolver = WindowSelectionResolver(
            coordinateConverter: SelectionCoordinateConverter(
                primaryDisplayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            )
        )
        let frontWindow = fixtureWindow(
            bundleIdentifier: "com.example.front",
            windowIdentifier: 51,
            title: "Front",
            frame: CGRect(x: 100, y: 100, width: 300, height: 300)
        )
        let backgroundWindow = fixtureWindow(
            bundleIdentifier: "com.example.back",
            windowIdentifier: 52,
            title: "Back",
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        #expect(throws: WindowSelectionError.selectionCrossesWindowBoundary) {
            try resolver.resolve(
                appKitSelectionRect: CGRect(x: 150, y: 300, width: 400, height: 350),
                appKitAnchor: CGPoint(x: 160, y: 640),
                windowsFrontToBack: [frontWindow, backgroundWindow]
            )
        }
    }

    @Test("按下位置没有窗口时拒绝创建 Target")
    func missingWindowAtAnchorIsRejected() {
        let resolver = WindowSelectionResolver(
            coordinateConverter: SelectionCoordinateConverter(
                primaryDisplayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            )
        )

        #expect(throws: WindowSelectionError.noWindowAtSelectionStart) {
            try resolver.resolve(
                appKitSelectionRect: CGRect(x: 700, y: 600, width: 50, height: 50),
                appKitAnchor: CGPoint(x: 710, y: 620),
                windowsFrontToBack: [
                    fixtureWindow(
                        bundleIdentifier: "com.example.editor",
                        windowIdentifier: 61,
                        title: "Editor",
                        frame: CGRect(x: 0, y: 0, width: 400, height: 400)
                    )
                ]
            )
        }
    }
}

private func fixtureWindow(
    bundleIdentifier: String,
    windowIdentifier: UInt32,
    title: String,
    frame: CGRect
) -> DiscoveredWindow {
    DiscoveredWindow(
        applicationBundleIdentifier: bundleIdentifier,
        applicationName: bundleIdentifier,
        windowIdentifier: windowIdentifier,
        title: title,
        frame: frame
    )
}
