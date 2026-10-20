import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import AwaitCueCapture
import AwaitCueCore

@Suite("窗口观察")
struct ScreenCaptureServiceTests {
    @Test("窗口发现只返回可选择的普通应用窗口")
    func discoveryReturnsOnlySelectableApplicationWindows() async throws {
        let backend = FixtureScreenCaptureBackend(
            windows: [
                fixtureWindow(
                    identifier: 11,
                    bundleIdentifier: "com.example.editor",
                    applicationName: "Editor",
                    title: "Draft",
                    frame: CGRect(x: 10, y: 20, width: 800, height: 600)
                ),
                fixtureWindow(
                    identifier: 12,
                    bundleIdentifier: "com.example.editor",
                    applicationName: "Editor",
                    title: "Menu",
                    windowLayer: 1
                ),
                fixtureWindow(identifier: 13, bundleIdentifier: nil, applicationName: nil, title: "System"),
                fixtureWindow(
                    identifier: 14,
                    bundleIdentifier: "com.example.empty",
                    applicationName: "Empty",
                    title: "Zero Size",
                    frame: .zero
                ),
                fixtureWindow(
                    identifier: 15,
                    bundleIdentifier: "com.example.untitled",
                    applicationName: nil,
                    title: nil
                ),
            ]
        )
        let service = ScreenCaptureService(backend: backend)

        let windows = try await service.discoverWindows()

        #expect(
            windows == [
                DiscoveredWindow(
                    applicationBundleIdentifier: "com.example.editor",
                    applicationName: "Editor",
                    windowIdentifier: 11,
                    title: "Draft",
                    frame: CGRect(x: 10, y: 20, width: 800, height: 600)
                ),
                DiscoveredWindow(
                    applicationBundleIdentifier: "com.example.untitled",
                    applicationName: "com.example.untitled",
                    windowIdentifier: 15,
                    title: "",
                    frame: CGRect(x: 0, y: 0, width: 640, height: 480)
                )
            ]
        )
        #expect(await backend.requestedOnScreenOnlyValues == [true])
    }

    @Test("可用性按 bundle ID 和 window ID 精确匹配且忽略标题变化")
    func availabilityUsesStableWindowIdentity() async throws {
        let backend = FixtureScreenCaptureBackend(
            windows: [
                fixtureWindow(
                    identifier: 21,
                    bundleIdentifier: "com.example.editor",
                    applicationName: "Editor",
                    title: "Renamed Draft",
                    isOnScreen: false,
                    isActive: true
                ),
                fixtureWindow(
                    identifier: 21,
                    bundleIdentifier: "com.example.other",
                    applicationName: "Other",
                    title: "Original Draft"
                ),
            ]
        )
        let service = ScreenCaptureService(backend: backend)

        let availability = try await service.availability(
            of: fixtureTarget(
                bundleIdentifier: "com.example.editor",
                windowIdentifier: 21,
                initialTitle: "Original Draft"
            )
        )

        #expect(availability == .available)
        #expect(await backend.requestedOnScreenOnlyValues == [false])
    }

    @Test("窗口仍存在但不可见时报告 minimized")
    func availabilityReportsMinimizedWindow() async throws {
        let backend = FixtureScreenCaptureBackend(
            windows: [
                fixtureWindow(
                    identifier: 22,
                    bundleIdentifier: "com.example.editor",
                    applicationName: "Editor",
                    title: "Draft",
                    isOnScreen: false,
                    isActive: false
                )
            ]
        )
        let service = ScreenCaptureService(backend: backend)

        let availability = try await service.availability(
            of: fixtureTarget(bundleIdentifier: "com.example.editor", windowIdentifier: 22)
        )

        #expect(availability == .minimized)
    }

    @Test("缺失或身份有歧义的窗口报告 unavailable")
    func availabilityRejectsMissingOrAmbiguousWindow() async throws {
        let target = fixtureTarget(bundleIdentifier: "com.example.editor", windowIdentifier: 23)
        let missingService = ScreenCaptureService(
            backend: FixtureScreenCaptureBackend(
                windows: [
                    fixtureWindow(
                        identifier: 23,
                        bundleIdentifier: "com.example.other",
                        applicationName: "Other",
                        title: "Draft"
                    ),
                    fixtureWindow(
                        identifier: 99,
                        bundleIdentifier: "com.example.editor",
                        applicationName: "Editor",
                        title: "Draft"
                    )
                ]
            )
        )
        let ambiguousService = ScreenCaptureService(
            backend: FixtureScreenCaptureBackend(
                windows: [
                    fixtureWindow(
                        identifier: 23,
                        bundleIdentifier: "com.example.editor",
                        applicationName: "Editor",
                        title: "Draft A"
                    ),
                    fixtureWindow(
                        identifier: 23,
                        bundleIdentifier: "com.example.editor",
                        applicationName: "Editor",
                        title: "Draft B"
                    ),
                ]
            )
        )

        #expect(try await missingService.availability(of: target) == .unavailable)
        #expect(try await ambiguousService.availability(of: target) == .unavailable)
    }

    @Test("可用窗口截图返回内存图像并保留归一化区域")
    func captureReturnsImageForExactAvailableWindow() async throws {
        let fullWindowImage = stripedFixtureImage()
        let backend = FixtureScreenCaptureBackend(
            windows: [
                fixtureWindow(
                    identifier: 31,
                    bundleIdentifier: "com.example.editor",
                    applicationName: "Editor",
                    title: "Renamed Draft"
                )
            ],
            capturedImage: fullWindowImage
        )
        let service = ScreenCaptureService(backend: backend)
        let region = NormalizedRegion(x: 0.25, y: 0, width: 0.5, height: 0.5)

        let observation = try await service.capture(
            fixtureTarget(
                bundleIdentifier: "com.example.editor",
                windowIdentifier: 31,
                initialTitle: "Original Draft",
                normalizedRegion: region
            )
        )

        #expect(observation.availability == .available)
        let image = try #require(observation.image)
        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(firstPixelBytes(of: image) == [0, 0, 255, 255])
        #expect(image.dataProvider !== fullWindowImage.dataProvider)
        #expect(
            await backend.capturedRequests
                == [FixtureCaptureRequest(windowIdentifier: 31)]
        )
    }

    @Test("完整归一化区域保留整张单窗口截图")
    func captureReturnsWholeWindowForFullRegion() async throws {
        let fullWindowImage = fixtureImage(width: 4, height: 3)
        let backend = FixtureScreenCaptureBackend(
            windows: [
                fixtureWindow(
                    identifier: 35,
                    bundleIdentifier: "com.example.editor",
                    applicationName: "Editor",
                    title: "Draft"
                )
            ],
            capturedImage: fullWindowImage
        )

        let observation = try await ScreenCaptureService(backend: backend).capture(
            fixtureTarget(bundleIdentifier: "com.example.editor", windowIdentifier: 35)
        )

        #expect(observation.image === fullWindowImage)
    }

    @Test("不可用或最小化窗口不请求截图")
    func captureSkipsUnavailableAndMinimizedWindows() async throws {
        let minimizedBackend = FixtureScreenCaptureBackend(
            windows: [
                fixtureWindow(
                    identifier: 32,
                    bundleIdentifier: "com.example.editor",
                    applicationName: "Editor",
                    title: "Draft",
                    isOnScreen: false,
                    isActive: false
                )
            ]
        )
        let unavailableBackend = FixtureScreenCaptureBackend(windows: [])
        let target = fixtureTarget(bundleIdentifier: "com.example.editor", windowIdentifier: 32)

        let minimized = try await ScreenCaptureService(backend: minimizedBackend).capture(target)
        let unavailable = try await ScreenCaptureService(backend: unavailableBackend).capture(target)

        #expect(minimized.availability == .minimized)
        #expect(minimized.image == nil)
        #expect(unavailable.availability == .unavailable)
        #expect(unavailable.image == nil)
        #expect(await minimizedBackend.capturedRequests.isEmpty)
        #expect(await unavailableBackend.capturedRequests.isEmpty)
    }

    @Test("截图在系统调用前拒绝无效归一化区域")
    func captureRejectsInvalidNormalizedRegion() async {
        let invalidRegions = [
            NormalizedRegion(x: 0.8, y: 0.8, width: 0.4, height: 0.4),
            NormalizedRegion(x: 0, y: 0, width: 0, height: 1),
            NormalizedRegion(x: .nan, y: 0, width: 1, height: 1),
        ]

        for region in invalidRegions {
            let backend = FixtureScreenCaptureBackend(windows: [])
            let target = fixtureTarget(
                bundleIdentifier: "com.example.editor",
                windowIdentifier: 33,
                normalizedRegion: region
            )

            await #expect(throws: ScreenCaptureError.invalidNormalizedRegion) {
                try await ScreenCaptureService(backend: backend).capture(target)
            }
            #expect(await backend.requestedOnScreenOnlyValues.isEmpty)
        }
    }

    @Test("系统拒绝屏幕录制权限时返回稳定错误")
    func permissionDenialMapsToStableError() async {
        let backend = FixtureScreenCaptureBackend(
            windows: [],
            windowsError: NSError(
                domain: SCStreamErrorDomain,
                code: SCStreamError.Code.userDeclined.rawValue
            )
        )

        await #expect(throws: ScreenCaptureError.capturePermissionMissing) {
            try await ScreenCaptureService(backend: backend).discoverWindows()
        }
    }

    @Test("未知截图故障不会泄漏底层错误")
    func unknownCaptureFailureMapsToStableError() async {
        let backend = FixtureScreenCaptureBackend(
            windows: [
                fixtureWindow(
                    identifier: 34,
                    bundleIdentifier: "com.example.editor",
                    applicationName: "Editor",
                    title: "Draft"
                )
            ],
            captureError: FixtureError.captureFailed
        )

        await #expect(throws: ScreenCaptureError.captureFailed) {
            try await ScreenCaptureService(backend: backend).capture(
                fixtureTarget(bundleIdentifier: "com.example.editor", windowIdentifier: 34)
            )
        }
    }

    @Test("取消和模块输入错误不会被改写为系统故障")
    func cancellationAndModuleErrorsPassThrough() async {
        let cancelledBackend = FixtureScreenCaptureBackend(
            windows: [],
            windowsError: CancellationError()
        )
        let geometryBackend = FixtureScreenCaptureBackend(
            windows: [
                fixtureWindow(
                    identifier: 36,
                    bundleIdentifier: "com.example.editor",
                    applicationName: "Editor",
                    title: "Draft"
                )
            ],
            captureError: ScreenCaptureError.invalidWindowGeometry
        )

        await #expect(throws: CancellationError.self) {
            try await ScreenCaptureService(backend: cancelledBackend).discoverWindows()
        }
        await #expect(throws: ScreenCaptureError.invalidWindowGeometry) {
            try await ScreenCaptureService(backend: geometryBackend).capture(
                fixtureTarget(bundleIdentifier: "com.example.editor", windowIdentifier: 36)
            )
        }
    }

    @Test("默认服务可以在不触发权限请求时构造")
    func defaultServiceConstructionDoesNotCapture() {
        _ = ScreenCaptureService()
    }

    @Test("完整窗口截图按点像素比例保留所有边缘像素")
    func fullWindowOutputSizeRoundsOutward() throws {
        let geometry = try ScreenshotOutputGeometry(
            contentSize: CGSize(width: 101, height: 99),
            pointPixelScale: 1.25
        )

        #expect(geometry.pixelWidth == 127)
        #expect(geometry.pixelHeight == 124)
    }

    @Test("完整截图配置使用无光标无阴影的最佳分辨率")
    func screenshotConfigurationUsesWindowEvidenceDefaults() throws {
        let configuration = try ScreenshotConfigurationFactory.make(
            contentSize: CGSize(width: 101, height: 99),
            pointPixelScale: 1.25
        )

        #expect(configuration.width == 127)
        #expect(configuration.height == 124)
        #expect(configuration.showsCursor == false)
        #expect(configuration.capturesAudio == false)
        #expect(configuration.ignoreShadowsSingleWindow)
        #expect(configuration.ignoreGlobalClipSingleWindow)
        #expect(configuration.captureResolution == .best)
    }

    @Test("无效窗口几何不会生成截图配置或裁剪矩形")
    func invalidImageGeometryIsRejected() {
        #expect(throws: ScreenCaptureError.invalidWindowGeometry) {
            try ScreenshotOutputGeometry(
                contentSize: CGSize(width: 0, height: 100),
                pointPixelScale: 2
            )
        }
        #expect(throws: ScreenCaptureError.invalidWindowGeometry) {
            try ImageCropGeometry(
                region: NormalizedRegion(x: 0, y: 0, width: 1, height: 1),
                imageWidth: 0,
                imageHeight: 100
            )
        }
        #expect(throws: ScreenCaptureError.invalidWindowGeometry) {
            try DetachedImageCropper.crop(
                fixtureImage(width: 2, height: 2),
                to: CGRect(x: 3, y: 3, width: 1, height: 1)
            )
        }
    }

    @Test("归一化区域以左上为原点向外取整像素边界")
    func normalizedRegionMapsToOutwardRoundedPixelCrop() throws {
        let geometry = try ImageCropGeometry(
            region: NormalizedRegion(x: 0.1, y: 0.2, width: 0.5, height: 0.5),
            imageWidth: 101,
            imageHeight: 99
        )
        let bottomRightEdge = try ImageCropGeometry(
            region: NormalizedRegion(x: 0.9, y: 0.8, width: 0.1, height: 0.2),
            imageWidth: 7,
            imageHeight: 5
        )

        #expect(geometry.pixelRect == CGRect(x: 10, y: 19, width: 51, height: 51))
        #expect(bottomRightEdge.pixelRect == CGRect(x: 6, y: 4, width: 1, height: 1))
    }

    @Test("区域裁剪复制为只含所选像素的独立图像")
    func cropCopiesOnlySelectedPixels() throws {
        let image = fixtureImage(width: 4, height: 3)

        let cropped = try DetachedImageCropper.crop(
            image,
            to: CGRect(x: 1, y: 1, width: 2, height: 1)
        )

        #expect(cropped.width == 2)
        #expect(cropped.height == 1)
        #expect(cropped.dataProvider !== image.dataProvider)
    }
}

