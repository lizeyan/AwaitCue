import AwaitCueCore
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// 可由用户选择并绑定为窗口 Target 的 ScreenCaptureKit 窗口元数据。
public struct DiscoveredWindow: Equatable, Sendable {
    public let applicationBundleIdentifier: String
    public let applicationName: String
    public let windowIdentifier: UInt32
    public let title: String
    public let frame: CGRect

    /// 创建一份不包含屏幕像素的窗口发现结果。
    public init(
        applicationBundleIdentifier: String,
        applicationName: String,
        windowIdentifier: UInt32,
        title: String,
        frame: CGRect
    ) {
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationName = applicationName
        self.windowIdentifier = windowIdentifier
        self.title = title
        self.frame = frame
    }
}

/// 已绑定窗口当前是否还能安全地作为同一个 Target 继续观察。
public enum WindowTargetAvailability: Equatable, Sendable {
    /// 精确窗口仍可捕获。
    case available
    /// 精确窗口仍存在但不在屏幕上，当前业务将其作为最小化暂时阻塞。
    case minimized
    /// 精确窗口已经缺失，或系统结果不足以唯一确认其身份。
    case unavailable
}

/// 在请求 ScreenCaptureKit 截图之前即可确定的输入错误。
public enum ScreenCaptureError: Error, Equatable, Sendable {
    /// Target 中的比例区域没有完整落在单位矩形内。
    case invalidNormalizedRegion
    /// 系统报告的窗口尺寸或点像素比例无法生成有效截图。
    case invalidWindowGeometry
    /// 用户尚未授予或已经拒绝屏幕录制权限。
    case capturePermissionMissing
    /// ScreenCaptureKit 返回了不应暴露到业务层的其他捕获故障。
    case captureFailed
}

/// 一次窗口观察的可用性和可选图像证据；图像不会被本模块写入磁盘。
public struct WindowCaptureObservation: Sendable {
    public let availability: WindowTargetAvailability
    public let image: CGImage?

    /// 创建一次观察结果；只有 available 结果会携带图像。
    init(availability: WindowTargetAvailability, image: CGImage?) {
        self.availability = availability
        self.image = image
    }
}

/// 通过 ScreenCaptureKit 发现和观察普通 macOS 应用窗口。
public struct ScreenCaptureService: Sendable {
    private let backend: any ScreenCaptureBackend

    /// 创建使用系统 ScreenCaptureKit 的窗口观察服务。
    public init() {
        backend = ScreenCaptureKitBackend()
    }

    /// 注入底层窗口来源，供模块自身验证公开行为。
    init(backend: any ScreenCaptureBackend) {
        self.backend = backend
    }

    /// 返回当前屏幕上可供用户选择的普通应用窗口。
    public func discoverWindows() async throws -> [DiscoveredWindow] {
        let windows = try await performSystemOperation {
            try await backend.windows(onScreenOnly: true)
        }
        return windows.compactMap { window in
            guard
                window.windowLayer == 0,
                window.frame.width > 0,
                window.frame.height > 0,
                let bundleIdentifier = window.bundleIdentifier,
                !bundleIdentifier.isEmpty
            else {
                return nil
            }

            return DiscoveredWindow(
                applicationBundleIdentifier: bundleIdentifier,
                applicationName: window.applicationName ?? bundleIdentifier,
                windowIdentifier: window.identifier,
                title: window.title ?? "",
                frame: window.frame
            )
        }
    }

    /// 判断已绑定窗口是否仍存在，且不会按标题猜测或替换成相似窗口。
    public func availability(of target: WindowTarget) async throws -> WindowTargetAvailability {
        let windows = try await performSystemOperation {
            try await backend.windows(onScreenOnly: false)
        }
        return resolve(target, among: windows).availability
    }

    /// 截取已绑定窗口的归一化区域；区域坐标以窗口左上角为原点。
    ///
    /// 窗口不可用时返回状态而不是猜测替代窗口，图像始终只在内存中传递。
    public func capture(_ target: WindowTarget) async throws -> WindowCaptureObservation {
        guard target.normalizedRegion.isValid else {
            throw ScreenCaptureError.invalidNormalizedRegion
        }

        let windows = try await performSystemOperation {
            try await backend.windows(onScreenOnly: false)
        }
        let resolved = resolve(target, among: windows)
        guard resolved.availability == .available, let window = resolved.window else {
            return WindowCaptureObservation(availability: resolved.availability, image: nil)
        }

        let fullImage = try await performSystemOperation {
            try await backend.captureImage(of: window)
        }
        let image = try crop(fullImage, to: target.normalizedRegion)
        return WindowCaptureObservation(availability: .available, image: image)
    }

