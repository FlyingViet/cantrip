import Foundation
import LocalAuthentication
import Security

/// Cantrip's own list of MCP servers, shared by every backend. Copilot's and Claude Code's
/// configs are imported once; from then on Cantrip writes each backend's config from this list.
/// Nothing secret is stored here: header and environment values that are credentials, and OAuth
/// sign-ins, live in the Keychain (`MCPSecrets`), and servers that need them reach backends
/// through Cantrip's relay (`MCPRelay`).
struct MCPServer: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    /// A local server's command; nil for a remote one.
    var command: String?
    var args: [String] = []
    /// Environment values that aren't secret.
    var env: [String: String] = [:]
    /// Environment keys whose values are in the Keychain.
    var secretEnv: [String] = []
    var cwd: String?
    /// A remote (streamable HTTP) server's address.
    var url: String?
    var headers: [String: String] = [:]
    /// Header names whose values are in the Keychain.
    var secretHeaders: [String] = []
    /// Signs in with OAuth, through Cantrip.
    var oauth = false
    /// Tools the models may use; nil means all.
    var tools: [String]?
    /// Where it was imported from: "copilot", "claude" or "cantrip".
    var source = "cantrip"
    var enabled = true
    /// Backends (BackendKind raw values) that don't get it.
    var disabledBackends: [String] = []

    var isRemote: Bool { url != nil }
    var hasToolLimit: Bool { tools.map { !$0.contains("*") } ?? false }
    /// Reaches backends through Cantrip's relay: it signs in, adds secrets or limits tools.
    var isRelayed: Bool { isRemote || !secretEnv.isEmpty || !secretHeaders.isEmpty || hasToolLimit }

    func isEnabled(for backend: String) -> Bool { enabled && !disabledBackends.contains(backend) }
}

/// Where a server's credentials go: Keychain items under one service, never files.
enum MCPSecrets {
    static let service = "Cantrip MCP"

    enum Failure: LocalizedError, Equatable {
        case locked
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .locked:
                return "The login keychain is locked, so Cantrip can't read MCP sign-ins. Unlock it (log in to the Mac) and try again."
            case .status(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "Cantrip couldn't use the keychain for MCP sign-ins: \(text)"
            }
        }
    }

    /// Reads and writes secrets; tests use an in-memory one.
    struct Store {
        var read: (_ account: String) throws -> Data?
        var write: (_ account: String, _ value: Data) throws -> Void
        var delete: (_ account: String) throws -> Void

        func string(_ account: String) throws -> String? {
            try read(account).flatMap { String(data: $0, encoding: .utf8) }
        }

        func set(_ value: String, for account: String) throws { try write(account, Data(value.utf8)) }

        static let keychain = Store(read: MCPSecrets.load, write: MCPSecrets.save, delete: MCPSecrets.remove)

        static func memory() -> Store {
            final class Box: @unchecked Sendable { var items: [String: Data] = [:]; let lock = NSLock() }
            let box = Box()
            return Store(read: { account in box.lock.withLock { box.items[account] } },
                         write: { account, value in box.lock.withLock { box.items[account] = value } },
                         delete: { account in _ = box.lock.withLock { box.items.removeValue(forKey: account) } })
        }
    }

    /// Account names: "<server>/env/<KEY>", "<server>/header/<Name>", "<server>/oauth".
    static func envAccount(_ server: String, _ key: String) -> String { "\(server)/env/\(key)" }
    static func headerAccount(_ server: String, _ name: String) -> String { "\(server)/header/\(name.lowercased())" }
    static func oauthAccount(_ server: String) -> String { "\(server)/oauth" }
    static func backupAccount(_ file: String) -> String { "backup/\(file)" }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never show a keychain prompt from a background relay: a locked keychain fails visibly.
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        query[kSecUseAuthenticationContext as String] = context
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        return result as? Data
    }

    static func save(_ account: String, _ value: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: value,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw failure(update) }
        var item = query(account)
        for (key, value) in attributes { item[key] = value }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw failure(added) }
    }

    static func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> Failure {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed ? .locked : .status(status)
    }
}

enum MCPRegistry {
    static var file: URL { CantripPaths.cache("mcp/servers.json") }

    struct Snapshot: Codable, Equatable {
        var servers: [MCPServer] = []
        /// When the backends' configs were imported; nil until then.
        var importedAt: Date?
    }

