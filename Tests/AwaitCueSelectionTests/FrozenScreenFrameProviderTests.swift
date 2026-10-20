import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import AwaitCueSelection

@Suite("跨显示器冻结截图")
struct FrozenScreenFrameProviderTests {
    @MainActor
    @Test("冻结 provider 捕获每个已映射显示器并保留系统顺序")
    func freezesEveryMappedDisplayInSystemOrder() async throws {
        let firstImage = fixtureDisplayImage(width: 4, height: 3)
        let secondImage = fixtureDisplayImage(width: 6, height: 4)
        let backend = FixtureFrozenDisplayBackend(
            displays: [
                FrozenDisplayCaptureSource(identifier: 100, handle: NSObject()),
                FrozenDisplayCaptureSource(identifier: 200, handle: NSObject()),
            ],
            images: [100: firstImage, 200: secondImage]
        )
        let provider = ScreenCaptureKitFrozenScreenFrameProvider(
            backend: backend,
            appKitScreenFrames: {
                [
                    100: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                    200: CGRect(x: -1_280, y: 100, width: 1_280, height: 800),
                ]
            }
        )

        let frames = try await provider.freezeDisplays()

        #expect(frames.map(\.displayIdentifier) == [100, 200])
        #expect(frames.map(\.appKitFrame) == [
            CGRect(x: 0, y: 0, width: 1_440, height: 900),
            CGRect(x: -1_280, y: 100, width: 1_280, height: 800),
        ])
        #expect(frames[0].image === firstImage)
        #expect(frames[1].image === secondImage)
        #expect(await Set(backend.capturedDisplayIdentifiers) == Set([100, 200]))
    }

    @MainActor
    @Test("任何显示器缺少 AppKit 映射时整次冻结失败且不返回部分结果")
    func missingAppKitDisplayMappingFailsBeforeCapture() async {
        let backend = FixtureFrozenDisplayBackend(
            displays: [
                FrozenDisplayCaptureSource(identifier: 300, handle: NSObject()),
                FrozenDisplayCaptureSource(identifier: 301, handle: NSObject()),
            ],
            images: [:]
        )
        let provider = ScreenCaptureKitFrozenScreenFrameProvider(
            backend: backend,
            appKitScreenFrames: { [300: CGRect(x: 0, y: 0, width: 1_440, height: 900)] }
        )

        await #expect(throws: FrozenScreenFrameError.appKitScreenMissing(301)) {
            try await provider.freezeDisplays()
        }
        #expect(await backend.capturedDisplayIdentifiers.isEmpty)
    }

    @MainActor
    @Test("空显示器列表和屏幕录制拒绝返回稳定错误")
    func providerMapsEmptyAndPermissionErrors() async {
        let emptyProvider = ScreenCaptureKitFrozenScreenFrameProvider(
            backend: FixtureFrozenDisplayBackend(displays: [], images: [:]),
            appKitScreenFrames: { [:] }
        )
        let deniedProvider = ScreenCaptureKitFrozenScreenFrameProvider(
            backend: FixtureFrozenDisplayBackend(
                displays: [],
                images: [:],
                displaysError: NSError(
                    domain: SCStreamErrorDomain,
                    code: SCStreamError.Code.userDeclined.rawValue
                )
            ),
            appKitScreenFrames: { [:] }
        )

        await #expect(throws: FrozenScreenFrameError.noDisplays) {
            try await emptyProvider.freezeDisplays()
        }
        await #expect(throws: FrozenScreenFrameError.capturePermissionMissing) {
            try await deniedProvider.freezeDisplays()
        }
    }

    @Test("显示器截图配置采用原生像素尺寸且排除光标音频")
    func displayScreenshotConfigurationUsesNativeScale() throws {
        let configuration = try FrozenDisplayScreenshotConfiguration.make(
            contentSize: CGSize(width: 1_001, height: 799),
            pointPixelScale: 1.25
        )

        #expect(configuration.width == 1_252)
        #expect(configuration.height == 999)
        #expect(configuration.showsCursor == false)
        #expect(configuration.capturesAudio == false)
        #expect(configuration.captureResolution == .best)
        #expect(throws: FrozenScreenFrameError.captureFailed) {
            try FrozenDisplayScreenshotConfiguration.make(
                contentSize: .zero,
                pointPixelScale: 1
            )
        }
    }
}

private actor FixtureFrozenDisplayBackend: FrozenDisplayCaptureBackend {
    private let stubbedDisplays: [FrozenDisplayCaptureSource]
    private let images: [UInt32: CGImage]
    private let displaysError: (any Error)?
    private(set) var capturedDisplayIdentifiers: [UInt32] = []

    init(
        displays: [FrozenDisplayCaptureSource],
        images: [UInt32: CGImage],
        displaysError: (any Error)? = nil
    ) {
        stubbedDisplays = displays
        self.images = images
        self.displaysError = displaysError
    }

    func displays() async throws -> [FrozenDisplayCaptureSource] {
        if let displaysError {
            throw displaysError
        }
        return stubbedDisplays
    }

    func captureDisplay(_ display: FrozenDisplayCaptureSource) async throws -> CGImage {
        capturedDisplayIdentifiers.append(display.identifier)
        guard let image = images[display.identifier] else {
            throw FixtureFrozenDisplayError.imageMissing
        }
        return image
    }
}

private enum FixtureFrozenDisplayError: Error {
    case imageMissing
}

private func fixtureDisplayImage(width: Int, height: Int) -> CGImage {
    let bytesPerRow = width * 4
    let data = Data(repeating: 0, count: bytesPerRow * height)
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: data as CFData)!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
