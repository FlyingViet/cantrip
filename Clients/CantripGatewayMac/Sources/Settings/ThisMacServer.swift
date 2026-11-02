import Foundation
import Security

/// The Macs Cantrip's Home window (the plug-in inside Cantrip.app) can open: "This Mac", the
/// Cantrip it runs in, and any other Mac paired from Settings › Macs.
///
/// Other Macs' pairing tokens are Keychain items under the window's own service, apart from Cantrip
/// Gateway Mac's ("AgentGateway") so neither app is asked about the other's items. This Mac's token
/// stays in memory: Cantrip hands it over every time it opens the window.
enum ThisMacServer {
    static let name = "This Mac"
    static let keychainService = "Cantrip Home Window"
    /// This Mac's saved-server ID, so its entry (and the history kept for it) survives relaunches.
    static let idKey = "cantrip.home-window.this-mac.id"

    struct Registration {
        let server: SavedServer
        /// This Mac's previous entry was the Mac in use and had to be replaced (its address changed).
        let replacedSelection: Bool
    }

    /// Saves This Mac's current address and token and marks it as `remote`'s local server. It keeps
    /// the existing entry when only the token changed; a new address replaces it. Leftover entries
    /// from builds that re-created This Mac on every launch are dropped.
    @MainActor
    static func register(url: String, token: String, remote: CantripRemoteModel, local: ThisMacToken,
                         defaults: UserDefaults) throws -> Registration {
        local.set(token)
        let servers = remote.servers
        let address = try CantripRemoteModel.normalizedBaseURL(url)?.absoluteString ?? url
        let storedID = defaults.string(forKey: idKey).flatMap(UUID.init(uuidString:))
        let candidates = servers.servers.filter { $0.id == storedID || ($0.name == name && isLoopback($0.url)) }
        var keep = candidates.first { $0.id == storedID && $0.url == address }
            ?? candidates.first { $0.url == address }
        var replacedSelection = false
        remote.localServerID = nil
        for stale in candidates where stale.id != keep?.id {
            if servers.selectedID == stale.id { replacedSelection = true }
            try remote.removeServer(stale)
        }
        if let existing = keep, (try? servers.storedCredential(for: existing)) != token {
            try servers.replaceCredential(token, for: existing)
        }
        if keep == nil {
            keep = try servers.add(ServerDraft(name: name, url: address, credential: token,
                                               tailscaleOnly: true, directAddress: ""))
        }
        guard let server = keep else { throw ServerConfigurationError(message: "This Mac could not be saved.") }
        defaults.set(server.id.uuidString, forKey: idKey)
        remote.localServerID = server.id
        return Registration(server: server, replacedSelection: replacedSelection)
    }

    private static func isLoopback(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

/// This Mac's pairing token, held in memory only, plus the credentials that matched it.
final class ThisMacToken: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var values: [String: String] = [:]

    func set(_ value: String) { lock.withLock { token = value } }

    /// Saved credentials: This Mac's token in memory, anything else in `persistent`.
    func store(persistent: ServerCredentialStore) -> ServerCredentialStore {
        ServerCredentialStore(
            read: { [self] account in
                if let value = lock.withLock({ values[account] }) { return value }
                return try persistent.read(account)
            },
            write: { [self] account, value in
                if lock.withLock({ token == value }) {
                    lock.withLock { values[account] = value }
                    try? persistent.remove(account)
                } else {
                    try persistent.write(account, value)
                    lock.withLock { values[account] = nil }
                }
            },
            remove: { [self] account in
                lock.withLock { values[account] = nil }
                try persistent.remove(account)
            }
        )
    }
}

extension ServerCredentialStore {
    /// Generic passwords under `service` in this app's login Keychain.
    static func keychain(service: String) -> ServerCredentialStore {
        func query(_ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: service,
             kSecAttrAccount as String: account]
        }
        return ServerCredentialStore(
            read: { account in
                var search = query(account)
                search[kSecReturnData as String] = true
                search[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                let status = SecItemCopyMatching(search as CFDictionary, &item)
                if status == errSecItemNotFound { return nil }
                guard status == errSecSuccess, let data = item as? Data else { throw Keychain.Failure(status: status) }
                return String(data: data, encoding: .utf8)
            },
            write: { account, value in
                let data = Data(value.utf8)
                let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                if status == errSecSuccess { return }
                guard status == errSecItemNotFound else { throw Keychain.Failure(status: status) }
                var item = query(account)
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let added = SecItemAdd(item as CFDictionary, nil)
                guard added == errSecSuccess else { throw Keychain.Failure(status: added) }
            },
            remove: { account in
                let status = SecItemDelete(query(account) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw Keychain.Failure(status: status) }
            }
        )
    }
}
