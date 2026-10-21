import AppKit
import AwaitCueBrowserBridge
import AwaitCueCapture
import AwaitCueCore
import AwaitCueModel
import AwaitCuePersistence
import AwaitCueRuntime
import AwaitCueSelection
import CoreGraphics
import Foundation

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
    @Published private(set) var browserBridgeStatus = "等待扩展连接"
    @Published var pendingTarget: HookTarget?
    @Published private(set) var isSelectingTarget = false
    @Published private(set) var screenCapturePermissionGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var conditionPreview: PreparedCondition?
    @Published private(set) var isPreparingCondition = false

    private var coordinator: HookCoordinator?
    private let notificationClient = SystemNotificationClient()
    private let bridgeServer: NativeBridgeServer
    private let browserSelectionRelay: NativeBrowserSelectionRelay
    private let selectionController: GlobalSelectionController
    private let privacyExclusionStore: AppPrivacyExclusionStore
    private let keychainStore = KeychainSecretStore(service: "org.awaitcue.model")
    private let hookCreationPresentationCoordinator = HookCreationPresentationCoordinator()
    private let apiKeyAccount = "default-responses-api-key"
    private var hasStarted = false
    private var bridgeStatusTask: Task<Void, Never>?
    private var browserEvidenceTask: Task<Void, Never>?
    private var browserTargetTask: Task<Void, Never>?
    private var runtimeLoopTask: Task<Void, Never>?
    private var runtime: HookRuntime?
    private var globalHotKeyController: GlobalHotKeyController?
    private var sessionActivityObserver: NSObjectProtocol?
    private var applicationActivationObserver: NSObjectProtocol?
    private var notificationActionTask: Task<Void, Never>?
    private var pendingInitialEvidence: ModelEvidence?

    init() {
        let defaults = UserDefaults.standard
        let storedModelBaseURL = defaults.string(forKey: "modelBaseURL")
            ?? "https://api.openai.com/v1"
        modelBaseURL = storedModelBaseURL
        modelName = defaults.string(forKey: "modelName") ?? "gpt-6-luna"
        confirmedAPIHostname = defaults.string(forKey: Self.confirmedAPIHostnameKey)
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
        let browserSelectionRelay = NativeBrowserSelectionRelay(server: bridgeServer)
        self.bridgeServer = bridgeServer
        self.browserSelectionRelay = browserSelectionRelay
        selectionController = GlobalSelectionController(browserRelay: browserSelectionRelay)

        do {
            let directory = try Self.applicationSupportDirectory()
            let repository = try SQLiteHookRepository(databaseURL: directory.appendingPathComponent("awaitcue.sqlite3"))
            coordinator = HookCoordinator(repository: repository)
            apiKey = try keychainStore.load(account: apiKeyAccount) ?? ""
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
            await browserSelectionRelay.start()
            bridgeStatusTask = Task { [weak self] in
                guard let self else { return }
                for await status in browserSelectionRelay.statuses {
                    browserBridgeStatus = status
                    if status == "Chromium 扩展已连接" {
                        try? await restoreBrowserBindings()
                    }
                }
            }
            try await restoreBrowserBindings()
            await configureRuntimeIfPossible()
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
            let client = OpenAIResponsesClient(baseURL: url, apiKey: apiKey, model: modelName)
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
            try keychainStore.save(apiKey, account: apiKeyAccount)
            UserDefaults.standard.set(modelBaseURL, forKey: "modelBaseURL")
            UserDefaults.standard.set(modelName, forKey: "modelName")
            UserDefaults.standard.set(url.host, forKey: Self.confirmedAPIHostnameKey)
            modelStatus = .connected
            await configureRuntimeIfPossible()
        } catch {
            modelStatus = .failed(Self.userFacingMessage(for: error))
        }
    }

    /// 删除模型配置，但保留 Hook；依赖模型的 Hook 会在运行时显示阻塞。
    func deleteModelConfiguration() async {
        do {
            await runtime?.stop()
            try keychainStore.delete(account: apiKeyAccount)
            apiKey = ""
            modelStatus = .notConfigured
            runtimeLoopTask?.cancel()
            browserEvidenceTask?.cancel()
            runtime = nil
            confirmedAPIHostname = false
            UserDefaults.standard.removeObject(forKey: "modelBaseURL")
            UserDefaults.standard.removeObject(forKey: "modelName")
            UserDefaults.standard.removeObject(forKey: Self.confirmedAPIHostnameKey)
        } catch {
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
            try? await browserSelectionRelay.unbind(
                hookID: hook.id,
                extensionInstallationID: browser.extensionInstallationID
            )
        }
    }

    /// 取消一个未完成 Hook。
    func cancel(_ hook: Hook) async {
        if case let .browser(browser) = hook.target {
            try? await browserSelectionRelay.unbind(
                hookID: hook.id,
                extensionInstallationID: browser.extensionInstallationID
            )
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
            startupError = "需要屏幕录制权限才能冻结屏幕并观察框选目标。授权后请重新启动 AwaitCue。"
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
            startupError = Self.userFacingMessage(for: error)
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
            case let .browser(browser):
                // Chromium 页面同时依赖可读内容与视觉状态；不能让模型把其中一种误判为足够。
                PreparedCondition(
                    confirmedSummary: prepared.confirmedSummary,
                    requiredEvidence: browser.observationMode.evidenceRequirement,
                    currentDecision: prepared.currentDecision,
                    confidence: prepared.confidence
                )
            }
        } catch {
            conditionPreview = nil
            startupError = Self.userFacingMessage(for: error)
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
                    try await browserSelectionRelay.bind(
                        hookID: hook.id,
                        target: browserTarget,
                        requirePixels: browserTarget.observationMode.evidenceRequirement != .dom
                    )
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
    }

    private func finishPendingTarget() {
        hookCreationPresentationCoordinator.finish {
            pendingTarget = nil
            pendingInitialEvidence = nil
            conditionPreview = nil
        }
    }

    /// 仅在用户主动新建 Hook 或设置页点击时请求屏幕录制权限。
    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        screenCapturePermissionGranted = granted || CGPreflightScreenCaptureAccess()
        return screenCapturePermissionGranted
    }

    /// 删除所有 Hook 和模型密钥。
    func deleteAllLocalData() async {
        do {
            for hook in hooks {
                if case let .browser(browser) = hook.target {
                    try? await browserSelectionRelay.unbind(
                        hookID: hook.id,
                        extensionInstallationID: browser.extensionInstallationID
                    )
                }
            }
            try await coordinator?.deleteAll()
            try keychainStore.delete(account: apiKeyAccount)
            hooks = []
            apiKey = ""
            modelBaseURL = "https://api.openai.com/v1"
            modelName = "gpt-6-luna"
            modelStatus = .notConfigured
            confirmedAPIHostname = false
            finishPendingTarget()
            excludedApplicationBundleIdentifiersText = ""
            excludedBrowserHostsText = ""
            UserDefaults.standard.removeObject(
                forKey: Self.excludedApplicationBundleIdentifiersKey
            )
            UserDefaults.standard.removeObject(forKey: Self.excludedBrowserHostsKey)
            UserDefaults.standard.removeObject(forKey: "modelBaseURL")
            UserDefaults.standard.removeObject(forKey: "modelName")
            UserDefaults.standard.removeObject(forKey: Self.confirmedAPIHostnameKey)
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
            UserDefaults.standard.set(preset.rawValue, forKey: Self.globalShortcutPresetKey)
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

    private func handleNotificationAction(_ action: SystemNotificationAction) async {
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
            try await browserSelectionRelay.focus(hookID: hook.id, target: browser)
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

    private static func nativeBridgeDescriptorURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("native-bridge.json")
    }

    /// 保存用户可编辑的排除清单，并让已经运行的 provider 在下一次截图前立即读取新规则。
    private func persistPrivacyExclusionConfiguration() {
        UserDefaults.standard.set(
            excludedApplicationBundleIdentifiersText,
            forKey: Self.excludedApplicationBundleIdentifiersKey
        )
        UserDefaults.standard.set(
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

    private func configuredModelClient() throws -> OpenAIResponsesClient {
        guard confirmedAPIHostname,
              let url = URL(string: modelBaseURL),
              url.host == UserDefaults.standard.string(forKey: Self.confirmedAPIHostnameKey),
              !apiKey.isEmpty,
              !modelName.isEmpty
        else {
            throw OpenAIResponsesClientError.invalidConfiguration
        }
        return OpenAIResponsesClient(baseURL: url, apiKey: apiKey, model: modelName)
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
              url.host == UserDefaults.standard.string(forKey: Self.confirmedAPIHostnameKey),
              !apiKey.isEmpty,
              !modelName.isEmpty
        else {
            runtime = nil
            return
        }
        let client = OpenAIResponsesClient(baseURL: url, apiKey: apiKey, model: modelName)
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
            clock: SystemHookRuntimeClock()
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

    private func restoreBrowserBindings() async throws {
        guard let coordinator else { return }
        for hook in try await coordinator.restoreActiveHooks() {
            guard hook.state == .observing,
                  case let .browser(target) = hook.target,
                  case .condition = hook.trigger
            else {
                continue
            }
            try await browserSelectionRelay.bind(
                hookID: hook.id,
                target: target,
                requirePixels: target.observationMode.evidenceRequirement != .dom
            )
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
    ) throws -> GlobalHotKeyController {
        try GlobalHotKeyController(preset: preset) { [weak self] in
            Task { await self?.beginNewHookSelection() }
        }
    }

    private func resetGlobalShortcut() {
        globalHotKeyController?.stop()
        globalShortcutPreset = .default
        UserDefaults.standard.removeObject(forKey: Self.globalShortcutPresetKey)
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

    /// 把冻结框选压缩为只驻留内存的 JPEG，并附上稳定 Target 上下文供首次模型判断。
    private static func previewEvidence(
        for target: HookTarget,
        image: CGImage,
        browserDOMText: String?
    ) throws -> ModelEvidence {
        let resizedImage = try resizedPreviewImage(image, maximumDimension: 1_024)
        let bitmap = NSBitmapImageRep(cgImage: resizedImage)
        guard let jpeg = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.62]
        ) else {
            throw OpenAIResponsesClientError.invalidRequest
        }
        let contextText = switch target {
        case let .window(window):
            window.initialTitle
        case let .browser(browser):
            "\(browser.initialTitle)\n\(browser.host)"
        }
        return ModelEvidence(
            text: contextText,
            domText: browserDOMText,
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
