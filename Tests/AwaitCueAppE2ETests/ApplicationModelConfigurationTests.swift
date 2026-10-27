import AwaitCueCore
import AwaitCueModel
import AwaitCuePersistence
import Foundation
import Testing
@testable import AwaitCueApp

@Suite("App 模型设置用户链路", .serialized)
struct ApplicationModelConfigurationTests {
    @Test("live E2E 模型配置只接受显式标记下的 loopback endpoint")
    func e2eModelConfigurationIsExplicitAndLoopbackOnly() {
        let allowed = AwaitCueApplicationModel.e2eModelConfiguration(environment: [
            "AWAITCUE_E2E": "1",
            "AWAITCUE_E2E_SKIP_KEYCHAIN": "1",
            "AWAITCUE_E2E_MODEL_BASE_URL": "http://127.0.0.1:8123/v1",
            "AWAITCUE_E2E_MODEL_API_KEY": "e2e-key",
            "AWAITCUE_E2E_MODEL": "e2e-decision",
        ])

        #expect(allowed?.baseURL == "http://127.0.0.1:8123/v1")
        #expect(allowed?.apiKey == "e2e-key")
        #expect(allowed?.model == "e2e-decision")
        #expect(AwaitCueApplicationModel.e2eModelConfiguration(environment: [
            "AWAITCUE_E2E_SKIP_KEYCHAIN": "1",
            "AWAITCUE_E2E_MODEL_BASE_URL": "http://127.0.0.1:8123/v1",
            "AWAITCUE_E2E_MODEL_API_KEY": "e2e-key",
            "AWAITCUE_E2E_MODEL": "e2e-decision",
        ]) == nil)
        #expect(AwaitCueApplicationModel.e2eModelConfiguration(environment: [
            "AWAITCUE_E2E": "1",
            "AWAITCUE_E2E_SKIP_KEYCHAIN": "1",
            "AWAITCUE_E2E_MODEL_BASE_URL": "https://model.example/v1",
            "AWAITCUE_E2E_MODEL_API_KEY": "e2e-key",
            "AWAITCUE_E2E_MODEL": "e2e-decision",
        ]) == nil)
    }

    @MainActor
    @Test("live E2E 启动直接连接隔离模型且不读取 Keychain")
    func e2eModelConfigurationInitializesConnectedModel() throws {
        let fixture = try ModelConfigurationFixture(
            preparationResult: .success(preparedCondition),
            environmentOverrides: [
                "AWAITCUE_E2E_SKIP_KEYCHAIN": "1",
                "AWAITCUE_E2E_MODEL_BASE_URL": "http://127.0.0.1:8123/v1",
                "AWAITCUE_E2E_MODEL_API_KEY": "e2e-key",
                "AWAITCUE_E2E_MODEL": "e2e-decision",
            ]
        )
        defer { fixture.cleanup() }

        #expect(fixture.model.modelStatus == .connected)
        #expect(fixture.model.modelBaseURL == "http://127.0.0.1:8123/v1")
        #expect(fixture.model.modelName == "e2e-decision")
        #expect(fixture.model.apiKey == "e2e-key")
        #expect(fixture.secretStore.loadCount == 0)
    }

    @MainActor
    @Test("未确认 hostname 时不请求模型也不保存密钥")
    func unconfirmedHostnameCannotBeSaved() async throws {
        let fixture = try ModelConfigurationFixture(
            preparationResult: .success(preparedCondition)
        )
        defer { fixture.cleanup() }
        fixture.model.modelBaseURL = "https://model.example/v1"
        fixture.model.modelName = "decision-model"
        fixture.model.apiKey = "secret"
        fixture.model.confirmedAPIHostname = false

        await fixture.model.testAndSaveModelConfiguration()

        #expect(
            fixture.model.modelStatus
                == .failed("请先确认屏幕内容将发送到当前 API hostname。")
        )
        #expect(await fixture.client.preparationCallCount == 0)
        #expect(fixture.secretStore.savedSecret == nil)
        #expect(fixture.defaults.string(forKey: "modelBaseURL") == nil)
    }

    @MainActor
    @Test("模型测试成功后保存配置并连接 Runtime")
    func successfulTestPersistsConfiguration() async throws {
        let fixture = try ModelConfigurationFixture(
            preparationResult: .success(preparedCondition)
        )
        defer { fixture.cleanup() }
        fixture.model.modelBaseURL = "https://model.example/v1"
        fixture.model.modelName = "decision-model"
        fixture.model.apiKey = "secret"
        fixture.model.confirmedAPIHostname = true

        await fixture.model.testAndSaveModelConfiguration()

        #expect(fixture.model.modelStatus == .connected)
        #expect(await fixture.client.preparationCallCount == 1)
        #expect(fixture.secretStore.savedSecret == "secret")
        #expect(fixture.defaults.string(forKey: "modelBaseURL") == "https://model.example/v1")
        #expect(fixture.defaults.string(forKey: "modelName") == "decision-model")
        #expect(fixture.defaults.string(forKey: "model.confirmedAPIHostname") == "model.example")
        await fixture.model.deleteModelConfiguration()
    }

    @MainActor
    @Test("模型测试失败时展示错误且不落盘")
    func failedTestDoesNotPersistConfiguration() async throws {
        let fixture = try ModelConfigurationFixture(
            preparationResult: .failure(ModelFixtureError.failed)
        )
        defer { fixture.cleanup() }
        fixture.model.modelBaseURL = "https://model.example/v1"
        fixture.model.modelName = "decision-model"
        fixture.model.apiKey = "secret"
        fixture.model.confirmedAPIHostname = true

        await fixture.model.testAndSaveModelConfiguration()

        guard case let .failed(message) = fixture.model.modelStatus else {
            Issue.record("模型失败必须进入 failed 状态")
            return
        }
        #expect(!message.isEmpty)
        #expect(fixture.secretStore.savedSecret == nil)
        #expect(fixture.defaults.string(forKey: "modelBaseURL") == nil)
    }

    @MainActor
    @Test("删除模型配置会清除密钥和 Defaults")
    func deletionClearsPersistedConfiguration() async throws {
        let fixture = try ModelConfigurationFixture(
            preparationResult: .success(preparedCondition),
            initialSecret: "stored-secret",
            initialConfiguration: true
        )
        defer { fixture.cleanup() }
        #expect(fixture.model.modelStatus == .connected)

        await fixture.model.deleteModelConfiguration()

        #expect(fixture.model.modelStatus == .notConfigured)
        #expect(fixture.secretStore.deleteCount == 1)
        #expect(fixture.defaults.string(forKey: "modelBaseURL") == nil)
        #expect(fixture.defaults.string(forKey: "modelName") == nil)
        #expect(fixture.defaults.string(forKey: "model.confirmedAPIHostname") == nil)
    }

    @MainActor
    @Test("删除模型配置保留通知状态并在数据库成功后才删除密钥")
    func deletionPreservesNotificationStatesWithoutHalfDeletingSecret() async throws {
        let browserOperations = RecordingBrowserBindingOperations()
        let fixture = try ModelConfigurationFixture(
            preparationResult: .success(preparedCondition),
            initialSecret: "stored-secret",
            initialConfiguration: true,
            browserBindingOperations: browserOperations.operations
        )
        defer { fixture.cleanup() }
        let observing = try conditionHook(title: "观察中", state: .observing)
        let notified = try conditionHook(title: "已通知", state: .notified)
        let delivering = try conditionHook(title: "正在通知", state: .deliveringNotification)
        try await fixture.saveHooks([observing, notified, delivering])

        await fixture.model.deleteModelConfiguration()

        #expect(fixture.model.modelStatus == .notConfigured)
        #expect(fixture.secretStore.savedSecret == nil)
        #expect(fixture.secretStore.deleteCount == 1)
        let stored = try await fixture.loadHooks()
        #expect(stored.first { $0.id == observing.id }?.blockReason == .modelUnavailable)
        #expect(stored.first { $0.id == notified.id }?.state == .notified)
        #expect(stored.first { $0.id == notified.id }?.blockReason == nil)
        #expect(stored.first { $0.id == delivering.id }?.state == .deliveringNotification)
        #expect(stored.first { $0.id == delivering.id }?.blockReason == nil)
        #expect(await browserOperations.unboundHookIDs == Set([observing.id, notified.id, delivering.id]))
    }

    @MainActor
    @Test("重新保存模型配置恢复浏览器观察且只清除扩展断开原因")
    func savingAgainRestoresBindingsWithoutClearingOtherBlocks() async throws {
        let browserOperations = RecordingBrowserBindingOperations()
        let fixture = try ModelConfigurationFixture(
            preparationResult: .success(preparedCondition),
            initialSecret: "stored-secret",
            initialConfiguration: true,
            browserBindingOperations: browserOperations.operations
        )
        defer { fixture.cleanup() }
        var disconnected = try conditionHook(title: "扩展断开", state: .observing)
        disconnected.blockReason = .browserExtensionDisconnected
        var modelUnavailable = try conditionHook(title: "模型不可用", state: .observing)
        modelUnavailable.blockReason = .modelUnavailable
        var captureMissing = try conditionHook(title: "截图权限", state: .observing)
        captureMissing.blockReason = .capturePermissionMissing
        var notificationMissing = try conditionHook(title: "通知权限", state: .observing)
        notificationMissing.blockReason = .notificationPermissionMissing
        try await fixture.saveHooks([
            disconnected,
            modelUnavailable,
            captureMissing,
            notificationMissing,
        ])
        fixture.model.modelBaseURL = "https://model.example/v1"
        fixture.model.modelName = "decision-model"
        fixture.model.apiKey = "secret"
        fixture.model.confirmedAPIHostname = true

        await fixture.model.testAndSaveModelConfiguration()

        #expect(await browserOperations.boundHookIDs == Set([
            disconnected.id,
            modelUnavailable.id,
            captureMissing.id,
            notificationMissing.id,
        ]))
        let stored = try await fixture.loadHooks()
        #expect(stored.first { $0.id == disconnected.id }?.blockReason == nil)
        #expect(stored.first { $0.id == modelUnavailable.id }?.blockReason == .modelUnavailable)
        #expect(stored.first { $0.id == captureMissing.id }?.blockReason == .capturePermissionMissing)
        #expect(
            stored.first { $0.id == notificationMissing.id }?.blockReason
                == .notificationPermissionMissing
        )
    }

    @MainActor
    @Test("通知动作聚焦精确 tab、稍后提醒、完成解绑并忽略过期 Hook")
    func notificationActionsDriveHookLifecycleAndBrowserOperations() async throws {
        let browserOperations = RecordingBrowserBindingOperations()
        let fixture = try ModelConfigurationFixture(
            preparationResult: .success(preparedCondition),
            browserBindingOperations: browserOperations.operations
        )
        defer { fixture.cleanup() }
        let openHook = try conditionHook(title: "打开", state: .notified)
        let snoozeHook = try conditionHook(title: "稍后", state: .notified)
        let completeHook = try conditionHook(title: "完成", state: .notified)
        try await fixture.saveHooks([openHook, snoozeHook, completeHook])

        await fixture.model.handleNotificationAction(.open(openHook.id))
        await fixture.model.handleNotificationAction(.snooze(snoozeHook.id))
        await fixture.model.handleNotificationAction(.complete(completeHook.id))
        await fixture.model.handleNotificationAction(
            .complete(HookID(rawValue: UUID()))
        )

        #expect(await browserOperations.focusedHookIDs == [openHook.id])
        #expect(await browserOperations.unboundHookIDs.contains(completeHook.id))
        let stored = try await fixture.loadHooks()
        let snoozed = try #require(stored.first { $0.id == snoozeHook.id })
        #expect(snoozed.state == .waitingMinimum)
        #expect(snoozed.earliestAttentionAt != nil)
        #expect(stored.first { $0.id == completeHook.id }?.state == .completed)
        #expect(fixture.model.startupError == nil)
    }

    @MainActor
    @Test("删除全部本地数据恢复模型、隐私规则和快捷键初始状态")
    func deleteAllResetsUserConfiguration() async throws {
        let fixture = try ModelConfigurationFixture(
            preparationResult: .success(preparedCondition),
            initialSecret: "stored-secret",
            initialConfiguration: true
        )
        defer { fixture.cleanup() }
        fixture.model.excludedApplicationBundleIdentifiersText = "com.example.Private"
        fixture.model.excludedBrowserHostsText = "private.example"
        fixture.model.updateGlobalShortcut(.optionShiftSpace)

        await fixture.model.deleteAllLocalData()

        #expect(fixture.model.hooks.isEmpty)
        #expect(fixture.model.apiKey.isEmpty)
        #expect(fixture.model.modelBaseURL == "https://api.openai.com/v1")
        #expect(fixture.model.modelName == "gpt-6-luna")
        #expect(fixture.model.modelStatus == .notConfigured)
        #expect(fixture.model.excludedApplicationBundleIdentifiersText.isEmpty)
        #expect(fixture.model.excludedBrowserHostsText.isEmpty)
        #expect(fixture.model.globalShortcutPreset == .default)
        #expect(fixture.secretStore.deleteCount == 1)
        #expect(fixture.defaults.string(forKey: "globalShortcutPreset") == nil)
    }

    private var preparedCondition: PreparedCondition {
        PreparedCondition(
            confirmedSummary: "当测试图片中的状态值得重新关注时",
            requiredEvidence: .image,
            currentDecision: .notMatched,
            confidence: 0.9
        )
    }

    private func conditionHook(title: String, state: HookState) throws -> Hook {
        var hook = try HookFactory.makeCondition(
            title: title,
            target: .browser(
                BrowserTarget(
                    browserBundleIdentifier: "com.google.Chrome",
                    nativeWindowIdentifier: 42,
                    extensionInstallationID: "extension-\(UUID().uuidString)",
                    tabIdentifier: 7,
                    host: "example.com",
                    initialURL: URL(string: "https://example.com/build")!,
                    initialTitle: "Build",
                    normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1),
                    observationMode: .dom
                )
            ),
            condition: ConditionDefinition(
                originalText: "构建完成",
                confirmedSummary: "构建已经完成",
                requiredEvidence: .dom
            ),
            now: .now
        )
        hook.state = state
        return hook
    }
}

