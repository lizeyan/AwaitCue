import AwaitCueCapture
import AwaitCueCore
import CoreGraphics

/// 全局框选无法稳定绑定到鼠标按下时窗口的原因。
public enum WindowSelectionError: Error, Equatable, Sendable {
    case noWindowAtSelectionStart
    case selectionCrossesWindowBoundary
}

/// 已解析到一个具体 ScreenCaptureKit 窗口、但尚未经过浏览器 relay 分类的框选。
public struct ResolvedWindowSelection: Equatable, Sendable {
    public let window: DiscoveredWindow
    public let screenCaptureRect: CGRect
    public let normalizedRegion: NormalizedRegion

    /// 仅在 relay 明确确认该窗口不是浏览器后，生成普通窗口 Target。
    public var windowTarget: WindowTarget {
        WindowTarget(
            applicationBundleIdentifier: window.applicationBundleIdentifier,
            windowIdentifier: window.windowIdentifier,
            initialTitle: window.title,
            normalizedRegion: normalizedRegion
        )
    }

    /// 保存精确窗口身份和框选几何，不按标题查找其他窗口。
    init(
        window: DiscoveredWindow,
        screenCaptureRect: CGRect,
        normalizedRegion: NormalizedRegion
    ) {
        self.window = window
        self.screenCaptureRect = screenCaptureRect
        self.normalizedRegion = normalizedRegion
    }
}

/// 用鼠标按下时的前后顺序命中窗口，并强制整个框选留在同一个窗口内。
public struct WindowSelectionResolver: Equatable, Sendable {
    public let coordinateConverter: SelectionCoordinateConverter

    /// 创建使用固定桌面坐标转换规则的单窗口解析器。
    public init(coordinateConverter: SelectionCoordinateConverter) {
        self.coordinateConverter = coordinateConverter
    }

    /// 将 AppKit 全局框选解析成一个精确窗口候选。
    public func resolve(
        appKitSelectionRect: CGRect,
        appKitAnchor: CGPoint,
        windowsFrontToBack: [DiscoveredWindow]
    ) throws -> ResolvedWindowSelection {
        let screenCaptureAnchor = coordinateConverter.screenCapturePoint(fromAppKit: appKitAnchor)
        guard let window = windowsFrontToBack.first(where: { candidate in
            SelectionGeometry.contains(candidate.frame, point: screenCaptureAnchor)
        }) else {
            throw WindowSelectionError.noWindowAtSelectionStart
        }

        let screenCaptureRect = coordinateConverter.screenCaptureRect(
            fromAppKit: appKitSelectionRect
        )
        guard SelectionGeometry.contains(window.frame, rect: screenCaptureRect) else {
            throw WindowSelectionError.selectionCrossesWindowBoundary
        }
        let normalizedRegion = try SelectionGeometry.normalizedRegion(
            for: screenCaptureRect,
            in: window.frame
        )
        return ResolvedWindowSelection(
            window: window,
            screenCaptureRect: screenCaptureRect,
            normalizedRegion: normalizedRegion
        )
    }
}
