import AwaitCueCore
import AwaitCueModel
import Foundation

/// Evidence provider 可以交给 Runtime 持久化处理的稳定目标错误。
public enum HookRuntimeEvidenceError: Error, Equatable, Sendable {
    case targetUnavailable
    case targetMinimized
    case browserExtensionDisconnected
    case capturePermissionMissing
    case evidenceIncomplete
    /// 当前活动内容命中本地排除规则；调用方不得截图或把任何证据发给模型。
    case locallyExcluded
}

/// 通知副作用可以安全映射回 Hook 的稳定错误。
public enum HookRuntimeEffectError: Error, Equatable, Sendable {
    case notificationPermissionMissing
}

/// 为一个 Condition Hook 提供当前内存证据；证据不完整时，事件源或周期观察必须再次调用 Runtime。
public protocol HookRuntimeConditionEvidenceProvider: Sendable {
    func evidence(for hook: Hook) async throws -> ModelEvidence
}

/// 提供当前活动上下文的内存证据，供多个已满足 Hook 共享一次判断。
public protocol HookRuntimeActiveEvidenceProvider: Sendable {
    func currentEvidence() async throws -> ModelEvidence
}

/// 把 Runtime 与具体 Responses API 客户端隔开的最小判断接口。
public protocol HookRuntimeDecisionProvider: Sendable {
    func evaluateCondition(
        _ request: ConditionEvaluationRequest
    ) async throws -> ConditionEvaluation

    func evaluateInterruptibility(
        _ request: InterruptibilityEvaluationRequest
    ) async throws -> InterruptibilityEvaluation
}

/// 执行 Core 生命周期返回的通知副作用。
public protocol HookRuntimeEffectExecutor: Sendable {
    func execute(_ effect: HookEffect, for hook: Hook) async throws
}

/// 为 Runtime 提供可替换的当前时间和异步等待能力。
public protocol HookRuntimeClock: Sendable {
    func now() async -> Date
    func sleep(until deadline: Date) async throws
}

extension OpenAIResponsesClient: HookRuntimeDecisionProvider {}