private actor FixtureScreenCaptureBackend: ScreenCaptureBackend {
    private let stubbedWindows: [ScreenCaptureWindow]
    private let capturedImage: CGImage
    private let windowsError: (any Error)?
    private let captureError: (any Error)?
    private(set) var requestedOnScreenOnlyValues: [Bool] = []
    private(set) var capturedRequests: [FixtureCaptureRequest] = []

    init(
        windows: [ScreenCaptureWindow],
        capturedImage: CGImage = fixtureImage(),
        windowsError: (any Error)? = nil,
        captureError: (any Error)? = nil
    ) {
        stubbedWindows = windows
        self.capturedImage = capturedImage
        self.windowsError = windowsError
        self.captureError = captureError
    }

    func windows(onScreenOnly: Bool) async throws -> [ScreenCaptureWindow] {
        requestedOnScreenOnlyValues.append(onScreenOnly)
        if let windowsError {
            throw windowsError
        }
        return stubbedWindows
    }

    func captureImage(
        of window: ScreenCaptureWindow
    ) async throws -> CGImage {
        capturedRequests.append(
            FixtureCaptureRequest(windowIdentifier: window.identifier)
        )
        if let captureError {
            throw captureError
        }
        return capturedImage
    }
}

private enum FixtureError: Error {
    case captureFailed
}

