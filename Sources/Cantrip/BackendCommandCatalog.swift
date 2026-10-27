import Foundation

/// The commands a tab's backend exposes in the tab's folder, discovered on this Mac and cached.
/// A cached list is reused while the skill and command folders the backends read are unchanged
/// (and refreshed in the background after 10 minutes); any change there, a new folder or a new
/// backend discovers again. The list itself always comes from the backend.
@MainActor
final class BackendCommandCatalog {
    static let shared = BackendCommandCatalog()

    /// QA hosts point discovery at the real home folder while running with a temporary one.
    var environment = ProcessInfo.processInfo.environment
    var staleAfter: TimeInterval = 10 * 60
    /// How long a request waits for a first discovery before answering with what it has.
    var maximumWait: TimeInterval = 8

    private struct Key: Hashable {
        let backend: BackendKind
        let workdir: String
        let cli: String
    }

    private struct Entry {
        var result: BackendCommandDiscovery.Result
        var fetchedAt: Date
        var fingerprint: String
    }

    private var entries: [Key: Entry] = [:]
    private var inflight: [Key: Task<Entry, Never>] = [:]

    static func family(for backend: BackendKind) -> BackendCommandFamily? {
        switch backend {
        case .copilot: return .copilot
        case .copilotRemote: return .copilotRemote
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        case .localModel: return nil
        }
    }

    /// The list for a tab, discovering it when needed (bounded by `maximumWait`).
    func list(for session: ChatSession, refresh: Bool = false) async -> BackendCommandList {
        let backend = session.effectiveBackendKind
        let workdir = Self.standardized(session.workdir)
        if !session.isLocalPrivate { CommandRegistry.shared.reload() }
        let scripts = session.isLocalPrivate ? [] : CommandRegistry.shared.commands.map { ($0.name, $0.description) }
        if session.isLocalPrivate {
            return BackendCommandList(backend: "Private Local", workdir: workdir,
                                      status: "Private Local tabs have no slash commands.", commands: [])
        }
        let discovered: BackendCommandDiscovery.Result
        switch backend {
        case .copilot, .claudeCode, .codex:
            discovered = await discover(backend: backend, workdir: workdir, refresh: refresh)
        case .copilotRemote:
            discovered = Self.acpResult(session.copilotRemoteCommands)
        case .localModel:
            discovered = .init(commands: [], status: "Local Model has no slash commands of its own.")
        }
        return Self.combine(backend: backend.rawValue, workdir: workdir, discovered: discovered, scripts: scripts)
    }

    /// The last known list, without discovering. Used to label commands as they are sent.
    func cachedList(for session: ChatSession) -> BackendCommandList? {
        guard !session.isLocalPrivate else { return nil }
        let backend = session.effectiveBackendKind
        let workdir = Self.standardized(session.workdir)
        let discovered: BackendCommandDiscovery.Result
        switch backend {
        case .copilot, .claudeCode, .codex:
            guard let entry = entries[key(backend: backend, workdir: workdir)] else { return nil }
            discovered = entry.result
        case .copilotRemote:
            discovered = Self.acpResult(session.copilotRemoteCommands)
        case .localModel:
            discovered = .init(commands: [], status: nil)
        }
        let scripts = CommandRegistry.shared.commands.map { ($0.name, $0.description) }
        return Self.combine(backend: backend.rawValue, workdir: workdir, discovered: discovered, scripts: scripts)
    }

    /// Warms the cache for a tab so its first "/" is instant.
    func prefetch(_ session: ChatSession) {
        guard !session.isLocalPrivate else { return }
        let backend = session.effectiveBackendKind
        guard [.copilot, .claudeCode, .codex].contains(backend) else { return }
        let workdir = Self.standardized(session.workdir)
        Task { _ = await discover(backend: backend, workdir: workdir, refresh: false, wait: .infinity) }
    }

    static func combine(backend: String, workdir: String, discovered: BackendCommandDiscovery.Result,
                        scripts: [(name: String, description: String)]) -> BackendCommandList {
        // Cantrip runs its own script commands before the backend sees the prompt.
        let scriptNames = Set(scripts.map { $0.name.lowercased() })
        let fromBackend = discovered.commands.filter { !scriptNames.contains($0.name.lowercased()) }
        let commands = BackendCommandPolicy.ordered(fromBackend + BackendCommandParsers.cantripScripts(scripts))
        return BackendCommandList(backend: backend, workdir: workdir, status: discovered.status, commands: commands)
    }

