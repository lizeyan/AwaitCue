import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// 一个显示器在进入全局框选前冻结的内存图像和 AppKit 全局位置。
public struct FrozenDisplayFrame: Sendable {
    public let displayIdentifier: UInt32
    public let appKitFrame: CGRect
    public let image: CGImage

    /// 创建不会被本模块写入磁盘的显示器冻结帧。
    public init(displayIdentifier: UInt32, appKitFrame: CGRect, image: CGImage) {
        self.displayIdentifier = displayIdentifier
        self.appKitFrame = appKitFrame
        self.image = image
    }
}

/// 全局 overlay 开始前冻结所有显示器的公开边界。
@MainActor
public protocol FrozenScreenFrameProviding: Sendable {
    /// 返回每个当前显示器的冻结帧；任一显示器失败时不返回部分桌面。
    func freezeDisplays() async throws -> [FrozenDisplayFrame]
}

/// 冻结桌面无法形成一致多显示器快照的稳定错误。
public enum FrozenScreenFrameError: Error, Equatable, Sendable {
    case noDisplays
    case appKitScreenMissing(UInt32)
    case capturePermissionMissing
    case captureFailed
}

/// 使用 macOS 14 ScreenCaptureKit 并发冻结所有显示器。
public struct ScreenCaptureKitFrozenScreenFrameProvider: FrozenScreenFrameProviding, Sendable {
    private let backend: any FrozenDisplayCaptureBackend
    private let appKitScreenFrames: @MainActor @Sendable () -> [UInt32: CGRect]

    /// 创建使用当前 NSScreen 布局和 ScreenCaptureKit 的 provider。
    public init() {
        backend = ScreenCaptureKitFrozenDisplayBackend()
        appKitScreenFrames = {
            let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
            return Dictionary(
                uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                    guard let number = screen.deviceDescription[screenNumberKey] as? NSNumber else {
                        return nil
                    }
                    return (number.uint32Value, screen.frame)
                }
            )
        }
    }

    /// 注入显示器捕获边界和 AppKit 布局，供模块测试跨显示器行为。
    init(
        backend: any FrozenDisplayCaptureBackend,
        appKitScreenFrames: @escaping @MainActor @Sendable () -> [UInt32: CGRect]
    ) {
        self.backend = backend
        self.appKitScreenFrames = appKitScreenFrames
    }

    /// 先验证所有显示器都有 AppKit 映射，再并发捕获以缩短多屏画面之间的时间差。
    public func freezeDisplays() async throws -> [FrozenDisplayFrame] {
        do {
            let displays = try await backend.displays()
            guard !displays.isEmpty else {
                throw FrozenScreenFrameError.noDisplays
            }

            let screenFrames = appKitScreenFrames()
            let mappedDisplays = try displays.enumerated().map { index, display in
                guard let appKitFrame = screenFrames[display.identifier] else {
                    throw FrozenScreenFrameError.appKitScreenMissing(display.identifier)
                }
                return (index, display, appKitFrame)
            }

            // 多块显示器并发截图会增加瞬时内存，但能减少冻结画面之间的时间偏差，避免跨屏拖动看到明显错帧。
            let indexedFrames = try await withThrowingTaskGroup(
                of: (Int, FrozenDisplayFrame).self
            ) { group in
                for (index, display, appKitFrame) in mappedDisplays {
                    group.addTask {
                        let image = try await backend.captureDisplay(display)
                        return (
                            index,
                            FrozenDisplayFrame(
                                displayIdentifier: display.identifier,
                                appKitFrame: appKitFrame,
                                image: image
                            )
                        )
                    }
                }

                var frames: [(Int, FrozenDisplayFrame)] = []
                for try await frame in group {
                    frames.append(frame)
                }
                return frames
            }
            return indexedFrames.sorted { $0.0 < $1.0 }.map(\.1)
        } catch let error as CancellationError {
            throw error
        } catch let error as FrozenScreenFrameError {
            throw error
        } catch {
            let systemError = error as NSError
            if
                systemError.domain == SCStreamErrorDomain,
                systemError.code == SCStreamError.Code.userDeclined.rawValue
            {
                throw FrozenScreenFrameError.capturePermissionMissing
            }
            throw FrozenScreenFrameError.captureFailed
        }
    }
}

/// 系统显示器句柄及稳定标识；句柄只会原样传回 ScreenCaptureKit。
struct FrozenDisplayCaptureSource: @unchecked Sendable {
    let identifier: UInt32
    let handle: AnyObject
}

/// provider 与不可构造的 SCDisplay 系统对象之间的最小测试边界。
protocol FrozenDisplayCaptureBackend: Sendable {
    /// 读取当前所有可共享显示器。
    func displays() async throws -> [FrozenDisplayCaptureSource]

    /// 捕获一个完整显示器的内存图像。
    func captureDisplay(_ display: FrozenDisplayCaptureSource) async throws -> CGImage
}

private struct ScreenCaptureKitFrozenDisplayBackend: FrozenDisplayCaptureBackend {
    /// 从 ScreenCaptureKit 读取显示器，并保留对应 SCDisplay 句柄。
    func displays() async throws -> [FrozenDisplayCaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        return content.displays.map { display in
            FrozenDisplayCaptureSource(identifier: display.displayID, handle: display)
        }
    }

    /// 使用显示器过滤器捕获实际桌面画面，overlay 会在截图完成后才出现。
    func captureDisplay(_ display: FrozenDisplayCaptureSource) async throws -> CGImage {
        guard let screenCaptureDisplay = display.handle as? SCDisplay else {
            throw FrozenDisplayBackendError.invalidDisplayHandle
        }
        let filter = SCContentFilter(display: screenCaptureDisplay, excludingWindows: [])
        let configuration = try FrozenDisplayScreenshotConfiguration.make(
            contentSize: filter.contentRect.size,
            pointPixelScale: CGFloat(filter.pointPixelScale)
        )
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}

/// 系统显示器句柄不满足 provider 内部不变量。
private enum FrozenDisplayBackendError: Error {
    case invalidDisplayHandle
}

/// 构造完整显示器截图的 macOS 14 SCStreamConfiguration。
enum FrozenDisplayScreenshotConfiguration {
    /// 以原生点像素比例冻结桌面，并排除不会作为 Target 证据的鼠标指针和音频。
    static func make(contentSize: CGSize, pointPixelScale: CGFloat) throws -> SCStreamConfiguration {
        guard
            contentSize.width.isFinite,
            contentSize.height.isFinite,
            contentSize.width > 0,
            contentSize.height > 0,
            pointPixelScale.isFinite,
            pointPixelScale > 0
        else {
            throw FrozenScreenFrameError.captureFailed
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(ceil(contentSize.width * pointPixelScale))
        configuration.height = Int(ceil(contentSize.height * pointPixelScale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureResolution = .best
        return configuration
    }
}