    /// 将系统错误收敛为稳定分类，同时保留取消和本模块自己的输入错误。
    private func performSystemOperation<Result>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        do {
            return try await operation()
        } catch let error as CancellationError {
            throw error
        } catch let error as ScreenCaptureError {
            throw error
        } catch {
            let systemError = error as NSError
            if
                systemError.domain == SCStreamErrorDomain,
                systemError.code == SCStreamError.Code.userDeclined.rawValue
            {
                throw ScreenCaptureError.capturePermissionMissing
            }
            throw ScreenCaptureError.captureFailed
        }
    }

    /// 按实际截图像素裁剪 Target 区域，并让非完整区域脱离完整窗口的图像存储。
    private func crop(_ image: CGImage, to region: NormalizedRegion) throws -> CGImage {
        let cropGeometry = try ImageCropGeometry(
            region: region,
            imageWidth: image.width,
            imageHeight: image.height
        )
        let fullImageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard cropGeometry.pixelRect != fullImageRect else {
            return image
        }
        return try DetachedImageCropper.crop(image, to: cropGeometry.pixelRect)
    }

    /// 使用稳定窗口身份解析 Target，同时保留匹配到的系统句柄供截图使用。
    private func resolve(
        _ target: WindowTarget,
        among windows: [ScreenCaptureWindow]
    ) -> ResolvedWindowTarget {
        // 标题会随文档或页面状态变化，不能参与重绑；同时匹配 bundle ID 可防止窗口 ID 被其他进程复用。
        let matches = windows.filter { window in
            window.identifier == target.windowIdentifier
                && window.bundleIdentifier == target.applicationBundleIdentifier
        }

        guard matches.count == 1, let window = matches.first else {
            return ResolvedWindowTarget(availability: .unavailable, window: nil)
        }

        // Stage Manager 可能让 active 窗口暂时不在屏幕上，但该窗口仍是可捕获的同一 Target。
        // 一次性截图 API 无法严格区分最小化和其他 inactive 离屏状态，因此后者统一进入可恢复的 minimized 分支，
        // 而不是被误判为永久 unavailable；若产品以后要求精确区分，需要引入额外窗口状态来源。
        let availability: WindowTargetAvailability = window.isOnScreen || window.isActive
            ? .available
            : .minimized
        return ResolvedWindowTarget(availability: availability, window: window)
    }
}

/// 一次 Target 解析的结果；只有唯一匹配时才保留窗口句柄。
private struct ResolvedWindowTarget {
    let availability: WindowTargetAvailability
    let window: ScreenCaptureWindow?
}

/// ScreenCaptureKit 与业务服务之间的最小边界，测试替身只替换系统调用。
protocol ScreenCaptureBackend: Sendable {
    /// 读取可共享窗口；availability 检查需要包含当前不在屏幕上的窗口。
    func windows(onScreenOnly: Bool) async throws -> [ScreenCaptureWindow]

    /// 对已经精确解析的系统窗口执行一次完整窗口内存截图。
    func captureImage(of window: ScreenCaptureWindow) async throws -> CGImage
}

/// 保留窗口元数据及其系统句柄，后续截图必须使用同一次发现得到的精确窗口。
///
/// `SCWindow` 由系统创建且没有公开 Sendable 标注；句柄只被原样传给 ScreenCaptureKit，不读取可变业务状态。
struct ScreenCaptureWindow: @unchecked Sendable {
    let identifier: UInt32
    let bundleIdentifier: String?
    let applicationName: String?
    let title: String?
    let frame: CGRect
    let windowLayer: Int
    let isOnScreen: Bool
    let isActive: Bool
    let handle: AnyObject
}

private struct ScreenCaptureKitBackend: ScreenCaptureBackend {
    /// 从系统读取窗口，并保留 `SCWindow` 句柄供同一观察周期使用。
    func windows(onScreenOnly: Bool) async throws -> [ScreenCaptureWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: onScreenOnly
        )