    static func load(from url: URL = file) -> Snapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Snapshot.self, from: $0) }
    }

    static func save(_ snapshot: Snapshot, to url: URL = file) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try PrivateFile.write(try encoder.encode(snapshot), to: url)
    }

    // MARK: - Import

    /// Environment keys and headers that hold credentials.
    static func isSecretEnv(_ key: String) -> Bool {
        let upper = key.uppercased()
        guard !["PATH", "HOME", "NODE_PATH", "PYTHONPATH"].contains(upper), !upper.hasSuffix("_PATH"),
              !upper.hasSuffix("_URL"), !upper.hasSuffix("_HOST"), !upper.hasSuffix("_PORT") else { return false }
        return ["TOKEN", "SECRET", "KEY", "PASSWORD", "PASSWD", "AUTH", "CREDENTIAL", "COOKIE", "SESSION"]
            .contains { upper.contains($0) }
    }

    static func isSecretHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["authorization", "cookie", "proxy-authorization"].contains(lower)
            || ["token", "key", "secret", "auth", "session"].contains { lower.contains($0) }
    }

    struct Imported: Equatable {
        var servers: [MCPServer] = []
        /// Keychain account → value, for every credential found.
        var secrets: [String: String] = [:]
        /// Notes for the import report ("notion: kept Copilot's; Claude's NOTION_TOKEN saved").
        var notes: [String] = []
    }

    /// One config's `mcpServers` in Cantrip's form, credentials split off.
    static func parse(_ servers: [String: [String: Any]], source: String) -> Imported {
        var imported = Imported()
        for (name, spec) in servers.sorted(by: { $0.key < $1.key }) {
            let type = (spec["type"] as? String ?? (spec["url"] != nil ? "http" : "stdio")).lowercased()
            var server = MCPServer(name: name, source: source)
            if ["http", "sse", "streamable-http", "streamablehttp"].contains(type) {
                guard let url = spec["url"] as? String, !url.isEmpty else { continue }
                server.url = url
                for (header, value) in spec["headers"] as? [String: String] ?? [:] {
                    if isSecretHeader(header) {
                        server.secretHeaders.append(header)
                        imported.secrets[MCPSecrets.headerAccount(name, header)] = value
                    } else {
                        server.headers[header] = value
                    }
                }
                // A remote server with no credential of its own signs in with OAuth.
                server.oauth = server.secretHeaders.isEmpty
            } else {
                guard let command = spec["command"] as? String, !command.isEmpty else { continue }
                server.command = command
                server.args = spec["args"] as? [String] ?? []
                server.cwd = spec["cwd"] as? String
            }
            for (key, value) in spec["env"] as? [String: String] ?? [:] {
                if isSecretEnv(key) {
                    server.secretEnv.append(key)
                    imported.secrets[MCPSecrets.envAccount(name, key)] = value
                } else {
                    server.env[key] = value
                }
            }
            server.secretEnv.sort()
            server.secretHeaders.sort()
            if let tools = spec["tools"] as? [String], !tools.contains("*") { server.tools = tools }
            imported.servers.append(server)
        }
        return imported
    }

    /// Copilot's servers first, then Claude Code's. On a name both define differently, the one
    /// without credentials in its config wins; the other's credentials are still kept (for
    /// `cantrip mcp restore`).
    static func importConfigs(copilot: [String: Any]?, claude: [String: Any]?) -> Imported {
        func servers(_ object: [String: Any]?) -> [String: [String: Any]] {
            (object?["mcpServers"] ?? object?["servers"]) as? [String: [String: Any]] ?? [:]
        }
        var result = parse(servers(copilot), source: "copilot")
        let fromClaude = parse(servers(claude), source: "claude")
        result.secrets.merge(fromClaude.secrets) { current, _ in current }
        for server in fromClaude.servers {
            guard let index = result.servers.firstIndex(where: { $0.name == server.name }) else {
                result.servers.append(server)
                continue
            }
            let existing = result.servers[index]
            let same = existing.command == server.command && existing.args == server.args && existing.url == server.url
            if same {
                result.servers[index].source = "copilot+claude"
                continue
            }
            let claudeHasSecrets = !(server.secretEnv.isEmpty && server.secretHeaders.isEmpty)
            let copilotHasSecrets = !(existing.secretEnv.isEmpty && existing.secretHeaders.isEmpty)
            if claudeHasSecrets && !copilotHasSecrets || !claudeHasSecrets {
                result.notes.append("\(server.name): kept Copilot's definition"
                    + (claudeHasSecrets ? "; Claude Code's credentials are saved in the keychain." : " over Claude Code's."))
            } else {
                // Both carry credentials: Claude's version stays available under its own name.
                var renamed = server
                renamed.name = server.name + "-claude"
                for key in server.secretEnv {
                    result.secrets[MCPSecrets.envAccount(renamed.name, key)] = fromClaude.secrets[MCPSecrets.envAccount(server.name, key)]
                }
                for header in server.secretHeaders {
                    result.secrets[MCPSecrets.headerAccount(renamed.name, header)] = fromClaude.secrets[MCPSecrets.headerAccount(server.name, header)]
                }
                result.servers.append(renamed)
                result.notes.append("\(server.name): both had credentials; Claude Code's is now \(renamed.name).")
            }
        }
        result.servers.sort { $0.name < $1.name }
        return result
    }
}
