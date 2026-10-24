import AwaitCueCore
import AwaitCueModel
import Foundation
import Testing
@testable import AwaitCueRuntime

@Suite("Hook Runtime", .serialized)
struct HookRuntimeTests {
    @Test("Condition 观察拒绝不存在、错误 trigger 和错误生命周期状态")
    func conditionObservationValidatesHookBeforeEvidence() async throws {
        let now = Date(timeIntervalSince1970: 114_000)
        let missingRepository = RuntimeHookRepository(hooks: [])
        let missingRuntime = makeValidationRuntime(repository: missingRepository, now: now)
        let missingID = HookID(rawValue: UUID())
        await #expect(throws: HookCoordinatorError.hookNotFound(missingID)) {
            try await missingRuntime.observeCondition(hookID: missingID)
        }

        let delay = makeDelayHook(id: UUID().uuidString, earliestAttentionAt: now, now: now)
        let delayRuntime = makeValidationRuntime(repository: RuntimeHookRepository(hooks: [delay]), now: now)
        await #expect(throws: HookLifecycleError.triggerDoesNotSupportEvent) {
            try await delayRuntime.observeCondition(hookID: delay.id)
        }

        var wrongState = makeObservingHook(id: UUID().uuidString, now: now)
        wrongState.state = .waitingInterruptible
        let wrongStateRuntime = makeValidationRuntime(
            repository: RuntimeHookRepository(hooks: [wrongState]),
            now: now
        )
        await #expect(throws: HookLifecycleError.invalidState(.waitingInterruptible)) {
            try await wrongStateRuntime.observeCondition(hookID: wrongState.id)
        }
    }

    @Test("较旧的 Condition 判断晚返回时不会覆盖更新结果")
    func staleConditionEvaluationCannotOverwriteNewerResult() async throws {
        let now = Date(timeIntervalSince1970: 114_500)
        let hook = makeObservingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [hook])
        let decisions = OutOfOrderConditionDecisionProvider()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(fixtureConditionImageEvidence(text: "状态变化"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            decisionProvider: decisions,
            effectExecutor: RecordingEffectExecutor(),
            clock: FixedRuntimeClock(now: now)
        )

        let olderEvaluation = Task {
            try await runtime.observeCondition(hookID: hook.id)
        }
        try await waitUntil { await decisions.conditionCallCount == 1 }
        try await runtime.observeCondition(hookID: hook.id)
        await decisions.resumeFirstEvaluation(
            with: ConditionEvaluation(decision: .matched, confidence: 0.9)
        )
        try await olderEvaluation.value

        let stored = try #require(await repository.hooks.first)
        #expect(stored.lastDecision?.value == ConditionDecision.notMatched.rawValue)
        #expect(await decisions.conditionCallCount == 2)
    }

    @Test("notInterruptible 安排六十秒重试，活动变化可以立即重新判断")
    func manualEvaluationReplacesNotInterruptibleRetry() async throws {
        let now = Date(timeIntervalSince1970: 113_000)
        let hook = makeWaitingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [hook])
        let clock = ControllableRuntimeClock(now: now)
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: [
                .success(InterruptibilityEvaluation(decision: .notInterruptible, confidence: 0.85)),
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 0.9)),
            ]
        )
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "当前活动"))
            ),
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: clock
        )

        try await runtime.evaluateInterruptibility()
        try await waitUntil { await clock.deadlines.count == 1 }
        #expect(await clock.deadlines == [now.addingTimeInterval(60)])

        try await runtime.evaluateInterruptibility()

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .notified)
        #expect(await decisions.interruptibilityCallCount == 2)
        #expect(await effects.deliveredHookIDs == [hook.id])
        await runtime.stop()
    }

    @Test("较旧的适合打断判断晚返回时不会覆盖更新结果或发送通知")
    func staleInterruptibilityEvaluationCannotNotify() async throws {
        let now = Date(timeIntervalSince1970: 113_500)
        let hook = makeWaitingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [hook])
        let decisions = OutOfOrderInterruptibilityDecisionProvider()
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "活动变化"))
            ),
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now)
        )

        let olderEvaluation = Task {
            try await runtime.evaluateInterruptibility()
        }
        try await waitUntil { await decisions.interruptibilityCallCount == 1 }
        try await runtime.evaluateInterruptibility()
        await decisions.resumeFirstEvaluation(
            with: InterruptibilityEvaluation(decision: .interruptible, confidence: 0.95)
        )
        try await olderEvaluation.value

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .waitingInterruptible)
        #expect(stored.lastDecision?.value == InterruptibilityDecision.notInterruptible.rawValue)
        #expect(await effects.deliveredHookIDs.isEmpty)
    }

    @Test("Runtime 停止后忽略仍在进行中的模型结果")
    func stopInvalidatesInFlightInterruptibilityEvaluation() async throws {
        let now = Date(timeIntervalSince1970: 113_750)
        let hook = makeWaitingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [hook])
        let decisions = OutOfOrderInterruptibilityDecisionProvider()
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "当前活动"))
            ),
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now)
        )

        let evaluation = Task {
            try await runtime.evaluateInterruptibility()
        }
        try await waitUntil { await decisions.interruptibilityCallCount == 1 }
        await runtime.stop()
        await decisions.resumeFirstEvaluation(
            with: InterruptibilityEvaluation(decision: .interruptible, confidence: 1)
        )
        try await evaluation.value

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .waitingInterruptible)
        #expect(stored.lastDecision == nil)
        #expect(await effects.deliveredHookIDs.isEmpty)
    }

    @Test("Runtime 停止后所有公开推进入口都保持静默")
    func stoppedRuntimeIgnoresAllEntryPoints() async throws {
        let now = Date(timeIntervalSince1970: 113_900)
        let observing = makeObservingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [observing])
        let conditionEvidence = RecordingConditionEvidenceProvider(
            result: .success(fixtureConditionImageEvidence(text: "不应读取"))
        )
        let activeEvidence = RecordingActiveEvidenceProvider(
            result: .success(ModelEvidence(text: "不应读取"))
        )
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: []
        )
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: conditionEvidence,
            activeEvidenceProvider: activeEvidence,
            decisionProvider: decisions,
            effectExecutor: RecordingEffectExecutor(),
            clock: FixedRuntimeClock(now: now)
        )

        await runtime.stop()
        try await runtime.observeCondition(hookID: observing.id)
        try await runtime.advanceMinimumWaits()
        try await runtime.userSessionBecameActive()
        try await runtime.resumePendingNotificationDeliveries()
        try await runtime.evaluateInterruptibility()

        #expect(await conditionEvidence.callCount == 0)
        #expect(await activeEvidence.callCount == 0)
        #expect(await decisions.conditionCallCount == 0)
        #expect(await decisions.interruptibilityCallCount == 0)
    }

    @Test("Runtime 在通知状态落盘期间停止会撤销尚未执行的通知")
    func stopDuringNotificationReservationDefersDelivery() async throws {
        let now = Date(timeIntervalSince1970: 113_950)
        let hook = makeWaitingHook(id: UUID().uuidString, now: now)
        let repository = SuspendingDeliveryRepository(hook: hook)
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "适合打断"))
            ),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: [
                    .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 1)),
                ]
            ),
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now)
        )

        let evaluation = Task { try await runtime.evaluateInterruptibility() }
        try await waitUntil { await repository.isDeliverySaveSuspended }
        await runtime.stop()
        await repository.releaseDeliverySave()
        try await evaluation.value

        #expect(await repository.hook.state == .waitingInterruptible)
        #expect(await effects.deliveredHookIDs.isEmpty)
    }

    @Test("稳定满足 Condition 后自动进入适合打断判断并通知")
    func conditionMatchFlowsThroughInterruptibilityAndNotification() async throws {
        let now = Date(timeIntervalSince1970: 112_000)
        var hook = makeObservingHook(id: UUID().uuidString, now: now.addingTimeInterval(-10))
        hook.conditionProgress = ConditionProgress(
            consecutiveMatches: 1,
            firstMatchAt: now.addingTimeInterval(-4)
        )
        let repository = RuntimeHookRepository(hooks: [hook])
        let decisions = RecordingDecisionProvider(
            conditionResults: [
                .success(ConditionEvaluation(decision: .matched, confidence: 0.9)),
            ],
            interruptibilityResults: [
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 0.8)),
            ]
        )
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(fixtureConditionImageEvidence(text: "已经完成"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "适合打断"))
            ),
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.observeCondition(hookID: hook.id)

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .notified)
        #expect(stored.lastDecision?.kind == .interruptibility)
        #expect(await decisions.conditionCallCount == 1)
        #expect(await decisions.interruptibilityCallCount == 1)
        #expect(await effects.deliveredHookIDs == [hook.id])
    }

    @Test("浏览器内容不再变化时仍会在三秒后完成第二次稳定确认")
    func matchedConditionSchedulesStableRecheck() async throws {
        let now = Date(timeIntervalSince1970: 112_500)
        let hook = makeObservingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [hook])
        let clock = ControllableRuntimeClock(now: now)
        let decisions = RecordingDecisionProvider(
            conditionResults: [
                .success(ConditionEvaluation(decision: .matched, confidence: 0.9)),
                .success(ConditionEvaluation(decision: .matched, confidence: 0.9)),
            ],
            interruptibilityResults: [
                .success(InterruptibilityEvaluation(decision: .notInterruptible, confidence: 0.9)),
            ]
        )
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(fixtureConditionImageEvidence(text: "已经完成"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "暂不打断"))
            ),
            decisionProvider: decisions,
            effectExecutor: RecordingEffectExecutor(),
            clock: clock
        )

        try await runtime.observeCondition(hookID: hook.id)
        try await waitUntil { await clock.deadlines.count == 1 }
        #expect(await clock.deadlines.first == now.addingTimeInterval(3))
        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.fireNextSleep()
        try await waitUntil {
            let state = await repository.hooksByID[hook.id]?.state
            let interruptionCalls = await decisions.interruptibilityCallCount
            return state == .waitingInterruptible && interruptionCalls == 1
        }

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .waitingInterruptible)
        #expect(await decisions.interruptibilityCallCount == 1)
        await runtime.stop()
    }

    @Test("Condition evidence 的不可用和权限错误映射为稳定状态或 blockReason")
    func mapsConditionEvidenceFailures() async throws {
        let now = Date(timeIntervalSince1970: 110_000)
        let cases: [(HookRuntimeEvidenceError, HookState, HookBlockReason?)] = [
            (.targetUnavailable, .targetUnavailable, nil),
            (.browserExtensionDisconnected, .observing, .browserExtensionDisconnected),
            (.capturePermissionMissing, .observing, .capturePermissionMissing),
        ]

        for (error, expectedState, expectedReason) in cases {
            let hook = makeObservingHook(id: UUID().uuidString, now: now)
            let repository = RuntimeHookRepository(hooks: [hook])
            let runtime = HookRuntime(
                coordinator: HookCoordinator(repository: repository),
                conditionEvidenceProvider: FailingConditionEvidenceProvider(error: error),
                activeEvidenceProvider: RecordingActiveEvidenceProvider(
                    result: .success(ModelEvidence(text: "unused"))
                ),
                decisionProvider: RecordingDecisionProvider(
                    conditionResults: [],
                    interruptibilityResults: []
                ),
                effectExecutor: RecordingEffectExecutor(),
                clock: FixedRuntimeClock(now: now)
            )

            try await runtime.observeCondition(hookID: hook.id)

            let stored = try #require(await repository.hooks.first)
            #expect(stored.state == expectedState)
            #expect(stored.blockReason == expectedReason)
        }
    }

    @Test("Runtime 在调用模型前统一拒绝缺少所需类型的 Condition evidence")
    func requiredEvidenceIsEnforcedBeforeModelCall() async throws {
        let now = Date(timeIntervalSince1970: 110_500)
        let cases: [(EvidenceRequirement, ModelEvidence)] = [
            (.dom, ModelEvidence(text: "普通上下文不是 DOM")),
            (.image, ModelEvidence(domText: "只有 DOM")),
            (.domAndImage, ModelEvidence(domText: "缺少图片")),
        ]

        for (requirement, evidence) in cases {
            let hook = makeObservingHook(
                id: UUID().uuidString,
                now: now,
                requiredEvidence: requirement
            )
            let repository = RuntimeHookRepository(hooks: [hook])
            let decisions = RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: []
            )
            let runtime = HookRuntime(
                coordinator: HookCoordinator(repository: repository),
                conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                    result: .success(evidence)
                ),
                activeEvidenceProvider: RecordingActiveEvidenceProvider(
                    result: .success(ModelEvidence(text: "unused"))
                ),
                decisionProvider: decisions,
                effectExecutor: RecordingEffectExecutor(),
                clock: FixedRuntimeClock(now: now)
            )

            try await runtime.observeCondition(hookID: hook.id)

            #expect(await decisions.conditionCallCount == 0)
            let stored = await repository.hooksByID[hook.id]
            #expect(stored?.lastDecision == nil)
        }
    }

    @Test("DOM 与 DOM+图片证据完整时允许进入 Condition 模型判断")
    func completeDOMEvidenceReachesModel() async throws {
        let now = Date(timeIntervalSince1970: 110_600)
        let cases: [(EvidenceRequirement, ModelEvidence)] = [
            (.dom, ModelEvidence(domText: "DOM ready")),
            (
                .domAndImage,
                ModelEvidence(
                    domText: "DOM ready",
                    image: ModelImage(data: Data([0x89]), mediaType: "image/png")
                )
            ),
        ]

        for (requirement, evidence) in cases {
            let hook = makeObservingHook(
                id: UUID().uuidString,
                now: now,
                requiredEvidence: requirement
            )
            let repository = RuntimeHookRepository(hooks: [hook])
            let decisions = RecordingDecisionProvider(
                conditionResults: [
                    .success(ConditionEvaluation(decision: .notMatched, confidence: 0.8)),
                ],
                interruptibilityResults: []
            )
            let runtime = HookRuntime(
                coordinator: HookCoordinator(repository: repository),
                conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                    result: .success(evidence)
                ),
                activeEvidenceProvider: RecordingActiveEvidenceProvider(
                    result: .success(ModelEvidence(text: "unused"))
                ),
                decisionProvider: decisions,
                effectExecutor: RecordingEffectExecutor(),
                clock: FixedRuntimeClock(now: now)
            )

            try await runtime.observeCondition(hookID: hook.id)
            #expect(await decisions.conditionCallCount == 1)
        }
    }

    @Test("旧浏览器 Hook 即使曾要求图片也只用 DOM 进入判断")
    func legacyBrowserImageRequirementMigratesToDOM() async throws {
        let now = Date(timeIntervalSince1970: 110_650)
        let hook = makeBrowserObservingHook(
            id: UUID().uuidString,
            now: now,
            requiredEvidence: .domAndImage
        )
        let repository = RuntimeHookRepository(hooks: [hook])
        let decisions = RecordingDecisionProvider(
            conditionResults: [
                .success(ConditionEvaluation(decision: .notMatched, confidence: 0.8)),
            ],
            interruptibilityResults: []
        )
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(domText: "DOM ready"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            decisionProvider: decisions,
            effectExecutor: RecordingEffectExecutor(),
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.observeCondition(hookID: hook.id)

        #expect(await decisions.conditionCallCount == 1)
    }

    @Test("Condition provider 报告局部证据未完成时保持观察且不调用模型")
    func partialConditionEvidenceWaitsForNextObservation() async throws {
        let now = Date(timeIntervalSince1970: 110_700)
        for error in [HookRuntimeEvidenceError.evidenceIncomplete, .locallyExcluded] {
            let hook = makeObservingHook(id: UUID().uuidString, now: now)
            let repository = RuntimeHookRepository(hooks: [hook])
            let decisions = RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: []
            )
            let runtime = HookRuntime(
                coordinator: HookCoordinator(repository: repository),
                conditionEvidenceProvider: FailingConditionEvidenceProvider(error: error),
                activeEvidenceProvider: RecordingActiveEvidenceProvider(
                    result: .success(ModelEvidence(text: "unused"))
                ),
                decisionProvider: decisions,
                effectExecutor: RecordingEffectExecutor(),
                clock: FixedRuntimeClock(now: now)
            )

            try await runtime.observeCondition(hookID: hook.id)
            #expect((await repository.hooksByID[hook.id])?.state == .observing)
            #expect(await decisions.conditionCallCount == 0)
        }
    }

    @Test("当前活动证据暂不可用时阻塞全部等待 Hook 并共享一次重试")
    func mapsActiveEvidenceFailureAndSchedulesSharedRetry() async throws {
        let now = Date(timeIntervalSince1970: 111_000)
        let cases: [(HookRuntimeEvidenceError, HookBlockReason)] = [
            (.targetMinimized, .targetMinimized),
            (.browserExtensionDisconnected, .browserExtensionDisconnected),
            (.capturePermissionMissing, .capturePermissionMissing),
        ]

        for (error, expectedReason) in cases {
            let first = makeWaitingHook(id: UUID().uuidString, now: now)
            let second = makeWaitingHook(id: UUID().uuidString, now: now.addingTimeInterval(1))
            let repository = RuntimeHookRepository(hooks: [first, second])
            let clock = ControllableRuntimeClock(now: now)
            let decisions = RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: []
            )
            let runtime = HookRuntime(
                coordinator: HookCoordinator(repository: repository),
                conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                    result: .success(ModelEvidence(text: "unused"))
                ),
                activeEvidenceProvider: FailingActiveEvidenceProvider(error: error),
                decisionProvider: decisions,
                effectExecutor: RecordingEffectExecutor(),
                clock: clock
            )

            try await runtime.evaluateInterruptibility()

            let stored = await repository.hooks
            #expect(stored.allSatisfy { $0.state == .waitingInterruptible })
            #expect(stored.allSatisfy { $0.blockReason == expectedReason })
            #expect(await decisions.interruptibilityCallCount == 0)
            try await waitUntil { await clock.deadlines.count == 1 }
            #expect(await clock.deadlines == [now.addingTimeInterval(30)])
            await runtime.stop()
        }
    }

    @Test("活动窗口被本地排除时不调用模型并按不可打断继续等待")
    func locallyExcludedActivitySkipsModelAndRetriesNormally() async throws {
        let now = Date(timeIntervalSince1970: 110_500)
        let hook = makeWaitingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [hook])
        let clock = ControllableRuntimeClock(now: now)
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: []
        )
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: FailingActiveEvidenceProvider(error: .locallyExcluded),
            decisionProvider: decisions,
            effectExecutor: RecordingEffectExecutor(),
            clock: clock
        )

        try await runtime.evaluateInterruptibility()

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .waitingInterruptible)
        #expect(stored.lastDecision?.value == InterruptibilityDecision.notInterruptible.rawValue)
        #expect(stored.blockReason == nil)
        #expect(await decisions.interruptibilityCallCount == 0)
        try await waitUntil { await clock.deadlines.count == 1 }
        #expect(await clock.deadlines == [now.addingTimeInterval(60)])
        await runtime.stop()
    }

    @Test("通知权限错误保留等待通知状态并记录对应 blockReason")
    func mapsNotificationPermissionFailureAfterLifecycleTransition() async throws {
        let now = Date(timeIntervalSince1970: 109_000)
        let hook = makeWaitingHook(
            id: "00000000-0000-0000-0000-000000001015",
            now: now
        )
        let repository = RuntimeHookRepository(hooks: [hook])
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "适合打断"))
            ),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: [
                    .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 1)),
                ]
            ),
            effectExecutor: FailingEffectExecutor(error: .notificationPermissionMissing),
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.evaluateInterruptibility()

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .waitingInterruptible)
        #expect(stored.blockReason == .notificationPermissionMissing)
    }

    @Test("通知失败后重新判断，权限恢复时完成交付")
    func retriesNotificationAfterDeliveryFailure() async throws {
        let now = Date(timeIntervalSince1970: 109_500)
        let hook = makeWaitingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [hook])
        let clock = ControllableRuntimeClock(now: now)
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: [
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 1)),
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 1)),
            ]
        )
        let effects = SequencedEffectExecutor(results: [
            .failure(.notificationPermissionMissing),
            .success(()),
        ])
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "适合打断"))
            ),
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: clock
        )

        try await runtime.evaluateInterruptibility()
        try await waitUntil { await clock.deadlines.count == 1 }
        let failed = try #require(await repository.hooks.first)
        #expect(failed.state == .waitingInterruptible)
        #expect(failed.blockReason == .notificationPermissionMissing)
        #expect(await clock.deadlines == [now.addingTimeInterval(30)])

        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.fireNextSleep()
        try await waitUntil {
            await repository.hooksByID[hook.id]?.state == .notified
        }

        let delivered = try #require(await repository.hooks.first)
        #expect(delivered.state == .notified)
        #expect(delivered.blockReason == nil)
        #expect(await effects.attemptCount == 2)
        await runtime.stop()
    }

    @Test("当前没有可捕获窗口时保留 Hook 并安排重试")
    func retriesWhenActiveWindowIsTemporarilyUnavailable() async throws {
        let now = Date(timeIntervalSince1970: 109_750)
        let hook = makeWaitingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [hook])
        let clock = ControllableRuntimeClock(now: now)
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: []
        )
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: FailingActiveEvidenceProvider(error: .targetUnavailable),
            decisionProvider: decisions,
            effectExecutor: RecordingEffectExecutor(),
            clock: clock
        )

        try await runtime.evaluateInterruptibility()

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .waitingInterruptible)
        #expect(stored.blockReason == nil)
        #expect(await decisions.interruptibilityCallCount == 0)
        try await waitUntil { await clock.deadlines.count == 1 }
        #expect(await clock.deadlines == [now.addingTimeInterval(30)])
        await runtime.stop()
    }

    @Test("当前活动证据尚未完整时安排重试而不写入阻塞原因")
    func retriesWhenActiveEvidenceIsIncomplete() async throws {
        let now = Date(timeIntervalSince1970: 109_800)
        let hook = makeWaitingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [hook])
        let clock = ControllableRuntimeClock(now: now)
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: FailingActiveEvidenceProvider(error: .evidenceIncomplete),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: []
            ),
            effectExecutor: RecordingEffectExecutor(),
            clock: clock
        )

        try await runtime.evaluateInterruptibility()

        #expect((await repository.hooksByID[hook.id])?.blockReason == nil)
        try await waitUntil { await clock.deadlines.count == 1 }
        #expect(await clock.deadlines == [now.addingTimeInterval(30)])
        await runtime.stop()
    }

    @Test("没有等待中的 Hook 时不采集当前活动证据")
    func emptyWaitingSetSkipsActiveEvidence() async throws {
        let now = Date(timeIntervalSince1970: 109_850)
        let observing = makeObservingHook(id: UUID().uuidString, now: now)
        let activeEvidence = RecordingActiveEvidenceProvider(
            result: .success(ModelEvidence(text: "不应读取"))
        )
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: RuntimeHookRepository(hooks: [observing])),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: activeEvidence,
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: []
            ),
            effectExecutor: RecordingEffectExecutor(),
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.evaluateInterruptibility()
        try await runtime.advanceMinimumWaits()

        #expect(await activeEvidence.callCount == 0)
    }

    @Test("应用重启后继续交付已经持久化的通知")
    func resumesPersistedNotificationDelivery() async throws {
        let now = Date(timeIntervalSince1970: 109_900)
        var hook = makeWaitingHook(id: UUID().uuidString, now: now)
        hook.state = .deliveringNotification
        let repository = RuntimeHookRepository(hooks: [hook])
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: []
            ),
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.resumePendingNotificationDeliveries()

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .notified)
        #expect(await effects.deliveredHookIDs == [hook.id])
    }

    @Test("恢复中的通知失败时回到等待并安排重新判断")
    func resumedNotificationFailureSchedulesRetry() async throws {
        let now = Date(timeIntervalSince1970: 109_950)
        var hook = makeWaitingHook(id: UUID().uuidString, now: now)
        hook.state = .deliveringNotification
        let repository = RuntimeHookRepository(hooks: [hook])
        let clock = ControllableRuntimeClock(now: now)
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: []
            ),
            effectExecutor: FailingEffectExecutor(error: .notificationPermissionMissing),
            clock: clock
        )

        try await runtime.resumePendingNotificationDeliveries()

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .waitingInterruptible)
        #expect(stored.blockReason == .notificationPermissionMissing)
        try await waitUntil { await clock.deadlines.count == 1 }
        #expect(await clock.deadlines == [now.addingTimeInterval(30)])
        await runtime.stop()
    }

    @Test("会话唤醒直接通知已满足和已到时 Hook，不再请求模型")
    func activeSessionDeliversEligibleHooksWithoutDecision() async throws {
        let now = Date(timeIntervalSince1970: 108_000)
        var satisfied = makeWaitingHook(
            id: "00000000-0000-0000-0000-000000001012",
            now: now.addingTimeInterval(-60)
        )
        satisfied.blockReason = .modelUnavailable
        let elapsedDelay = makeDelayHook(
            id: "00000000-0000-0000-0000-000000001013",
            earliestAttentionAt: now.addingTimeInterval(-1),
            now: now.addingTimeInterval(-120)
        )
        let futureDelay = makeDelayHook(
            id: "00000000-0000-0000-0000-000000001014",
            earliestAttentionAt: now.addingTimeInterval(60),
            now: now.addingTimeInterval(-30)
        )
        let repository = RuntimeHookRepository(hooks: [satisfied, elapsedDelay, futureDelay])
        let activeEvidence = RecordingActiveEvidenceProvider(
            result: .success(ModelEvidence(text: "不应读取"))
        )
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: []
        )
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: activeEvidence,
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.userSessionBecameActive()

        let stored = await repository.hooksByID
        #expect(stored[satisfied.id]?.state == .notified)
        #expect(stored[satisfied.id]?.blockReason == nil)
        #expect(stored[elapsedDelay.id]?.state == .notified)
        #expect(stored[futureDelay.id]?.state == .waitingMinimum)
        #expect(await activeEvidence.callCount == 0)
        #expect(await decisions.interruptibilityCallCount == 0)
        #expect(Set(await effects.deliveredHookIDs) == [satisfied.id, elapsedDelay.id])
    }

    @Test("会话唤醒通知失败时保留等待状态并安排重新判断")
    func activeSessionNotificationFailureSchedulesRetry() async throws {
        let now = Date(timeIntervalSince1970: 108_500)
        let hook = makeWaitingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [hook])
        let clock = ControllableRuntimeClock(now: now)
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: []
            ),
            effectExecutor: FailingEffectExecutor(error: .notificationPermissionMissing),
            clock: clock
        )

        try await runtime.userSessionBecameActive()

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .waitingInterruptible)
        #expect(stored.blockReason == .notificationPermissionMissing)
        try await waitUntil { await clock.deadlines.count == 1 }
        #expect(await clock.deadlines == [now.addingTimeInterval(30)])
        await runtime.stop()
    }

    @Test("会话唤醒通知落盘期间停止会撤销尚未执行的通知")
    func stopDuringSessionNotificationReservationDefersDelivery() async throws {
        let now = Date(timeIntervalSince1970: 108_750)
        let hook = makeWaitingHook(id: UUID().uuidString, now: now)
        let repository = SuspendingDeliveryRepository(hook: hook)
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: []
            ),
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now)
        )

        let wake = Task { try await runtime.userSessionBecameActive() }
        try await waitUntil { await repository.isDeliverySaveSuspended }
        await runtime.stop()
        await repository.releaseDeliverySave()
        try await wake.value

        #expect(await repository.hook.state == .waitingInterruptible)
        #expect(await effects.deliveredHookIDs.isEmpty)
    }

    @Test("共享适合打断判断的模型错误阻塞全部 Hook 并在三十秒后重试")
    func blocksWaitingHooksAndRetriesAfterModelFailure() async throws {
        let now = Date(timeIntervalSince1970: 107_000)
        let first = makeWaitingHook(
            id: "00000000-0000-0000-0000-000000001010",
            now: now
        )
        let second = makeWaitingHook(
            id: "00000000-0000-0000-0000-000000001011",
            now: now
        )
        let repository = RuntimeHookRepository(hooks: [first, second])
        let clock = ControllableRuntimeClock(now: now)
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "当前活动"))
            ),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: [.failure(.failure)]
            ),
            effectExecutor: RecordingEffectExecutor(),
            clock: clock
        )

        try await runtime.evaluateInterruptibility()

        let stored = await repository.hooks
        #expect(stored.allSatisfy { $0.state == .waitingInterruptible })
        #expect(stored.allSatisfy { $0.blockReason == .modelUnavailable })
        try await waitUntil { await clock.deadlines.count == 1 }
        #expect(await clock.deadlines == [now.addingTimeInterval(30)])
        await runtime.stop()
    }

    @Test("证据和模型恢复后清除旧 blockReason 再保存判断")
    func clearsRecoveredBlockBeforeConditionDecision() async throws {
        let now = Date(timeIntervalSince1970: 106_000)
        var hook = makeObservingHook(
            id: "00000000-0000-0000-0000-000000001009",
            now: now
        )
        hook.blockReason = .modelUnavailable
        let repository = RuntimeHookRepository(hooks: [hook])
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(fixtureConditionImageEvidence(text: "已恢复"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [
                    .success(ConditionEvaluation(decision: .notMatched, confidence: 0.7)),
                ],
                interruptibilityResults: []
            ),
            effectExecutor: RecordingEffectExecutor(),
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.observeCondition(hookID: hook.id)

        let stored = try #require(await repository.hooks.first)
        #expect(stored.blockReason == nil)
        #expect(stored.lastDecision?.value == ConditionDecision.notMatched.rawValue)
    }

    @Test("模型失败记录 modelUnavailable 而不改变 Hook 生命周期")
    func mapsModelFailureToBlockReason() async throws {
        let now = Date(timeIntervalSince1970: 105_000)
        let hook = makeObservingHook(
            id: "00000000-0000-0000-0000-000000001008",
            now: now
        )
        let repository = RuntimeHookRepository(hooks: [hook])
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(fixtureConditionImageEvidence(text: "当前状态"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [.failure(.failure)],
                interruptibilityResults: []
            ),
            effectExecutor: RecordingEffectExecutor(),
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.observeCondition(hookID: hook.id)

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .observing)
        #expect(stored.blockReason == .modelUnavailable)
        #expect(stored.lastDecision == nil)
    }

    @Test("模型取消会原样传播且不写入 Hook")
    func cancellationIsNotConvertedIntoModelUnavailable() async throws {
        let now = Date(timeIntervalSince1970: 105_500)
        let conditionHook = makeObservingHook(id: UUID().uuidString, now: now)
        let conditionRepository = RuntimeHookRepository(hooks: [conditionHook])
        let conditionRuntime = HookRuntime(
            coordinator: HookCoordinator(repository: conditionRepository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(fixtureConditionImageEvidence(text: "状态"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            decisionProvider: CancellingDecisionProvider(),
            effectExecutor: RecordingEffectExecutor(),
            clock: FixedRuntimeClock(now: now)
        )
        await #expect(throws: CancellationError.self) {
            try await conditionRuntime.observeCondition(hookID: conditionHook.id)
        }
        #expect((await conditionRepository.hooksByID[conditionHook.id])?.blockReason == nil)

        let waitingHook = makeWaitingHook(id: UUID().uuidString, now: now)
        let waitingRepository = RuntimeHookRepository(hooks: [waitingHook])
        let interruptibilityRuntime = HookRuntime(
            coordinator: HookCoordinator(repository: waitingRepository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "当前活动"))
            ),
            decisionProvider: CancellingDecisionProvider(),
            effectExecutor: RecordingEffectExecutor(),
            clock: FixedRuntimeClock(now: now)
        )
        await #expect(throws: CancellationError.self) {
            try await interruptibilityRuntime.evaluateInterruptibility()
        }
        #expect((await waitingRepository.hooksByID[waitingHook.id])?.blockReason == nil)
    }

    @Test("目标暂时最小化时记录 blockReason 而不改变生命周期")
    func mapsTransientTargetFailureToBlockReason() async throws {
        let now = Date(timeIntervalSince1970: 104_000)
        let hook = makeObservingHook(
            id: "00000000-0000-0000-0000-000000001007",
            now: now
        )
        let repository = RuntimeHookRepository(hooks: [hook])
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: []
        )
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: FailingConditionEvidenceProvider(error: .targetMinimized),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            decisionProvider: decisions,
            effectExecutor: RecordingEffectExecutor(),
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.observeCondition(hookID: hook.id)

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .observing)
        #expect(stored.blockReason == .targetMinimized)
        #expect(await decisions.conditionCallCount == 0)
    }

    @Test("uncertain 在三十秒后通过单一共享任务重试")
    func retriesUncertainInterruptibilityAfterThirtySeconds() async throws {
        let now = Date(timeIntervalSince1970: 103_000)
        let hook = makeWaitingHook(
            id: "00000000-0000-0000-0000-000000001006",
            now: now
        )
        let repository = RuntimeHookRepository(hooks: [hook])
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: [
                .success(InterruptibilityEvaluation(decision: .uncertain, confidence: 0.4)),
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 0.95)),
            ]
        )
        let effects = RecordingEffectExecutor()
        let clock = ControllableRuntimeClock(now: now)
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "当前活动"))
            ),
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: clock
        )

        try await runtime.evaluateInterruptibility()

        let firstState = try #require(await repository.hooks.first)
        #expect(firstState.state == .waitingInterruptible)
        #expect(firstState.lastDecision?.value == InterruptibilityDecision.uncertain.rawValue)
        try await waitUntil { await clock.deadlines.count == 1 }
        #expect(await clock.deadlines == [now.addingTimeInterval(30)])

        try await waitUntil { await clock.pendingSleepCount == 1 }
        await clock.fireNextSleep()
        try await waitUntil {
            await repository.hooksByID[hook.id]?.state == .notified
        }

        let retriedState = try #require(await repository.hooks.first)
        #expect(retriedState.state == .notified)
        #expect(await decisions.interruptibilityCallCount == 2)
        #expect(await effects.deliveredHookIDs == [hook.id])
        await runtime.stop()
    }

    @Test("最短等待到时后进入共享适合打断判断，未到时 Hook 保持等待")
    func advancesDueDelaysBeforeInterruptibilityEvaluation() async throws {
        let now = Date(timeIntervalSince1970: 102_000)
        let due = makeDelayHook(
            id: "00000000-0000-0000-0000-000000001004",
            earliestAttentionAt: now,
            now: now.addingTimeInterval(-60)
        )
        let notDue = makeDelayHook(
            id: "00000000-0000-0000-0000-000000001005",
            earliestAttentionAt: now.addingTimeInterval(60),
            now: now.addingTimeInterval(-30)
        )
        let repository = RuntimeHookRepository(hooks: [due, notDue])
        let activeEvidence = RecordingActiveEvidenceProvider(
            result: .success(ModelEvidence(text: "适合打断"))
        )
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: [
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 0.9)),
            ]
        )
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: activeEvidence,
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.advanceMinimumWaits()

        let stored = await repository.hooksByID
        #expect(stored[due.id]?.state == .notified)
        #expect(stored[notDue.id]?.state == .waitingMinimum)
        #expect(await activeEvidence.callCount == 1)
        #expect(await decisions.interruptibilityCallCount == 1)
        #expect(await effects.deliveredHookIDs == [due.id])
    }

    @Test("目标已关闭的 Delay Hook 到时后进入 Target Unavailable 且不通知")
    func closedDelayTargetDoesNotNotify() async throws {
        let now = Date(timeIntervalSince1970: 102_250)
        let hook = makeDelayHook(
            id: "00000000-0000-0000-0000-000000001006",
            earliestAttentionAt: now,
            now: now.addingTimeInterval(-60)
        )
        let repository = RuntimeHookRepository(hooks: [hook])
        let activeEvidence = RecordingActiveEvidenceProvider(
            result: .success(ModelEvidence(text: "不应读取"))
        )
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: [
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 1)),
            ]
        )
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: activeEvidence,
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now),
            targetAvailabilityProvider: FixedTargetAvailabilityProvider(
                availability: .targetUnavailable
            )
        )

        try await runtime.advanceMinimumWaits()

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .targetUnavailable)
        #expect(await activeEvidence.callCount == 0)
        #expect(await decisions.interruptibilityCallCount == 0)
        #expect(await effects.deliveredHookIDs.isEmpty)
    }

    @Test("等待合适时机期间目标关闭也不会发送通知")
    func closedSatisfiedTargetDoesNotNotify() async throws {
        let now = Date(timeIntervalSince1970: 102_300)
        let hook = makeWaitingHook(
            id: "00000000-0000-0000-0000-000000001007",
            now: now
        )
        let repository = RuntimeHookRepository(hooks: [hook])
        let activeEvidence = RecordingActiveEvidenceProvider(
            result: .success(ModelEvidence(text: "不应读取"))
        )
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: [
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 1)),
            ]
        )
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: activeEvidence,
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now),
            targetAvailabilityProvider: FixedTargetAvailabilityProvider(
                availability: .targetUnavailable
            )
        )

        try await runtime.evaluateInterruptibility()

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .targetUnavailable)
        #expect(await activeEvidence.callCount == 0)
        #expect(await decisions.interruptibilityCallCount == 0)
        #expect(await effects.deliveredHookIDs.isEmpty)
    }

    @Test("Target 检查暂时阻塞后会重试并在恢复时继续通知")
    func targetAvailabilityBlockRetriesAndRecovers() async throws {
        let now = Date(timeIntervalSince1970: 102_350)
        let hook = makeWaitingHook(
            id: "00000000-0000-0000-0000-000000001008",
            now: now
        )
        let repository = RuntimeHookRepository(hooks: [hook])
        let clock = ControllableRuntimeClock(now: now)
        let availability = SequencedTargetAvailabilityProvider(results: [
            .blocked(.browserExtensionDisconnected),
            .available,
        ])
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "适合打断"))
            ),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: [
                    .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 1)),
                ]
            ),
            effectExecutor: effects,
            clock: clock,
            targetAvailabilityProvider: availability
        )

        try await runtime.evaluateInterruptibility()
        try await waitUntil { await clock.pendingSleepCount == 1 }
        #expect((await repository.hooksByID[hook.id])?.blockReason == .browserExtensionDisconnected)
        #expect(await clock.deadlines == [now.addingTimeInterval(30)])

        await clock.fireNextSleep()
        try await waitUntil { (await repository.hooksByID[hook.id])?.state == .notified }

        #expect((await repository.hooksByID[hook.id])?.blockReason == nil)
        #expect(await effects.deliveredHookIDs == [hook.id])
        await runtime.stop()
    }

    @Test("到时但 Target 暂不可用的 Minimum Wait Hook 由共享重试恢复并只判断一次")
    func dueMinimumWaitAvailabilityRetryAdvancesAndSharesDecision() async throws {
        let now = Date(timeIntervalSince1970: 102_400)
        let first = makeDelayHook(
            id: "00000000-0000-0000-0000-000000001009",
            earliestAttentionAt: now,
            now: now.addingTimeInterval(-120)
        )
        let second = makeDelayHook(
            id: "00000000-0000-0000-0000-000000001010",
            earliestAttentionAt: now,
            now: now.addingTimeInterval(-60)
        )
        let repository = RuntimeHookRepository(hooks: [first, second])
        let clock = ControllableRuntimeClock(now: now)
        let availability = SequencedTargetAvailabilityProvider(results: [
            .blocked(.browserExtensionDisconnected),
            .retryLater,
            .available,
            .available,
        ])
        let activeEvidence = RecordingActiveEvidenceProvider(
            result: .success(ModelEvidence(text: "适合打断"))
        )
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: [
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 1)),
            ]
        )
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: activeEvidence,
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: clock,
            targetAvailabilityProvider: availability
        )

        try await runtime.advanceMinimumWaits()
        try await waitUntil { await clock.pendingSleepCount == 1 }

        let blocked = await repository.hooksByID
        #expect(blocked[first.id]?.state == .waitingMinimum)
        #expect(blocked[first.id]?.blockReason == .browserExtensionDisconnected)
        #expect(blocked[second.id]?.state == .waitingMinimum)
        #expect(await activeEvidence.callCount == 0)
        #expect(await decisions.interruptibilityCallCount == 0)

        await clock.fireNextSleep()
        try await waitUntil {
            let hooks = await repository.hooksByID
            return hooks[first.id]?.state == .notified
                && hooks[second.id]?.state == .notified
        }

        let recovered = await repository.hooksByID
        #expect(recovered[first.id]?.blockReason == nil)
        #expect(recovered[second.id]?.blockReason == nil)
        let availabilityCallCount = await availability.callCount
        // 两个 Hook 在推进 Minimum Wait 和共享模型判断前各检查一次 Target，模型仍只共享调用一次。
        #expect(availabilityCallCount == 6)
        #expect(await activeEvidence.callCount == 1)
        #expect(await decisions.interruptibilityCallCount == 1)
        #expect(await effects.deliveredHookIDs == [first.id, second.id])
        await runtime.stop()
    }

    @Test("稍后提醒的 Condition Hook 到时后进入共享适合打断判断")
    func advancesSnoozedConditionHook() async throws {
        let now = Date(timeIntervalSince1970: 102_500)
        var hook = makeObservingHook(id: UUID().uuidString, now: now.addingTimeInterval(-300))
        hook.state = .waitingMinimum
        hook.earliestAttentionAt = now
        let repository = RuntimeHookRepository(hooks: [hook])
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "适合打断"))
            ),
            decisionProvider: RecordingDecisionProvider(
                conditionResults: [],
                interruptibilityResults: [
                    .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 1)),
                ]
            ),
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.advanceMinimumWaits()

        #expect((await repository.hooksByID[hook.id])?.state == .notified)
        #expect(await effects.deliveredHookIDs == [hook.id])
    }

    @Test("Condition 观察只持久化有限判断而不保存 evidence")
    func persistsConditionDecisionWithoutEvidence() async throws {
        let now = Date(timeIntervalSince1970: 101_000)
        let hook = makeObservingHook(
            id: "00000000-0000-0000-0000-000000001003",
            now: now
        )
        let repository = RuntimeHookRepository(hooks: [hook])
        let sensitiveText = "private-build-token-should-never-persist"
        let conditionEvidence = RecordingConditionEvidenceProvider(
            result: .success(fixtureConditionImageEvidence(text: sensitiveText))
        )
        let decisions = RecordingDecisionProvider(
            conditionResults: [
                .success(ConditionEvaluation(decision: .notMatched, confidence: 0.81)),
            ],
            interruptibilityResults: []
        )
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: conditionEvidence,
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            decisionProvider: decisions,
            effectExecutor: RecordingEffectExecutor(),
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.observeCondition(hookID: hook.id)

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .observing)
        #expect(stored.lastDecision?.value == ConditionDecision.notMatched.rawValue)
        #expect(stored.lastDecision?.confidence == 0.81)
        #expect(await conditionEvidence.callCount == 1)
        #expect(await decisions.conditionCallCount == 1)
        let persistedJSON = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        #expect(!persistedJSON.contains(sensitiveText))
    }

    @Test("多个已满足 Hook 共享一次适合打断判断并分别通知")
    func sharesInterruptibilityDecisionAcrossWaitingHooks() async throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let first = makeWaitingHook(id: "00000000-0000-0000-0000-000000001001", now: now)
        let second = makeWaitingHook(id: "00000000-0000-0000-0000-000000001002", now: now)
        let repository = RuntimeHookRepository(hooks: [first, second])
        let activeEvidence = RecordingActiveEvidenceProvider(
            result: .success(ModelEvidence(text: "当前桌面空闲"))
        )
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: [
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 0.92)),
            ]
        )
        let effects = RecordingEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: activeEvidence,
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now)
        )

        try await runtime.evaluateInterruptibility()

        let stored = await repository.hooks.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        #expect(stored.map(\.state) == [.notified, .notified])
        #expect(stored.map(\.lastDecision?.value) == ["interruptible", "interruptible"])
        #expect(await activeEvidence.callCount == 1)
        #expect(await decisions.interruptibilityCallCount == 1)
        #expect(await effects.deliveredHookIDs == [first.id, second.id])
    }

    @Test("通知交付进行中时并发判断不会重复请求模型或重复通知")
    func notificationInFlightDeduplicatesConcurrentEvaluation() async throws {
        let now = Date(timeIntervalSince1970: 99_500)
        let hook = makeWaitingHook(id: UUID().uuidString, now: now)
        let repository = RuntimeHookRepository(hooks: [hook])
        let decisions = RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: [
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 0.9)),
                .success(InterruptibilityEvaluation(decision: .interruptible, confidence: 0.9)),
            ]
        )
        let effects = BlockingFirstEffectExecutor()
        let runtime = HookRuntime(
            coordinator: HookCoordinator(repository: repository),
            conditionEvidenceProvider: RecordingConditionEvidenceProvider(
                result: .success(ModelEvidence(text: "unused"))
            ),
            activeEvidenceProvider: RecordingActiveEvidenceProvider(
                result: .success(ModelEvidence(text: "当前活动"))
            ),
            decisionProvider: decisions,
            effectExecutor: effects,
            clock: FixedRuntimeClock(now: now)
        )

        let firstEvaluation = Task {
            try await runtime.evaluateInterruptibility()
        }
        try await waitUntil { await effects.attemptCount == 1 }
        try await runtime.evaluateInterruptibility()

        #expect(await decisions.interruptibilityCallCount == 1)
        #expect(await effects.attemptCount == 1)
        await effects.releaseFirstDelivery()
        try await firstEvaluation.value

        let stored = try #require(await repository.hooks.first)
        #expect(stored.state == .notified)
    }
}

