import AppKit
import AwaitCueCapture
import AwaitCueCore
import CoreGraphics
import Foundation
import Testing
@testable import AwaitCueSelection

@Suite("全局框选 controller")
struct GlobalSelectionControllerTests {
    @MainActor
    @Test("非 key 显示器 overlay 接受第一次鼠标拖动")
    func overlayAcceptsFirstMouse() {
        let frame = FrozenDisplayFrame(
            displayIdentifier: 2,
            appKitFrame: CGRect(x: 1_000, y: 0, width: 800, height: 600),
            image: fixtureControllerImage()
        )
        let view = GlobalSelectionOverlayView(
            frozenFrame: frame,
            onMouseDown: { _ in },
            onMouseDragged: { _ in },
            onMouseUp: { _ in },
            onCancel: {}
        )

        #expect(view.acceptsFirstMouse(for: nil))
    }

    @MainActor
    @Test("默认 controller 构造不会提前请求屏幕权限")
    func defaultControllerCanBeConstructedWithoutStartingSelection() {
        let controller = GlobalSelectionController(browserRelay: FixtureControllerBrowserRelay())
        controller.cancelSelection()
    }

    @MainActor
    @Test("controller 使用冻结帧和鼠标手势生成最终 Target")
    func controllerResolvesOverlayInteraction() async throws {
        let frozenImage = fixtureControllerImage()
        let frameProvider = FixtureFrozenScreenFrameProvider(
            frames: [
                FrozenDisplayFrame(
                    displayIdentifier: 1,
                    appKitFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                    image: frozenImage
                )
            ]
        )
        let presenter = FixtureGlobalSelectionOverlayPresenter(
            interaction: GlobalSelectionInteraction(
                anchor: CGPoint(x: 130, y: 640),
                selectionRect: CGRect(x: 120, y: 570, width: 100, height: 80)
            )
        )
        let relay = FixtureControllerBrowserRelay()
        let controller = GlobalSelectionController(
            frozenFrameProvider: frameProvider,
            discoverWindows: {
                [
                    DiscoveredWindow(
                        applicationBundleIdentifier: "com.example.editor",
                        applicationName: "Editor",
                        windowIdentifier: 81,
                        title: "Document",
                        frame: CGRect(x: 100, y: 100, width: 400, height: 400)
                    )
                ]
            },
            browserRelay: relay,
            overlayPresenter: presenter,
            windowZOrderProvider: FixtureWindowZOrderProvider(),
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 1_000, height: 800) }
        )

        let target = try await controller.beginSelection()

        #expect(
            target
                == .window(
                    WindowTarget(
                        applicationBundleIdentifier: "com.example.editor",
                        windowIdentifier: 81,
                        initialTitle: "Document",
                        normalizedRegion: NormalizedRegion(
                            x: 0.05,
                            y: 0.125,
                            width: 0.25,
                            height: 0.2
                        )
                    )
                )
        )
        #expect(presenter.receivedFrameIdentifiers == [1])
    }

    @MainActor
    @Test("创建前分析获得框选区域的冻结截图而不是完整屏幕")
    func controllerReturnsSelectedPreviewImage() async throws {
        let controller = GlobalSelectionController(
            frozenFrameProvider: FixtureFrozenScreenFrameProvider(
                frames: [
                    FrozenDisplayFrame(
                        displayIdentifier: 1,
                        appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 50),
                        image: fixtureControllerImage(width: 200, height: 100)
                    )
                ]
            ),
            discoverWindows: {
                [
                    DiscoveredWindow(
                        applicationBundleIdentifier: "com.example.editor",
                        applicationName: "Editor",
                        windowIdentifier: 82,
                        title: "Document",
                        frame: CGRect(x: 0, y: 0, width: 100, height: 50)
                    )
                ]
            },
            browserRelay: FixtureControllerBrowserRelay(),
            overlayPresenter: FixtureGlobalSelectionOverlayPresenter(
                interaction: GlobalSelectionInteraction(
                    anchor: CGPoint(x: 25, y: 15),
                    selectionRect: CGRect(x: 20, y: 10, width: 40, height: 20)
                )
            ),
            windowZOrderProvider: FixtureWindowZOrderProvider(),
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 100, height: 50) }
        )

        let result = try await controller.beginSelectionWithPreview()

        // 比例换算沿用截图模块的向外取整；浮点边界可能多保留一行或一列像素。
        #expect((80 ... 81).contains(result.previewImage.width))
        #expect((40 ... 41).contains(result.previewImage.height))
    }

    @MainActor
    @Test("跨显示器框选不会把部分冻结画面冒充成完整预览")
    func controllerRejectsCrossDisplayPreview() async {
        let window = DiscoveredWindow(
            applicationBundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            windowIdentifier: 83,
            title: "Spanning document",
            frame: CGRect(x: 70, y: 30, width: 70, height: 40)
        )
        let controller = GlobalSelectionController(
            frozenFrameProvider: FixtureFrozenScreenFrameProvider(
                frames: [
                    FrozenDisplayFrame(
                        displayIdentifier: 1,
                        appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                        image: fixtureControllerImage(width: 100, height: 100)
                    ),
                    FrozenDisplayFrame(
                        displayIdentifier: 2,
                        appKitFrame: CGRect(x: 100, y: 0, width: 100, height: 100),
                        image: fixtureControllerImage(width: 100, height: 100)
                    ),
                ]
            ),
            discoverWindows: { [window] },
            browserRelay: FixtureControllerBrowserRelay(),
            overlayPresenter: FixtureGlobalSelectionOverlayPresenter(
                interaction: GlobalSelectionInteraction(
                    anchor: CGPoint(x: 90, y: 50),
                    selectionRect: CGRect(x: 80, y: 40, width: 40, height: 20)
                )
            ),
            windowZOrderProvider: FixtureWindowZOrderProvider(),
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 200, height: 100) }
        )

        await #expect(throws: GlobalSelectionControllerError.previewUnavailable) {
            try await controller.beginSelectionWithPreview()
        }
    }

    @MainActor
    @Test("缺少主显示器或冻结帧时返回稳定错误并清理 overlay")
    func controllerRejectsUnavailableDesktop() async {
        let presenter = ThrowingGlobalSelectionOverlayPresenter(error: GlobalSelectionControllerError.cancelled)
        let noPrimary = GlobalSelectionController(
            frozenFrameProvider: FixtureFrozenScreenFrameProvider(frames: []),
            discoverWindows: { [] },
            browserRelay: FixtureControllerBrowserRelay(),
            overlayPresenter: presenter,
            windowZOrderProvider: FixtureWindowZOrderProvider(),
            primaryDisplayFrame: { nil }
        )
        await #expect(throws: GlobalSelectionControllerError.primaryDisplayUnavailable) {
            try await noPrimary.beginSelection()
        }

        let noFrames = GlobalSelectionController(
            frozenFrameProvider: FixtureFrozenScreenFrameProvider(frames: []),
            discoverWindows: { [] },
            browserRelay: FixtureControllerBrowserRelay(),
            overlayPresenter: presenter,
            windowZOrderProvider: FixtureWindowZOrderProvider(),
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 100, height: 100) }
        )
        await #expect(throws: GlobalSelectionControllerError.noFrozenDisplays) {
            try await noFrames.beginSelection()
        }
        #expect(presenter.cancelCount == 1)
    }

    @MainActor
    @Test("overlay 取消和窗口顺序失败都会关闭全部 overlay")
    func controllerCleansUpAfterFailures() async {
        let image = fixtureControllerImage()
        let frames = [FrozenDisplayFrame(displayIdentifier: 1, appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100), image: image)]
        let cancelledPresenter = ThrowingGlobalSelectionOverlayPresenter(error: GlobalSelectionControllerError.cancelled)
        let cancelled = GlobalSelectionController(
            frozenFrameProvider: FixtureFrozenScreenFrameProvider(frames: frames),
            discoverWindows: { [] },
            browserRelay: FixtureControllerBrowserRelay(),
            overlayPresenter: cancelledPresenter,
            windowZOrderProvider: FixtureWindowZOrderProvider(),
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 100, height: 100) }
        )
        await #expect(throws: GlobalSelectionControllerError.cancelled) {
            try await cancelled.beginSelection()
        }
        #expect(cancelledPresenter.cancelCount == 1)

        let interactionPresenter = FixtureGlobalSelectionOverlayPresenter(
            interaction: GlobalSelectionInteraction(anchor: .zero, selectionRect: CGRect(x: 0, y: 0, width: 10, height: 10))
        )
        let orderingFailure = GlobalSelectionController(
            frozenFrameProvider: FixtureFrozenScreenFrameProvider(frames: frames),
            discoverWindows: { [] },
            browserRelay: FixtureControllerBrowserRelay(),
            overlayPresenter: interactionPresenter,
            windowZOrderProvider: ThrowingWindowZOrderProvider(),
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 100, height: 100) }
        )
        await #expect(throws: GlobalSelectionControllerError.windowOrderUnavailable) {
            try await orderingFailure.beginSelection()
        }
    }

    @MainActor
    @Test("同一时间只允许一次框选且显式取消会结束当前手势")
    func controllerPreventsConcurrentSelectionsAndCancelsActiveGesture() async {
        let image = fixtureControllerImage()
        let presenter = BlockingGlobalSelectionOverlayPresenter()
        let controller = GlobalSelectionController(
            frozenFrameProvider: FixtureFrozenScreenFrameProvider(
                frames: [FrozenDisplayFrame(displayIdentifier: 1, appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100), image: image)]
            ),
            discoverWindows: { [] },
            browserRelay: FixtureControllerBrowserRelay(),
            overlayPresenter: presenter,
            windowZOrderProvider: FixtureWindowZOrderProvider(),
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 100, height: 100) }
        )
        let activeSelection = Task { try await controller.beginSelection() }
        await presenter.waitUntilPresented()

        await #expect(throws: GlobalSelectionControllerError.selectionAlreadyActive) {
            try await controller.beginSelection()
        }
        controller.cancelSelection()
        await #expect(throws: GlobalSelectionControllerError.cancelled) {
            try await activeSelection.value
        }
    }

    @MainActor
    @Test("拖动期间窗口移动时拒绝把冻结区域绑定到新位置")
    func controllerRejectsWindowMovementDuringSelection() async {
        let image = fixtureControllerImage()
        let original = DiscoveredWindow(
            applicationBundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            windowIdentifier: 95,
            title: "Document",
            frame: CGRect(x: 100, y: 100, width: 400, height: 400)
        )
        let moved = DiscoveredWindow(
            applicationBundleIdentifier: original.applicationBundleIdentifier,
            applicationName: original.applicationName,
            windowIdentifier: original.windowIdentifier,
            title: original.title,
            frame: CGRect(x: 120, y: 100, width: 400, height: 400)
        )
        let discovery = SequencedWindowDiscovery(results: [[original], [moved]])
        let relay = FixtureControllerBrowserRelay()
        let controller = GlobalSelectionController(
            frozenFrameProvider: FixtureFrozenScreenFrameProvider(
                frames: [FrozenDisplayFrame(displayIdentifier: 1, appKitFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), image: image)]
            ),
            discoverWindows: { try await discovery.next() },
            browserRelay: relay,
            overlayPresenter: FixtureGlobalSelectionOverlayPresenter(
                interaction: GlobalSelectionInteraction(
                    anchor: CGPoint(x: 130, y: 640),
                    selectionRect: CGRect(x: 120, y: 570, width: 100, height: 80)
                )
            ),
            windowZOrderProvider: FixtureWindowZOrderProvider(),
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 1_000, height: 800) }
        )

        await #expect(throws: GlobalSelectionControllerError.windowChangedDuringSelection) {
            try await controller.beginSelection()
        }
        #expect(await relay.resolveCallCount == 0)
    }

    @MainActor
    @Test("Target 解析后窗口消失时拒绝返回冻结位置")
    func controllerRejectsWindowDisappearingAfterTargetResolution() async {
        let image = fixtureControllerImage()
        let original = fixtureDiscoveredWindow(identifier: 96)
        let discovery = SequencedWindowDiscovery(results: [[original], [original], []])
        let controller = GlobalSelectionController(
            frozenFrameProvider: FixtureFrozenScreenFrameProvider(
                frames: [FrozenDisplayFrame(displayIdentifier: 1, appKitFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), image: image)]
            ),
            discoverWindows: { try await discovery.next() },
            browserRelay: FixtureControllerBrowserRelay(),
            overlayPresenter: fixtureSelectionPresenter(),
            windowZOrderProvider: FixtureWindowZOrderProvider(),
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 1_000, height: 800) }
        )

        await #expect(throws: GlobalSelectionControllerError.windowChangedDuringSelection) {
            try await controller.beginSelection()
        }
    }

    @MainActor
    @Test("浏览器 Target 使用 native window 身份完成最终稳定性校验")
    func controllerValidatesResolvedBrowserWindowIdentity() async throws {
        let image = fixtureControllerImage()
        let original = fixtureDiscoveredWindow(identifier: 97)
        let target = BrowserTarget(
            browserBundleIdentifier: original.applicationBundleIdentifier,
            nativeWindowIdentifier: original.windowIdentifier,
            extensionInstallationID: "chrome.runtime.id:test",
            tabIdentifier: 7,
            host: "example.com",
            initialURL: URL(string: "https://example.com/build")!,
            initialTitle: "Build",
            normalizedRegion: NormalizedRegion(x: 0.05, y: 0.125, width: 0.25, height: 0.2),
            observationMode: .domAndImage
        )
        let relay = FixtureControllerBrowserRelay(
            resolution: .resolved(target),
            previewDOMText: "[10,20] Build succeeded"
        )
        let controller = GlobalSelectionController(
            frozenFrameProvider: FixtureFrozenScreenFrameProvider(
                frames: [FrozenDisplayFrame(displayIdentifier: 1, appKitFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), image: image)]
            ),
            discoverWindows: { [original] },
            browserRelay: relay,
            overlayPresenter: fixtureSelectionPresenter(),
            windowZOrderProvider: FixtureWindowZOrderProvider(),
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 1_000, height: 800) }
        )

        let result = try await controller.beginSelectionWithPreview()
        #expect(result.target == .browser(target))
        #expect(result.browserDOMText == "[10,20] Build succeeded")
    }

    @MainActor
    @Test("浏览器 relay 返回另一 native window 时拒绝目标")
    func controllerRejectsBrowserTargetFromAnotherWindow() async {
        let image = fixtureControllerImage()
        let original = fixtureDiscoveredWindow(identifier: 98)
        let mismatched = BrowserTarget(
            browserBundleIdentifier: original.applicationBundleIdentifier,
            nativeWindowIdentifier: 999,
            extensionInstallationID: "chrome.runtime.id:test",
            tabIdentifier: 8,
            host: "example.com",
            initialURL: URL(string: "https://example.com")!,
            initialTitle: "Example",
            normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1),
            observationMode: .dom
        )
        let controller = GlobalSelectionController(
            frozenFrameProvider: FixtureFrozenScreenFrameProvider(
                frames: [FrozenDisplayFrame(displayIdentifier: 1, appKitFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800), image: image)]
            ),
            discoverWindows: { [original] },
            browserRelay: FixtureControllerBrowserRelay(resolution: .resolved(mismatched)),
            overlayPresenter: fixtureSelectionPresenter(),
            windowZOrderProvider: FixtureWindowZOrderProvider(),
            primaryDisplayFrame: { CGRect(x: 0, y: 0, width: 1_000, height: 800) }
        )

        await #expect(throws: GlobalSelectionControllerError.windowChangedDuringSelection) {
            try await controller.beginSelection()
        }
    }
}

