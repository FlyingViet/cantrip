import Foundation
import Security

#if CANTRIP_EMBEDDED
/// Inside Cantrip.app (its Home window plug-in) secrets live in memory only: the Keychain there
/// belongs to Cantrip's own signature, and reading items another app saved would prompt the user.
/// Cantrip hands the window its local server's credential on every open.
enum EmbeddedSecrets {
    nonisolated(unsafe) private static var values: [String: String] = [:]
    private static let lock = NSLock()

    static func get(_ key: String) -> String? { lock.withLock { values[key] } }
    static func set(_ value: String?, for key: String) { lock.withLock { values[key] = value } }
}
#endif

/// Tiny Keychain wrapper for the gateway API key — never store secrets in
/// UserDefaults or the repo.
enum Keychain {
    private static let service = "AgentGateway"

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "The server credential could not be accessed in Keychain (error \(status))."
        }
    }

    static func saveCredential(_ value: String, for account: String) throws {
        #if CANTRIP_EMBEDDED
        return EmbeddedSecrets.set(value, for: "credential:" + account)
        #endif
        let query = credentialQuery(account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        let item = query.merging(attributes) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    static func loadCredential(_ account: String) throws -> String? {
        #if CANTRIP_EMBEDDED
        return EmbeddedSecrets.get("credential:" + account)
        #endif
        var query = credentialQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Failure(status: errSecDecode)
        }
        return value
    }

    static func deleteCredential(_ account: String) throws {
        #if CANTRIP_EMBEDDED
        return EmbeddedSecrets.set(nil, for: "credential:" + account)
        #endif
        let status = SecItemDelete(credentialQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(status: status)
        }
    }

    private static func credentialQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func set(_ value: String, for account: String) {
        #if CANTRIP_EMBEDDED
        return EmbeddedSecrets.set(value, for: account)
        #endif
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        #if CANTRIP_EMBEDDED
        return EmbeddedSecrets.get(account)
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func remove(_ account: String) {
        #if CANTRIP_EMBEDDED
        return EmbeddedSecrets.set(nil, for: account)
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
