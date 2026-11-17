import CryptoKit
import Foundation

/// Local-tools shadow runs (a time-limited test): right after a real run of a listed scheduled
/// task finishes, the task runs again on the local model with read-only personal and homelab
/// tools, against the task as it was before the real run (same prompt, Home instructions and
/// window note). Every Cantrip block it writes is captured to a private folder and never applied,
/// nothing is notified, and the real run, its records and the cloud backends are untouched.
/// Off unless `~/.cache/Cantrip/local-tools-shadow/config.json` lists tasks and an end date.
struct CantripHomeShadowConfig: Codable, Equatable {
    var tasks: [String] = []
    var until: Date = .distantPast
    /// MCP servers from the cloud backends' list the shadow runs may use (read-only tools only).
    var servers: [String] = ["personal", "homelab"]
    var maxSteps = 40
    var resultCharacters = 12_000
    /// The local run's input budget (older tool output is left out first).
    var contextBudgetTokens = 56_000
    /// Shadow runs wait while these tasks run (other heavy users of the local model).
    var waitForTasks: [String] = []
    /// Where the cloud backends' MCP servers are listed.
    var mcpConfigPath = "~/.copilot/mcp-config.json"
    /// Run after each shadow run with its folder as the argument (scoring), e.g. a local script.
    var afterRun: [String] = []
    /// Sent as the request's `priority` (Splash: foreground, normal or background) so shadow runs
    /// yield to Home chat and the Privacy Gate; empty for servers that reject unknown fields.
    var priority = "background"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        tasks = try c.decodeIfPresent([String].self, forKey: .tasks) ?? d.tasks
        until = try c.decodeIfPresent(Date.self, forKey: .until) ?? d.until
        servers = try c.decodeIfPresent([String].self, forKey: .servers) ?? d.servers
        maxSteps = try c.decodeIfPresent(Int.self, forKey: .maxSteps) ?? d.maxSteps
        resultCharacters = try c.decodeIfPresent(Int.self, forKey: .resultCharacters) ?? d.resultCharacters
        contextBudgetTokens = try c.decodeIfPresent(Int.self, forKey: .contextBudgetTokens) ?? d.contextBudgetTokens
        waitForTasks = try c.decodeIfPresent([String].self, forKey: .waitForTasks) ?? d.waitForTasks
        mcpConfigPath = try c.decodeIfPresent(String.self, forKey: .mcpConfigPath) ?? d.mcpConfigPath
        afterRun = try c.decodeIfPresent([String].self, forKey: .afterRun) ?? d.afterRun
        priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? d.priority
    }

    static var folder: URL { CantripPaths.cache("local-tools-shadow") }

    static func load(from url: URL = folder.appendingPathComponent("config.json")) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }

    func covers(_ taskID: UUID, at date: Date) -> Bool {
        date <= until && tasks.contains { $0.caseInsensitiveCompare(taskID.uuidString) == .orderedSame }
    }

    func waits(for taskID: UUID) -> Bool {
        waitForTasks.contains { $0.caseInsensitiveCompare(taskID.uuidString) == .orderedSame }
    }
}

/// The shadow runs' tools: the listed MCP servers from the cloud backends' configuration, their
/// read-only tools only. Never Bitwarden, never a shell.
final class CantripHomeShadowTools: @unchecked Sendable {
    static let deniedServers: Set<String> = ["bitwarden"]
    /// A tool whose name has one of these words can change something; it's left out.
    static let writeWords: Set<String> = [
        "create", "update", "delete", "remove", "set", "send", "edit", "write", "post", "put", "patch", "move",
        "rename", "unlock", "lock", "generate", "sync", "upload", "fill", "approve", "archive", "publish",
        "execute", "call", "toggle", "turn", "add", "mark", "reply", "trash", "save", "submit", "cancel", "run",
    ]

    static func isReadOnly(server: String, tool: String) -> Bool {
        guard !deniedServers.contains(server.lowercased()) else { return false }
        let words = tool.lowercased().split { $0 == "_" || $0 == "-" || $0 == "." }.map(String.init)
        return !words.contains { writeWords.contains($0) }
    }

    struct Tool { let server: String; let name: String; let description: String; let schema: [String: Any] }

    private let lock = NSLock()
    private var connections: [String: MCPServerConnection] = [:]
    private var available: [Tool] = []
    private var started = false
    let config: CantripHomeShadowConfig
    /// Replaceable for tests: (server, tool, arguments) -> (output, success).
    var caller: ((String, String, [String: Any]) -> (String, Bool))?

    init(config: CantripHomeShadowConfig, tools: [Tool]? = nil) {
        self.config = config
        if let tools {
            available = tools.filter { Self.isReadOnly(server: $0.server, tool: $0.name) }
            started = true
        }
    }

