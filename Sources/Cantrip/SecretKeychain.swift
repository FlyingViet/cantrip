import Foundation
import LocalAuthentication
import Security

/// The Keychain cache of the Bitwarden secrets folder: one generic password per item (account =
/// item name, data = the item's JSON). Only Cantrip's own signed binary reads it without a prompt,
/// which is what `cantrip secret run` is.
enum SecretKeychain {
    static let service = "Cantrip Secrets"

    enum Failure: LocalizedError, Equatable {
        case locked
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .locked:
                return "The login keychain is locked, so Cantrip can't read its secrets. Log in to the Mac and try again."
            case .status(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "Cantrip couldn't use the keychain for secrets: \(text)"
            }
        }
    }

    /// Reads and writes the cache; tests use an in-memory one.
    struct Store {
        var read: (_ name: String) throws -> Data?
        var write: (_ name: String, _ value: Data) throws -> Void
        var delete: (_ name: String) throws -> Void
        var names: () throws -> [String]

        static let keychain = Store(read: SecretKeychain.load, write: SecretKeychain.save,
                                    delete: SecretKeychain.remove, names: SecretKeychain.accounts)

        static func memory() -> Store {
            final class Box: @unchecked Sendable { var items: [String: Data] = [:]; let lock = NSLock() }
            let box = Box()
            return Store(read: { name in box.lock.withLock { box.items[name] } },
                         write: { name, value in box.lock.withLock { box.items[name] = value } },
                         delete: { name in _ = box.lock.withLock { box.items.removeValue(forKey: name) } },
                         names: { box.lock.withLock { box.items.keys.sorted() } })
        }

        func item(_ name: String) throws -> SecretItem? {
            try read(name).map { try SecretIndex.decoder.decode(SecretItem.self, from: $0) }
        }

        func put(_ item: SecretItem) throws {
            try write(item.name, try SecretIndex.encoder.encode(item))
        }

        func allItems() throws -> [SecretItem] {
            try names().compactMap { try item($0) }
        }
    }

    private static func query(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// Never shows a keychain prompt: unattended jobs fail visibly instead of hanging.
    private static func silent(_ query: inout [String: Any]) -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return context
    }

    static func load(_ name: String) throws -> Data? {
        var query = query(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = silent(&query)
        defer { context.invalidate() }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        return result as? Data
    }

    static func save(_ name: String, _ value: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: value,
                                         kSecAttrLabel as String: "\(service): \(name)",
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query(name) as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw failure(update) }
        var item = query(name)
        for (key, value) in attributes { item[key] = value }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw failure(added) }
    }

    static func remove(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    static func accounts() throws -> [String] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let context = silent(&query)
        defer { context.invalidate() }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw failure(status) }
        return ((result as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private static func failure(_ status: OSStatus) -> Failure {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed ? .locked : .status(status)
    }
}
