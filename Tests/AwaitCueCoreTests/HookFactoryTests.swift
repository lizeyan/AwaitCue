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

    @Test("浏览器只使用 DOM 证据并把旧像素模式迁移为 DOM")
    func browserObservationModeIsDOMOnly() throws {
        #expect(BrowserTarget.ObservationMode.dom.evidenceRequirement == .dom)
        for legacyValue in ["dom", "image", "domAndImage"] {
            let decoded = try JSONDecoder().decode(
                BrowserTarget.ObservationMode.self,
                from: Data("\"\(legacyValue)\"".utf8)
            )
            #expect(decoded == .dom)
        }
        let encoded = try JSONEncoder().encode(BrowserTarget.ObservationMode.dom)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"dom\"")
    }

    @Test("浏览器扩展安装入口覆盖受支持浏览器并使用稳定身份")
    func browserExtensionInstallDestinationsAreStable() {
        #expect(BrowserExtensionFamily.allCases.map(\.displayName) == [
            "Google Chrome",
            "Microsoft Edge",
            "Arc",
            "Chromium",
        ])
        #expect(BrowserExtensionFamily.chrome.bundleIdentifier == "com.google.Chrome")
        #expect(BrowserExtensionFamily.edge.bundleIdentifier == "com.microsoft.edgemac")
        #expect(BrowserExtensionFamily.arc.bundleIdentifier == "company.thebrowser.Browser")
        #expect(BrowserExtensionFamily.chromium.bundleIdentifier == "org.chromium.Chromium")
        #expect(BrowserExtensionFamily.chrome.managementURL.absoluteString == "chrome://extensions/")
        #expect(BrowserExtensionFamily.edge.managementURL.absoluteString == "edge://extensions/")
        #expect(BrowserExtensionFamily.arc.managementURL.absoluteString == "chrome://extensions/")
        #expect(BrowserExtensionFamily.chromium.managementURL.absoluteString == "chrome://extensions/")
        #expect(
            BrowserExtensionDistribution.releaseDownloadURL.absoluteString
                == "https://github.com/lizeyan/AwaitCue/releases/latest"
        )
        #expect(
            SystemSettingsDestination.screenRecording.url.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
        #expect(
            SystemSettingsDestination.notifications.url.absoluteString
                == "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        )
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
