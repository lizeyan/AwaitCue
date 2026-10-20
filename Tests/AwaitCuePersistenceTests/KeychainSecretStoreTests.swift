import Foundation
import Testing
@testable import AwaitCuePersistence

@Suite("Keychain 密钥存储", .serialized)
struct KeychainSecretStoreTests {
    @Test("真实 Security Keychain 支持保存、覆盖、读取和删除")
    func roundTripsSecretThroughSystemKeychain() throws {
        let store = KeychainSecretStore(
            service: "dev.awaitcue.tests.\(UUID().uuidString)"
        )
        let account = "responses-api-key"
        defer { try? store.delete(account: account) }

        try store.delete(account: account)
        #expect(try store.load(account: account) == nil)

        try store.save("test-secret-first", account: account)
        #expect(try store.load(account: account) == "test-secret-first")

        try store.save("test-secret-replaced", account: account)
        #expect(try store.load(account: account) == "test-secret-replaced")

        try store.delete(account: account)
        #expect(try store.load(account: account) == nil)
    }

    @Test("空 service、account 或密钥返回明确输入错误")
    func rejectsInvalidIdentifiersAndSecret() {
        let emptyService = KeychainSecretStore(service: "")
        #expect(throws: KeychainSecretStoreError.invalidIdentifier) {
            try emptyService.load(account: "api-key")
        }

        let store = KeychainSecretStore(service: "dev.awaitcue.tests.validation")
        #expect(throws: KeychainSecretStoreError.invalidIdentifier) {
            try store.delete(account: "")
        }
        #expect(throws: KeychainSecretStoreError.invalidSecret) {
            try store.save("", account: "api-key")
        }
    }
}
