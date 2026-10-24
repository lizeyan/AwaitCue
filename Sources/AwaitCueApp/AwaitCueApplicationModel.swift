import AppKit
import AwaitCueBrowserBridge
import AwaitCueCapture
import AwaitCueCore
import AwaitCueModel
import AwaitCuePersistence
import AwaitCueRuntime
import AwaitCueSafariBridge
import AwaitCueSelection
import CoreGraphics
import Foundation

/// Browser 页面观察的最小操作 seam；生产环境转发给 relay，配置链路测试使用记录 adapter。
struct BrowserBindingOperations: Sendable {
    let bind: @Sendable (HookID, BrowserTarget) async throws -> Void
    let unbind: @Sendable (HookID, BrowserTarget) async throws -> Void
    let focus: @Sendable (HookID, BrowserTarget) async throws -> Void

    init(
        bind: @escaping @Sendable (HookID, BrowserTarget) async throws -> Void,
        unbind: @escaping @Sendable (HookID, BrowserTarget) async throws -> Void,
        focus: @escaping @Sendable (HookID, BrowserTarget) async throws -> Void = { _, _ in }
    ) {
        self.bind = bind
        self.unbind = unbind
        self.focus = focus
    }
}

/// 真实 live E2E 使用的本机模型端点；只允许显式测试进程连接 loopback。
struct ApplicationE2EModelConfiguration: Equatable, Sendable {
    let baseURL: String
    let apiKey: String
    let model: String
}

/// 菜单栏界面的单一展示状态，并负责把系统副作用接到 Core 生命周期结果。
@MainActor
final class AwaitCueApplicationModel: ObservableObject {
    enum ModelConnectionStatus: Equatable {
        case notConfigured
        case testing
        case connected
        case failed(String)
    }

    @Published private(set) var hooks: [Hook] = []
    @Published private(set) var startupError: String?
    @Published private(set) var modelStatus: ModelConnectionStatus = .notConfigured
    @Published var modelBaseURL: String
    @Published var modelName: String
    @Published var apiKey: String = ""
    @Published var confirmedAPIHostname = false
    @Published private(set) var globalShortcutPreset: GlobalShortcutPreset
    @Published private(set) var globalShortcutError: String?
    @Published var excludedApplicationBundleIdentifiersText: String {
        didSet { persistPrivacyExclusionConfiguration() }
    }
    @Published var excludedBrowserHostsText: String {
        didSet { persistPrivacyExclusionConfiguration() }
    }
    @Published private(set) var chromiumBridgeStatus = "等待扩展连接"
    @Published private(set) var safariBridgeStatus = "等待扩展连接"
    @Published private(set) var safariExtensionStatus = "未检查"
    @Published private(set) var setupActionError: String?
    @Published var pendingTarget: HookTarget?
    @Published private(set) var isSelectingTarget = false
    @Published private(set) var screenCapturePermissionGranted: Bool
    @Published private(set) var conditionPreview: PreparedCondition?
    @Published private(set) var isPreparingCondition = false
    @Published private(set) var conditionPreparationError: String?