private struct FixtureCaptureRequest: Equatable {
    let windowIdentifier: UInt32
}

private func fixtureWindow(
    identifier: UInt32,
    bundleIdentifier: String?,
    applicationName: String?,
    title: String?,
    frame: CGRect = CGRect(x: 0, y: 0, width: 640, height: 480),
    windowLayer: Int = 0,
    isOnScreen: Bool = true,
    isActive: Bool = false
) -> ScreenCaptureWindow {
    ScreenCaptureWindow(
        identifier: identifier,
        bundleIdentifier: bundleIdentifier,
        applicationName: applicationName,
        title: title,
        frame: frame,
        windowLayer: windowLayer,
        isOnScreen: isOnScreen,
        isActive: isActive,
        handle: NSObject()
    )
}

private func fixtureTarget(
    bundleIdentifier: String,
    windowIdentifier: UInt32,
    initialTitle: String = "Draft",
    normalizedRegion: NormalizedRegion = NormalizedRegion(x: 0, y: 0, width: 1, height: 1)
) -> WindowTarget {
    WindowTarget(
        applicationBundleIdentifier: bundleIdentifier,
        windowIdentifier: windowIdentifier,
        initialTitle: initialTitle,
        normalizedRegion: normalizedRegion
    )
}

private func fixtureImage(width: Int = 1, height: Int = 1) -> CGImage {
    let bytesPerRow = width * 4
    let data = Data(repeating: 0, count: bytesPerRow * height)
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func stripedFixtureImage() -> CGImage {
    let width = 4
    let height = 4
    var bytes: [UInt8] = []
    for y in 0..<height {
        let pixel: [UInt8] = y < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255]
        for _ in 0..<width {
            bytes.append(contentsOf: pixel)
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func firstPixelBytes(of image: CGImage) -> [UInt8] {
    guard let data = image.dataProvider?.data else {
        return []
    }
    return Array((data as Data).prefix(4))
}