        return content.windows.map { window in
            ScreenCaptureWindow(
                identifier: window.windowID,
                bundleIdentifier: window.owningApplication?.bundleIdentifier,
                applicationName: window.owningApplication?.applicationName,
                title: window.title,
                frame: window.frame,
                windowLayer: window.windowLayer,
                isOnScreen: window.isOnScreen,
                isActive: window.isActive,
                handle: window
            )
        }
    }

    /// 通过独立窗口过滤器截取归一化区域，避免其他窗口遮挡进入图像证据。
    func captureImage(of window: ScreenCaptureWindow) async throws -> CGImage {
        guard let screenCaptureWindow = window.handle as? SCWindow else {
            throw ScreenCaptureBackendError.invalidWindowHandle
        }

        let filter = SCContentFilter(desktopIndependentWindow: screenCaptureWindow)
        let configuration = try ScreenshotConfigurationFactory.make(
            contentSize: filter.contentRect.size,
            pointPixelScale: CGFloat(filter.pointPixelScale)
        )

        // ScreenCaptureKit 在独立窗口过滤器上忽略 sourceRect，因此这里只能取得完整窗口。
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}

/// ScreenCaptureKit 句柄的模块内部不变量被破坏时使用的错误。
private enum ScreenCaptureBackendError: Error {
    case invalidWindowHandle
}

/// 创建单窗口截图所需的稳定 ScreenCaptureKit 配置。
enum ScreenshotConfigurationFactory {
    /// 使用窗口原生像素尺寸，且排除光标、音频和窗口阴影等非 Target 内容。
    static func make(contentSize: CGSize, pointPixelScale: CGFloat) throws -> SCStreamConfiguration {
        let outputGeometry = try ScreenshotOutputGeometry(
            contentSize: contentSize,
            pointPixelScale: pointPixelScale
        )
        let configuration = SCStreamConfiguration()
        configuration.width = outputGeometry.pixelWidth
        configuration.height = outputGeometry.pixelHeight
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        // 窗口部分移出屏幕时仍按完整窗口坐标截图，避免同一归一化区域随窗口位置被裁短。
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.captureResolution = .best
        return configuration
    }
}

/// 根据窗口点尺寸和缩放比例计算完整截图的像素输出尺寸。
struct ScreenshotOutputGeometry: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int

    /// 计算完整窗口截图配置；向上取整，避免丢失窗口最右侧或最下侧的部分像素。
    init(
        contentSize: CGSize,
        pointPixelScale: CGFloat
    ) throws {
        guard
            contentSize.width.isFinite,
            contentSize.height.isFinite,
            contentSize.width > 0,
            contentSize.height > 0,
            pointPixelScale.isFinite,
            pointPixelScale > 0
        else {
            throw ScreenCaptureError.invalidWindowGeometry
        }

        pixelWidth = Int(ceil(contentSize.width * pointPixelScale))
        pixelHeight = Int(ceil(contentSize.height * pointPixelScale))
    }
}

/// 把左上原点的比例区域换算为实际 `CGImage` 的整数像素裁剪矩形。
struct ImageCropGeometry: Equatable, Sendable {
    let pixelRect: CGRect

    /// 计算向外取整的像素边界，使比例区域覆盖到的每个像素都保留在结果中。
    init(region: NormalizedRegion, imageWidth: Int, imageHeight: Int) throws {
        guard region.isValid, imageWidth > 0, imageHeight > 0 else {
            throw ScreenCaptureError.invalidWindowGeometry
        }

        let width = Double(imageWidth)
        let height = Double(imageHeight)
        let minX = max(0, min(width, floor(width * region.x)))
        let minY = max(0, min(height, floor(height * region.y)))
        let maxX = max(0, min(width, ceil(width * (region.x + region.width))))
        let maxY = max(0, min(height, ceil(height * (region.y + region.height))))
        guard maxX > minX, maxY > minY else {
            throw ScreenCaptureError.invalidWindowGeometry
        }

        // ScreenCaptureKit 返回的 CGImage 按图像数据首行作为 y=0，与 Target 的左上原点约定一致。
        pixelRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// 将区域像素复制到独立位图，避免裁剪结果继续持有完整窗口图像。
enum DetachedImageCropper {
    /// 裁剪并重绘所选区域；额外一次内存复制换取完整窗口像素能在方法返回前释放。
    static func crop(_ image: CGImage, to pixelRect: CGRect) throws -> CGImage {
        guard let croppedView = image.cropping(to: pixelRect) else {
            throw ScreenCaptureError.invalidWindowGeometry
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: croppedView.width,
            height: croppedView.height,
            bitsPerComponent: 8,
            bytesPerRow: croppedView.width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ScreenCaptureError.invalidWindowGeometry
        }

        context.interpolationQuality = .none
        context.draw(
            croppedView,
            in: CGRect(x: 0, y: 0, width: croppedView.width, height: croppedView.height)
        )
        guard let detachedImage = context.makeImage() else {
            throw ScreenCaptureError.invalidWindowGeometry
        }
        return detachedImage
    }
}
