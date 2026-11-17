import AwaitCueCapture
import AwaitCueCore
import AwaitCueRuntime
import AwaitCueSelection
import CoreGraphics
import Foundation
import Testing
@testable import AwaitCueApp

@Suite("App Target 可用性 adapter")
struct RuntimeAdaptersTests {
    @Test("忙闲证据使用最近任意键鼠输入而不是 null 事件")
    func activeEvidenceUsesAnyUserInputEvent() {
        var requestedEventType: CGEventType?

        let seconds = AppActiveEvidenceProvider.secondsSinceLastUserInput { eventType in
            requestedEventType = eventType
            return eventType.rawValue == UInt32.max ? 2 : 127_841
        }

        #expect(seconds == 2)
        #expect(requestedEventType?.rawValue == UInt32.max)
    }

    @Test("前台应用命中排除规则时不会读取窗口或截图")
    func excludedApplicationSkipsAllScreenCaptureOperations() async {
        let captureCalls = ActiveEvidenceCaptureCallCounter()
        let provider = AppActiveEvidenceProvider(
            privacyExclusionStore: AppPrivacyExclusionStore(
                rules: PrivacyExclusionRules(
                    applicationBundleIdentifiers: ["com.example.Secret"],
                    browserHosts: []
                )
            ),
            activeBrowserHostResolver: FixedActiveBrowserHostResolver(
                resolution: .notBrowser
            ),
            frontmostApplication: {
                ActiveApplicationSnapshot(
                    bundleIdentifier: "com.example.Secret",
                    localizedName: "Secret"
                )
            },
            discoverWindows: {
                await captureCalls.recordDiscovery()
                return []
            },
            captureWindow: { _ in
                await captureCalls.recordCapture()
                throw AdapterFixtureError.failed
            }
        )

        await #expect(throws: HookRuntimeEvidenceError.locallyExcluded) {
            try await provider.currentEvidence()
        }
        #expect(await captureCalls.discoveryCount == 0)
        #expect(await captureCalls.captureCount == 0)
    }

    @Test("浏览器 host 命中排除规则时不会读取窗口或截图")
    func excludedBrowserHostSkipsAllScreenCaptureOperations() async {
        let captureCalls = ActiveEvidenceCaptureCallCounter()
        let provider = AppActiveEvidenceProvider(
            privacyExclusionStore: AppPrivacyExclusionStore(
                rules: PrivacyExclusionRules(
                    applicationBundleIdentifiers: [],
                    browserHosts: ["secret.example"]
                )
            ),
            activeBrowserHostResolver: FixedActiveBrowserHostResolver(
                resolution: .resolved(
                    ActiveBrowserContext(
                        extensionInstallationID: "installation-1",
                        tabIdentifier: 7,
                        browserWindowIdentifier: 42,
                        host: "secret.example"
                    )
                )
            ),
            frontmostApplication: {
                ActiveApplicationSnapshot(
                    bundleIdentifier: "com.google.Chrome",
                    localizedName: "Google Chrome"
                )
            },
            discoverWindows: {
                await captureCalls.recordDiscovery()
                return []
            },
            captureWindow: { _ in
                await captureCalls.recordCapture()
                throw AdapterFixtureError.failed
            }
        )

        await #expect(throws: HookRuntimeEvidenceError.locallyExcluded) {
            try await provider.currentEvidence()
        }
        #expect(await captureCalls.discoveryCount == 0)
        #expect(await captureCalls.captureCount == 0)
    }

    @Test("配置了 host 排除但浏览器身份无法确认时保守跳过截图")
    func unresolvedBrowserHostSkipsAllScreenCaptureOperations() async {
        let captureCalls = ActiveEvidenceCaptureCallCounter()
        let provider = AppActiveEvidenceProvider(
            privacyExclusionStore: AppPrivacyExclusionStore(
                rules: PrivacyExclusionRules(
                    applicationBundleIdentifiers: [],
                    browserHosts: ["secret.example"]
                )
            ),
            activeBrowserHostResolver: FixedActiveBrowserHostResolver(
                resolution: .unavailable
            ),
            frontmostApplication: {
                ActiveApplicationSnapshot(
                    bundleIdentifier: "com.google.Chrome",
                    localizedName: "Google Chrome"
                )
            },
            discoverWindows: {
                await captureCalls.recordDiscovery()
                return []
            },
            captureWindow: { _ in
                await captureCalls.recordCapture()
                throw AdapterFixtureError.failed
            }
        )

        await #expect(throws: HookRuntimeEvidenceError.locallyExcluded) {
            try await provider.currentEvidence()
        }
        #expect(await captureCalls.discoveryCount == 0)
        #expect(await captureCalls.captureCount == 0)
    }

    @Test("Delay Hook 的窗口最小化仍可继续等待通知")
    func minimizedWindowRemainsAvailable() async {
        let provider = AppTargetAvailabilityProvider(
            browserChecker: FixedBrowserTargetChecker(result: .success(true)),
            windowChecker: FixedWindowTargetChecker(result: .success(.minimized))
        )

        #expect(await provider.availability(for: windowHook) == .available)
    }

    @Test("精确窗口关闭后返回 Target Unavailable")
    func closedWindowBecomesUnavailable() async {
        let provider = AppTargetAvailabilityProvider(
            browserChecker: FixedBrowserTargetChecker(result: .success(true)),
            windowChecker: FixedWindowTargetChecker(result: .success(.unavailable))
        )

        #expect(await provider.availability(for: windowHook) == .targetUnavailable)
    }

    @Test("窗口权限拒绝与临时系统故障保持不同处理")
    func windowErrorsRemainStable() async {
        let permissionProvider = AppTargetAvailabilityProvider(
            browserChecker: FixedBrowserTargetChecker(result: .success(true)),
            windowChecker: FixedWindowTargetChecker(
                result: .failure(ScreenCaptureError.capturePermissionMissing)
            )
        )
        let transientProvider = AppTargetAvailabilityProvider(
            browserChecker: FixedBrowserTargetChecker(result: .success(true)),
            windowChecker: FixedWindowTargetChecker(
                result: .failure(ScreenCaptureError.captureFailed)
            )
        )

        #expect(
            await permissionProvider.availability(for: windowHook)
                == .blocked(.capturePermissionMissing)
        )
        #expect(await transientProvider.availability(for: windowHook) == .retryLater)
    }

    @Test("Chrome tab 身份验证区分可用、关闭和 relay 断开")
    func chromiumAvailabilityUsesExactTabValidation() async {
        let availableProvider = AppTargetAvailabilityProvider(
            browserChecker: FixedBrowserTargetChecker(result: .success(true)),
            windowChecker: FixedWindowTargetChecker(result: .success(.available))
        )
        let closedProvider = AppTargetAvailabilityProvider(
            browserChecker: FixedBrowserTargetChecker(result: .success(false)),
            windowChecker: FixedWindowTargetChecker(result: .success(.available))
        )
        let disconnectedProvider = AppTargetAvailabilityProvider(
            browserChecker: FixedBrowserTargetChecker(result: .failure(AdapterFixtureError.failed)),
            windowChecker: FixedWindowTargetChecker(result: .success(.available))
        )

        #expect(await availableProvider.availability(for: browserHook) == .available)
        #expect(await closedProvider.availability(for: browserHook) == .targetUnavailable)
        #expect(
            await disconnectedProvider.availability(for: browserHook)
                == .blocked(.browserExtensionDisconnected)
        )
    }

    private var windowHook: Hook {
        Hook(
            id: HookID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!),
            title: "窗口 Delay Hook",
            target: .window(
                WindowTarget(
                    applicationBundleIdentifier: "com.example.App",
                    windowIdentifier: 42,
                    initialTitle: "Target",
                    normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1)
                )
            ),
            trigger: .delay(DelayDefinition(minimumDelay: 300)),
            state: .waitingMinimum,
            createdAt: .now,
            updatedAt: .now,
            earliestAttentionAt: .now.addingTimeInterval(300)
        )
    }

    private var browserHook: Hook {
        Hook(
            id: HookID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000043")!),
            title: "Chrome Delay Hook",
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
            trigger: .delay(DelayDefinition(minimumDelay: 300)),
            state: .waitingMinimum,
            createdAt: .now,
            updatedAt: .now,
            earliestAttentionAt: .now.addingTimeInterval(300)
        )
    }
}

private struct FixedBrowserTargetChecker: BrowserTargetAvailabilityChecking {
    let result: Result<Bool, AdapterFixtureError>

    func targetIsAvailable(hookID: HookID, target: BrowserTarget) async throws -> Bool {
        try result.get()
    }
}

private struct FixedWindowTargetChecker: WindowTargetAvailabilityChecking {
    let result: Result<WindowTargetAvailability, ScreenCaptureError>

    func availability(of target: WindowTarget) async throws -> WindowTargetAvailability {
        try result.get()
    }
}

private struct FixedActiveBrowserHostResolver: ActiveBrowserHostResolving {
    let resolution: ActiveBrowserHostResolution

    func resolveActiveBrowserHost(
        for browserBundleIdentifier: String
    ) async throws -> ActiveBrowserHostResolution {
        resolution
    }
}

private actor ActiveEvidenceCaptureCallCounter {
    private(set) var discoveryCount = 0
    private(set) var captureCount = 0

    func recordDiscovery() {
        discoveryCount += 1
    }

    func recordCapture() {
        captureCount += 1
    }
}

private enum AdapterFixtureError: Error {
    case failed
}
