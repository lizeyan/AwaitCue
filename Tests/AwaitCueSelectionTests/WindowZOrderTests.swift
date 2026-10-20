import AwaitCueCapture
import CoreGraphics
import Testing
@testable import AwaitCueSelection

@Suite("窗口前后顺序")
struct WindowZOrderTests {
    @Test("Core Graphics window ID 顺序决定 hit-test 前后关系")
    func ordersDiscoveredWindowsByExplicitIdentifiers() {
        let back = zOrderWindow(identifier: 91)
        let front = zOrderWindow(identifier: 92)
        let missingFromSystemList = zOrderWindow(identifier: 93)

        let ordered = WindowZOrder.order(
            [back, missingFromSystemList, front],
            identifiersFrontToBack: [92, 91]
        )

        #expect(ordered.map(\.windowIdentifier) == [92, 91, 93])
    }
}

private func zOrderWindow(identifier: UInt32) -> DiscoveredWindow {
    DiscoveredWindow(
        applicationBundleIdentifier: "com.example.\(identifier)",
        applicationName: "Window \(identifier)",
        windowIdentifier: identifier,
        title: "Window \(identifier)",
        frame: CGRect(x: 0, y: 0, width: 100, height: 100)
    )
}
