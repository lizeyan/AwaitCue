import Foundation
import Testing
@testable import AwaitCueCore

@Suite("Hook 生命周期边界")
struct HookLifecycleEdgeCaseTests {
    @Test("未满足和不确定都会清除连续满足进度")
    func nonMatchesResetStableProgress() throws {
        let now = Date(timeIntervalSince1970: 50_000)
        var hook = try makeCondition(now: now)
        hook = try HookLifecycle.apply(
            .conditionEvaluated(.matched, confidence: 0.9, at: now),
            to: hook
        ).hook

        hook = try HookLifecycle.apply(
            .conditionEvaluated(.uncertain, confidence: 0.4, at: now.addingTimeInterval(1)),
            to: hook
        ).hook
        #expect(hook.conditionProgress == ConditionProgress())
        #expect(hook.lastDecision?.value == ConditionDecision.uncertain.rawValue)

        hook = try HookLifecycle.apply(
            .conditionEvaluated(.notMatched, confidence: 0.8, at: now.addingTimeInterval(2)),
            to: hook
        ).hook
        #expect(hook.conditionProgress == ConditionProgress())
    }

    @Test("不匹配触发方式或生命周期状态时明确失败")
    func rejectsEventsAtWrongSeam() throws {
        let now = Date(timeIntervalSince1970: 51_000)
        let condition = try makeCondition(now: now)
        let delay = try makeDelay(now: now)

        #expect(try HookLifecycle.apply(.timeAdvanced(to: now), to: condition).hook == condition)
        #expect(throws: HookLifecycleError.triggerDoesNotSupportEvent) {
            try HookLifecycle.apply(
                .conditionEvaluated(.matched, at: now),
                to: delay
            )
        }
        #expect(throws: HookLifecycleError.invalidState(.waitingMinimum)) {
            try HookLifecycle.apply(
                .interruptibilityEvaluated(.interruptible, at: now),
                to: delay
            )
        }
    }

    @Test("未到最短等待的时间推进保持原状态")
    func timeAdvanceBeforeMinimumIsNoOp() throws {
        let now = Date(timeIntervalSince1970: 52_000)
        let hook = try makeDelay(now: now)

        let transition = try HookLifecycle.apply(
            .timeAdvanced(to: now.addingTimeInterval(10)),
            to: hook
        )

        #expect(transition.hook == hook)
        #expect(transition.effects.isEmpty)
    }

    @Test("用户解锁后直接通知睡眠前已满足或睡眠期间到时的 Hook")
    func activeSessionDeliversEligibleHooks() throws {
        let now = Date(timeIntervalSince1970: 53_000)
        var satisfied = try makeCondition(now: now)
        satisfied.state = .waitingInterruptible

        let conditionTransition = try HookLifecycle.apply(
            .userSessionBecameActive(at: now.addingTimeInterval(60)),
            to: satisfied
        )
        #expect(conditionTransition.hook.state == .deliveringNotification)
        #expect(conditionTransition.effects == [.deliverNotification(satisfied.id)])

        let delay = try makeDelay(now: now)
        let delayTransition = try HookLifecycle.apply(
            .userSessionBecameActive(at: now.addingTimeInterval(301)),
            to: delay
        )
        #expect(delayTransition.hook.state == .deliveringNotification)

        let tooEarly = try HookLifecycle.apply(
            .userSessionBecameActive(at: now.addingTimeInterval(10)),
            to: delay
        )
        #expect(tooEarly.hook.state == .waitingMinimum)
        #expect(tooEarly.effects.isEmpty)
    }

    @Test("目标不可用后只能显式重新绑定")
    func targetUnavailableRequiresExplicitRebind() throws {
        let now = Date(timeIntervalSince1970: 54_000)
        let hook = try makeCondition(now: now)
        let unavailable = try HookLifecycle.apply(
            .targetBecameUnavailable(at: now),
            to: hook
        ).hook
        #expect(unavailable.state == .targetUnavailable)

        let replacement = HookTarget.window(
            WindowTarget(
                applicationBundleIdentifier: "com.example.Rebound",
                windowIdentifier: 88,
                initialTitle: "Rebound",
                normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1)
            )
        )
        let rebound = try HookLifecycle.apply(
            .targetRebound(replacement, at: now.addingTimeInterval(1)),
            to: unavailable
        ).hook
        #expect(rebound.state == .observing)
        #expect(rebound.target == replacement)

        #expect(throws: HookLifecycleError.invalidState(.observing)) {
            try HookLifecycle.apply(.targetRebound(replacement, at: now), to: hook)
        }
    }

    @Test("延迟 Hook 重新绑定时依据最短等待是否已经经过恢复")
    func delayRebindRespectsMinimumWait() throws {
        let now = Date(timeIntervalSince1970: 55_000)
        var hook = try makeDelay(now: now)
        hook.state = .targetUnavailable

        let before = try HookLifecycle.apply(
            .targetRebound(hook.target, at: now.addingTimeInterval(10)),
            to: hook
        ).hook
        #expect(before.state == .waitingMinimum)

        hook.state = .targetUnavailable
        let after = try HookLifecycle.apply(
            .targetRebound(hook.target, at: now.addingTimeInterval(301)),
            to: hook
        ).hook
        #expect(after.state == .waitingInterruptible)
    }

    @Test("暂时阻塞原因不会改变生命周期状态")
    func blockReasonIsOrthogonalToLifecycle() throws {
        let now = Date(timeIntervalSince1970: 56_000)
        let hook = try makeCondition(now: now)

        let blocked = try HookLifecycle.apply(
            .blocked(.modelUnavailable, at: now),
            to: hook
        ).hook
        #expect(blocked.state == .observing)
        #expect(blocked.blockReason == .modelUnavailable)

        let unblocked = try HookLifecycle.apply(
            .unblocked(at: now.addingTimeInterval(1)),
            to: blocked
        ).hook
        #expect(unblocked.state == .observing)
        #expect(unblocked.blockReason == nil)
    }

    @Test("完成和取消遵守各自允许的状态")
    func completionAndCancellationRules() throws {
        let now = Date(timeIntervalSince1970: 57_000)
        var notified = try makeDelay(now: now)
        notified.state = .notified

        let completed = try HookLifecycle.apply(.completed(at: now), to: notified).hook
        #expect(completed.state == .completed)
        #expect(completed.completedAt == now)
        #expect(throws: HookLifecycleError.invalidState(.completed)) {
            try HookLifecycle.apply(.cancelled(at: now), to: completed)
        }

        let active = try makeCondition(now: now)
        let cancelled = try HookLifecycle.apply(.cancelled(at: now), to: active).hook
        #expect(cancelled.state == .cancelled)
        #expect(throws: HookLifecycleError.invalidState(.cancelled)) {
            try HookLifecycle.apply(.targetBecameUnavailable(at: now), to: cancelled)
        }
    }

    @Test("迟到的目标不可用事件不会破坏已通知事实")
    func targetUnavailableDoesNotReplaceNotifiedState() throws {
        let now = Date(timeIntervalSince1970: 81_500)
        var hook = try makeDelay(now: now)
        hook.state = .notified

        let transition = try HookLifecycle.apply(
            .targetBecameUnavailable(at: now.addingTimeInterval(1)),
            to: hook
        )

        #expect(transition.hook.state == .notified)
    }

    @Test("稍后提醒拒绝非正等待时间和错误状态")
    func snoozeValidation() throws {
        let now = Date(timeIntervalSince1970: 58_000)
        var hook = try makeDelay(now: now)
        hook.state = .notified

        #expect(throws: HookLifecycleError.invalidMinimumDelay) {
            try HookLifecycle.apply(.snoozed(minimumDelay: 0, at: now), to: hook)
        }

        hook.state = .waitingInterruptible
        #expect(throws: HookLifecycleError.invalidState(.waitingInterruptible)) {
            try HookLifecycle.apply(.snoozed(minimumDelay: 60, at: now), to: hook)
        }
    }

    @Test("Condition Hook 稍后提醒也会在最短等待后恢复通知流程")
    func snoozedConditionUsesMinimumWait() throws {
        let now = Date(timeIntervalSince1970: 58_250)
        var condition = try makeCondition(now: now)
        condition.state = .notified
        let snoozed = try HookLifecycle.apply(
            .snoozed(minimumDelay: 300, at: now),
            to: condition
        ).hook

        let advanced = try HookLifecycle.apply(
            .timeAdvanced(to: now.addingTimeInterval(300)),
            to: snoozed
        ).hook
        #expect(advanced.state == .waitingInterruptible)

        let sessionTransition = try HookLifecycle.apply(
            .userSessionBecameActive(at: now.addingTimeInterval(300)),
            to: snoozed
        )
        #expect(sessionTransition.hook.state == .deliveringNotification)
        #expect(sessionTransition.effects == [.deliverNotification(condition.id)])
    }

    @Test("通知交付与终态事件拒绝不允许的生命周期状态")
    func notificationAndTerminalEventsValidateState() throws {
        let now = Date(timeIntervalSince1970: 58_500)
        var condition = try makeCondition(now: now)
        condition.state = .waitingInterruptible

        #expect(throws: HookLifecycleError.invalidState(.waitingInterruptible)) {
            try HookLifecycle.apply(.conditionEvaluated(.matched, at: now), to: condition)
        }
        let unchanged = try HookLifecycle.apply(.timeAdvanced(to: now), to: try makeDelay(now: now).withState(.notified))
        #expect(unchanged.hook.state == .notified)
        #expect(throws: HookLifecycleError.invalidState(.waitingInterruptible)) {
            try HookLifecycle.apply(.notificationDelivered(at: now), to: condition)
        }
        #expect(throws: HookLifecycleError.invalidState(.waitingInterruptible)) {
            try HookLifecycle.apply(
                .notificationDeliveryFailed(.notificationPermissionMissing, at: now),
                to: condition
            )
        }
        #expect(throws: HookLifecycleError.invalidState(.waitingInterruptible)) {
            try HookLifecycle.apply(.notificationDeliveryDeferred(at: now), to: condition)
        }

        let delivering = try HookLifecycle.apply(
            .interruptibilityEvaluated(.interruptible, at: now),
            to: condition
        ).hook
        let deferred = try HookLifecycle.apply(
            .notificationDeliveryDeferred(at: now.addingTimeInterval(1)),
            to: delivering
        ).hook
        #expect(deferred.state == .waitingInterruptible)

        for terminalState in [HookState.notified, .deliveringNotification, .completed, .cancelled] {
            let terminal = try makeDelay(now: now).withState(terminalState)
            #expect(throws: HookLifecycleError.invalidState(terminalState)) {
                try HookLifecycle.apply(.blocked(.modelUnavailable, at: now), to: terminal)
            }
            #expect(throws: HookLifecycleError.invalidState(terminalState)) {
                try HookLifecycle.apply(.unblocked(at: now), to: terminal)
            }
        }

        #expect(throws: HookLifecycleError.invalidState(.waitingMinimum)) {
            try HookLifecycle.apply(.completed(at: now), to: try makeDelay(now: now))
        }
        #expect(throws: HookLifecycleError.invalidState(.deliveringNotification)) {
            try HookLifecycle.apply(.cancelled(at: now), to: delivering)
        }
    }

    @Test("浏览器目标区域和 Codable 往返保持一致")
    func browserTargetCodableRoundTrip() throws {
        let target = HookTarget.browser(
            BrowserTarget(
                browserBundleIdentifier: "com.google.Chrome",
                nativeWindowIdentifier: 11,
                extensionInstallationID: "extension-id",
                tabIdentifier: 11,
                host: "example.com",
                initialURL: URL(string: "https://example.com/build")!,
                initialTitle: "Build",
                normalizedRegion: NormalizedRegion(x: 0.2, y: 0.3, width: 0.4, height: 0.5),
                observationMode: .dom,
                selectionRegionExpanded: true
            )
        )

        let data = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(HookTarget.self, from: data)

        #expect(decoded == target)
        #expect(decoded.normalizedRegion == NormalizedRegion(x: 0.2, y: 0.3, width: 0.4, height: 0.5))
        guard case let .browser(browser) = decoded else {
            Issue.record("往返结果不是浏览器目标")
            return
        }
        #expect(browser.selectionRegionExpanded)
    }

    private func makeCondition(now: Date) throws -> Hook {
        try HookFactory.makeCondition(
            title: "条件",
            target: fixtureTarget,
            condition: ConditionDefinition(
                originalText: "完成时",
                confirmedSummary: "明确完成时",
                requiredEvidence: .image
            ),
            now: now
        )
    }

    private func makeDelay(now: Date) throws -> Hook {
        try HookFactory.makeDelay(
            title: "延迟",
            target: fixtureTarget,
            minimumDelay: 300,
            now: now
        )
    }

    private var fixtureTarget: HookTarget {
        .window(
            WindowTarget(
                applicationBundleIdentifier: "com.example.App",
                windowIdentifier: 57,
                initialTitle: "Fixture",
                normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1)
            )
        )
    }
}

private extension Hook {
    func withState(_ state: HookState) -> Hook {
        var copy = self
        copy.state = state
        return copy
    }
}
