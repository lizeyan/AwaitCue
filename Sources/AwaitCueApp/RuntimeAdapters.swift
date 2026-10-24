import AppKit
import AwaitCueCapture
import AwaitCueCore
import AwaitCueModel
import AwaitCueRuntime
import AwaitCueSelection
import CoreGraphics
import Foundation

/// 保存设置页当前隐私排除规则，供后台 Runtime 在每次截图前读取最新值。
final class AppPrivacyExclusionStore: @unchecked Sendable {
    // 设置变更和后台截图发生在不同 actor；同步锁确保新规则写入返回后，下一次截图不会读到旧值。
    private let lock = NSLock()
    private var currentRules: PrivacyExclusionRules

    init(rules: PrivacyExclusionRules) {
        currentRules = rules
    }

    func update(_ rules: PrivacyExclusionRules) {
        lock.withLock {
            currentRules = rules
        }
    }

    func rules() -> PrivacyExclusionRules {
        lock.withLock { currentRules }
    }
}

/// 为普通窗口和 Chromium Target 提供只驻留内存的 Condition 证据。
struct AppConditionEvidenceProvider: HookRuntimeConditionEvidenceProvider {
    let browserRelay: NativeBrowserSelectionRelay
    private let captureService = ScreenCaptureService()

    func evidence(for hook: Hook) async throws -> ModelEvidence {
        switch hook.target {
        case let .window(window):
            let observation: WindowCaptureObservation
            do {
                observation = try await captureService.capture(window)
            } catch ScreenCaptureError.capturePermissionMissing {
                throw HookRuntimeEvidenceError.capturePermissionMissing
            }
            switch observation.availability {
            case .available:
                guard let image = observation.image,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                else {
                    throw HookRuntimeEvidenceError.targetUnavailable
                }
                return ModelEvidence(
                    text: window.initialTitle,
                    image: ModelImage(data: png, mediaType: "image/png")
                )
            case .minimized:
                throw HookRuntimeEvidenceError.targetMinimized
            case .unavailable:
                throw HookRuntimeEvidenceError.targetUnavailable
            }
        case let .browser(browser):
            let evidence = try await browserRelay.evidence(for: hook.id)
            guard case .condition = hook.trigger else {
                throw HookRuntimeEvidenceError.evidenceIncomplete
            }
            let hasDOM = !(evidence.domText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            guard browser.observationMode == .dom, hasDOM else {
                throw HookRuntimeEvidenceError.evidenceIncomplete
            }
            return evidence
        }
    }
}

/// 在 Runtime 推进通知前验证原窗口或 Chrome tab 仍是用户绑定的同一 Target。
protocol BrowserTargetAvailabilityChecking: Sendable {
    func targetIsAvailable(hookID: HookID, target: BrowserTarget) async throws -> Bool
}

protocol WindowTargetAvailabilityChecking: Sendable {
    func availability(of target: WindowTarget) async throws -> WindowTargetAvailability
}

extension NativeBrowserSelectionRelay: BrowserTargetAvailabilityChecking {}
extension ScreenCaptureService: WindowTargetAvailabilityChecking {}

struct AppTargetAvailabilityProvider: HookRuntimeTargetAvailabilityProvider {
    let browserChecker: any BrowserTargetAvailabilityChecking
    let windowChecker: any WindowTargetAvailabilityChecking

    init(browserRelay: NativeBrowserSelectionRelay) {
        browserChecker = browserRelay
        windowChecker = ScreenCaptureService()
    }

    init(
        browserChecker: any BrowserTargetAvailabilityChecking,
        windowChecker: any WindowTargetAvailabilityChecking
    ) {
        self.browserChecker = browserChecker
        self.windowChecker = windowChecker
    }

    func availability(for hook: Hook) async -> HookRuntimeTargetAvailability {
        switch hook.target {
        case let .window(window):
            do {
                switch try await windowChecker.availability(of: window) {
                case .available, .minimized:
                    // Delay Hook 的窗口最小化不妨碍稍后通知；用户点击通知时再恢复应用。
                    return .available
                case .unavailable:
                    return .targetUnavailable
                }
            } catch ScreenCaptureError.capturePermissionMissing {
                return .blocked(.capturePermissionMissing)
            } catch {
                // 系统窗口列表暂时失败时不能猜测为已关闭，也不能继续发送可能失去目标的通知。
                return .retryLater
            }
        case let .browser(browser):
            guard browser.browserBundleIdentifier != "com.apple.Safari" else {
                // Safari 不属于当前 Chromium 验收范围；保留既有行为，避免本轮改变其产品状态。
                return .available
            }
            do {
                return try await browserChecker.targetIsAvailable(hookID: hook.id, target: browser)
                    ? .available
                    : .targetUnavailable
            } catch {
                return .blocked(.browserExtensionDisconnected)
            }
        }
    }
}

/// 采集当前前台窗口和有限输入活动摘要，供全部已满足 Hook 共享一次判断。
struct AppActiveEvidenceProvider: HookRuntimeActiveEvidenceProvider {
    let privacyExclusionStore: AppPrivacyExclusionStore
    let activeBrowserHostResolver: any ActiveBrowserHostResolving
    private let captureService = ScreenCaptureService()