    /// Starts the listed servers (once) from the cloud backends' MCP list.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        let path = (config.mcpConfigPath as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = (object["mcpServers"] ?? object["servers"]) as? [String: [String: Any]] else {
            Log.write("home shadow: no MCP list at \(config.mcpConfigPath)")
            return
        }
        for name in config.servers where !Self.deniedServers.contains(name.lowercased()) {
            guard let spec = servers[name], let command = spec["command"] as? String,
                  let connection = MCPServerConnection(name: name, command: command, args: spec["args"] as? [String] ?? [],
                                                       extraEnv: spec["env"] as? [String: String] ?? [:]) else {
                Log.write("home shadow: MCP server \(name) unavailable")
                continue
            }
            connections[name] = connection
            for tool in connection.tools where Self.isReadOnly(server: name, tool: tool.name) {
                available.append(Tool(server: name, name: tool.name, description: tool.description, schema: tool.schema))
            }
        }
        Log.write("home shadow: \(available.count) read-only tools from \(connections.keys.sorted().joined(separator: ", "))")
    }

    func openAITools() -> [[String: Any]] {
        start()
        lock.lock(); defer { lock.unlock() }
        return available.map { tool in
            ["type": "function", "function": [
                "name": "mcp__\(tool.server)__\(tool.name)",
                "description": String(tool.description.prefix(500)), "parameters": tool.schema,
            ] as [String: Any]]
        }
    }

    /// Runs one offered tool; anything else is refused. `allowed` is false for refusals.
    func call(_ fullName: String, arguments: [String: Any]) -> (output: String, success: Bool, allowed: Bool) {
        start()
        let parts = fullName.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else {
            return ("Only the read-only personal and homelab tools are available in this run.", false, false)
        }
        let server = parts[1], tool = parts.dropFirst(2).joined(separator: "__")
        lock.lock()
        let offered = available.contains { $0.server == server && $0.name == tool }
        let connection = connections[server]
        lock.unlock()
        guard offered else { return ("This tool isn't available in this run (read-only tools only).", false, false) }
        if let caller { let (output, success) = caller(server, tool, arguments); return (output, success, true) }
        guard let connection else { return ("The \(server) server isn't running.", false, true) }
        let (output, success) = connection.callTool(tool, arguments: arguments)
        return (output, success, true)
    }
}

/// One shadow run: the task as it was before the real run, and everything the local run wrote,
/// kept in a private folder. Its log holds tool names and counts, never arguments or results.
final class CantripHomeShadowRun: @unchecked Sendable {
    let realRunID: UUID
    let taskID: UUID
    let title: String
    /// The store as it was when the real run started.
    let tasks: [CantripHomeTask]
    let note: String?
    let folder: URL
    let config: CantripHomeShadowConfig
    var startedAt: Date?
    let queuedAt = Date()
    private let lock = NSLock()
    private(set) var toolCalls: [String: Int] = [:]
    private(set) var refusedCalls: [String: Int] = [:]
    private(set) var blockCounts: [String: Int] = [:]
    private(set) var steps = 0
    private(set) var promptTokens = 0
    private(set) var completionTokens = 0

    var task: CantripHomeTask? { tasks.first { $0.id == taskID } }

    init(realRunID: UUID, task: CantripHomeTask, tasks: [CantripHomeTask], note: String?,
         config: CantripHomeShadowConfig, root: URL = CantripHomeShadowConfig.folder) {
        self.realRunID = realRunID
        self.taskID = task.id
        self.title = task.title
        self.tasks = tasks
        self.note = note
        self.config = config
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        folder = root.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("\(stamp)-\(task.id.uuidString.prefix(8))-\(realRunID.uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.deletingLastPathComponent().path)
    }

    func noteStep() { lock.withLock { steps += 1 } }

    func noteUsage(prompt: Int, completion: Int) {
        lock.withLock { promptTokens += prompt; completionTokens += completion }
    }

    func noteToolCall(_ name: String, allowed: Bool) {
        lock.withLock {
            if allowed { toolCalls[name, default: 0] += 1 } else { refusedCalls[name, default: 0] += 1 }
        }
    }

    /// A Cantrip block the run wrote: kept as written, never applied.
    func capture(kind: String, payload: String) {
        lock.withLock { blockCounts[kind, default: 0] += 1 }
        let line = (try? JSONSerialization.data(withJSONObject: ["kind": kind, "payload": payload])) ?? Data()
        append(line + Data([0x0A]), to: "blocks.jsonl")
    }

    /// The task's records (as saved) and their checksum.
    static func records(of task: CantripHomeTask?) -> (data: Data, sha256: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(task?.workspace?.records ?? [])) ?? Data("[]".utf8)
        return (data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func write(_ name: String, data: Data) {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    func writeJSON(_ name: String, _ object: [String: Any]) {
        write(name, data: (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data())
    }

    private func append(_ data: Data, to name: String) {
        let url = folder.appendingPathComponent(name)
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// The run's summary: counts, labels and times only.
    func summary(status: String, endedAt: Date, error: String?, model: String, server: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: Any] = [
            "realRun": realRunID.uuidString, "task": taskID.uuidString, "title": title, "status": status,
            "model": model, "server": server, "steps": steps, "toolCalls": toolCalls, "refusedCalls": refusedCalls,
            "blocks": blockCounts, "promptTokens": promptTokens, "completionTokens": completionTokens,
            "seconds": Int(endedAt.timeIntervalSince(startedAt ?? endedAt)),
        ]
        result["startedAt"] = startedAt.map { ISO8601DateFormatter().string(from: $0) }
        result["error"] = error.map { String($0.prefix(300)) }
        return result
    }
}