    private var coordinator: HookCoordinator?
    private let notificationClient: SystemNotificationClient
    private let bridgeServer: NativeBridgeServer
    private let browserSelectionRelay: NativeBrowserSelectionRelay
    private let safariExtensionDispatcher: SafariExtensionCommandDispatcher
    private let selectionController: GlobalSelectionController
    private let privacyExclusionStore: AppPrivacyExclusionStore
    private let secretStore: any AwaitCueModelSecretStore
    private let defaults: UserDefaults
    private let e2eModelConfiguration: ApplicationE2EModelConfiguration?
    private let modelClientFactory: AwaitCueModelClientFactory
    private let browserBindingOperations: BrowserBindingOperations
    private let screenCapturePermission: any ScreenCapturePermissionProviding
    private let globalHotKeyFactory: GlobalHotKeyFactory
    private let hookCreationPresentationCoordinator = HookCreationPresentationCoordinator()
    private let apiKeyAccount = "default-responses-api-key"
    private var hasStarted = false
    private var bridgeStatusTask: Task<Void, Never>?
    private var browserEvidenceTask: Task<Void, Never>?
    private var browserTargetTask: Task<Void, Never>?
    private var runtimeLoopTask: Task<Void, Never>?
    private var runtime: HookRuntime?
    private var globalHotKeyController: (any GlobalHotKeyControlling)?
    private var sessionActivityObserver: NSObjectProtocol?
    private var applicationActivationObserver: NSObjectProtocol?
    private var notificationActionTask: Task<Void, Never>?
    private var pendingInitialEvidence: ModelEvidence?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        notificationClient: SystemNotificationClient? = nil,
        secretStore: (any AwaitCueModelSecretStore)? = nil,
        screenCapturePermission: (any ScreenCapturePermissionProviding)? = nil,
        globalHotKeyFactory: @escaping GlobalHotKeyFactory = {
            try GlobalHotKeyController(preset: $0, action: $1)
        },
        modelClientFactory: @escaping AwaitCueModelClientFactory = {
            OpenAIResponsesClient(baseURL: $0, apiKey: $1, model: $2)
        },
        browserBindingOperations: BrowserBindingOperations? = nil
    ) {
        self.notificationClient = notificationClient ?? SystemNotificationClient()
        self.secretStore = secretStore ?? KeychainSecretStore(service: "org.awaitcue.model")
        self.defaults = defaults
        let e2eModelConfiguration = Self.e2eModelConfiguration(environment: environment)
        self.e2eModelConfiguration = e2eModelConfiguration
        self.modelClientFactory = modelClientFactory
        self.screenCapturePermission = screenCapturePermission
            ?? SystemScreenCapturePermissionProvider()
        self.globalHotKeyFactory = globalHotKeyFactory
        screenCapturePermissionGranted = self.screenCapturePermission.preflight()
        let storedModelBaseURL = e2eModelConfiguration?.baseURL
            ?? defaults.string(forKey: "modelBaseURL")
            ?? "https://api.openai.com/v1"
        modelBaseURL = storedModelBaseURL
        modelName = e2eModelConfiguration?.model
            ?? defaults.string(forKey: "modelName")
            ?? "gpt-6-luna"
        confirmedAPIHostname = e2eModelConfiguration != nil
            || defaults.string(forKey: Self.confirmedAPIHostnameKey)
                == URL(string: storedModelBaseURL)?.host
        globalShortcutPreset = defaults.string(forKey: Self.globalShortcutPresetKey)
            .flatMap(GlobalShortcutPreset.init(rawValue:))
            ?? .default
        let excludedBundleIdentifiers = defaults.string(
            forKey: Self.excludedApplicationBundleIdentifiersKey
        ) ?? ""
        let excludedBrowserHosts = defaults.string(forKey: Self.excludedBrowserHostsKey) ?? ""
        excludedApplicationBundleIdentifiersText = excludedBundleIdentifiers
        excludedBrowserHostsText = excludedBrowserHosts
        privacyExclusionStore = AppPrivacyExclusionStore(
            rules: Self.makePrivacyExclusionRules(
                applicationBundleIdentifiersText: excludedBundleIdentifiers,
                browserHostsText: excludedBrowserHosts
            )
        )
        let bridgeServer = NativeBridgeServer()
        let safariExtensionDispatcher = SafariExtensionCommandDispatcher()
        let browserSelectionRelay = NativeBrowserSelectionRelay(
            server: bridgeServer,
            safariCommandDispatcher: safariExtensionDispatcher
        )
        self.bridgeServer = bridgeServer
        self.browserSelectionRelay = browserSelectionRelay
        self.browserBindingOperations = browserBindingOperations ?? BrowserBindingOperations(
            bind: { hookID, target in
                try await browserSelectionRelay.bind(hookID: hookID, target: target)
            },
            unbind: { hookID, target in
                try await browserSelectionRelay.unbind(hookID: hookID, target: target)
            },
            focus: { hookID, target in
                try await browserSelectionRelay.focus(hookID: hookID, target: target)
            }
        )
        self.safariExtensionDispatcher = safariExtensionDispatcher
        selectionController = GlobalSelectionController(browserRelay: browserSelectionRelay)

        do {
            let directory = try Self.applicationSupportDirectory()
            let databaseURL = Self.hookDatabaseURL(
                environment: environment,
                defaultDirectory: directory
            )
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let repository = try SQLiteHookRepository(databaseURL: databaseURL)
            coordinator = HookCoordinator(repository: repository)
            if let e2eModelConfiguration {
                apiKey = e2eModelConfiguration.apiKey
            } else {
                apiKey = Self.shouldAccessKeychain(
                    environment: environment
                ) ? try self.secretStore.load(account: apiKeyAccount) ?? "" : ""
            }
            modelStatus = apiKey.isEmpty || !confirmedAPIHostname ? .notConfigured : .connected
        } catch {
            coordinator = nil
            startupError = Self.userFacingMessage(for: error)
        }
    }

    var menuBarSystemImage: String {
        if startupError != nil { return "exclamationmark.circle" }
        if hooks.contains(where: { $0.blockReason != nil || $0.state == .targetUnavailable }) {
            return "circle.dotted.and.circle"
        }
        return hooks.isEmpty ? "circle.dotted" : "circle.dotted.circle.fill"
    }

    var apiHostname: String? {
        URL(string: modelBaseURL)?.host
    }

    /// 只有本机 live E2E 的显式环境标记可以隔离 Keychain；普通和发布启动始终读取真实密钥。
    nonisolated static func shouldAccessKeychain(environment: [String: String]) -> Bool {
        environment["AWAITCUE_E2E_SKIP_KEYCHAIN"] != "1"
    }

    /// 只接受带双重 E2E 标记的 loopback 配置，避免测试变量把屏幕内容发到外部服务。
    nonisolated static func e2eModelConfiguration(
        environment: [String: String]
    ) -> ApplicationE2EModelConfiguration? {
        guard environment["AWAITCUE_E2E"] == "1",
              environment["AWAITCUE_E2E_SKIP_KEYCHAIN"] == "1",
              let baseURL = environment["AWAITCUE_E2E_MODEL_BASE_URL"],
              let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1"].contains(host),
              let apiKey = environment["AWAITCUE_E2E_MODEL_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty,
              let model = environment["AWAITCUE_E2E_MODEL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else {
            return nil
        }
        return ApplicationE2EModelConfiguration(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model
        )
    }

    func isBrowserInstalled(_ family: BrowserExtensionFamily) -> Bool {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: family.bundleIdentifier
        ) != nil
    }

    /// 用指定浏览器打开自身扩展管理页，避免 custom scheme 被错误交给默认浏览器。
    func openBrowserExtensionManagement(_ family: BrowserExtensionFamily) {
        setupActionError = nil
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: family.bundleIdentifier
        ) else {
            setupActionError = "未找到 \(family.displayName)。"
            return
        }
        NSWorkspace.shared.open(
            [family.managementURL],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.setupActionError = "无法打开 \(family.displayName) 扩展管理页：\(error.localizedDescription)"
            }
        }
    }

    func openBrowserExtensionDownload() {
        setupActionError = nil
        guard NSWorkspace.shared.open(BrowserExtensionDistribution.releaseDownloadURL) else {
            setupActionError = "无法打开 AwaitCue 扩展下载页。"
            return
        }
    }

    /// 打开 Safari 扩展设置；启用扩展与网站访问权限始终由用户亲自确认。
    func openSafariExtensionPreferences() {
        setupActionError = nil
        Task {
            do {
                try await safariExtensionDispatcher.showPreferences()
                await refreshSafariExtensionStatus()
            } catch {
                setupActionError = "无法打开 Safari 扩展设置：\(error.localizedDescription)"
            }
        }
    }

    func refreshSafariExtensionStatus() async {
        do {
            safariExtensionStatus = try await safariExtensionDispatcher.isEnabled()
                ? "已启用"
                : "未启用"
        } catch {
            safariExtensionStatus = "不可用"
        }
    }

    func openSystemSettings(_ destination: SystemSettingsDestination) {
        setupActionError = nil
        guard NSWorkspace.shared.open(destination.url) else {
            setupActionError = "无法打开对应的 macOS 系统设置。"
            return
        }
    }

    /// 恢复本地 Hook，并请求系统通知权限。
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            hooks = try await coordinator?.restoreActiveHooks() ?? []
            notificationActionTask = Task { [weak self, notificationClient] in
                for await action in notificationClient.actions {
                    guard !Task.isCancelled else { return }
                    await self?.handleNotificationAction(action)
                }
            }
            let descriptor = try await bridgeServer.start()
            try descriptor.write(to: try Self.nativeBridgeDescriptorURL())
            let safariContainerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AwaitCueSafariBridgeConfiguration.appGroupIdentifier
            )
            safariBridgeStatus = Self.safariBridgeStartupStatus(
                containerURL: safariContainerURL
            )
            if let safariDescriptorURL = Self.safariNativeBridgeDescriptorURL(
                containerURL: safariContainerURL
            ) {
                try descriptor.write(to: safariDescriptorURL)
            }
            await browserSelectionRelay.start()
            bridgeStatusTask = Task { [weak self] in
                guard let self else { return }
                for await status in browserSelectionRelay.statuses {
                    if status.browserBundleIdentifier
                        == SafariBridgeMessageCodec.browserBundleIdentifier
                    {
                        safariBridgeStatus = status.message
                    } else if status.browserBundleIdentifier != nil {
                        chromiumBridgeStatus = status.message
                    }
                    if status.message == "浏览器扩展已连接" {
                        try? await restoreBrowserBindings()
                    }
                }
            }
            // 先建立 evidence consumer，再恢复页面绑定；静态页 bind 立即返回的首份 DOM
            // 不能在 Runtime 尚未就绪时被丢弃。
            await configureRuntimeIfPossible()
            try await restoreBrowserBindings()
            await refreshSafariExtensionStatus()
            configureGlobalHotKey()
            startWorkspaceEventMonitoring()
            // 通知授权可能等待用户操作；不能让它阻塞 SQLite、relay、快捷键和观察 Runtime 启动。
            Task { [notificationClient] in
                _ = try? await notificationClient.requestAuthorization()
            }
        } catch {
            startupError = Self.userFacingMessage(for: error)
        }
    }

    /// 测试图片、结构化输出和鉴权，成功后才保存模型配置。
    func testAndSaveModelConfiguration() async {
        guard confirmedAPIHostname, let url = URL(string: modelBaseURL), url.host != nil else {
            modelStatus = .failed("请先确认屏幕内容将发送到当前 API hostname。")
            return
        }
        modelStatus = .testing
        do {
            let client = modelClientFactory(url, apiKey, modelName)
            let imageData = Data(base64Encoded: Self.connectionTestPNG) ?? Data()
            _ = try await client.prepareCondition(
                ConditionPreparationRequest(
                    originalText: "当测试图片中的状态值得重新关注时",
                    evidence: ModelEvidence(
                        text: "AwaitCue connection test",
                        image: ModelImage(data: imageData, mediaType: "image/png")
                    )
                )
            )
            try secretStore.save(apiKey, account: apiKeyAccount)
            defaults.set(modelBaseURL, forKey: "modelBaseURL")
            defaults.set(modelName, forKey: "modelName")
            defaults.set(url.host, forKey: Self.confirmedAPIHostnameKey)
            modelStatus = .connected
            await configureRuntimeIfPossible()
            try await restoreBrowserBindings()
        } catch {
            modelStatus = .failed(Self.userFacingMessage(for: error))
        }
    }

    /// 删除模型配置，但保留 Hook；依赖模型的 Hook 会在运行时显示阻塞。
    func deleteModelConfiguration() async {
        await stopRuntimeObservation()
        do {
            let activeHooks = try await coordinator?.restoreActiveHooks() ?? []
            _ = try await coordinator?.blockActiveHooks(
                reason: .modelUnavailable,
                at: .now
            )
            for hook in activeHooks {
                guard case let .browser(browser) = hook.target else { continue }
                try? await browserBindingOperations.unbind(hook.id, browser)
            }
            let updatedHooks = try await coordinator?.restoreActiveHooks() ?? []
            // Hook 状态已经安全落盘后才删除密钥，数据库故障不会留下半删除配置。
            try secretStore.delete(account: apiKeyAccount)
            hooks = updatedHooks
            apiKey = ""
            modelStatus = .notConfigured
            confirmedAPIHostname = false
            defaults.removeObject(forKey: "modelBaseURL")
            defaults.removeObject(forKey: "modelName")
            defaults.removeObject(forKey: Self.confirmedAPIHostnameKey)
        } catch {
            // 密钥和 Defaults 尚在时恢复原 Runtime 与页面观察，删除失败不会让配置静默失效。
            await configureRuntimeIfPossible()
            try? await restoreBrowserBindings()
            modelStatus = .failed(Self.userFacingMessage(for: error))
        }
    }

    /// 对已通知 Hook 执行“稍后提醒”。
    func snooze(_ hook: Hook, minimumDelay: TimeInterval = 300) async {
        await apply(.snoozed(minimumDelay: minimumDelay, at: .now), to: hook)
    }

    /// 完成一个已经通知的 Hook。
    func complete(_ hook: Hook) async {
        await apply(.completed(at: .now), to: hook)
        if case let .browser(browser) = hook.target,
           !hooks.contains(where: { $0.id == hook.id })
        {
            try? await browserBindingOperations.unbind(hook.id, browser)
        }
    }

    /// 取消一个未完成 Hook。
    func cancel(_ hook: Hook) async {
        if case let .browser(browser) = hook.target {
            try? await browserBindingOperations.unbind(hook.id, browser)
        }
        await apply(.cancelled(at: .now), to: hook)
    }

    /// 冻结全部显示器并让用户框选一个稳定 Target。
    func beginNewHookSelection() async {
        guard !isSelectingTarget else { return }
        guard pendingTarget == nil else {
            hookCreationPresentationCoordinator.presentExisting()
            return
        }
        guard screenCapturePermissionGranted || requestScreenCapturePermission() else {
            let message = "需要屏幕录制权限才能冻结屏幕并观察框选目标。授权后请重新启动 AwaitCue。"
            startupError = message
            hookCreationPresentationCoordinator.selectionFailed(message: message)
            return
        }
        isSelectingTarget = true
        defer { isSelectingTarget = false }
        do {
            let selection = try await selectionController.beginSelectionWithPreview()
            let evidence = try Self.previewEvidence(
                for: selection.target,
                image: selection.previewImage,
                browserDOMText: selection.browserDOMText
            )
            hookCreationPresentationCoordinator.selectionCompleted(selection.target) {
                pendingTarget = $0
                pendingInitialEvidence = evidence
            }
        } catch {
            let message = Self.userFacingMessage(for: error)
            startupError = message
            hookCreationPresentationCoordinator.selectionFailed(message: message)
        }
    }

    /// 使用已经框选的 Target 创建最短等待 Hook。
    func createDelayHook(title: String, minimumDelay: TimeInterval) async -> Bool {
        guard let target = pendingTarget, let coordinator else { return false }
        do {
            let hook = try HookFactory.makeDelay(
                title: title,
                target: target,
                minimumDelay: minimumDelay,
                now: .now
            )
            try await coordinator.add(hook)
            finishPendingTarget()
            hooks = try await coordinator.restoreActiveHooks()
            try await runtime?.advanceMinimumWaits()
            return true
        } catch {
            startupError = Self.userFacingMessage(for: error)
            return false
        }
    }

    /// 让模型解释当前 Target 的 Condition，并返回当前判断供用户确认。
    func prepareCondition(_ conditionText: String) async {
        guard let target = pendingTarget else { return }
        conditionPreparationError = nil
        isPreparingCondition = true
        defer { isPreparingCondition = false }
        do {
            let client = try configuredModelClient()
            let prepared = try await client.prepareCondition(
                ConditionPreparationRequest(
                    originalText: conditionText,
                    evidence: try await initialEvidence(for: target)
                )
            )
            conditionPreview = switch target {
            case .window:
                // 普通窗口只能稳定提供像素证据；不能把模型建议的 DOM 要求写进无法满足的 Hook。
                PreparedCondition(
                    confirmedSummary: prepared.confirmedSummary,
                    requiredEvidence: .image,
                    currentDecision: prepared.currentDecision,
                    confidence: prepared.confidence
                )
            case .browser:
                // 所有浏览器 Target 只使用页面内容；模型不能要求扩展补充截图。
                PreparedCondition(
                    confirmedSummary: prepared.confirmedSummary,
                    requiredEvidence: .dom,
                    currentDecision: prepared.currentDecision,
                    confidence: prepared.confidence
                )
            }
        } catch {
            conditionPreview = nil
            conditionPreparationError = Self.userFacingMessage(for: error)
        }
    }

    /// 使用用户已经确认的模型解释创建观察中的 Condition Hook。
    func createConditionHook(
        title: String,
        conditionText: String,
        prepared: PreparedCondition
    ) async -> Bool {
        guard let target = pendingTarget, let coordinator else { return false }
        do {
            let hook = try HookFactory.makeCondition(
                title: title,
                target: target,
                condition: ConditionDefinition(
                    originalText: conditionText,
                    confirmedSummary: prepared.confirmedSummary,
                    requiredEvidence: prepared.requiredEvidence
                ),
                now: .now
            )
            try await coordinator.add(hook)
            if case let .browser(browserTarget) = target {
                do {
                    try await browserBindingOperations.bind(hook.id, browserTarget)
                } catch {
                    // 创建对用户是一个整体操作；bind 失败时必须把已经落盘的 Hook 一并回滚。
                    try await coordinator.delete(id: hook.id)
                    throw error
                }
            }
            finishPendingTarget()
            hooks = try await coordinator.restoreActiveHooks()
            try await runtime?.observeCondition(hookID: hook.id)
            return true
        } catch {
            startupError = Self.userFacingMessage(for: error)
            return false
        }
    }

    func dismissPendingTarget() {
        finishPendingTarget()
    }

    func attachHookCreationPresenter(_ presenter: any HookCreationPresenting) {
        hookCreationPresentationCoordinator.attach(presenter)
    }

    func clearConditionPreview() {
        conditionPreview = nil
        conditionPreparationError = nil
    }

    private func finishPendingTarget() {
        hookCreationPresentationCoordinator.finish {
            pendingTarget = nil
            pendingInitialEvidence = nil
            conditionPreview = nil
            conditionPreparationError = nil
        }
    }

    /// 仅在用户主动新建 Hook 或设置页点击时请求屏幕录制权限。
    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        let granted = screenCapturePermission.request()
        screenCapturePermissionGranted = granted || screenCapturePermission.preflight()
        return screenCapturePermissionGranted
    }

    /// 删除所有 Hook 和模型密钥。
    func deleteAllLocalData() async {
        do {
            for hook in hooks {
                if case let .browser(browser) = hook.target {
                    try? await browserBindingOperations.unbind(hook.id, browser)
                }
            }
            try await coordinator?.deleteAll()
            try secretStore.delete(account: apiKeyAccount)
            hooks = []
            apiKey = ""
            modelBaseURL = "https://api.openai.com/v1"
            modelName = "gpt-6-luna"
            modelStatus = .notConfigured
            confirmedAPIHostname = false
            finishPendingTarget()
            excludedApplicationBundleIdentifiersText = ""
            excludedBrowserHostsText = ""
            defaults.removeObject(
                forKey: Self.excludedApplicationBundleIdentifiersKey
            )
            defaults.removeObject(forKey: Self.excludedBrowserHostsKey)
            defaults.removeObject(forKey: "modelBaseURL")
            defaults.removeObject(forKey: "modelName")
            defaults.removeObject(forKey: Self.confirmedAPIHostnameKey)
            resetGlobalShortcut()
            notificationClient.removeAllPendingNotifications()
            await runtime?.stop()
            runtimeLoopTask?.cancel()
            browserEvidenceTask?.cancel()
            browserTargetTask?.cancel()
            runtime = nil
        } catch {
            startupError = Self.userFacingMessage(for: error)
        }
    }

    func updateGlobalShortcut(_ preset: GlobalShortcutPreset) {
        guard preset != globalShortcutPreset else { return }
        let previousPreset = globalShortcutPreset
        globalHotKeyController?.stop()
        globalHotKeyController = nil
        do {
            globalHotKeyController = try makeGlobalHotKeyController(for: preset)
            globalShortcutPreset = preset
            globalShortcutError = nil
            defaults.set(preset.rawValue, forKey: Self.globalShortcutPresetKey)
        } catch {
            globalShortcutError = "无法注册 \(preset.displayName)，已恢复 \(previousPreset.displayName)。"
            globalHotKeyController = try? makeGlobalHotKeyController(for: previousPreset)
        }
    }

    func quit() {
        globalHotKeyController?.stop()
        globalHotKeyController = nil
        bridgeStatusTask?.cancel()
        browserEvidenceTask?.cancel()
        browserTargetTask?.cancel()
        runtimeLoopTask?.cancel()
        stopWorkspaceEventMonitoring()
        notificationActionTask?.cancel()
        Task { [browserSelectionRelay, bridgeServer] in
            await runtime?.stop()
            await browserSelectionRelay.stop()
            bridgeServer.stop()
            await MainActor.run { NSApplication.shared.terminate(nil) }
        }
    }

    private func apply(_ event: HookEvent, to hook: Hook) async {
        do {
            guard let transition = try await coordinator?.apply(event, to: hook.id) else { return }
            for effect in transition.effects {
                if case let .deliverNotification(id) = effect {
                    try await notificationClient.deliver(transition.hook, identifier: id)
                }
            }
            hooks = try await coordinator?.restoreActiveHooks() ?? []
        } catch {
            startupError = Self.userFacingMessage(for: error)
        }
    }

    /// 把通知按钮动作交给同一 Hook 生命周期；测试通过系统 action 映射后验证最终行为。
    func handleNotificationAction(_ action: SystemNotificationAction) async {
        do {
            let hookID: HookID = switch action {
            case let .open(id), let .snooze(id), let .complete(id): id
            }
            guard let hook = try await coordinator?.restoreActiveHooks()
                .first(where: { $0.id == hookID })
            else {
                return
            }
            switch action {
            case .open:
                try await openTarget(for: hook)
            case .snooze:
                await snooze(hook)
            case .complete:
                await complete(hook)
            }
        } catch {
            startupError = Self.userFacingMessage(for: error)
        }
    }

    private func openTarget(for hook: Hook) async throws {
        switch hook.target {
        case let .window(window):
            NSRunningApplication.runningApplications(
                withBundleIdentifier: window.applicationBundleIdentifier
            ).first?.activate(options: [.activateAllWindows])
        case let .browser(browser):
            try await browserBindingOperations.focus(hook.id, browser)
        }
    }

    private static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("AwaitCue", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 真实 live E2E 必须隔离 Hook 数据，但 native relay descriptor 仍保留产品默认路径供 Chrome 读取。
    /// 只有显式 `AWAITCUE_E2E=1` 时才接受测试目录，避免普通启动被环境变量意外改写。
    nonisolated static func hookDatabaseURL(
        environment: [String: String],
        defaultDirectory: URL
    ) -> URL {
        if environment["AWAITCUE_E2E"] == "1",
           let path = environment["AWAITCUE_E2E_DATA_DIRECTORY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty
        {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("awaitcue.sqlite3")
        }
        return defaultDirectory.appendingPathComponent("awaitcue.sqlite3")
    }

    private static func nativeBridgeDescriptorURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("native-bridge.json")
    }

    /// App Group 由签名与 provisioning 决定；缺失时必须把真实原因展示给用户，不能伪装成扩展未连接。
    nonisolated static func safariBridgeStartupStatus(containerURL: URL?) -> String {
        containerURL == nil
            ? "App Group 不可用；请安装带有效 Apple 签名与配置文件的 AwaitCue。"
            : "等待扩展连接"
    }

    /// Development/Developer ID provisioning 提供 App Group 时，把同一短期 token 暴露给 Safari native extension。
    private static func safariNativeBridgeDescriptorURL(containerURL: URL?) -> URL? {
        containerURL?.appendingPathComponent(AwaitCueSafariBridgeConfiguration.descriptorFilename)
    }

    /// 保存用户可编辑的排除清单，并让已经运行的 provider 在下一次截图前立即读取新规则。
    private func persistPrivacyExclusionConfiguration() {
        defaults.set(
            excludedApplicationBundleIdentifiersText,
            forKey: Self.excludedApplicationBundleIdentifiersKey
        )
        defaults.set(
            excludedBrowserHostsText,
            forKey: Self.excludedBrowserHostsKey
        )
        privacyExclusionStore.update(
            Self.makePrivacyExclusionRules(
                applicationBundleIdentifiersText: excludedApplicationBundleIdentifiersText,
                browserHostsText: excludedBrowserHostsText
            )
        )
    }

    private static func makePrivacyExclusionRules(
        applicationBundleIdentifiersText: String,
        browserHostsText: String
    ) -> PrivacyExclusionRules {
        PrivacyExclusionRules(
            applicationBundleIdentifiers: exclusionEntries(from: applicationBundleIdentifiersText),
            browserHosts: exclusionEntries(from: browserHostsText)
        )
    }

    private static func exclusionEntries(from text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
    }

    private func configuredModelClient() throws -> any AwaitCueModelClient {
        guard confirmedAPIHostname,
              let url = URL(string: modelBaseURL),
              isAPIHostnameConfirmed(for: url),
              !apiKey.isEmpty,
              !modelName.isEmpty
        else {
            throw OpenAIResponsesClientError.invalidConfiguration
        }
        return modelClientFactory(url, apiKey, modelName)
    }

    private func configureRuntimeIfPossible() async {
        let previousRuntime = runtime
        runtimeLoopTask?.cancel()
        browserEvidenceTask?.cancel()
        browserTargetTask?.cancel()
        runtime = nil
        // 先让旧 generation 和 retry 全部失效，再构造使用新模型配置的 Runtime。
        await previousRuntime?.stop()

        guard let coordinator,
              confirmedAPIHostname,
              let url = URL(string: modelBaseURL),
              isAPIHostnameConfirmed(for: url),
              !apiKey.isEmpty,
              !modelName.isEmpty
        else {
            runtime = nil
            return
        }
        let client = modelClientFactory(url, apiKey, modelName)
        let runtime = HookRuntime(
            coordinator: coordinator,
            conditionEvidenceProvider: AppConditionEvidenceProvider(browserRelay: browserSelectionRelay),
            activeEvidenceProvider: AppActiveEvidenceProvider(
                privacyExclusionStore: privacyExclusionStore,
                activeBrowserHostResolver: browserSelectionRelay
            ),
            decisionProvider: client,
            effectExecutor: AppRuntimeEffectExecutor(
                notificationClient: notificationClient,
                browserRelay: browserSelectionRelay
            ),
            clock: SystemHookRuntimeClock(),
            targetAvailabilityProvider: AppTargetAvailabilityProvider(
                browserRelay: browserSelectionRelay
            )
        )
        self.runtime = runtime
        Task { [weak self, runtime] in
            try? await runtime.resumePendingNotificationDeliveries()
            await self?.reloadHooks()
        }
        browserEvidenceTask = Task { [weak self, runtime, browserSelectionRelay] in
            for await hookID in browserSelectionRelay.evidenceUpdates {
                guard !Task.isCancelled else { return }
                try? await runtime.observeCondition(hookID: hookID)
                await self?.reloadHooks()
            }
        }
        browserTargetTask = Task { [weak self, coordinator, browserSelectionRelay] in
            for await hookID in browserSelectionRelay.targetUnavailableUpdates {
                guard !Task.isCancelled else { return }
                _ = try? await coordinator.apply(.targetBecameUnavailable(at: .now), to: hookID)
                await self?.reloadHooks()
            }
        }
        runtimeLoopTask = Task { [weak self, runtime] in
            while !Task.isCancelled {
                try? await runtime.advanceMinimumWaits()
                if let activeHooks = try? await coordinator.restoreActiveHooks() {
                    for hook in activeHooks where hook.state == .observing {
                        if case .window = hook.target {
                            try? await runtime.observeCondition(hookID: hook.id)
                        }
                    }
                }
                await self?.reloadHooks()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// 停止全部模型任务并等待 Runtime generation 失效；浏览器解绑由调用方在持久化成功后执行。
    private func stopRuntimeObservation() async {
        let previousRuntime = runtime
        runtimeLoopTask?.cancel()
        browserEvidenceTask?.cancel()
        browserTargetTask?.cancel()
        runtimeLoopTask = nil
        browserEvidenceTask = nil
        browserTargetTask = nil
        runtime = nil
        await previousRuntime?.stop()
    }

    private func restoreBrowserBindings() async throws {
        guard modelStatus == .connected, let coordinator else { return }
        for hook in try await coordinator.restoreActiveHooks() {
            guard hook.state == .observing,
                  case let .browser(target) = hook.target,
                  case .condition = hook.trigger
            else {
                continue
            }
            do {
                try await browserBindingOperations.bind(hook.id, target)
                _ = try await coordinator.unblockHook(
                    id: hook.id,
                    onlyIf: .browserExtensionDisconnected,
                    at: .now
                )
            } catch {
                // 一个浏览器或 Profile 不可用不能阻断其他 Hook 的恢复。
                if hook.blockReason == nil || hook.blockReason == .browserExtensionDisconnected {
                    _ = try? await coordinator.apply(
                        .blocked(.browserExtensionDisconnected, at: .now),
                        to: hook.id
                    )
                }
            }
        }
    }

    private func reloadHooks() async {
        hooks = (try? await coordinator?.restoreActiveHooks()) ?? []
    }

    private func configureGlobalHotKey() {
        globalHotKeyController?.stop()
        do {
            globalHotKeyController = try makeGlobalHotKeyController(
                for: globalShortcutPreset
            )
            globalShortcutError = nil
        } catch {
            globalHotKeyController = nil
            globalShortcutError = "无法注册 \(globalShortcutPreset.displayName)，请在设置中选择其他快捷键。"
        }
    }

    private func makeGlobalHotKeyController(
        for preset: GlobalShortcutPreset
    ) throws -> any GlobalHotKeyControlling {
        try globalHotKeyFactory(preset) { [weak self] in
            Task { await self?.beginNewHookSelection() }
        }
    }

    private func isAPIHostnameConfirmed(for url: URL) -> Bool {
        if let e2eModelConfiguration,
           e2eModelConfiguration.baseURL == modelBaseURL,
           URL(string: e2eModelConfiguration.baseURL)?.host == url.host
        {
            return true
        }
        return url.host == defaults.string(forKey: Self.confirmedAPIHostnameKey)
    }

    private func resetGlobalShortcut() {
        globalHotKeyController?.stop()
        globalShortcutPreset = .default
        defaults.removeObject(forKey: Self.globalShortcutPresetKey)
        configureGlobalHotKey()
    }

    private func startWorkspaceEventMonitoring() {
        stopWorkspaceEventMonitoring()
        let notifications = NSWorkspace.shared.notificationCenter
        sessionActivityObserver = notifications.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let runtime = self.runtime else { return }
                try? await runtime.userSessionBecameActive()
                await self.reloadHooks()
            }
        }
        applicationActivationObserver = notifications.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let runtime = self.runtime else { return }
                try? await runtime.evaluateInterruptibility()
                await self.reloadHooks()
            }
        }
    }

    private func stopWorkspaceEventMonitoring() {
        let notifications = NSWorkspace.shared.notificationCenter
        if let sessionActivityObserver {
            notifications.removeObserver(sessionActivityObserver)
            self.sessionActivityObserver = nil
        }
        if let applicationActivationObserver {
            notifications.removeObserver(applicationActivationObserver)
            self.applicationActivationObserver = nil
        }
    }

    private func initialEvidence(for target: HookTarget) async throws -> ModelEvidence {
        if target == pendingTarget, let pendingInitialEvidence {
            return pendingInitialEvidence
        }
        switch target {
        case let .window(window):
            let observation = try await ScreenCaptureService().capture(window)
            guard let image = observation.image else {
                throw OpenAIResponsesClientError.invalidRequest
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw OpenAIResponsesClientError.invalidRequest
            }
            return ModelEvidence(
                text: window.initialTitle,
                image: ModelImage(data: png, mediaType: "image/png")
            )
        case let .browser(browser):
            return ModelEvidence(text: "\(browser.initialTitle)\n\(browser.host)")
        }
    }

    /// 普通 App 使用冻结框选图片；Browser Target 只返回页面内容，绝不把冻结截图发送给模型。
    static func previewEvidence(
        for target: HookTarget,
        image: CGImage,
        browserDOMText: String?
    ) throws -> ModelEvidence {
        if case let .browser(browser) = target {
            return ModelEvidence(
                text: "\(browser.initialTitle)\n\(browser.host)",
                domText: browserDOMText
            )
        }
        let resizedImage = try resizedPreviewImage(image, maximumDimension: 1_024)
        let bitmap = NSBitmapImageRep(cgImage: resizedImage)
        guard let jpeg = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.62]
        ) else {
            throw OpenAIResponsesClientError.invalidRequest
        }
        guard case let .window(window) = target else {
            throw OpenAIResponsesClientError.invalidRequest
        }
        return ModelEvidence(
            text: window.initialTitle,
            image: ModelImage(data: jpeg, mediaType: "image/jpeg")
        )
    }

    /// 创建前截图只需支持快速决策；限制长边可以显著减少视觉 tokens 和服务端预处理时间。
    private static func resizedPreviewImage(
        _ image: CGImage,
        maximumDimension: Int
    ) throws -> CGImage {
        let sourceMaximum = max(image.width, image.height)
        guard sourceMaximum > maximumDimension else { return image }
        let scale = Double(maximumDimension) / Double(sourceMaximum)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw OpenAIResponsesClientError.invalidRequest
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else {
            throw OpenAIResponsesClientError.invalidRequest
        }
        return resized
    }

    private static func userFacingMessage(for error: Error) -> String {
        if error as? GlobalSelectionControllerError == .previewUnavailable {
            return "框选区域必须完整位于一块显示器内，才能进行创建前状态分析。"
        }
        if case let SelectionTargetError.browserRelayUnavailable(reason) = error {
            return switch reason {
            case .windowNotMatched:
                "当前浏览器窗口没有匹配的 AwaitCue 扩展连接。若使用了其他 Chrome 个人资料，请确认该资料也启用了扩展。"
            case .activeTabUnavailable:
                "当前标签页不是可观察的普通网页。"
            case .selectionOutsideViewport:
                "框选必须完全位于网页内容区域内，不能包含标签栏、地址栏、书签栏或浏览器侧栏。"
            case .pageAccessUnavailable:
                "AwaitCue 无法读取当前页面，请检查扩展的站点访问权限。"
            case .invalidPageResponse:
                "浏览器扩展返回了无效的页面信息，请刷新页面后重试。"
            case .noExtensionResponse:
                "当前浏览器没有响应，请确认 AwaitCue 扩展已在这个浏览器个人资料中启用。"
            case .ambiguousResponse:
                "检测到多个浏览器窗口或扩展实例，无法唯一绑定目标。"
            }
        }
        if let clientError = error as? OpenAIResponsesClientError {
            return switch clientError {
            case .invalidConfiguration: "模型地址、API key 或模型名称无效。"
            case .invalidRequest: "模型测试请求不满足图片或文字要求。"
            case let .transport(code): "模型网络连接失败：\(code.rawValue)。"
            case let .httpStatus(status): "模型服务返回 HTTP \(status)。"
            case .invalidResponse: "模型服务没有返回有效的 Responses API 内容。"
            case .invalidStructuredOutput: "模型不支持所需的严格结构化输出。"
            case let .incompleteResponse(reason):
                reason == "max_output_tokens"
                    ? "模型分析耗尽了输出预算，尚未产生判断。请重试或调整模型配置。"
                    : "模型分析未完成\(reason.map { "：\($0)" } ?? "。")"
            }
        }
        return String(describing: error)
    }

    /// 一个很小的有效 PNG，仅用于验证用户配置的模型确实支持图片输入。
    private static let connectionTestPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    private static let excludedApplicationBundleIdentifiersKey =
        "privacy.excludedApplicationBundleIdentifiers"
    private static let excludedBrowserHostsKey = "privacy.excludedBrowserHosts"
    private static let confirmedAPIHostnameKey = "model.confirmedAPIHostname"
    private static let globalShortcutPresetKey = "globalShortcutPreset"
}
