import Foundation

/// Hook 的稳定本地身份，用独立类型避免在模块接口中混用其他 UUID。
public struct HookID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// 相对于目标窗口或页面 viewport 的比例区域。
public struct NormalizedRegion: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 区域是否完整落在单位矩形中。
    public var isValid: Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1 && y + height <= 1
    }
}

/// 普通 macOS 应用窗口目标。
public struct WindowTarget: Codable, Equatable, Sendable {
    public let applicationBundleIdentifier: String
    public let windowIdentifier: UInt32
    public let initialTitle: String
    public let normalizedRegion: NormalizedRegion

    public init(
        applicationBundleIdentifier: String,
        windowIdentifier: UInt32,
        initialTitle: String,
        normalizedRegion: NormalizedRegion
    ) {
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.windowIdentifier = windowIdentifier
        self.initialTitle = initialTitle
        self.normalizedRegion = normalizedRegion
    }
}

/// Chromium 扩展绑定的具体标签页目标。
public struct BrowserTarget: Codable, Equatable, Sendable {
    public enum ObservationMode: String, Codable, Sendable {
        case dom
        case image
        case domAndImage
    }

    public let browserBundleIdentifier: String
    public let nativeWindowIdentifier: UInt32
    public let extensionInstallationID: String
    public let tabIdentifier: Int
    public let host: String
    public let initialURL: URL
    public let initialTitle: String
    public let normalizedRegion: NormalizedRegion
    public let observationMode: ObservationMode

    public init(
        browserBundleIdentifier: String,
        nativeWindowIdentifier: UInt32,
        extensionInstallationID: String,
        tabIdentifier: Int,
        host: String,
        initialURL: URL,
        initialTitle: String,
        normalizedRegion: NormalizedRegion,
        observationMode: ObservationMode
    ) {
        self.browserBundleIdentifier = browserBundleIdentifier
        self.nativeWindowIdentifier = nativeWindowIdentifier
        self.extensionInstallationID = extensionInstallationID
        self.tabIdentifier = tabIdentifier
        self.host = host
        self.initialURL = initialURL
        self.initialTitle = initialTitle
        self.normalizedRegion = normalizedRegion
        self.observationMode = observationMode
    }
}

/// Hook 绑定的唯一目标。
public enum HookTarget: Codable, Equatable, Sendable {
    case window(WindowTarget)
    case browser(BrowserTarget)
}

/// 条件判断需要观察的证据种类。
public enum EvidenceRequirement: String, Codable, Sendable {
    case dom
    case image
    case domAndImage
}

/// 用户已经确认过的条件 Hook 定义。
public struct ConditionDefinition: Codable, Equatable, Sendable {
    public let originalText: String
    public let confirmedSummary: String
    public let requiredEvidence: EvidenceRequirement

    public init(
        originalText: String,
        confirmedSummary: String,
        requiredEvidence: EvidenceRequirement
    ) {
        self.originalText = originalText
        self.confirmedSummary = confirmedSummary
        self.requiredEvidence = requiredEvidence
    }
}

/// 延迟 Hook 的最短等待定义；它不是强制通知的截止时间。
public struct DelayDefinition: Codable, Equatable, Sendable {
    public let minimumDelay: TimeInterval

    public init(minimumDelay: TimeInterval) {
        self.minimumDelay = minimumDelay
    }
}

/// Hook 进入“已满足”状态之前采用的触发方式。
public enum HookTrigger: Codable, Equatable, Sendable {
    case condition(ConditionDefinition)
    case delay(DelayDefinition)
}

/// Hook 的稳定生命周期状态；暂时故障由 `HookBlockReason` 单独表达。
public enum HookState: String, Codable, Sendable {
    case draft
    case observing
    case waitingMinimum
    case waitingInterruptible
    case deliveringNotification
    case notified
    case targetUnavailable
    case completed
    case cancelled
}

/// 不改变生命周期事实的暂时阻塞原因。
public enum HookBlockReason: String, Codable, Sendable {
    case modelUnavailable
    case targetMinimized
    case browserExtensionDisconnected
    case capturePermissionMissing
    case notificationPermissionMissing
}

/// 条件稳定确认的有限运行状态。
public struct ConditionProgress: Codable, Equatable, Sendable {
    public var consecutiveMatches: Int
    public var firstMatchAt: Date?

    public init(consecutiveMatches: Int = 0, firstMatchAt: Date? = nil) {
        self.consecutiveMatches = consecutiveMatches
        self.firstMatchAt = firstMatchAt
    }
}

/// 最近一次可以安全落盘的有限判断摘要。
public struct LastDecision: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case condition
        case interruptibility
    }

    public let kind: Kind
    public let value: String
    public let confidence: Double
    public let evaluatedAt: Date

    public init(kind: Kind, value: String, confidence: Double, evaluatedAt: Date) {
        self.kind = kind
        self.value = value
        self.confidence = confidence
        self.evaluatedAt = evaluatedAt
    }
}

/// AwaitCue 运行时持有并持久化的 Hook 聚合。
public struct Hook: Codable, Equatable, Sendable {
    public let id: HookID
    public var title: String
    public var target: HookTarget
    public let trigger: HookTrigger
    public var state: HookState
    public var blockReason: HookBlockReason?
    public let createdAt: Date
    public var updatedAt: Date
    public var earliestAttentionAt: Date?
    public var notifiedAt: Date?
    public var completedAt: Date?
    public var conditionProgress: ConditionProgress?
    public var lastDecision: LastDecision?

    public init(
        id: HookID,
        title: String,
        target: HookTarget,
        trigger: HookTrigger,
        state: HookState,
        blockReason: HookBlockReason? = nil,
        createdAt: Date,
        updatedAt: Date,
        earliestAttentionAt: Date? = nil,
        notifiedAt: Date? = nil,
        completedAt: Date? = nil,
        conditionProgress: ConditionProgress? = nil,
        lastDecision: LastDecision? = nil
    ) {
        self.id = id
        self.title = title
        self.target = target
        self.trigger = trigger
        self.state = state
        self.blockReason = blockReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.earliestAttentionAt = earliestAttentionAt
        self.notifiedAt = notifiedAt
        self.completedAt = completedAt
        self.conditionProgress = conditionProgress
        self.lastDecision = lastDecision
    }
}
