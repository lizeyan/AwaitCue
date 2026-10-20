import AwaitCueCore
import AwaitCueModel
import Foundation

/// 串行协调证据、模型判断、Hook 生命周期、重试和通知副作用。
public actor HookRuntime {
    private let coordinator: HookCoordinator
    private let conditionEvidenceProvider: any HookRuntimeConditionEvidenceProvider
    private let activeEvidenceProvider: any HookRuntimeActiveEvidenceProvider
    private let decisionProvider: any HookRuntimeDecisionProvider
    private let effectExecutor: any HookRuntimeEffectExecutor
    private let clock: any HookRuntimeClock
    private var interruptibilityRetryTask: Task<Void, any Error>?
    private var conditionRetryTasks: [HookID: Task<Void, Never>] = [:]
    private var interruptibilityGeneration: UInt64 = 0
    private var conditionGenerations: [HookID: UInt64] = [:]
    private var isStopped = false

    /// 创建一个只持有依赖、不持久化任何屏幕或 DOM 证据的 Runtime。
    public init(
        coordinator: HookCoordinator,
        conditionEvidenceProvider: any HookRuntimeConditionEvidenceProvider,
        activeEvidenceProvider: any HookRuntimeActiveEvidenceProvider,
        decisionProvider: any HookRuntimeDecisionProvider,
        effectExecutor: any HookRuntimeEffectExecutor,
        clock: any HookRuntimeClock
    ) {
        self.coordinator = coordinator
        self.conditionEvidenceProvider = conditionEvidenceProvider
        self.activeEvidenceProvider = activeEvidenceProvider
        self.decisionProvider = decisionProvider
        self.effectExecutor = effectExecutor
        self.clock = clock
    }

    /// 采集一个 Condition Hook 的当前证据，并把类型化判断交给 Core 生命周期。
    public func observeCondition(hookID: HookID) async throws {
        guard !isStopped else { return }
        cancelScheduledConditionRetry(for: hookID)
        let generation = (conditionGenerations[hookID] ?? 0) &+ 1
        conditionGenerations[hookID] = generation
        defer {
            if conditionGenerations[hookID] == generation {
                conditionGenerations[hookID] = nil
            }
        }
        guard let hook = try await coordinator.restoreActiveHooks()
            .first(where: { $0.id == hookID })
        else {
            throw HookCoordinatorError.hookNotFound(hookID)
        }
        guard case let .condition(condition) = hook.trigger else {
            throw HookLifecycleError.triggerDoesNotSupportEvent
        }
        guard hook.state == .observing else {
            throw HookLifecycleError.invalidState(hook.state)
        }
        guard isCurrentConditionEvaluation(generation, hookID: hookID) else { return }

        // evidence 只存活到本次判断结束，Runtime 不把文字、图片或模型请求写入 Hook。
        let evidence: ModelEvidence
        do {
            evidence = try await conditionEvidenceProvider.evidence(for: hook)
        } catch let error as HookRuntimeEvidenceError {
            guard isCurrentConditionEvaluation(generation, hookID: hookID) else { return }
            try await applyEvidenceFailure(
                error,
                to: hookID,
                generation: generation
            )
            return
        }
        guard isCurrentConditionEvaluation(generation, hookID: hookID) else { return }
        guard Self.evidence(evidence, satisfies: condition.requiredEvidence) else {
            return
        }
        let evaluation: ConditionEvaluation
        do {
            evaluation = try await decisionProvider.evaluateCondition(
                ConditionEvaluationRequest(condition: condition, evidence: evidence)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard isCurrentConditionEvaluation(generation, hookID: hookID) else { return }
            let failedAt = await clock.now()
            guard isCurrentConditionEvaluation(generation, hookID: hookID) else { return }
            try await applyBlock(.modelUnavailable, to: hookID, at: failedAt)
            scheduleConditionRetry(
                for: hookID,
                at: failedAt.addingTimeInterval(30)
            )
            return
        }
        guard isCurrentConditionEvaluation(generation, hookID: hookID) else { return }
        let evaluatedAt = await clock.now()
        guard isCurrentConditionEvaluation(generation, hookID: hookID) else { return }
        try await clearRecoveredBlockIfNeeded(on: hook, at: evaluatedAt)
        guard isCurrentConditionEvaluation(generation, hookID: hookID) else { return }
        let transition = try await coordinator.apply(
            .conditionEvaluated(
                evaluation.decision,
                confidence: evaluation.confidence,
                at: evaluatedAt
            ),
            to: hookID
        )
        guard isCurrentConditionEvaluation(generation, hookID: hookID) else { return }
        if transition.hook.state == .waitingInterruptible {
            cancelScheduledConditionRetry(for: hookID)
            try await evaluateInterruptibility()
        } else if evaluation.decision == .matched,
                  let firstMatchAt = transition.hook.conditionProgress?.firstMatchAt
        {
            // 页面稳定后可能不再产生 DOM mutation；主动做一次最小稳定确认，避免 Hook 永久停在第一次 matched。
            scheduleConditionRetry(
                for: hookID,
                at: firstMatchAt.addingTimeInterval(3)
            )
        } else {
            cancelScheduledConditionRetry(for: hookID)
        }
    }

    /// 推进已经到达 Minimum Wait 的 Delay 或 Snooze Hook，并让它们进入共享判断。
    public func advanceMinimumWaits() async throws {
        guard !isStopped else { return }
        let now = await clock.now()
        let dueHooks = try await coordinator.restoreActiveHooks().filter { hook in
            guard hook.state == .waitingMinimum,
                  let earliestAttentionAt = hook.earliestAttentionAt
            else {
                return false
            }
            return earliestAttentionAt <= now
        }

        for hook in dueHooks {
            _ = try await coordinator.apply(.timeAdvanced(to: now), to: hook.id)
        }
        if !dueHooks.isEmpty {
            try await evaluateInterruptibility()
        }
    }

    /// 用户会话重新活跃时，直接交付睡眠前已满足或睡眠期间已到时的 Hook。
    public func userSessionBecameActive() async throws {
        guard !isStopped else { return }
        cancelScheduledRetry()
        interruptibilityGeneration &+= 1
        let generation = interruptibilityGeneration
        let activeAt = await clock.now()
        guard generation == interruptibilityGeneration, !isStopped else { return }
        let eligibleHooks = try await coordinator.restoreActiveHooks().filter { hook in
            if hook.state == .waitingInterruptible {
                return true
            }
            guard hook.state == .waitingMinimum,
                  let earliestAttentionAt = hook.earliestAttentionAt
            else {
                return false
            }
            return earliestAttentionAt <= activeAt
        }
        guard generation == interruptibilityGeneration, !isStopped else { return }

        for hook in eligibleHooks {
            guard generation == interruptibilityGeneration, !isStopped else { return }
            try await clearRecoveredBlockIfNeeded(on: hook, at: activeAt)
            guard generation == interruptibilityGeneration, !isStopped else { return }
            let transition = try await coordinator.apply(
                .userSessionBecameActive(at: activeAt),
                to: hook.id
            )
            guard generation == interruptibilityGeneration, !isStopped else {
                if transition.hook.state == .deliveringNotification {
                    _ = try? await coordinator.apply(
                        .notificationDeliveryDeferred(at: activeAt),
                        to: hook.id
                    )
                    if !isStopped {
                        scheduleInterruptibilityRetry(at: activeAt)
                    }
                }
                return
            }
            if try await executeEffects(in: transition) {
                scheduleInterruptibilityRetry(at: activeAt.addingTimeInterval(30))
            }
        }
    }

    /// 应用重启后继续处理已经持久化为“通知交付中”的 Hook。
    public func resumePendingNotificationDeliveries() async throws {
        guard !isStopped else { return }
        let hooks = try await coordinator.restoreActiveHooks()
            .filter { $0.state == .deliveringNotification }
        for hook in hooks {
            let transition = HookTransition(
                hook: hook,
                effects: [.deliverNotification(hook.id)]
            )
            if try await executeEffects(in: transition) {
                scheduleInterruptibilityRetry(
                    at: (await clock.now()).addingTimeInterval(30)
                )
            }
        }
    }

    /// 对全部等待中的 Hook 共享一次当前活动证据和适合打断判断。
    public func evaluateInterruptibility() async throws {
        guard !isStopped else { return }
        cancelScheduledRetry()
        try await evaluateInterruptibilityWithoutCancellingRetry()
    }

    /// 取消等待中的共享重试；已经持久化的 Hook 状态不受影响。
    public func stop() {
        isStopped = true
        interruptibilityGeneration &+= 1
        conditionGenerations.removeAll()
        for task in conditionRetryTasks.values {
            task.cancel()
        }
        conditionRetryTasks.removeAll()
        cancelScheduledRetry()
    }

    private func evaluateInterruptibilityWithoutCancellingRetry() async throws {
        interruptibilityGeneration &+= 1
        let generation = interruptibilityGeneration
        let hooks = try await waitingInterruptibilityHooks()
        guard !hooks.isEmpty else { return }

        // evidence 只作为当前栈上的短生命周期值传给模型，绝不写入 Hook 或 Repository。
        let evidence: ModelEvidence
        do {
            evidence = try await activeEvidenceProvider.currentEvidence()
        } catch let error as HookRuntimeEvidenceError {
            guard generation == interruptibilityGeneration else { return }
            try await handleActiveEvidenceFailure(error, for: hooks, generation: generation)
            return
        }
        guard generation == interruptibilityGeneration else { return }
        let evaluation: InterruptibilityEvaluation
        do {
            evaluation = try await decisionProvider.evaluateInterruptibility(
                InterruptibilityEvaluationRequest(evidence: evidence)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard generation == interruptibilityGeneration else { return }
            let failedAt = await clock.now()
            guard generation == interruptibilityGeneration, !isStopped else { return }
            for hook in hooks {
                try await applyBlock(.modelUnavailable, to: hook.id, at: failedAt)
                guard generation == interruptibilityGeneration, !isStopped else { return }
            }
            scheduleInterruptibilityRetry(at: failedAt.addingTimeInterval(30))
            return
        }
        guard generation == interruptibilityGeneration else { return }
        let evaluatedAt = await clock.now()
        guard generation == interruptibilityGeneration, !isStopped else { return }

        for hook in hooks {
            guard generation == interruptibilityGeneration, !isStopped else { return }
            try await clearRecoveredBlockIfNeeded(on: hook, at: evaluatedAt)
            guard generation == interruptibilityGeneration, !isStopped else { return }
            let transition = try await coordinator.apply(
                .interruptibilityEvaluated(
                    evaluation.decision,
                    confidence: evaluation.confidence,
                    at: evaluatedAt
                ),
                to: hook.id
            )
            guard generation == interruptibilityGeneration, !isStopped else {
                if transition.hook.state == .deliveringNotification {
                    let deferredAt = await clock.now()
                    _ = try? await coordinator.apply(
                        .notificationDeliveryDeferred(at: deferredAt),
                        to: hook.id
                    )
                    if !isStopped {
                        scheduleInterruptibilityRetry(at: deferredAt)
                    }
                }
                return
            }
            let shouldRetry = try await executeEffects(in: transition)
            guard generation == interruptibilityGeneration, !isStopped else { return }
            if shouldRetry {
                scheduleInterruptibilityRetry(
                    at: evaluatedAt.addingTimeInterval(30)
                )
            }
        }

        switch evaluation.decision {
        case .interruptible:
            break
        case .uncertain:
            scheduleInterruptibilityRetry(
                at: evaluatedAt.addingTimeInterval(30)
            )
        case .notInterruptible:
            scheduleInterruptibilityRetry(
                at: evaluatedAt.addingTimeInterval(60)
            )
        }
    }

    private func waitingInterruptibilityHooks() async throws -> [Hook] {
        try await coordinator.restoreActiveHooks()
            .filter { $0.state == .waitingInterruptible }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                }
                return $0.createdAt < $1.createdAt
            }
    }

    private func applyEvidenceFailure(
        _ error: HookRuntimeEvidenceError,
        to hookID: HookID,
        generation: UInt64
    ) async throws {
        guard error != .evidenceIncomplete, error != .locallyExcluded else {
            return
        }
        let occurredAt = await clock.now()
        guard isCurrentConditionEvaluation(generation, hookID: hookID) else { return }
        let event: HookEvent = switch error {
        case .targetUnavailable:
            .targetBecameUnavailable(at: occurredAt)
        case .targetMinimized:
            .blocked(.targetMinimized, at: occurredAt)
        case .browserExtensionDisconnected:
            .blocked(.browserExtensionDisconnected, at: occurredAt)
        case .capturePermissionMissing:
            .blocked(.capturePermissionMissing, at: occurredAt)
        case .evidenceIncomplete:
            preconditionFailure("evidenceIncomplete 已在前置分支处理")
        case .locallyExcluded:
            preconditionFailure("locallyExcluded 已在前置分支处理")
        }
        _ = try await coordinator.apply(event, to: hookID)
    }

    private func applyBlock(
        _ reason: HookBlockReason,
        to hookID: HookID,
        at occurredAt: Date
    ) async throws {
        _ = try await coordinator.apply(.blocked(reason, at: occurredAt), to: hookID)
    }

    private func clearRecoveredBlockIfNeeded(on hook: Hook, at recoveredAt: Date) async throws {
        guard let reason = hook.blockReason, reason != .notificationPermissionMissing else {
            return
        }
        _ = try await coordinator.apply(.unblocked(at: recoveredAt), to: hook.id)
    }

    private func handleActiveEvidenceFailure(
        _ error: HookRuntimeEvidenceError,
        for hooks: [Hook],
        generation: UInt64
    ) async throws {
        let failedAt = await clock.now()
        guard generation == interruptibilityGeneration, !isStopped else { return }
        if error == .locallyExcluded {
            for hook in hooks {
                try await clearRecoveredBlockIfNeeded(on: hook, at: failedAt)
                guard generation == interruptibilityGeneration, !isStopped else { return }
                _ = try await coordinator.apply(
                    .interruptibilityEvaluated(
                        .notInterruptible,
                        confidence: 1,
                        at: failedAt
                    ),
                    to: hook.id
                )
                guard generation == interruptibilityGeneration, !isStopped else { return }
            }
            scheduleInterruptibilityRetry(at: failedAt.addingTimeInterval(60))
            return
        }
        if error == .evidenceIncomplete {
            scheduleInterruptibilityRetry(at: failedAt.addingTimeInterval(30))
            return
        }
        if error == .targetUnavailable {
            // 这里观察的是当前活动上下文，不是 Hook 自己的目标；桌面或系统 UI 只需稍后重试。
            scheduleInterruptibilityRetry(at: failedAt.addingTimeInterval(30))
            return
        }
        let reason: HookBlockReason
        switch error {
        case .targetUnavailable:
            preconditionFailure("targetUnavailable 已在前置分支处理")
        case .targetMinimized:
            reason = .targetMinimized
        case .browserExtensionDisconnected:
            reason = .browserExtensionDisconnected
        case .capturePermissionMissing:
            reason = .capturePermissionMissing
        case .evidenceIncomplete:
            preconditionFailure("evidenceIncomplete 已在前置分支处理")
        case .locallyExcluded:
            preconditionFailure("locallyExcluded 已在前置分支处理")
        }
        for hook in hooks {
            try await applyBlock(reason, to: hook.id, at: failedAt)
            guard generation == interruptibilityGeneration, !isStopped else { return }
        }
        scheduleInterruptibilityRetry(at: failedAt.addingTimeInterval(30))
    }

    private func executeEffects(in transition: HookTransition) async throws -> Bool {
        var shouldRetry = false
        for effect in transition.effects {
            do {
                try await effectExecutor.execute(effect, for: transition.hook)
                _ = try await coordinator.apply(
                    .notificationDelivered(at: await clock.now()),
                    to: transition.hook.id
                )
            } catch HookRuntimeEffectError.notificationPermissionMissing {
                _ = try await coordinator.apply(
                    .notificationDeliveryFailed(
                        .notificationPermissionMissing,
                        at: await clock.now()
                    ),
                    to: transition.hook.id
                )
                shouldRetry = true
            }
        }
        return shouldRetry
    }

    private func scheduleInterruptibilityRetry(at deadline: Date) {
        cancelScheduledRetry()
        let retryClock = clock
        // 只保留一个共享任务，避免每个 Hook 分别截图和请求模型；外部活动变化会取消它并立即重判。
        interruptibilityRetryTask = Task { [weak self, retryClock] in
            try await retryClock.sleep(until: deadline)
            try Task.checkCancellation()
            guard let self else { return }
            try await self.performScheduledInterruptibilityRetry()
        }
    }

    private func performScheduledInterruptibilityRetry() async throws {
        interruptibilityRetryTask = nil
        try await evaluateInterruptibilityWithoutCancellingRetry()
    }

    private func cancelScheduledRetry() {
        interruptibilityRetryTask?.cancel()
        interruptibilityRetryTask = nil
    }

    private func scheduleConditionRetry(for hookID: HookID, at deadline: Date) {
        cancelScheduledConditionRetry(for: hookID)
        let retryClock = clock
        conditionRetryTasks[hookID] = Task { [weak self, retryClock] in
            do {
                try await retryClock.sleep(until: deadline)
                try Task.checkCancellation()
                await self?.performScheduledConditionRetry(for: hookID)
            } catch {
                // 外部证据或 Runtime stop 会取消旧任务；取消不是 Hook 故障。
            }
        }
    }

    private func performScheduledConditionRetry(for hookID: HookID) async {
        conditionRetryTasks[hookID] = nil
        try? await observeCondition(hookID: hookID)
    }

    private func cancelScheduledConditionRetry(for hookID: HookID) {
        conditionRetryTasks[hookID]?.cancel()
        conditionRetryTasks[hookID] = nil
    }

    private func isCurrentConditionEvaluation(_ generation: UInt64, hookID: HookID) -> Bool {
        !isStopped && conditionGenerations[hookID] == generation
    }

    private static func evidence(
        _ evidence: ModelEvidence,
        satisfies requirement: EvidenceRequirement
    ) -> Bool {
        let hasDOM = !(evidence.domText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasImage = !(evidence.image?.data.isEmpty ?? true)
        return switch requirement {
        case .dom: hasDOM
        case .image: hasImage
        case .domAndImage: hasDOM && hasImage
        }
    }
}
