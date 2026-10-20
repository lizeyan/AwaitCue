import AppKit
import CoreGraphics

/// 用一组无边框 AppKit 窗口覆盖所有显示器并收集一次全局拖动手势。
@MainActor
final class AppKitGlobalSelectionOverlayPresenter: GlobalSelectionOverlayPresenting {
    private var continuation: CheckedContinuation<GlobalSelectionInteraction, any Error>?
    private var overlayWindows: [GlobalSelectionOverlayWindow] = []
    private var anchor: CGPoint?
    private var selectionRect: CGRect?

    /// 展示冻结桌面；同一个 presenter 同时只允许一轮选择。
    func select(in frames: [FrozenDisplayFrame]) async throws -> GlobalSelectionInteraction {
        guard continuation == nil else {
            throw GlobalSelectionControllerError.selectionAlreadyActive
        }
        guard !frames.isEmpty else {
            throw GlobalSelectionControllerError.noFrozenDisplays
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                presentOverlays(for: frames)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    /// 取消等待中的手势，并释放冻结截图所处的窗口层级。
    func cancel() {
        guard let continuation else {
            dismissOverlays()
            return
        }
        self.continuation = nil
        dismissOverlays()
        continuation.resume(throwing: GlobalSelectionControllerError.cancelled)
    }

    /// 为每个显示器创建一个独立窗口，使负坐标和不同缩放比例仍由 AppKit 正确路由事件。
    private func presentOverlays(for frames: [FrozenDisplayFrame]) {
        anchor = nil
        selectionRect = nil
        overlayWindows = frames.map { frame in
            let window = GlobalSelectionOverlayWindow(
                contentRect: frame.appKitFrame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            let view = GlobalSelectionOverlayView(
                frozenFrame: frame,
                onMouseDown: { [weak self] point in
                    self?.beginDrag(at: point)
                },
                onMouseDragged: { [weak self] point in
                    self?.updateDrag(to: point)
                },
                onMouseUp: { [weak self] point in
                    self?.finishDrag(at: point)
                },
                onCancel: { [weak self] in
                    self?.cancel()
                }
            )
            window.contentView = view
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            return window
        }

        // overlay 必须在截图完成后才激活；否则 AwaitCue 自己的窗口会进入冻结帧。
        NSApp.activate(ignoringOtherApps: true)
        for window in overlayWindows {
            window.orderFrontRegardless()
        }
        if
            let firstWindow = overlayWindows.first,
            let firstView = firstWindow.contentView
        {
            firstWindow.makeKey()
            firstWindow.makeFirstResponder(firstView)
        }
    }

    /// 记录 mouse-down 的全局 AppKit 坐标，后续窗口解析始终以这个锚点为准。
    private func beginDrag(at point: CGPoint) {
        anchor = point
        selectionRect = SelectionGeometry.dragRectangle(from: point, to: point)
        updateOverlaySelection()
    }

    /// 更新可能跨显示器的全局矩形，并让每个窗口仅绘制与自身相交的部分。
    private func updateDrag(to point: CGPoint) {
        guard let anchor else {
            return
        }
        selectionRect = SelectionGeometry.dragRectangle(from: anchor, to: point)
        updateOverlaySelection()
    }

    /// 完成手势并在关闭 overlay 后恢复异步调用方。
    private func finishDrag(at point: CGPoint) {
        updateDrag(to: point)
        guard
            let anchor,
            let selectionRect,
            let continuation
        else {
            return
        }

        self.continuation = nil
        dismissOverlays()
        continuation.resume(
            returning: GlobalSelectionInteraction(
                anchor: anchor,
                selectionRect: selectionRect
            )
        )
    }

    /// 将同一个全局框选矩形同步给所有显示器窗口。
    private func updateOverlaySelection() {
        for window in overlayWindows {
            (window.contentView as? GlobalSelectionOverlayView)?.selectionRect = selectionRect
        }
    }

    /// 关闭窗口并释放仅驻留内存的冻结截图。
    private func dismissOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.close()
        }
        overlayWindows.removeAll()
        anchor = nil
        selectionRect = nil
    }
}

/// borderless overlay 默认不能成为 key window；框选需要键盘 Escape 和跨窗拖动事件。
private final class GlobalSelectionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 绘制单个显示器冻结帧，并把鼠标事件转换为 AppKit 全局坐标。
@MainActor
final class GlobalSelectionOverlayView: NSView {
    private let frozenImage: NSImage
    private let globalFrame: CGRect
    private let onMouseDown: (CGPoint) -> Void
    private let onMouseDragged: (CGPoint) -> Void
    private let onMouseUp: (CGPoint) -> Void
    private let onCancel: () -> Void

    var selectionRect: CGRect? {
        didSet {
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    /// 非 key 显示器的首个 mouse-down 也必须开始框选，不能只用于激活窗口。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// 创建与一个显示器 frame 等大的绘制视图。
    init(
        frozenFrame: FrozenDisplayFrame,
        onMouseDown: @escaping (CGPoint) -> Void,
        onMouseDragged: @escaping (CGPoint) -> Void,
        onMouseUp: @escaping (CGPoint) -> Void,
        onCancel: @escaping () -> Void
    ) {
        frozenImage = NSImage(cgImage: frozenFrame.image, size: frozenFrame.appKitFrame.size)
        globalFrame = frozenFrame.appKitFrame
        self.onMouseDown = onMouseDown
        self.onMouseDragged = onMouseDragged
        self.onMouseUp = onMouseUp
        self.onCancel = onCancel
        super.init(frame: CGRect(origin: .zero, size: frozenFrame.appKitFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    /// 绘制冻结桌面、暗色遮罩和当前框选的正常亮度区域。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        frozenImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()

        guard let selectionRect else {
            return
        }
        let localSelection = selectionRect
            .offsetBy(dx: -globalFrame.minX, dy: -globalFrame.minY)
            .intersection(bounds)
        guard !localSelection.isNull, !localSelection.isEmpty else {
            return
        }

        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.clip(to: localSelection)
            frozenImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
            context.restoreGState()
        }
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: localSelection.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 2
        path.stroke()
    }

    /// 使用十字光标提示当前界面处于矩形选择模式。
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown(globalPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged(globalPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp(globalPoint(for: event))
    }

    /// Escape 取消整轮选择，其他按键继续交给 AppKit responder chain。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    /// 将窗口局部事件点转换成跨显示器一致的 AppKit 全局坐标。
    private func globalPoint(for event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }
}
