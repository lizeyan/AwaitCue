import Foundation
import Testing
@testable import AwaitCueCore

@Suite("Hook 生命周期")
struct HookLifecycleTests {
    @Test("条件连续两次满足后才进入等待适合被打断")
    func conditionRequiresTwoStableMatches() throws {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        var hook = Hook.fixtureCondition(createdAt: createdAt)

        hook = try HookLifecycle.apply(
            .conditionEvaluated(.matched, at: createdAt.addingTimeInterval(1)),
            to: hook
        ).hook
        #expect(hook.state == .observing)

        hook = try HookLifecycle.apply(
            .conditionEvaluated(.matched, at: createdAt.addingTimeInterval(4)),
            to: hook
        ).hook
        #expect(hook.state == .waitingInterruptible)
    }

    @Test("两次条件满足间隔不足三秒时不会提前进入等待通知")
    func conditionMatchDebounceUsesDistinctMoments() throws {
        let createdAt = Date(timeIntervalSince1970: 2_000)
        var hook = Hook.fixtureCondition(createdAt: createdAt)

        hook = try HookLifecycle.apply(
            .conditionEvaluated(.matched, at: createdAt.addingTimeInterval(1)),
            to: hook
        ).hook
        hook = try HookLifecycle.apply(
            .conditionEvaluated(.matched, at: createdAt.addingTimeInterval(2)),
            to: hook
        ).hook

        #expect(hook.state == .observing)
        #expect(hook.conditionProgress?.consecutiveMatches == 1)
    }

    @Test("延迟 Hook 只把时间当作最短等待时间")
    func delayMovesToWaitingInterruptibleAtEarliestTime() throws {
        let createdAt = Date(timeIntervalSince1970: 3_000)
        let earliestAttentionAt = createdAt.addingTimeInterval(300)
        var hook = Hook.fixtureDelay(
            createdAt: createdAt,
            earliestAttentionAt: earliestAttentionAt
        )

        hook = try HookLifecycle.apply(
            .timeAdvanced(to: earliestAttentionAt.addingTimeInterval(-1)),
            to: hook
        ).hook
        #expect(hook.state == .waitingMinimum)

        hook = try HookLifecycle.apply(
            .timeAdvanced(to: earliestAttentionAt),
            to: hook
        ).hook
        #expect(hook.state == .waitingInterruptible)
    }

    @Test("只有适合被打断的判断才产生通知副作用")
    func interruptionDecisionControlsNotificationEffect() throws {
        let now = Date(timeIntervalSince1970: 4_000)
        var hook = Hook.fixtureDelay(createdAt: now, earliestAttentionAt: now)
        hook.state = .waitingInterruptible

        let blocked = try HookLifecycle.apply(
            .interruptibilityEvaluated(.notInterruptible, at: now),
            to: hook
        )
        #expect(blocked.hook.state == .waitingInterruptible)
        #expect(blocked.effects.isEmpty)

        let ready = try HookLifecycle.apply(
            .interruptibilityEvaluated(.interruptible, at: now),
            to: hook
        )
        #expect(ready.hook.state == .notified)
        #expect(ready.effects == [.deliverNotification(hook.id)])
    }

    @Test("稍后提醒重新进入最短等待而不是固定时间通知")
    func snoozeReturnsToMinimumWait() throws {
        let now = Date(timeIntervalSince1970: 5_000)
        var hook = Hook.fixtureDelay(createdAt: now, earliestAttentionAt: now)
        hook.state = .notified

        hook = try HookLifecycle.apply(
            .snoozed(minimumDelay: 300, at: now),
            to: hook
        ).hook

        #expect(hook.state == .waitingMinimum)
        #expect(hook.earliestAttentionAt == now.addingTimeInterval(300))
    }
}

private extension Hook {
    static func fixtureCondition(createdAt: Date) -> Hook {
        Hook(
            id: HookID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            title: "等待编译完成",
            target: .window(
                WindowTarget(
                    applicationBundleIdentifier: "com.example.Editor",
                    windowIdentifier: 7,
                    initialTitle: "Build",
                    normalizedRegion: NormalizedRegion(x: 0.1, y: 0.2, width: 0.4, height: 0.3)
                )
            ),
            trigger: .condition(
                ConditionDefinition(
                    originalText: "编译成功或失败时",
                    confirmedSummary: "编译明确结束时",
                    requiredEvidence: .image
                )
            ),
            state: .observing,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    static func fixtureDelay(createdAt: Date, earliestAttentionAt: Date) -> Hook {
        Hook(
            id: HookID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            title: "稍后回来查看",
            target: .window(
                WindowTarget(
                    applicationBundleIdentifier: "com.example.Editor",
                    windowIdentifier: 9,
                    initialTitle: "Tests",
                    normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1)
                )
            ),
            trigger: .delay(DelayDefinition(minimumDelay: 300)),
            state: .waitingMinimum,
            createdAt: createdAt,
            updatedAt: createdAt,
            earliestAttentionAt: earliestAttentionAt
        )
    }
}