@MainActor
private final class ThrowingGlobalSelectionOverlayPresenter: GlobalSelectionOverlayPresenting {
    let error: any Error
    private(set) var cancelCount = 0

    init(error: any Error) {
        self.error = error
    }

    func select(in frames: [FrozenDisplayFrame]) async throws -> GlobalSelectionInteraction {
        throw error
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
private final class BlockingGlobalSelectionOverlayPresenter: GlobalSelectionOverlayPresenting {
    private var continuation: CheckedContinuation<GlobalSelectionInteraction, any Error>?

    func select(in frames: [FrozenDisplayFrame]) async throws -> GlobalSelectionInteraction {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        continuation?.resume(throwing: GlobalSelectionControllerError.cancelled)
        continuation = nil
    }

    func waitUntilPresented() async {
        while continuation == nil {
            await Task.yield()
        }
    }
}

@MainActor
private final class FixtureFrozenScreenFrameProvider: FrozenScreenFrameProviding {
    private let frames: [FrozenDisplayFrame]

    init(frames: [FrozenDisplayFrame]) {
        self.frames = frames
    }

    func freezeDisplays() async throws -> [FrozenDisplayFrame] {
        frames
    }
}

@MainActor
private final class FixtureGlobalSelectionOverlayPresenter: GlobalSelectionOverlayPresenting {
    private let interaction: GlobalSelectionInteraction
    private(set) var receivedFrameIdentifiers: [UInt32] = []

    init(interaction: GlobalSelectionInteraction) {
        self.interaction = interaction
    }

    func select(in frames: [FrozenDisplayFrame]) async throws -> GlobalSelectionInteraction {
        receivedFrameIdentifiers = frames.map(\.displayIdentifier)
        return interaction
    }

    func cancel() {}
}

private actor FixtureControllerBrowserRelay: BrowserSelectionRelaying {
    private let resolution: BrowserSelectionRelayResolution
    private let previewDOMText: String?
    private(set) var resolveCallCount = 0

    init(
        resolution: BrowserSelectionRelayResolution = .notBrowser,
        previewDOMText: String? = nil
    ) {
        self.resolution = resolution
        self.previewDOMText = previewDOMText
    }

    func resolveBrowserTarget(
        for selection: ResolvedWindowSelection
    ) async throws -> BrowserSelectionRelayResolution {
        resolveCallCount += 1
        return resolution
    }

    func previewDOMText(for target: BrowserTarget) async -> String? {
        previewDOMText
    }
}

@MainActor
private func fixtureSelectionPresenter() -> FixtureGlobalSelectionOverlayPresenter {
    FixtureGlobalSelectionOverlayPresenter(
        interaction: GlobalSelectionInteraction(
            anchor: CGPoint(x: 130, y: 640),
            selectionRect: CGRect(x: 120, y: 570, width: 100, height: 80)
        )
    )
}

private func fixtureDiscoveredWindow(identifier: UInt32) -> DiscoveredWindow {
    DiscoveredWindow(
        applicationBundleIdentifier: "com.example.editor",
        applicationName: "Editor",
        windowIdentifier: identifier,
        title: "Document",
        frame: CGRect(x: 100, y: 100, width: 400, height: 400)
    )
}

private struct FixtureWindowZOrderProvider: WindowZOrderProviding {
    func orderFrontToBack(_ windows: [DiscoveredWindow]) throws -> [DiscoveredWindow] {
        windows
    }
}

private struct ThrowingWindowZOrderProvider: WindowZOrderProviding {
    func orderFrontToBack(_ windows: [DiscoveredWindow]) throws -> [DiscoveredWindow] {
        throw GlobalSelectionControllerError.windowOrderUnavailable
    }
}

private actor SequencedWindowDiscovery {
    private var results: [[DiscoveredWindow]]

    init(results: [[DiscoveredWindow]]) {
        self.results = results
    }

    func next() throws -> [DiscoveredWindow] {
        guard !results.isEmpty else { return [] }
        return results.removeFirst()
    }
}

private func fixtureControllerImage(width: Int = 1, height: Int = 1) -> CGImage {
    let data = Data(repeating: 0, count: width * height * 4)
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: data as CFData)!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