    func currentEvidence() async throws -> ModelEvidence {
        let frontmostApplication = await MainActor.run {
            NSWorkspace.shared.frontmostApplication
        }
        guard let bundleIdentifier = frontmostApplication?.bundleIdentifier else {
            throw HookRuntimeEvidenceError.targetUnavailable
        }
        let exclusionRules = privacyExclusionStore.rules()
        guard !exclusionRules.excludes(applicationBundleIdentifier: bundleIdentifier) else {
            // 排除判断必须发生在窗口发现和截图之前，确保像素不会离开本机采集边界。
            throw HookRuntimeEvidenceError.locallyExcluded
        }
        var verifiedBrowserContext: ActiveBrowserContext?
        if !exclusionRules.browserHosts.isEmpty {
            let browserResolution: ActiveBrowserHostResolution
            do {
                browserResolution = try await activeBrowserHostResolver.resolveActiveBrowserHost(
                    for: bundleIdentifier
                )
            } catch {
                // 配置了 host 排除时，无法可信解析当前浏览器 host 就保守拒绝截图。
                throw HookRuntimeEvidenceError.locallyExcluded
            }
            switch browserResolution {
            case .notBrowser:
                break
            case let .resolved(context):
                guard !exclusionRules.excludes(browserHost: context.host) else {
                    throw HookRuntimeEvidenceError.locallyExcluded
                }
                verifiedBrowserContext = context
            case .unavailable:
                // 不猜测 host；否则一次 relay 暂时故障可能把用户排除的页面上传给模型。
                throw HookRuntimeEvidenceError.locallyExcluded
            }
        }
        let windows: [DiscoveredWindow]
        do {
            windows = try await captureService.discoverWindows()
        } catch ScreenCaptureError.capturePermissionMissing {
            throw HookRuntimeEvidenceError.capturePermissionMissing
        }
        guard let window = Self.frontmostWindow(
            for: bundleIdentifier,
            among: windows
        ) else {
            throw HookRuntimeEvidenceError.targetUnavailable
        }
        let target = WindowTarget(
            applicationBundleIdentifier: bundleIdentifier,
            windowIdentifier: window.windowIdentifier,
            initialTitle: window.title,
            normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1)
        )
        let observation = try await captureService.capture(target)
        guard observation.availability == .available,
              let image = observation.image
        else {
            throw HookRuntimeEvidenceError.targetUnavailable
        }
        if let verifiedBrowserContext {
            let afterCapture: ActiveBrowserHostResolution
            do {
                afterCapture = try await activeBrowserHostResolver.resolveActiveBrowserHost(
                    for: bundleIdentifier
                )
            } catch {
                throw HookRuntimeEvidenceError.locallyExcluded
            }
            guard afterCapture == .resolved(verifiedBrowserContext),
                  !exclusionRules.excludes(browserHost: verifiedBrowserContext.host)
            else {
                // 标签页在检查与截图之间变化时丢弃内存图像，绝不把竞态中的页面上传给模型。
                throw HookRuntimeEvidenceError.locallyExcluded
            }
        }
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.55]
              )
        else {
            throw HookRuntimeEvidenceError.targetUnavailable
        }
        let secondsSinceInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .null
        )
        let summary = """
        前台应用：\(frontmostApplication?.localizedName ?? bundleIdentifier)
        窗口标题：\(window.title)
        距最近输入约：\(Int(secondsSinceInput)) 秒
        """
        return ModelEvidence(
            text: summary,
            image: ModelImage(data: jpeg, mediaType: "image/jpeg")
        )
    }

    private static func frontmostWindow(
        for bundleIdentifier: String,
        among windows: [DiscoveredWindow]
    ) -> DiscoveredWindow? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        let windowsByID = Dictionary(
            uniqueKeysWithValues: windows.map { ($0.windowIdentifier, $0) }
        )
        let windowNumberKey = kCGWindowNumber as String
        // ScreenCaptureKit 的返回顺序没有前后语义；必须按 CGWindow 的前后顺序选中真正活动的窗口。
        for entry in windowInfo {
            guard let identifier = (entry[windowNumberKey] as? NSNumber)?.uint32Value,
                  let window = windowsByID[identifier],
                  window.applicationBundleIdentifier == bundleIdentifier
            else {
                continue
            }
            return window
        }
        return nil
    }
}

/// 执行 Runtime 返回的系统通知 effect，并把权限错误收敛到稳定分类。
struct AppRuntimeEffectExecutor: HookRuntimeEffectExecutor {
    let notificationClient: SystemNotificationClient
    let browserRelay: NativeBrowserSelectionRelay

    func execute(_ effect: HookEffect, for hook: Hook) async throws {
        guard case let .deliverNotification(id) = effect else { return }
        do {
            try await notificationClient.deliver(hook, identifier: id)
            if case let .browser(browser) = hook.target {
                try? await browserRelay.unbind(
                    hookID: hook.id,
                    target: browser
                )
            }
        } catch {
            throw HookRuntimeEffectError.notificationPermissionMissing
        }
    }
}

/// 生产 Runtime 使用的系统时钟。
struct SystemHookRuntimeClock: HookRuntimeClock {
    func now() async -> Date {
        .now
    }

    func sleep(until deadline: Date) async throws {
        let duration = max(0, deadline.timeIntervalSinceNow)
        try await Task.sleep(for: .seconds(duration))
    }
}
