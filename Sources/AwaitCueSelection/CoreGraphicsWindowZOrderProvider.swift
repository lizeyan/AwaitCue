import AwaitCueCapture
import CoreGraphics
import Foundation

/// 使用 Core Graphics on-screen window list 提供有文档约束的窗口前后顺序。
struct CoreGraphicsWindowZOrderProvider: WindowZOrderProviding {
    /// 按 CGWindowList 的前后顺序关联 ScreenCaptureKit window ID。
    func orderFrontToBack(_ windows: [DiscoveredWindow]) throws -> [DiscoveredWindow] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            throw GlobalSelectionControllerError.windowOrderUnavailable
        }
        let windowNumberKey = kCGWindowNumber as String
        let identifiers = windowInfo.compactMap { entry in
            (entry[windowNumberKey] as? NSNumber)?.uint32Value
        }
        return WindowZOrder.order(windows, identifiersFrontToBack: identifiers)
    }
}