private func makeValidationRuntime(
    repository: RuntimeHookRepository,
    now: Date
) -> HookRuntime {
    HookRuntime(
        coordinator: HookCoordinator(repository: repository),
        conditionEvidenceProvider: RecordingConditionEvidenceProvider(
            result: .success(ModelEvidence(text: "unused"))
        ),
        activeEvidenceProvider: RecordingActiveEvidenceProvider(
            result: .success(ModelEvidence(text: "unused"))
        ),
        decisionProvider: RecordingDecisionProvider(
            conditionResults: [],
            interruptibilityResults: []
        ),
        effectExecutor: RecordingEffectExecutor(),
        clock: FixedRuntimeClock(now: now)
    )
}

private func fixtureConditionImageEvidence(text: String) -> ModelEvidence {
    ModelEvidence(
        text: text,
        image: ModelImage(data: Data([0x89]), mediaType: "image/png")
    )
}

private enum StubRuntimeError: Error, Equatable, Sendable {
    case failure
}

private actor SuspendingDeliveryRepository: HookRepository {
    private(set) var hook: Hook
    private var shouldSuspendDeliverySave = true
    private var deliverySaveContinuation: CheckedContinuation<Void, Never>?
    private(set) var isDeliverySaveSuspended = false

    init(hook: Hook) {
        self.hook = hook
    }

    func loadHooks() async throws -> [Hook] {
        [hook]
    }

    func save(_ hook: Hook) async throws {
        if shouldSuspendDeliverySave, hook.state == .deliveringNotification {
            shouldSuspendDeliverySave = false
            isDeliverySaveSuspended = true
            await withCheckedContinuation { continuation in
                deliverySaveContinuation = continuation
            }
            isDeliverySaveSuspended = false
        }
        self.hook = hook
    }

    func delete(id: HookID) async throws {}

    func deleteAll() async throws {}

    func releaseDeliverySave() {
        deliverySaveContinuation?.resume()
        deliverySaveContinuation = nil
    }
}

