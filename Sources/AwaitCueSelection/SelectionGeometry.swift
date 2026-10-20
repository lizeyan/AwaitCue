import AwaitCueCore
import CoreGraphics

/// AppKit 全局左下原点与 ScreenCaptureKit 全局左上原点之间的坐标转换器。
public struct SelectionCoordinateConverter: Equatable, Sendable {
    private let primaryDisplayTop: CGFloat

    /// 使用主显示器的 AppKit frame 固定两套全局坐标的共同水平基线。
    public init(primaryDisplayFrame: CGRect) {
        primaryDisplayTop = primaryDisplayFrame.maxY
    }

    /// 将 AppKit 全局点转换为 ScreenCaptureKit 全局点。
    public func screenCapturePoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayTop - point.y)
    }

    /// 将 AppKit 全局矩形转换为 ScreenCaptureKit 全局矩形。
    public func screenCaptureRect(fromAppKit rect: CGRect) -> CGRect {
        let rect = rect.standardized
        return CGRect(
            x: rect.minX,
            y: primaryDisplayTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 将 ScreenCaptureKit 全局矩形转换为 AppKit 全局矩形。
    public func appKitRect(fromScreenCapture rect: CGRect) -> CGRect {
        let rect = rect.standardized
        return CGRect(
            x: rect.minX,
            y: primaryDisplayTop - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

/// 选择区域无法稳定绑定到一个窗口时返回的几何错误。
public enum SelectionGeometryError: Error, Equatable, Sendable {
    case emptySelection
    case invalidWindowFrame
    case selectionOutsideWindow
}

/// 全局框选矩形和窗口归一化区域所需的纯几何运算。
public enum SelectionGeometry {
    /// 根据拖动起点和当前点生成正宽高矩形。
    public static func dragRectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// 将 ScreenCaptureKit 全局框选矩形换算为窗口内部的左上原点比例区域。
    public static func normalizedRegion(
        for selectionRect: CGRect,
        in windowFrame: CGRect
    ) throws -> NormalizedRegion {
        let selectionRect = selectionRect.standardized
        let windowFrame = windowFrame.standardized
        guard isUsable(windowFrame) else {
            throw SelectionGeometryError.invalidWindowFrame
        }
        guard isUsable(selectionRect) else {
            throw SelectionGeometryError.emptySelection
        }
        guard contains(windowFrame, rect: selectionRect) else {
            throw SelectionGeometryError.selectionOutsideWindow
        }

        let region = NormalizedRegion(
            x: Double((selectionRect.minX - windowFrame.minX) / windowFrame.width),
            y: Double((selectionRect.minY - windowFrame.minY) / windowFrame.height),
            width: Double(selectionRect.width / windowFrame.width),
            height: Double(selectionRect.height / windowFrame.height)
        )
        guard region.isValid else {
            throw SelectionGeometryError.selectionOutsideWindow
        }
        return region
    }

    /// 判断点是否落在矩形闭区间内，允许用户从窗口边缘开始拖动。
    public static func contains(_ outerRect: CGRect, point: CGPoint) -> Bool {
        let outerRect = outerRect.standardized
        return point.x >= outerRect.minX
            && point.x <= outerRect.maxX
            && point.y >= outerRect.minY
            && point.y <= outerRect.maxY
    }

    /// 判断内部矩形是否完整落在外部矩形闭区间内。
    public static func contains(_ outerRect: CGRect, rect innerRect: CGRect) -> Bool {
        let outerRect = outerRect.standardized
        let innerRect = innerRect.standardized
        return innerRect.minX >= outerRect.minX
            && innerRect.maxX <= outerRect.maxX
            && innerRect.minY >= outerRect.minY
            && innerRect.maxY <= outerRect.maxY
    }

    /// 判断矩形是否具有有限坐标和正面积。
    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }
}
