import Foundation
import UserNotifications

/// Runs shared MCP in the host: the relay, keeping sign-ins fresh, alerts when a sign-in needs
/// you, and writing each backend's config from the list.
@MainActor
final class MCPHost {
    static let shared = MCPHost()

    private var relay: MCPRelay?
    private var timer: Timer?
    weak var remote: RemoteControlServer?
    var postsMacNotifications = true
    /// Scheduled-task runs (tab IDs), which only get `CantripHomeTaskTools.allowedServers`.
    static var taskRunTabs = Set<String>()
    private var alertIDs: [String: UUID] = [:]

    func start(remote: RemoteControlServer?, postsMacNotifications: Bool) {
        self.remote = remote
        self.postsMacNotifications = postsMacNotifications
        let hub = MCPServerHub.shared
        hub.onNeedsAttention = { [weak self] name, phase in self?.alert(name, phase) }
        let environment = MCPRelay.Environment(
            server: { name in MCPRegistry.load()?.servers.first { $0.name == name } },
            refusal: { hello, server in
                DispatchQueue.main.sync { MainActor.assumeIsolated { MCPHost.refusal(hello, server) } }
            },
            onSignInProblem: { name, message in
                DispatchQueue.main.async { MainActor.assumeIsolated { MCPServerHub.shared.reportProblem(name, message) } }
            })
        let relay = MCPRelay(environment: environment)
        relay.start()
        self.relay = relay
        Task { await hub.refreshStates() }
        // Refresh sign-ins before they lapse, so they survive days without use.
        timer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { _ in
            Task { @MainActor in await MCPHost.shared.refreshSignIns() }
        }
        Task { await refreshSignIns() }
    }

    func refreshSignIns() async {
        let hub = MCPServerHub.shared
        let names = hub.snapshot.servers.filter(\.oauth).map(\.name)
        guard !names.isEmpty else { return }
        let problems = await hub.signIns.refreshExpiring(names)
        for (name, message) in problems { hub.reportProblem(name, message) }
        await hub.refreshStates()
    }

    /// Why a tab or backend can't use a server right now (the relay's answer), or nil.
    static func refusal(_ hello: MCPRelay.Hello, _ server: MCPServer) -> String? {
        if !server.enabled { return "\(server.name) is switched off in Cantrip's MCP Servers settings." }
        if let backend = hello.backend, server.disabledBackends.contains(backend) {
            return "\(server.name) is switched off for \(backend) in Cantrip's MCP Servers settings."
        }
        guard let tab = hello.tab else { return nil }
        if MCPBackendConfig.tabDisabled(UUID(uuidString: tab)).contains(server.name) {
            return "\(server.name) is switched off for this tab."
        }
        if taskRunTabs.contains(tab.uppercased()), !CantripHomeTaskTools.allowedServers.contains(server.name) {
            return "Scheduled tasks don't get \(server.name) (\(CantripHomeTaskTools.serversKey))."
        }
        return nil
    }

    private func alert(_ name: String, _ phase: MCPServerHub.Phase) {
        let id = alertIDs[name] ?? UUID()
        alertIDs[name] = id
        remote?.notifyMCPSignIn(id: id)
        guard postsMacNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = phase == .awaitingApproval ? "Approve the \(name) sign-in" : "\(name) needs signing in"
        content.body = phase == .awaitingApproval
            ? "Approve it in Cantrip's MCP Servers settings or from Cantrip Agent."
            : "Open Cantrip's MCP Servers settings to connect it."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
    }

    /// The alert for `name` is no longer needed (approved, declined, signed in).
    func resolveAlert(_ name: String) {
        guard let id = alertIDs.removeValue(forKey: name) else { return }
        remote?.resolveInputNotification(id)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }
}

/// Moving the backends' own MCP configs into Cantrip's list, and back.
enum MCPMigration {
    static var copilotConfig: URL { ClaudeSharedMCP.copilotConfig }
    static var claudeConfig: URL { ClaudeSharedMCP.claudeConfig }
    static var managedFile: URL { CantripPaths.cache("mcp/antigravity-managed.json") }