private actor RuntimeHookRepository: HookRepository {
    private var stored: [HookID: Hook]

    init(hooks: [Hook]) {
        stored = Dictionary(uniqueKeysWithValues: hooks.map { ($0.id, $0) })
    }

    var hooks: [Hook] {
        Array(stored.values)
    }

    var hooksByID: [HookID: Hook] {
        stored
    }

    func loadHooks() async throws -> [Hook] {
        Array(stored.values)
    }

    func save(_ hook: Hook) async throws {
        stored[hook.id] = hook
    }

    func delete(id: HookID) async throws {
        stored[id] = nil
    }

    func deleteAll() async throws {
        stored.removeAll()
    }
}

private actor RecordingConditionEvidenceProvider: HookRuntimeConditionEvidenceProvider {
    private let result: Result<ModelEvidence, StubRuntimeError>
    private(set) var callCount = 0

    init(result: Result<ModelEvidence, StubRuntimeError>) {
        self.result = result
    }

    func evidence(for hook: Hook) async throws -> ModelEvidence {
        callCount += 1
        return try result.get()
    }
}

private struct FailingConditionEvidenceProvider: HookRuntimeConditionEvidenceProvider {
    let error: HookRuntimeEvidenceError

    func evidence(for hook: Hook) async throws -> ModelEvidence {
        throw error
    }
}

