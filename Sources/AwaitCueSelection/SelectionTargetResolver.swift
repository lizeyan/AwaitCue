import AwaitCueCapture
import AwaitCueCore
import CoreGraphics

/// Native/browser relay 对当前窗口框选的明确分类结果。
public enum BrowserSelectionRelayResolution: Equatable, Sendable {
    /// relay 已确认该窗口不是由浏览器标签页接管的 Target。
    case notBrowser
    /// relay 已根据具体标签页和 viewport 生成 BrowserTarget。
    case resolved(BrowserTarget)
    /// relay 已识别浏览器窗口，但当前无法可靠解析具体标签页。
    case unavailable
}

/// 浏览器窗口身份和标签页区域的唯一事实来源。
public protocol BrowserSelectionRelaying: Sendable {
    /// 分类一个精确窗口框选；实现方负责识别浏览器 bundle 和具体标签页。
    func resolveBrowserTarget(
        for selection: ResolvedWindowSelection
    ) async throws -> BrowserSelectionRelayResolution
}

/// 收集操作系统验证过 browser bundle 的选择响应，并拒绝跨浏览器或多 installation 歧义。
public struct BrowserSelectionMatchCollector: Sendable {
    private let browserBundleIdentifier: String
    private var matches: [BrowserTarget] = []

    public init(browserBundleIdentifier: String) {
        self.browserBundleIdentifier = browserBundleIdentifier
    }

    public mutating func record(
        browserBundleIdentifier: String,
        target: BrowserTarget
    ) {
        guard
            browserBundleIdentifier == self.browserBundleIdentifier,
            target.browserBundleIdentifier == self.browserBundleIdentifier,
            !matches.contains(where: {
                $0.extensionInstallationID == target.extensionInstallationID
                    && $0.tabIdentifier == target.tabIdentifier
            })
        else {
            return
        }
        matches.append(target)
    }

    public var resolution: BrowserSelectionRelayResolution {
        matches.count == 1 ? .resolved(matches[0]) : .unavailable
    }
}

/// 当前前台浏览器 host 查询的安全结果。
public enum ActiveBrowserHostResolution: Equatable, Sendable {
    /// 前台应用不是 Selection 模块支持的 Chromium 浏览器。
    case notBrowser
    /// 恰好一个匹配 browser bundle 的 installation 返回了活动标签页 host。
    case resolved(host: String)
    /// 没有可信响应，或多个 installation 同时声称自己是前台窗口。
    case unavailable
}

/// 在任何浏览器截图前解析当前前台标签页 host 的公开边界。
public protocol ActiveBrowserHostResolving: Sendable {
    /// 只接受与操作系统 browser bundle 身份一致且无歧义的活动标签页响应。
    func resolveActiveBrowserHost(
        for browserBundleIdentifier: String
    ) async throws -> ActiveBrowserHostResolution
}

/// 收集 native host 已认证 browser bundle 的活动 host 响应，并安全拒绝多 installation 歧义。
public struct ActiveBrowserHostMatchCollector: Sendable {
    private struct Match: Hashable, Sendable {
        let extensionInstallationID: String
        let host: String
    }

    private let browserBundleIdentifier: String
    private var matches: Set<Match> = []

    public init(browserBundleIdentifier: String) {
        self.browserBundleIdentifier = browserBundleIdentifier
    }

    public mutating func record(
        browserBundleIdentifier: String,
        extensionInstallationID: String,
        host: String
    ) {
        guard
            browserBundleIdentifier == self.browserBundleIdentifier,
            !extensionInstallationID.isEmpty,
            !host.isEmpty
        else {
            return
        }
        matches.insert(Match(extensionInstallationID: extensionInstallationID, host: host))
    }

    public var resolution: ActiveBrowserHostResolution {
        guard matches.count == 1, let match = matches.first else {
            return .unavailable
        }
        return .resolved(host: match.host)
    }
}

/// 选择已经命中浏览器窗口、但 relay 无法提供稳定标签页身份。
public enum SelectionTargetError: Error, Equatable, Sendable {
    case browserRelayUnavailable
}

/// 组合单窗口几何解析与 browser relay，输出最终 HookTarget。
public struct SelectionTargetResolver: Sendable {
    private let windowResolver: WindowSelectionResolver
    private let browserRelay: any BrowserSelectionRelaying

    /// 创建不自行猜测浏览器 bundle 或标签页的 Target 解析器。
    public init(
        windowResolver: WindowSelectionResolver,
        browserRelay: any BrowserSelectionRelaying
    ) {
        self.windowResolver = windowResolver
        self.browserRelay = browserRelay
    }

    /// 解析一次 AppKit 全局框选，并只在 relay 明确许可时生成普通 WindowTarget。
    public func resolve(
        appKitSelectionRect: CGRect,
        appKitAnchor: CGPoint,
        windowsFrontToBack: [DiscoveredWindow]
    ) async throws -> HookTarget {
        let selection = try windowResolver.resolve(
            appKitSelectionRect: appKitSelectionRect,
            appKitAnchor: appKitAnchor,
            windowsFrontToBack: windowsFrontToBack
        )

        return try await resolve(selection)
    }

    /// 对已经通过单窗口几何校验的选择执行 browser relay 分类。
    public func resolve(_ selection: ResolvedWindowSelection) async throws -> HookTarget {
        switch try await browserRelay.resolveBrowserTarget(for: selection) {
        case .notBrowser:
            return .window(selection.windowTarget)
        case let .resolved(browserTarget):
            return .browser(browserTarget)
        case .unavailable:
            throw SelectionTargetError.browserRelayUnavailable
        }
    }
}
