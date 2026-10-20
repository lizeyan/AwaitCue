import CoreGraphics
import Testing
@testable import AwaitCueSelection
import AwaitCueCore

@Suite("框选坐标几何")
struct SelectionGeometryTests {
    @Test("AppKit 与 ScreenCaptureKit 全局坐标在多显示器桌面中可逆")
    func globalCoordinateConversionIsReversibleAcrossDisplays() {
        let converter = SelectionCoordinateConverter(
            primaryDisplayFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let primaryRect = CGRect(x: 100, y: 100, width: 200, height: 150)
        let abovePrimaryRect = CGRect(x: -500, y: 1_000, width: 300, height: 200)
        let belowPrimaryRect = CGRect(x: 200, y: -600, width: 250, height: 100)

        #expect(
            converter.screenCaptureRect(fromAppKit: primaryRect)
                == CGRect(x: 100, y: 650, width: 200, height: 150)
        )
        #expect(
            converter.screenCaptureRect(fromAppKit: abovePrimaryRect)
                == CGRect(x: -500, y: -300, width: 300, height: 200)
        )
        #expect(
            converter.screenCaptureRect(fromAppKit: belowPrimaryRect)
                == CGRect(x: 200, y: 1_400, width: 250, height: 100)
        )
        #expect(
            converter.appKitRect(
                fromScreenCapture: converter.screenCaptureRect(fromAppKit: abovePrimaryRect)
            ) == abovePrimaryRect
        )
    }

    @Test("任意拖动方向都会生成标准化矩形")
    func dragRectangleIsStandardized() {
        #expect(
            SelectionGeometry.dragRectangle(
                from: CGPoint(x: 500, y: 400),
                to: CGPoint(x: 100, y: 150)
            ) == CGRect(x: 100, y: 150, width: 400, height: 250)
        )
    }

    @Test("窗口内矩形转换为左上原点归一化区域")
    func selectionNormalizesWithinWindow() throws {
        let region = try SelectionGeometry.normalizedRegion(
            for: CGRect(x: 300, y: 350, width: 400, height: 300),
            in: CGRect(x: 100, y: 200, width: 800, height: 600)
        )

        #expect(region == NormalizedRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    @Test("空框选、无效窗口和跨窗口矩形会被拒绝")
    func invalidSelectionGeometryIsRejected() {
        #expect(throws: SelectionGeometryError.emptySelection) {
            try SelectionGeometry.normalizedRegion(
                for: CGRect(x: 100, y: 100, width: 0, height: 20),
                in: CGRect(x: 0, y: 0, width: 500, height: 500)
            )
        }
        #expect(throws: SelectionGeometryError.invalidWindowFrame) {
            try SelectionGeometry.normalizedRegion(
                for: CGRect(x: 100, y: 100, width: 20, height: 20),
                in: .zero
            )
        }
        #expect(throws: SelectionGeometryError.selectionOutsideWindow) {
            try SelectionGeometry.normalizedRegion(
                for: CGRect(x: 450, y: 450, width: 100, height: 100),
                in: CGRect(x: 0, y: 0, width: 500, height: 500)
            )
        }
    }
}