private actor RecordingActiveEvidenceProvider: HookRuntimeActiveEvidenceProvider {
    private let result: Result<ModelEvidence, StubRuntimeError>
    private(set) var callCount = 0

    init(result: Result<ModelEvidence, StubRuntimeError>) {
        self.result = result
    }

    func currentEvidence() async throws -> ModelEvidence {
        callCount += 1
        return try result.get()
    }
}

private struct FailingActiveEvidenceProvider: HookRuntimeActiveEvidenceProvider {
    let error: HookRuntimeEvidenceError

    func currentEvidence() async throws -> ModelEvidence {
        throw error
    }
}

private struct FixedTargetAvailabilityProvider: HookRuntimeTargetAvailabilityProvider {
    let availability: HookRuntimeTargetAvailability

    func availability(for hook: Hook) async -> HookRuntimeTargetAvailability {
        availability
    }
}

private actor SequencedTargetAvailabilityProvider: HookRuntimeTargetAvailabilityProvider {
    private var results: [HookRuntimeTargetAvailability]
    private(set) var callCount = 0

    init(results: [HookRuntimeTargetAvailability]) {
        self.results = results
    }

    func availability(for hook: Hook) async -> HookRuntimeTargetAvailability {
        callCount += 1
        return results.isEmpty ? .available : results.removeFirst()
    }
}

