import AppKit
import AwaitCueCore
import AwaitCueModel
import AwaitCuePersistence
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

    private var coordinator: HookCoordinator?
    private let notificationClient = SystemNotificationClient()
    private let keychainStore = KeychainSecretStore(service: "org.awaitcue.model")
    private let apiKeyAccount = "default-responses-api-key"
    private var hasStarted = false

    init() {
        modelBaseURL = UserDefaults.standard.string(forKey: "modelBaseURL") ?? "https://api.openai.com/v1"
        modelName = UserDefaults.standard.string(forKey: "modelName") ?? "gpt-6-luna"

        do {
            let directory = try Self.applicationSupportDirectory()
            let repository = try SQLiteHookRepository(databaseURL: directory.appendingPathComponent("awaitcue.sqlite3"))
            coordinator = HookCoordinator(repository: repository)
            apiKey = try keychainStore.load(account: apiKeyAccount) ?? ""
            modelStatus = apiKey.isEmpty ? .notConfigured : .connected
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
            _ = try await notificationClient.requestAuthorization()
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
            modelStatus = .connected
        } catch {
            modelStatus = .failed(Self.userFacingMessage(for: error))
        }
    }

    /// 删除模型配置，但保留 Hook；依赖模型的 Hook 会在运行时显示阻塞。
    func deleteModelConfiguration() {
        do {
            try keychainStore.delete(account: apiKeyAccount)
            apiKey = ""
            modelStatus = .notConfigured
            confirmedAPIHostname = false
            UserDefaults.standard.removeObject(forKey: "modelBaseURL")
            UserDefaults.standard.removeObject(forKey: "modelName")
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
    }

    /// 取消一个未完成 Hook。
    func cancel(_ hook: Hook) async {
        await apply(.cancelled(at: .now), to: hook)
    }

    /// 删除所有 Hook 和模型密钥。
    func deleteAllLocalData() async {
        do {
            try await coordinator?.deleteAll()
            try keychainStore.delete(account: apiKeyAccount)
            hooks = []
            apiKey = ""
            modelStatus = .notConfigured
            confirmedAPIHostname = false
            await notificationClient.removeAllPendingNotifications()
        } catch {
            startupError = Self.userFacingMessage(for: error)
        }
    }

    func openSettings() {
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
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

    private static func userFacingMessage(for error: Error) -> String {
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
}
