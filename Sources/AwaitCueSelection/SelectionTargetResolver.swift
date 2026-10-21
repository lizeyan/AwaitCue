import AwaitCueCapture
import AwaitCueCore
import CoreGraphics

/// 浏览器框选无法稳定解析到具体标签页的原因；raw value 与扩展协议保持一致。
public enum BrowserSelectionFailureReason: String, Equatable, Hashable, Sendable {
    case windowNotMatched = "window_not_matched"
    case activeTabUnavailable = "active_tab_unavailable"
    case selectionOutsideViewport = "selection_outside_viewport"
    case pageAccessUnavailable = "page_access_unavailable"
    case invalidPageResponse = "invalid_page_response"
    case noExtensionResponse = "no_extension_response"
    case ambiguousResponse = "ambiguous_response"
}

/// Native/browser relay 对当前窗口框选的明确分类结果。
public enum BrowserSelectionRelayResolution: Equatable, Sendable {
    /// relay 已确认该窗口不是由浏览器标签页接管的 Target。
    case notBrowser
    /// relay 已根据具体标签页和 viewport 生成 BrowserTarget。
    case resolved(BrowserTarget)
    /// relay 已识别浏览器窗口，但当前无法可靠解析具体标签页。
    case unavailable(BrowserSelectionFailureReason)
}

/// 追踪一次广播需要等待多少个扩展实例响应，并容忍响应早于 peer 数量回传。
public struct BrowserSelectionResponseGate: Equatable, Sendable {
    private var expectedResponseCount: Int?
    private var hasAcceptedResponse = false

    public init() {}

    public mutating func setExpectedResponseCount(_ count: Int) {
        expectedResponseCount = max(0, count)
    }

    public mutating func recordAcceptedResponse() {
        hasAcceptedResponse = true
    }

    public var isComplete: Bool {
        guard let expectedResponseCount else { return false }
        return expectedResponseCount == 0
            || (expectedResponseCount == 1 && hasAcceptedResponse)
    }
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
    private var failures: Set<BrowserSelectionFailureReason> = []

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

    public mutating func recordFailure(
        browserBundleIdentifier: String,
        reason: BrowserSelectionFailureReason
    ) {
        guard browserBundleIdentifier == self.browserBundleIdentifier else { return }
        failures.insert(reason)
    }

    public var resolution: BrowserSelectionRelayResolution {
        if matches.count == 1 {
            return .resolved(matches[0])
        }
        if matches.count > 1 {
            return .unavailable(.ambiguousResponse)
        }
        // 多个 Chrome profile 可能各自返回失败；优先展示最接近用户操作的具体原因。
        let priority: [BrowserSelectionFailureReason] = [
            .selectionOutsideViewport,
            .pageAccessUnavailable,
            .invalidPageResponse,
            .activeTabUnavailable,
            .windowNotMatched,
        ]
        return priority.first(where: failures.contains)
            .map(BrowserSelectionRelayResolution.unavailable)
            ?? .unavailable(.noExtensionResponse)
    }
}

/// 当前前台浏览器 host 查询的安全结果。
public struct ActiveBrowserContext: Equatable, Hashable, Sendable {
    public let extensionInstallationID: String
    public let tabIdentifier: Int
    public let browserWindowIdentifier: Int
    public let host: String

    public init(
        extensionInstallationID: String,
        tabIdentifier: Int,
        browserWindowIdentifier: Int,
        host: String
    ) {
        self.extensionInstallationID = extensionInstallationID
        self.tabIdentifier = tabIdentifier
        self.browserWindowIdentifier = browserWindowIdentifier
        self.host = host
    }
}

public enum ActiveBrowserHostResolution: Equatable, Sendable {
    /// 前台应用不是 Selection 模块支持的 Chromium 浏览器。
    case notBrowser
    /// 恰好一个匹配 browser bundle 的 installation 返回了活动标签页 host。
    case resolved(ActiveBrowserContext)
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
        let tabIdentifier: Int
        let browserWindowIdentifier: Int
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
        tabIdentifier: Int,
        browserWindowIdentifier: Int,
        host: String
    ) {
        guard
            browserBundleIdentifier == self.browserBundleIdentifier,
            !extensionInstallationID.isEmpty,
            !host.isEmpty
        else {
            return
        }
        matches.insert(
            Match(
                extensionInstallationID: extensionInstallationID,
                tabIdentifier: tabIdentifier,
                browserWindowIdentifier: browserWindowIdentifier,
                host: host
            )
        )
    }

    public var resolution: ActiveBrowserHostResolution {
        guard matches.count == 1, let match = matches.first else {
            return .unavailable
        }
        return .resolved(
            ActiveBrowserContext(
                extensionInstallationID: match.extensionInstallationID,
                tabIdentifier: match.tabIdentifier,
                browserWindowIdentifier: match.browserWindowIdentifier,
                host: match.host
            )
        )
    }
}

/// 选择已经命中浏览器窗口、但 relay 无法提供稳定标签页身份。
public enum SelectionTargetError: Error, Equatable, Sendable {
    case browserRelayUnavailable(BrowserSelectionFailureReason)
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
        case let .unavailable(reason):
            throw SelectionTargetError.browserRelayUnavailable(reason)
        }
    }
}