private actor RecordingDecisionProvider: HookRuntimeDecisionProvider {
    private var conditionResults: [Result<ConditionEvaluation, StubRuntimeError>]
    private var interruptibilityResults: [Result<InterruptibilityEvaluation, StubRuntimeError>]
    private(set) var conditionCallCount = 0
    private(set) var interruptibilityCallCount = 0

    init(
        conditionResults: [Result<ConditionEvaluation, StubRuntimeError>],
        interruptibilityResults: [Result<InterruptibilityEvaluation, StubRuntimeError>]
    ) {
        self.conditionResults = conditionResults
        self.interruptibilityResults = interruptibilityResults
    }

    func evaluateCondition(
        _ request: ConditionEvaluationRequest
    ) async throws -> ConditionEvaluation {
        conditionCallCount += 1
        return try conditionResults.removeFirst().get()
    }

    func evaluateInterruptibility(
        _ request: InterruptibilityEvaluationRequest
    ) async throws -> InterruptibilityEvaluation {
        interruptibilityCallCount += 1
        return try interruptibilityResults.removeFirst().get()
    }
}

private actor OutOfOrderConditionDecisionProvider: HookRuntimeDecisionProvider {
    private var firstContinuation: CheckedContinuation<ConditionEvaluation, Never>?
    private(set) var conditionCallCount = 0

    func evaluateCondition(
        _ request: ConditionEvaluationRequest
    ) async throws -> ConditionEvaluation {
        conditionCallCount += 1
        if conditionCallCount == 1 {
            return await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return ConditionEvaluation(decision: .notMatched, confidence: 0.8)
    }

    func evaluateInterruptibility(
        _ request: InterruptibilityEvaluationRequest
    ) async throws -> InterruptibilityEvaluation {
        Issue.record("此测试不应执行适合打断判断")
        return InterruptibilityEvaluation(decision: .uncertain, confidence: 0)
    }

    func resumeFirstEvaluation(with evaluation: ConditionEvaluation) {
        firstContinuation?.resume(returning: evaluation)
        firstContinuation = nil
    }
}

private actor OutOfOrderInterruptibilityDecisionProvider: HookRuntimeDecisionProvider {
    private var firstContinuation: CheckedContinuation<InterruptibilityEvaluation, Never>?
    private(set) var interruptibilityCallCount = 0

    func evaluateCondition(
        _ request: ConditionEvaluationRequest
    ) async throws -> ConditionEvaluation {
        Issue.record("此测试不应执行 Condition 判断")
        return ConditionEvaluation(decision: .uncertain, confidence: 0)
    }

    func evaluateInterruptibility(
        _ request: InterruptibilityEvaluationRequest
    ) async throws -> InterruptibilityEvaluation {
        interruptibilityCallCount += 1
        if interruptibilityCallCount == 1 {
            return await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return InterruptibilityEvaluation(decision: .notInterruptible, confidence: 0.9)
    }

    func resumeFirstEvaluation(with evaluation: InterruptibilityEvaluation) {
        firstContinuation?.resume(returning: evaluation)
        firstContinuation = nil
    }
}

private struct CancellingDecisionProvider: HookRuntimeDecisionProvider {
    func evaluateCondition(
        _ request: ConditionEvaluationRequest
    ) async throws -> ConditionEvaluation {
        throw CancellationError()
    }

    func evaluateInterruptibility(
        _ request: InterruptibilityEvaluationRequest
    ) async throws -> InterruptibilityEvaluation {
        throw CancellationError()
    }
}

private actor RecordingEffectExecutor: HookRuntimeEffectExecutor {
    private(set) var deliveredHookIDs: [HookID] = []

    func execute(_ effect: HookEffect, for hook: Hook) async throws {
        if case let .deliverNotification(id) = effect {
            deliveredHookIDs.append(id)
        }
    }
}

private actor BlockingFirstEffectExecutor: HookRuntimeEffectExecutor {
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private(set) var attemptCount = 0

    func execute(_ effect: HookEffect, for hook: Hook) async throws {
        attemptCount += 1
        guard attemptCount == 1 else { return }
        await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func releaseFirstDelivery() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor SequencedEffectExecutor: HookRuntimeEffectExecutor {
    private var results: [Result<Void, HookRuntimeEffectError>]
    private(set) var attemptCount = 0

    init(results: [Result<Void, HookRuntimeEffectError>]) {
        self.results = results
    }

    func execute(_ effect: HookEffect, for hook: Hook) async throws {
        attemptCount += 1
        try results.removeFirst().get()
    }
}

private struct FailingEffectExecutor: HookRuntimeEffectExecutor {
    let error: HookRuntimeEffectError

    func execute(_ effect: HookEffect, for hook: Hook) async throws {
        throw error
    }
}

private struct FixedRuntimeClock: HookRuntimeClock {
    let fixedNow: Date

    init(now: Date) {
        fixedNow = now
    }

    func now() async -> Date {
        fixedNow
    }

    func sleep(until deadline: Date) async throws {
        throw CancellationError()
    }
}

private actor ControllableRuntimeClock: HookRuntimeClock {
    private var current: Date
    private var sleepers: [CheckedContinuation<Void, any Error>] = []
    private(set) var deadlines: [Date] = []

    var pendingSleepCount: Int { sleepers.count }

    init(now: Date) {
        current = now
    }

    func now() async -> Date {
        current
    }

    func sleep(until deadline: Date) async throws {
        deadlines.append(deadline)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers.append(continuation)
            }
        } onCancel: {
            Task { await self.cancelNextSleep() }
        }
    }

    func fireNextSleep() {
        guard !sleepers.isEmpty else { return }
        if !deadlines.isEmpty {
            current = deadlines[sleepers.count == deadlines.count ? 0 : deadlines.count - sleepers.count]
        }
        sleepers.removeFirst().resume()
    }

    private func cancelNextSleep() {
        guard !sleepers.isEmpty else { return }
        sleepers.removeFirst().resume(throwing: CancellationError())
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0 ..< 100 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("异步条件未在预期时间内成立")
}

private func makeWaitingHook(id: String, now: Date) -> Hook {
    Hook(
        id: HookID(rawValue: UUID(uuidString: id)!),
        title: "等待通知",
        target: .window(
            WindowTarget(
                applicationBundleIdentifier: "com.example.App",
                windowIdentifier: UInt32(id.suffix(1)) ?? 1,
                initialTitle: "Target",
                normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1)
            )
        ),
        trigger: .condition(
            ConditionDefinition(
                originalText: "完成时提醒",
                confirmedSummary: "已经完成",
                requiredEvidence: .image
            )
        ),
        state: .waitingInterruptible,
        createdAt: now,
        updatedAt: now
    )
}

private func makeObservingHook(
    id: String,
    now: Date,
    requiredEvidence: EvidenceRequirement = .image
) -> Hook {
    Hook(
        id: HookID(rawValue: UUID(uuidString: id)!),
        title: "观察条件",
        target: .window(
            WindowTarget(
                applicationBundleIdentifier: "com.example.App",
                windowIdentifier: UInt32(id.suffix(1)) ?? 1,
                initialTitle: "Target",
                normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1)
            )
        ),
        trigger: .condition(
            ConditionDefinition(
                originalText: "完成时提醒",
                confirmedSummary: "已经完成",
                requiredEvidence: requiredEvidence
            )
        ),
        state: .observing,
        createdAt: now,
        updatedAt: now,
        conditionProgress: ConditionProgress()
    )
}

private func makeBrowserObservingHook(
    id: String,
    now: Date,
    requiredEvidence: EvidenceRequirement
) -> Hook {
    Hook(
        id: HookID(rawValue: UUID(uuidString: id)!),
        title: "观察浏览器条件",
        target: .browser(
            BrowserTarget(
                browserBundleIdentifier: "com.google.Chrome",
                nativeWindowIdentifier: 42,
                extensionInstallationID: "installation-1",
                tabIdentifier: 7,
                host: "example.com",
                initialURL: URL(string: "https://example.com")!,
                initialTitle: "Example",
                normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1),
                observationMode: .dom
            )
        ),
        trigger: .condition(
            ConditionDefinition(
                originalText: "完成时提醒",
                confirmedSummary: "已经完成",
                requiredEvidence: requiredEvidence
            )
        ),
        state: .observing,
        createdAt: now,
        updatedAt: now,
        conditionProgress: ConditionProgress()
    )
}

private func makeDelayHook(
    id: String,
    earliestAttentionAt: Date,
    now: Date
) -> Hook {
    Hook(
        id: HookID(rawValue: UUID(uuidString: id)!),
        title: "延迟 Hook",
        target: .window(
            WindowTarget(
                applicationBundleIdentifier: "com.example.Delay",
                windowIdentifier: UInt32(id.suffix(1)) ?? 1,
                initialTitle: "Delay",
                normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1)
            )
        ),
        trigger: .delay(DelayDefinition(minimumDelay: 60)),
        state: .waitingMinimum,
        createdAt: now,
        updatedAt: now,
        earliestAttentionAt: earliestAttentionAt
    )
}
