import Foundation
import Testing
@testable import AwaitCueApp

@Suite("App 屏幕录制权限用户链路", .serialized)
struct ApplicationModelPermissionTests {
    @MainActor
    @Test("初始化只读取权限状态，不主动请求")
    func initializationDoesNotPromptForScreenCapture() throws {
        let permission = RecordingScreenCapturePermission(
            preflightResult: false,
            requestResult: true
        )
        let fixture = try IsolatedApplicationModelFixture(
            screenCapturePermission: permission
        )
        defer { fixture.cleanup() }

        #expect(!fixture.model.screenCapturePermissionGranted)
        #expect(permission.preflightCount == 1)
        #expect(permission.requestCount == 0)
    }

    @MainActor
    @Test("用户点击请求权限后立即刷新设置状态")
    func explicitPermissionRequestRefreshesState() throws {
        let permission = RecordingScreenCapturePermission(
            preflightResult: false,
            requestResult: true
        )
        let fixture = try IsolatedApplicationModelFixture(
            screenCapturePermission: permission
        )
        defer { fixture.cleanup() }

        #expect(fixture.model.requestScreenCapturePermission())

        #expect(fixture.model.screenCapturePermissionGranted)
        #expect(permission.requestCount == 1)
    }

    @MainActor
    @Test("权限拒绝时新建 Hook 显示明确原因且不启动框选")
    func deniedPermissionStopsSelectionWithVisibleReason() async throws {
        let permission = RecordingScreenCapturePermission(
            preflightResult: false,
            requestResult: false
        )
        let fixture = try IsolatedApplicationModelFixture(
            screenCapturePermission: permission
        )
        defer { fixture.cleanup() }

        await fixture.model.beginNewHookSelection()

        #expect(!fixture.model.isSelectingTarget)
        #expect(fixture.model.startupError?.contains("需要屏幕录制权限") == true)
        #expect(permission.requestCount == 1)
    }
}

private final class RecordingScreenCapturePermission: ScreenCapturePermissionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let preflightResult: Bool
    private let requestResult: Bool
    private var preflights = 0
    private var requests = 0

    init(preflightResult: Bool, requestResult: Bool) {
        self.preflightResult = preflightResult
        self.requestResult = requestResult
    }

    var preflightCount: Int { lock.withLock { preflights } }
    var requestCount: Int { lock.withLock { requests } }

    func preflight() -> Bool {
        lock.withLock { preflights += 1 }
        return preflightResult
    }

    func request() -> Bool {
        lock.withLock { requests += 1 }
        return requestResult
    }
}