@MainActor
private final class ModelConfigurationFixture {
    let model: AwaitCueApplicationModel
    let client: RecordingApplicationModelClient
    let secretStore: RecordingModelSecretStore
    let defaults: UserDefaults
    private let directory: URL
    private let suiteName: String

    init(
        preparationResult: Result<PreparedCondition, ModelFixtureError>,
        initialSecret: String? = nil,
        initialConfiguration: Bool = false,
        browserBindingOperations: BrowserBindingOperations? = nil,
        environmentOverrides: [String: String] = [:]
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "org.awaitcue.model-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        if initialConfiguration {
            defaults.set("https://model.example/v1", forKey: "modelBaseURL")
            defaults.set("decision-model", forKey: "modelName")
            defaults.set("model.example", forKey: "model.confirmedAPIHostname")
        }
        client = RecordingApplicationModelClient(preparationResult: preparationResult)
        secretStore = RecordingModelSecretStore(initialSecret: initialSecret)
        let client = self.client
        var environment = [
            "AWAITCUE_E2E": "1",
            "AWAITCUE_E2E_DATA_DIRECTORY": directory.path,
        ]
        environment.merge(environmentOverrides) { _, new in new }
        model = AwaitCueApplicationModel(
            environment: environment,
            defaults: defaults,
            notificationClient: SystemNotificationClient(center: SilentNotificationCenter()),
            secretStore: secretStore,
            globalHotKeyFactory: { _, _ in NoopModelHotKeyController() },
            modelClientFactory: { _, _, _ in client },
            browserBindingOperations: browserBindingOperations
        )
    }

    func saveHooks(_ hooks: [Hook]) async throws {
        let repository = try SQLiteHookRepository(
            databaseURL: directory.appendingPathComponent("awaitcue.sqlite3")
        )
        for hook in hooks { try await repository.save(hook) }
    }

    func loadHooks() async throws -> [Hook] {
        let repository = try SQLiteHookRepository(
            databaseURL: directory.appendingPathComponent("awaitcue.sqlite3")
        )
        return try await repository.loadHooks()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private actor RecordingApplicationModelClient: AwaitCueModelClient {
    private let preparationResult: Result<PreparedCondition, ModelFixtureError>
    private(set) var preparationCallCount = 0

    init(preparationResult: Result<PreparedCondition, ModelFixtureError>) {
        self.preparationResult = preparationResult
    }

    func prepareCondition(_ request: ConditionPreparationRequest) async throws -> PreparedCondition {
        preparationCallCount += 1
        return try preparationResult.get()
    }

    func evaluateCondition(
        _ request: ConditionEvaluationRequest
    ) async throws -> ConditionEvaluation {
        ConditionEvaluation(decision: .notMatched, confidence: 1)
    }

    func evaluateInterruptibility(
        _ request: InterruptibilityEvaluationRequest
    ) async throws -> InterruptibilityEvaluation {
        InterruptibilityEvaluation(decision: .notInterruptible, confidence: 1)
    }
}

private final class RecordingModelSecretStore: AwaitCueModelSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String?
    private var deletions = 0
    private var loads = 0

    init(initialSecret: String?) {
        secret = initialSecret
    }

    var savedSecret: String? { lock.withLock { secret } }
    var deleteCount: Int { lock.withLock { deletions } }
    var loadCount: Int { lock.withLock { loads } }

    func save(_ secret: String, account: String) throws {
        lock.withLock { self.secret = secret }
    }

    func load(account: String) throws -> String? {
        lock.withLock {
            loads += 1
            return secret
        }
    }

    func delete(account: String) throws {
        lock.withLock {
            secret = nil
            deletions += 1
        }
    }
}

private enum ModelFixtureError: Error {
    case failed
}

private actor RecordingBrowserBindingOperations {
    private(set) var boundHookIDs: Set<HookID> = []
    private(set) var unboundHookIDs: Set<HookID> = []
    private(set) var focusedHookIDs: [HookID] = []

    nonisolated var operations: BrowserBindingOperations {
        BrowserBindingOperations(
            bind: { [weak self] hookID, _ in await self?.recordBound(hookID) },
            unbind: { [weak self] hookID, _ in await self?.recordUnbound(hookID) },
            focus: { [weak self] hookID, _ in await self?.recordFocused(hookID) }
        )
    }

    private func recordBound(_ hookID: HookID) {
        boundHookIDs.insert(hookID)
    }

    private func recordUnbound(_ hookID: HookID) {
        unboundHookIDs.insert(hookID)
    }

    private func recordFocused(_ hookID: HookID) {
        focusedHookIDs.append(hookID)
    }
}

@MainActor
private final class NoopModelHotKeyController: GlobalHotKeyControlling {
    func stop() {}
}
