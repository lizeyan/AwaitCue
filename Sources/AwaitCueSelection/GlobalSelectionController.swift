import AppKit
import AwaitCueCapture
import AwaitCueCore
import CoreGraphics

/// overlay 完成的一次 AppKit 全局拖动手势。
struct GlobalSelectionInteraction: Equatable, Sendable {
    let anchor: CGPoint
    let selectionRect: CGRect
}

/// controller 与具体 AppKit 窗口实现之间的薄测试边界。
@MainActor
protocol GlobalSelectionOverlayPresenting: AnyObject {
    /// 展示所有冻结帧并等待用户完成一个全局矩形框选。
    func select(in frames: [FrozenDisplayFrame]) async throws -> GlobalSelectionInteraction

    /// 取消当前框选并关闭全部 overlay 窗口。
    func cancel()
}

/// 全局框选无法开始或被用户取消时的稳定错误。
public enum GlobalSelectionControllerError: Error, Equatable, Sendable {
    case selectionAlreadyActive
    case primaryDisplayUnavailable
    case noFrozenDisplays
    case windowOrderUnavailable
    case windowChangedDuringSelection
    case previewUnavailable
    case cancelled
}

/// 一次框选生成的稳定 Target 和仅包含所选区域的冻结预览图。
public struct GlobalSelectionResult: Sendable {
    public let target: HookTarget
    public let previewImage: CGImage

    /// 保存最终 Target 和已经脱离完整屏幕像素存储的区域预览。
    public init(target: HookTarget, previewImage: CGImage) {
        self.target = target
        self.previewImage = previewImage
    }
}

/// 冻结桌面、展示 AppKit overlay，并将手势解析为最终 HookTarget。
@MainActor
public final class GlobalSelectionController {
    private let frozenFrameProvider: any FrozenScreenFrameProviding
    private let discoverWindows: @Sendable () async throws -> [DiscoveredWindow]
    private let browserRelay: any BrowserSelectionRelaying
    private let overlayPresenter: any GlobalSelectionOverlayPresenting
    private let windowZOrderProvider: any WindowZOrderProviding
    private let primaryDisplayFrame: @MainActor @Sendable () -> CGRect?
    private var isSelecting = false

    /// 创建使用真实 ScreenCaptureKit、NSScreen 和 AppKit overlay 的 controller。
    public init(
        browserRelay: any BrowserSelectionRelaying,
        frozenFrameProvider: any FrozenScreenFrameProviding = ScreenCaptureKitFrozenScreenFrameProvider(),
        screenCaptureService: ScreenCaptureService = ScreenCaptureService()
    ) {
        self.frozenFrameProvider = frozenFrameProvider
        discoverWindows = {
            try await screenCaptureService.discoverWindows()
        }
        self.browserRelay = browserRelay
        overlayPresenter = AppKitGlobalSelectionOverlayPresenter()
        windowZOrderProvider = CoreGraphicsWindowZOrderProvider()
        primaryDisplayFrame = {
            NSScreen.screens.first?.frame
        }
    }

    /// 注入窗口发现和 overlay 边界，供模块验证 controller 编排行为。
    init(
        frozenFrameProvider: any FrozenScreenFrameProviding,
        discoverWindows: @escaping @Sendable () async throws -> [DiscoveredWindow],
        browserRelay: any BrowserSelectionRelaying,
        overlayPresenter: any GlobalSelectionOverlayPresenting,
        windowZOrderProvider: any WindowZOrderProviding = CoreGraphicsWindowZOrderProvider(),
        primaryDisplayFrame: @escaping @MainActor @Sendable () -> CGRect?
    ) {
        self.frozenFrameProvider = frozenFrameProvider
        self.discoverWindows = discoverWindows
        self.browserRelay = browserRelay
        self.overlayPresenter = overlayPresenter
        self.windowZOrderProvider = windowZOrderProvider
        self.primaryDisplayFrame = primaryDisplayFrame
    }

    /// 开始一次全局框选，并在普通窗口或 browser relay 之间生成唯一 Target。
    public func beginSelection() async throws -> HookTarget {
        try await performSelection().target
    }

    /// 开始一次全局框选，并保留创建前模型分析所需的精确区域截图。
    public func beginSelectionWithPreview() async throws -> GlobalSelectionResult {
        try await performSelection()
    }

