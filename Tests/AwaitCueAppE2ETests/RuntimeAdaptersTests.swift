import AwaitCueCapture
import AwaitCueCore
import AwaitCueRuntime
import Foundation
import Testing
@testable import AwaitCueApp

@Suite("App Target 可用性 adapter")
struct RuntimeAdaptersTests {
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

private enum AdapterFixtureError: Error {
    case failed
}
