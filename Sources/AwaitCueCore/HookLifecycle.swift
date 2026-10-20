import Foundation

/// 条件模型的三态判断；`uncertain` 不能被折叠为未满足。
public enum ConditionDecision: String, Codable, Sendable {
    case matched
    case notMatched
    case uncertain
}

/// 用户当前是否适合被打断的三态判断。
public enum InterruptibilityDecision: String, Codable, Sendable {
    case interruptible
    case notInterruptible
    case uncertain
}

/// 驱动 Hook 生命周期的外部事实。
public enum HookEvent: Sendable {
    case conditionEvaluated(ConditionDecision, confidence: Double = 1, at: Date)
    case timeAdvanced(to: Date)
    case interruptibilityEvaluated(InterruptibilityDecision, confidence: Double = 1, at: Date)
    case snoozed(minimumDelay: TimeInterval, at: Date)
    case userSessionBecameActive(at: Date)
    case targetBecameUnavailable(at: Date)
    case targetRebound(HookTarget, at: Date)
    case blocked(HookBlockReason, at: Date)
    case unblocked(at: Date)
    case completed(at: Date)
    case cancelled(at: Date)
}

/// 生命周期变化要求调用方执行的副作用。
public enum HookEffect: Equatable, Sendable {
    case deliverNotification(HookID)
}

/// 一次事件处理的完整结果。
public struct HookTransition: Equatable, Sendable {
    public let hook: Hook
    public let effects: [HookEffect]

    public init(hook: Hook, effects: [HookEffect] = []) {
        self.hook = hook
        self.effects = effects
    }
}

/// 调用方试图在不允许的生命周期状态中应用事件。
public enum HookLifecycleError: Error, Equatable {
    case triggerDoesNotSupportEvent
    case invalidState(HookState)
    case invalidMinimumDelay
}

/// 以纯函数方式维护 Hook 状态机，让持久化和系统通知保持在清晰 seam 之外。
public enum HookLifecycle {
    private static let stableMatchInterval: TimeInterval = 3

    /// 将一个外部事实应用到 Hook，并返回新状态及调用方需要执行的副作用。
    public static func apply(_ event: HookEvent, to original: Hook) throws -> HookTransition {
        var hook = original
        var effects: [HookEffect] = []

        switch event {
        case let .conditionEvaluated(decision, confidence, evaluatedAt):
            guard case .condition = hook.trigger else {
                throw HookLifecycleError.triggerDoesNotSupportEvent
            }
            guard hook.state == .observing else {
                throw HookLifecycleError.invalidState(hook.state)
            }

            hook.lastDecision = LastDecision(
                kind: .condition,
                value: decision.rawValue,
                confidence: confidence,
                evaluatedAt: evaluatedAt
            )

            switch decision {
            case .matched:
                var progress = hook.conditionProgress ?? ConditionProgress()
                if let firstMatchAt = progress.firstMatchAt,
                   evaluatedAt.timeIntervalSince(firstMatchAt) >= stableMatchInterval
                {
                    progress.consecutiveMatches += 1
                    if progress.consecutiveMatches >= 2 {
                        hook.state = .waitingInterruptible
                    }
                } else if progress.firstMatchAt == nil {
                    progress = ConditionProgress(consecutiveMatches: 1, firstMatchAt: evaluatedAt)
                }
                hook.conditionProgress = progress

            case .notMatched, .uncertain:
                // 不确定和未满足都会打断连续确认，但二者仍通过 lastDecision 保持可区分。
                hook.conditionProgress = ConditionProgress()
            }
            hook.updatedAt = evaluatedAt

        case let .timeAdvanced(currentTime):
            guard case .delay = hook.trigger else {
                throw HookLifecycleError.triggerDoesNotSupportEvent
            }
            guard hook.state == .waitingMinimum else {
                return HookTransition(hook: hook)
            }
            if let earliestAttentionAt = hook.earliestAttentionAt,
               currentTime >= earliestAttentionAt
            {
                hook.state = .waitingInterruptible
                hook.updatedAt = currentTime
            }

        case let .interruptibilityEvaluated(decision, confidence, evaluatedAt):
            guard hook.state == .waitingInterruptible else {
                throw HookLifecycleError.invalidState(hook.state)
            }
            hook.lastDecision = LastDecision(
                kind: .interruptibility,
                value: decision.rawValue,
                confidence: confidence,
                evaluatedAt: evaluatedAt
            )
            hook.updatedAt = evaluatedAt
            if decision == .interruptible {
                hook.state = .notified
                hook.notifiedAt = evaluatedAt
                effects.append(.deliverNotification(hook.id))
            }

        case let .snoozed(minimumDelay, snoozedAt):
            guard minimumDelay > 0 else {
                throw HookLifecycleError.invalidMinimumDelay
            }
            guard hook.state == .notified else {
                throw HookLifecycleError.invalidState(hook.state)
            }
            hook.state = .waitingMinimum
            hook.earliestAttentionAt = snoozedAt.addingTimeInterval(minimumDelay)
            hook.notifiedAt = nil
            hook.updatedAt = snoozedAt

        case let .userSessionBecameActive(activeAt):
            let delayElapsedWhileInactive: Bool
            if case .delay = hook.trigger,
               let earliestAttentionAt = hook.earliestAttentionAt
            {
                delayElapsedWhileInactive = activeAt >= earliestAttentionAt
            } else {
                delayElapsedWhileInactive = false
            }

            if hook.state == .waitingInterruptible
                || (hook.state == .waitingMinimum && delayElapsedWhileInactive)
            {
                hook.state = .notified
                hook.notifiedAt = activeAt
                hook.updatedAt = activeAt
                effects.append(.deliverNotification(hook.id))
            }

        case let .targetBecameUnavailable(changedAt):
            guard hook.state != .completed, hook.state != .cancelled else {
                throw HookLifecycleError.invalidState(hook.state)
            }
            hook.state = .targetUnavailable
            hook.blockReason = nil
            hook.updatedAt = changedAt

        case let .targetRebound(target, reboundAt):
            guard hook.state == .targetUnavailable else {
                throw HookLifecycleError.invalidState(hook.state)
            }
            hook.target = target
            hook.conditionProgress = ConditionProgress()
            hook.blockReason = nil
            hook.updatedAt = reboundAt
            switch hook.trigger {
            case .condition:
                hook.state = .observing
            case .delay:
                if let earliestAttentionAt = hook.earliestAttentionAt,
                   reboundAt >= earliestAttentionAt
                {
                    hook.state = .waitingInterruptible
                } else {
                    hook.state = .waitingMinimum
                }
            }

        case let .blocked(reason, blockedAt):
            hook.blockReason = reason
            hook.updatedAt = blockedAt

        case let .unblocked(unblockedAt):
            hook.blockReason = nil
            hook.updatedAt = unblockedAt

        case let .completed(completedAt):
            guard hook.state == .notified else {
                throw HookLifecycleError.invalidState(hook.state)
            }
            hook.state = .completed
            hook.completedAt = completedAt
            hook.updatedAt = completedAt

        case let .cancelled(cancelledAt):
            guard hook.state != .completed, hook.state != .cancelled else {
                throw HookLifecycleError.invalidState(hook.state)
            }
            hook.state = .cancelled
            hook.updatedAt = cancelledAt
        }

        return HookTransition(hook: hook, effects: effects)
    }
}