    /// 统一执行冻结、框选、Target 解析和预览裁剪，避免两个公开入口产生不同验证顺序。
    private func performSelection() async throws -> GlobalSelectionResult {
        guard !isSelecting else {
            throw GlobalSelectionControllerError.selectionAlreadyActive
        }
        guard let primaryDisplayFrame = primaryDisplayFrame() else {
            throw GlobalSelectionControllerError.primaryDisplayUnavailable
        }

        isSelecting = true
        defer {
            overlayPresenter.cancel()
            isSelecting = false
        }

        // 先记录窗口身份和位置，再冻结显示器；选中后会与截图后的第二份快照比较。
        let discoveredWindows = try await discoverWindows()
        let orderedWindows = try windowZOrderProvider.orderFrontToBack(discoveredWindows)
        let frames = try await frozenFrameProvider.freezeDisplays()
        let windowsAfterFreeze = try await discoverWindows()
        guard !frames.isEmpty else {
            throw GlobalSelectionControllerError.noFrozenDisplays
        }

        let interaction = try await overlayPresenter.select(in: frames)
        let windowResolver = WindowSelectionResolver(
            coordinateConverter: SelectionCoordinateConverter(
                primaryDisplayFrame: primaryDisplayFrame
            )
        )
        let selection = try windowResolver.resolve(
            appKitSelectionRect: interaction.selectionRect,
            appKitAnchor: interaction.anchor,
            windowsFrontToBack: orderedWindows
        )
        guard Self.window(selection.window, stillMatches: windowsAfterFreeze) else {
            throw GlobalSelectionControllerError.windowChangedDuringSelection
        }
        let targetResolver = SelectionTargetResolver(
            windowResolver: windowResolver,
            browserRelay: browserRelay
        )
        let target = try await targetResolver.resolve(selection)
        let currentWindows = try await discoverWindows()
        guard Self.target(target, frozenWindows: orderedWindows, stillMatches: currentWindows) else {
            throw GlobalSelectionControllerError.windowChangedDuringSelection
        }
        return GlobalSelectionResult(
            target: target,
            previewImage: try Self.previewImage(
                for: interaction.selectionRect,
                in: frames
            )
        )
    }

    /// 取消当前手势并立即关闭所有 overlay 窗口。
    public func cancelSelection() {
        overlayPresenter.cancel()
    }

    private static func target(
        _ target: HookTarget,
        frozenWindows: [DiscoveredWindow],
        stillMatches windows: [DiscoveredWindow]
    ) -> Bool {
        let bundleIdentifier: String
        let windowIdentifier: UInt32
        switch target {
        case let .window(window):
            bundleIdentifier = window.applicationBundleIdentifier
            windowIdentifier = window.windowIdentifier
        case let .browser(browser):
            bundleIdentifier = browser.browserBundleIdentifier
            windowIdentifier = browser.nativeWindowIdentifier
        }
        guard let frozenWindow = frozenWindows.first(where: {
            $0.applicationBundleIdentifier == bundleIdentifier
                && $0.windowIdentifier == windowIdentifier
        }) else {
            return false
        }
        return window(frozenWindow, stillMatches: windows)
    }

    /// 要求同一 bundle/window ID 的 frame 在两个快照中保持不变。
    private static func window(
        _ frozenWindow: DiscoveredWindow,
        stillMatches windows: [DiscoveredWindow]
    ) -> Bool {
        guard let currentWindow = windows.first(where: {
            $0.applicationBundleIdentifier == frozenWindow.applicationBundleIdentifier
                && $0.windowIdentifier == frozenWindow.windowIdentifier
        }) else {
            return false
        }
        // 拖动期间窗口移动或缩放会让冻结画面和实际 Target 不再对应，必须让用户重新框选。
        return abs(frozenWindow.frame.minX - currentWindow.frame.minX) < 1
            && abs(frozenWindow.frame.minY - currentWindow.frame.minY) < 1
            && abs(frozenWindow.frame.width - currentWindow.frame.width) < 1
            && abs(frozenWindow.frame.height - currentWindow.frame.height) < 1
    }

    /// 将 AppKit 左下原点的框选换算为冻结帧左上原点的像素矩形，并复制成独立图像。
    private static func previewImage(
        for selectionRect: CGRect,
        in frames: [FrozenDisplayFrame]
    ) throws -> CGImage {
        guard let frame = frames.first(where: { $0.appKitFrame.contains(selectionRect) }) else {
            // 跨显示器区域无法由单个冻结帧完整表达；不能用部分截图伪装成完整证据。
            throw GlobalSelectionControllerError.previewUnavailable
        }
        let region = NormalizedRegion(
            x: (selectionRect.minX - frame.appKitFrame.minX) / frame.appKitFrame.width,
            y: (frame.appKitFrame.maxY - selectionRect.maxY) / frame.appKitFrame.height,
            width: selectionRect.width / frame.appKitFrame.width,
            height: selectionRect.height / frame.appKitFrame.height
        )
        do {
            // 复用窗口截图已经验证过的向外取整和独立像素复制，避免两套裁剪规则漂移。
            return try ScreenCaptureService.croppedImage(frame.image, to: region)
        } catch {
            throw GlobalSelectionControllerError.previewUnavailable
        }
    }
}
