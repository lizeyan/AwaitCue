import AwaitCueCore
import AwaitCueModel
import AwaitCuePersistence
import AwaitCueRuntime
import CoreGraphics
import Foundation

/// App 的模型 seam 同时覆盖创建前 Condition 解释和 Runtime 两类决策。
protocol AwaitCueModelClient: HookRuntimeDecisionProvider {
    func prepareCondition(_ request: ConditionPreparationRequest) async throws -> PreparedCondition
}

extension OpenAIResponsesClient: AwaitCueModelClient {}

/// API key 只通过这个 seam 进入 Keychain；测试 adapter 不触碰用户真实密钥。
protocol AwaitCueModelSecretStore: Sendable {
    func save(_ secret: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

extension KeychainSecretStore: AwaitCueModelSecretStore {}

typealias AwaitCueModelClientFactory = @Sendable (
    _ baseURL: URL,
    _ apiKey: String,
    _ model: String
) -> any AwaitCueModelClient

/// 屏幕录制权限只在用户动作时请求；测试 adapter 验证启动不会弹系统权限框。
protocol ScreenCapturePermissionProviding: Sendable {
    func preflight() -> Bool
    func request() -> Bool
}

struct SystemScreenCapturePermissionProvider: ScreenCapturePermissionProviding {
    func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

/// Carbon 热键注册位于系统 seam；测试 adapter 可以稳定模拟冲突和注销。
@MainActor
protocol GlobalHotKeyControlling: AnyObject {
    func stop()
}

extension GlobalHotKeyController: GlobalHotKeyControlling {}

typealias GlobalHotKeyFactory = @MainActor (
    _ preset: GlobalShortcutPreset,
    _ action: @escaping @MainActor () -> Void
) throws -> any GlobalHotKeyControlling