    static func acpResult(_ available: (commands: [[String: Any]], endpoint: String)?) -> BackendCommandDiscovery.Result {
        guard let available else {
            return .init(commands: [], status: "Commands appear once this tab has connected to Copilot Remote. Send a message first.")
        }
        return .init(commands: BackendCommandParsers.acp(available.commands), status: nil)
    }

    // MARK: Discovery + cache

    private func key(backend: BackendKind, workdir: String) -> Key {
        let settings = AppSettings.shared
        let cli: String
        switch backend {
        case .copilot: cli = settings.copilotPath
        case .claudeCode: cli = settings.claudePath
        case .codex: cli = settings.codexPath
        default: cli = ""
        }
        return Key(backend: backend, workdir: workdir, cli: cli.trimmingCharacters(in: .whitespaces))
    }

    private func discover(backend: BackendKind, workdir: String, refresh: Bool,
                          wait: TimeInterval? = nil) async -> BackendCommandDiscovery.Result {
        let key = key(backend: backend, workdir: workdir)
        let environment = environment
        let home = environment["HOME"] ?? NSHomeDirectory()
        let fingerprint = await Task.detached(priority: .utility) {
            BackendCommandFingerprint.compute(workdir: workdir, home: home, environment: environment)
        }.value
        if let entry = entries[key], !refresh, entry.fingerprint == fingerprint {
            if Date().timeIntervalSince(entry.fetchedAt) > staleAfter, inflight[key] == nil {
                startDiscovery(key, home: home, fingerprint: fingerprint)
            }
            return entry.result
        }
        let task = inflight[key] ?? startDiscovery(key, home: home, fingerprint: fingerprint)
        let limit = wait ?? maximumWait
        if limit == .infinity { return await task.value.result }
        let finished = await withTaskGroup(of: Entry?.self) { group -> Entry? in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let finished { return finished.result }
        if let entry = entries[key] { return entry.result }
        return .init(commands: [], status: "Still finding this backend's commands. Type / again in a moment.")
    }

    @discardableResult
    private func startDiscovery(_ key: Key, home: String, fingerprint: String) -> Task<Entry, Never> {
        let environment = environment
        let task = Task<Entry, Never> { [weak self] in
            let started = Date()
            let result: BackendCommandDiscovery.Result
            switch key.backend {
            case .copilot:
                result = await BackendCommandDiscovery.copilot(
                    command: ToolLocator.shared.copilotCommand(configured: key.cli), workdir: key.workdir,
                    environment: environment)
            case .claudeCode:
                let configured = key.cli
                let path = await Task.detached(priority: .utility) {
                    ToolLocator.shared.claude(configured: configured)
                }.value
                result = await BackendCommandDiscovery.claude(path: path, workdir: key.workdir,
                                                             environment: environment, home: home)
            case .codex:
                result = await BackendCommandDiscovery.codex(command: key.cli, workdir: key.workdir,
                                                            environment: environment)
            default:
                result = .init(commands: [], status: nil)
            }
            // Measured again afterwards, in case running the CLI touched a folder it reads.
            let after = await Task.detached(priority: .utility) {
                BackendCommandFingerprint.compute(workdir: key.workdir, home: home, environment: environment)
            }.value
            let entry = Entry(result: result, fetchedAt: Date(), fingerprint: after)
            if after != fingerprint { Log.write("commands: discovery changed the fingerprint (kept the new one)") }
            Log.write(String(format: "commands: %@ in %@: %d commands in %.1f s%@", key.backend.rawValue,
                             (key.workdir as NSString).lastPathComponent, result.commands.count,
                             Date().timeIntervalSince(started), result.status.map { " (\($0.prefix(120)))" } ?? ""))
            if let self {
                // A failed refresh keeps the last good list.
                if result.commands.isEmpty, let previous = self.entries[key], !previous.result.commands.isEmpty,
                   key.backend != .codex || result.status?.contains("isn't installed") != true {
                    self.entries[key]?.fetchedAt = Date()
                } else {
                    self.entries[key] = entry
                }
                self.inflight[key] = nil
            }
            return entry
        }
        inflight[key] = task
        return task
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}
