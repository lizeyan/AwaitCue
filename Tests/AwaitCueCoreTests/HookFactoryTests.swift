import Foundation
import Testing
@testable import AwaitCueCore

@Suite("Hook 创建")
struct HookFactoryTests {
    @Test("条件 Hook 从观察中开始并保留用户确认的判断标准")
    func createsConditionHook() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let condition = ConditionDefinition(
            originalText: "测试完成时",
            confirmedSummary: "测试明确成功或失败时",
            requiredEvidence: .domAndImage
        )

        let hook = try HookFactory.makeCondition(
            title: "等待测试结果",
            target: fixtureTarget,
            condition: condition,
            now: now
        )

        #expect(hook.state == .observing)
        #expect(hook.trigger == .condition(condition))
        #expect(hook.conditionProgress == ConditionProgress())
        #expect(hook.createdAt == now)
    }

    @Test("延迟 Hook 计算最早关注时间但不把它当作通知截止时间")
    func createsDelayHook() throws {
        let now = Date(timeIntervalSince1970: 20_000)

        let hook = try HookFactory.makeDelay(
            title: "稍后查看",
            target: fixtureTarget,
            minimumDelay: 900,
            now: now
        )

        #expect(hook.state == .waitingMinimum)
        #expect(hook.earliestAttentionAt == now.addingTimeInterval(900))
        #expect(hook.trigger == .delay(DelayDefinition(minimumDelay: 900)))
    }

    @Test("无效框选区域不能创建 Hook")
    func rejectsInvalidTargetRegion() {
        let invalidTarget = HookTarget.window(
            WindowTarget(
                applicationBundleIdentifier: "com.example.App",
                windowIdentifier: 42,
                initialTitle: "Invalid",
                normalizedRegion: NormalizedRegion(x: 0.8, y: 0.8, width: 0.4, height: 0.4)
            )
        )

        #expect(throws: HookFactoryError.invalidTargetRegion) {
            try HookFactory.makeDelay(
                title: "无效目标",
                target: invalidTarget,
                minimumDelay: 60,
                now: .now
            )
        }
    }

    @Test("空判断标准不能创建条件 Hook")
    func rejectsEmptyCondition() {
        #expect(throws: HookFactoryError.emptyCondition) {
            try HookFactory.makeCondition(
                title: "等待",
                target: fixtureTarget,
                condition: ConditionDefinition(
                    originalText: "   ",
                    confirmedSummary: "",
                    requiredEvidence: .image
                ),
                now: .now
            )
        }
    }

    @Test("非正最短等待不能创建延迟 Hook")
    func rejectsInvalidMinimumDelay() {
        #expect(throws: HookFactoryError.invalidMinimumDelay) {
            try HookFactory.makeDelay(
                title: "无效等待",
                target: fixtureTarget,
                minimumDelay: 0,
                now: .now
            )
        }
    }

    @Test("浏览器观察模式映射为模型实际需要的证据组合")
    func browserObservationModeDefinesEvidenceRequirement() {
        #expect(BrowserTarget.ObservationMode.dom.evidenceRequirement == .dom)
        #expect(BrowserTarget.ObservationMode.image.evidenceRequirement == .image)
        #expect(BrowserTarget.ObservationMode.domAndImage.evidenceRequirement == .domAndImage)
    }

    private var fixtureTarget: HookTarget {
        .window(
            WindowTarget(
                applicationBundleIdentifier: "com.example.App",
                windowIdentifier: 12,
                initialTitle: "Build",
                normalizedRegion: NormalizedRegion(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
            )
        )
    }
}
