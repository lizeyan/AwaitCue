import Foundation
@preconcurrency import AwaitCueSafariServicesShim
@preconcurrency import SafariServices

/// 主 App 向 Safari Web Extension JavaScript 发送命令的最小 interface。
public protocol SafariExtensionCommandDispatching: Sendable {
    func dispatch(_ payload: Data) async throws
    func showPreferences() async throws
    func isEnabled() async throws -> Bool
}
protocol SafariServicesCalling: Sendable {
    func dispatch(
        extensionIdentifier: String,
        userInfo: [String: Any],
        completion: @escaping @Sendable (Error?) -> Void
    )
    func showPreferences(
        extensionIdentifier: String,
        completion: @escaping @Sendable (Error?) -> Void
    )
    func getExtensionEnabled(
        extensionIdentifier: String,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    )
}

/// AwaitCue 菜单栏进程向嵌入式 Safari Web Extension 发送命令的 adapter。
public struct SafariExtensionCommandDispatcher: SafariExtensionCommandDispatching {
    public static let defaultExtensionIdentifier = "org.awaitcue.AwaitCue.SafariExtension"

    private let extensionIdentifier: String
    private let services: any SafariServicesCalling

    public init(extensionIdentifier: String = Self.defaultExtensionIdentifier) {
        self.extensionIdentifier = extensionIdentifier
        services = SystemSafariServicesCaller()
    }

    init(
        extensionIdentifier: String = Self.defaultExtensionIdentifier,
        services: any SafariServicesCalling
    ) {
        self.extensionIdentifier = extensionIdentifier
        self.services = services
    }

    /// 发送与 Chromium relay 相同的 JSON 命令；页面证据仍只允许从 Safari 向应用单向返回。
    public nonisolated func dispatch(_ payload: Data) async throws {
        let object = try JSONSerialization.jsonObject(with: payload)
        guard let userInfo = object as? [String: Any] else {
            throw SafariBridgeMessageError.invalidEvent
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            services.dispatch(
                extensionIdentifier: extensionIdentifier,
                userInfo: userInfo
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// 打开 Safari 扩展设置仍需用户亲自启用扩展和网站访问权限。
    public nonisolated func showPreferences() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            services.showPreferences(extensionIdentifier: extensionIdentifier) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// 读取 Safari 当前是否已启用嵌入式扩展；网站访问权限仍由 Safari 单独管理。
    public nonisolated func isEnabled() async throws -> Bool {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Bool, any Error>) in
            services.getExtensionEnabled(extensionIdentifier: extensionIdentifier) { enabled, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: enabled)
                }
            }
        }
    }
}

private struct SystemSafariServicesCaller: SafariServicesCalling {
    func dispatch(
        extensionIdentifier: String,
        userInfo: [String: Any],
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        SFSafariApplication.dispatchMessage(
            withName: "awaitcue.command",
            toExtensionWithIdentifier: extensionIdentifier,
            userInfo: userInfo,
            completionHandler: completion
        )
    }

    func showPreferences(
        extensionIdentifier: String,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: extensionIdentifier,
            completionHandler: completion
        )
    }

    func getExtensionEnabled(
        extensionIdentifier: String,
        completion: @escaping @Sendable (Bool, Error?) -> Void
    ) {
        AwaitCueSafariServicesShim.getExtensionEnabled(extensionIdentifier) {
            enabled, error in
            completion(enabled, error)
        }
    }
}