    struct Report: Codable {
        var servers: [String] = []
        var relayed: [String] = []
        var secretsMoved = 0
        var notes: [String] = []
        var written: [String] = []
        var dryRun = true
    }

    struct Problem: LocalizedError {
        var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// `run` changed some files, then stopped: what it changed, and why it stopped.
    struct Incomplete: LocalizedError {
        var report: Report
        var reason: String
        /// Claude Code servers still in ~/.claude.json as they were, credentials included.
        var claudeUnchanged: [String] = []

        var errorDescription: String? {
            var lines = ["Stopped partway: \(reason)", "Already updated: " + report.written.joined(separator: "; ") + "."]
            if !claudeUnchanged.isEmpty {
                lines.append("Not updated: ~/.claude.json still has its own \(claudeUnchanged.joined(separator: ", ")) (credentials included). "
                             + "Fix that, then run `cantrip mcp migrate --apply` again.")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// The `claude` CLI to run: Settings' path, or `claude` when that's blank (as chats use), found
    /// the way Cantrip finds its CLIs, since a bare name can't be started directly.
    static func claudeExecutable(_ configured: String, locator: ToolLocator = .shared) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        return locator.claude(configured: trimmed) ?? (trimmed.isEmpty ? "claude" : trimmed)
    }

    private static func object(at url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Replaces every credential value with a placeholder, for backups kept as files.
    static func redacted(_ servers: [String: Any]) -> [String: Any] {
        var copy = servers
        for (name, value) in servers {
            guard var spec = value as? [String: Any] else { continue }
            for field in ["env", "headers"] {
                guard var values = spec[field] as? [String: String] else { continue }
                for key in values.keys where field == "env" ? MCPRegistry.isSecretEnv(key) : MCPRegistry.isSecretHeader(key) {
                    values[key] = "<in the keychain: cantrip mcp restore>"
                }
                spec[field] = values
            }
            copy[name] = spec
        }
        return copy
    }

    /// Imports both configs (keeping switches already set in Cantrip), moves credentials to the
    /// keychain, keeps redacted backups, and rewrites the backends' configs from the list. Throws
    /// `Incomplete` when it stops after changing something.
    @discardableResult
    static func run(dryRun: Bool, secrets: MCPSecrets.Store = .keychain, claudePath: String = AppSettings.shared.claudePath,
                    locator: ToolLocator = .shared, now: Date = Date(),
                    access: ([MCPServer]) -> [String: MCPOAuth.Access] = { MCPOAuth.detectAccessWaiting($0) }) throws -> Report {
        let copilot = object(at: copilotConfig), claude = object(at: claudeConfig)
        let imported = MCPRegistry.importConfigs(copilot: copilot, claude: claude)
        let previous = MCPRegistry.load()
        var servers = imported.servers
        var unasked: [MCPServer] = []
        for index in servers.indices {
            // A server already in the list keeps its switches; relay entries re-import as themselves.
            let known = previous?.servers.first(where: { $0.name == servers[index].name })
            if let known {
                if servers[index].command == MCPBackendConfig.relayScript || servers[index].args.first == known.name {
                    servers[index] = known
                    continue
                }
                servers[index].enabled = known.enabled
                servers[index].disabledBackends = known.disabledBackends
            }
            // A remote server without a credential of its own is asked whether it needs a sign-in,
            // unless it's already in the list at that address.
            guard servers[index].isRemote, servers[index].secretHeaders.isEmpty else { continue }
            if let known, known.url == servers[index].url, known.secretHeaders.isEmpty {
                servers[index].oauth = known.oauth
            } else {
                unasked.append(servers[index])
            }
        }
        var accessNotes: [String] = []
        for (name, found) in (unasked.isEmpty ? [:] : access(unasked)).sorted(by: { $0.key < $1.key }) {
            guard let index = servers.firstIndex(where: { $0.name == name }) else { continue }
            switch found {
            case .open:
                servers[index].oauth = false
                accessNotes.append("\(name) answers without signing in, so it needs no sign-in.")
            case .oauth:
                servers[index].oauth = true
                accessNotes.append("\(name) signs in with OAuth: `cantrip mcp connect \(name)` (or Connect in Settings).")
            case .unknown(let why):
                servers[index].oauth = true
                accessNotes.append("\(name): couldn't tell whether it needs a sign-in (\(why)), so it's set to sign in with OAuth; Connect checks again.")
            }
        }
        for known in previous?.servers ?? [] where !servers.contains(where: { $0.name == known.name }) { servers.append(known) }
        servers = MCPBackendConfig.droppingExportAliases(servers)
        servers.sort { $0.name < $1.name }
        var report = Report(servers: servers.map(\.name), relayed: servers.filter(\.isRelayed).map(\.name),
                            secretsMoved: imported.secrets.count, notes: imported.notes + accessNotes, dryRun: dryRun)
        let snapshot = MCPRegistry.Snapshot(servers: servers, importedAt: previous?.importedAt ?? now)
        let claudeServers = claude?["mcpServers"] as? [String: Any] ?? [:]
        let claudeNames = claudeServers.keys.sorted().filter { name in snapshot.servers.contains { $0.name == name } }
        // Claude Code's servers are rewritten through its CLI, last: check it runs before changing anything.
        let claudeCLI = claudeExecutable(claudePath, locator: locator)
        if !claudeNames.isEmpty, !(claudeCLI.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: claudeCLI)) {
            let problem = "Cantrip can't run Claude Code's CLI (\(claudeCLI)) to update ~/.claude.json. "
                + "Set its path in Cantrip's settings (Claude Code) or install it, then run this again."
            guard dryRun else { throw Problem(problem) }
            report.notes.append(problem)
        }
        guard !dryRun else { return report }

        var claudeDone = 0
        do {
            // Credentials first: nothing changes if the keychain refuses.
            for (account, value) in imported.secrets { try secrets.set(value, for: account) }
            let stamp = ISODate.localDay(now).replacingOccurrences(of: "-", with: "")
            if let copilot, previous?.importedAt == nil {
                // The file exactly as it was, so restoring gives it back byte for byte.
                try secrets.write(MCPSecrets.backupAccount("copilot-mcp-config.json"), try Data(contentsOf: copilotConfig))
                var safe = copilot
                safe["mcpServers"] = redacted(copilot["mcpServers"] as? [String: Any] ?? [:])
                try PrivateFile.write(try JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]),
                                      to: copilotConfig.appendingPathExtension("pre-cantrip-\(stamp)"))
            }
            if !claudeServers.isEmpty, previous?.importedAt == nil {
                try secrets.write(MCPSecrets.backupAccount("claude-mcpServers.json"), try JSONSerialization.data(withJSONObject: claudeServers))
                try PrivateFile.write(try JSONSerialization.data(withJSONObject: redacted(claudeServers), options: [.prettyPrinted, .sortedKeys]),
                                      to: CantripPaths.cache("mcp/claude-mcpServers.pre-cantrip-\(stamp).json"))
            }
            try MCPRegistry.save(snapshot)
            report.written.append("Cantrip's MCP list")
            try sync(snapshot, into: &report.written)
            // Claude Code's own servers become relay entries (no credentials left in ~/.claude.json).
            for name in claudeNames {
                guard let server = snapshot.servers.first(where: { $0.name == name }) else { continue }
                var entry = MCPBackendConfig.command(server, backend: .claudeCode)
                entry["type"] = "stdio"
                let json = String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), as: UTF8.self)
                let exported = MCPBackendConfig.exportName(name)
                for old in Set([name, exported]) {
                    _ = try? ProcessRunner.run(claudeCLI, ["mcp", "remove", "-s", "user", old], errorOutput: .discard, timeout: 30)
                }
                let added: ProcessRunner.Result
                do {
                    added = try ProcessRunner.run(claudeCLI, ["mcp", "add-json", "-s", "user", exported, json], timeout: 30)
                } catch {
                    throw Problem("couldn't run Claude Code's CLI (\(claudeCLI)): \(error.localizedDescription)")
                }
                claudeDone += 1
                guard added.succeeded else {
                    report.notes.append("Claude Code: couldn't update \(name): \(added.errorText.isEmpty ? added.text : added.errorText)")
                    continue
                }
                report.written.append("~/.claude.json: \(exported)")
            }
        } catch {
            guard !report.written.isEmpty else { throw error }
            Log.write("mcp: migration stopped partway: \(error.localizedDescription)")
            throw Incomplete(report: report, reason: error.localizedDescription, claudeUnchanged: Array(claudeNames.dropFirst(claudeDone)))
        }
        Log.write("mcp: migrated \(servers.count) servers (\(imported.secrets.count) credentials to the keychain)")
        return report
    }

    /// Writes Copilot's and Antigravity's configs from the list. Returns what it wrote.
    @discardableResult
    static func sync(_ snapshot: MCPRegistry.Snapshot) throws -> [String] {
        var written: [String] = []
        try sync(snapshot, into: &written)
        return written
    }

    /// `sync`, adding each file to `written` as it's written (so a failure partway still says what changed).
    static func sync(_ snapshot: MCPRegistry.Snapshot, into written: inout [String]) throws {
        guard snapshot.importedAt != nil else { return }
        var copilot = object(at: copilotConfig) ?? [:]
        copilot["mcpServers"] = MCPBackendConfig.copilot(snapshot)["mcpServers"]
        try PrivateFile.write(try JSONSerialization.data(withJSONObject: copilot, options: [.prettyPrinted, .sortedKeys]), to: copilotConfig)
        written.append("~/.copilot/mcp-config.json")
        let managed = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: managedFile))) ?? [])
        let antigravity = MCPBackendConfig.antigravity(existing: object(at: MCPBackendConfig.antigravityFile),
                                                       snapshot: snapshot, managed: managed)
        try PrivateFile.write(try JSONSerialization.data(withJSONObject: antigravity.config, options: [.prettyPrinted, .sortedKeys]),
                              to: MCPBackendConfig.antigravityFile)
        written.append("~/.gemini/config/mcp_config.json")
        try PrivateFile.write(try JSONEncoder().encode(antigravity.managed.sorted()), to: managedFile)
    }

    /// Puts the backends' original configs back (credentials included), from the keychain.
    static func restore(secrets: MCPSecrets.Store = .keychain, claudePath: String = AppSettings.shared.claudePath,
                        locator: ToolLocator = .shared) throws -> [String] {
        let claudeCLI = claudeExecutable(claudePath, locator: locator)
        var restored: [String] = []
        if let data = try secrets.read(MCPSecrets.backupAccount("copilot-mcp-config.json")) {
            try PrivateFile.write(data, to: copilotConfig)
            restored.append("~/.copilot/mcp-config.json")
        }
        if let data = try secrets.read(MCPSecrets.backupAccount("claude-mcpServers.json")),
           let servers = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (name, spec) in servers.sorted(by: { $0.key < $1.key }) {
                let json = String(decoding: try JSONSerialization.data(withJSONObject: spec), as: UTF8.self)
                _ = try? ProcessRunner.run(claudeCLI, ["mcp", "remove", "-s", "user", name], errorOutput: .discard, timeout: 30)
                _ = try ProcessRunner.run(claudeCLI, ["mcp", "add-json", "-s", "user", name, json], timeout: 30)
            }
            restored.append("~/.claude.json (\(servers.count) servers)")
        }
        if var snapshot = MCPRegistry.load() {
            snapshot.importedAt = nil
            try MCPRegistry.save(snapshot)
        }
        return restored
    }
}
