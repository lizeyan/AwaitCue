import Foundation
import Security

/// Keychain 密钥存储无法完成操作的稳定错误分类。
public enum KeychainSecretStoreError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidSecret
    case invalidStoredData
    case securityStatus(OSStatus)
}

/// 使用 macOS Security 框架保存模型 API 密钥，数据库只需持有对应 account 引用。
public struct KeychainSecretStore: Sendable {
    private let service: String

    /// 创建使用固定 Keychain service 命名空间的密钥存储。
    public init(service: String) {
        self.service = service
    }

    /// 保存或覆盖一个 UTF-8 密钥。
    public func save(_ secret: String, account: String) throws {
        guard !service.isEmpty, !account.isEmpty else {
            throw KeychainSecretStoreError.invalidIdentifier
        }
        guard !secret.isEmpty, let data = secret.data(using: .utf8) else {
            throw KeychainSecretStoreError.invalidSecret
        }

        let lookup = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainSecretStoreError.securityStatus(updateStatus)
        }

        var insertion = lookup
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainSecretStoreError.securityStatus(addStatus)
        }

        // 密钥只交给 Security.framework；实现不记录值，也不把它复制到 SQLite 或诊断信息。
    }

    /// 读取一个 UTF-8 密钥；不存在时返回 `nil`。
    public func load(account: String) throws -> String? {
        guard !service.isEmpty, !account.isEmpty else {
            throw KeychainSecretStoreError.invalidIdentifier
        }
        var lookup = baseQuery(account: account)
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        lookup[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.securityStatus(status)
        }
        guard let data = item as? Data,
              let secret = String(data: data, encoding: .utf8)
        else {
            throw KeychainSecretStoreError.invalidStoredData
        }
        return secret
    }

    /// 删除一个密钥；目标不存在时同样视为成功，便于安全清理。
    public func delete(account: String) throws {
        guard !service.isEmpty, !account.isEmpty else {
            throw KeychainSecretStoreError.invalidIdentifier
        }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.securityStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
