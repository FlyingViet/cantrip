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
    /// Tuning (shadow runs only): extra system instructions, sampling and thinking level.
    var instructions = ""
    var temperature: Double?
    /// Sent as `reasoning_effort` (Splash: low, medium, high turn thinking on); empty to leave it.
    var reasoningEffort = ""
    /// Offer `home_records`: the task's saved records from the run's snapshot, every field and full ID
    /// (real runs print them with a shell command shadow runs don't have).
    var recordsTool = false
    /// Check record changes the way saving them would, and send the problems back once to correct.
    var validateRecords = false
    /// Keep the first request and every tool call with its full result in the run's private folder,
    /// so the run can be replayed offline with other settings. Deleted a day after `until`.
    var keepTranscript = true
    /// Refuse repeated identical tool calls, warn 10 steps before the cap, and treat a new record that
    /// repeats an existing one (same title field) as a problem to correct.
    var guards = false
    /// Offer `memory_read` and `memory_search`: the memory vault's notes, read-only (real runs read a
    /// task's procedure note with the shell).
    var memoryTools = false

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
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? d.instructions
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        reasoningEffort = try c.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? d.reasoningEffort
        recordsTool = try c.decodeIfPresent(Bool.self, forKey: .recordsTool) ?? d.recordsTool
        validateRecords = try c.decodeIfPresent(Bool.self, forKey: .validateRecords) ?? d.validateRecords
        keepTranscript = try c.decodeIfPresent(Bool.self, forKey: .keepTranscript) ?? d.keepTranscript
        guards = try c.decodeIfPresent(Bool.self, forKey: .guards) ?? d.guards
        memoryTools = try c.decodeIfPresent(Bool.self, forKey: .memoryTools) ?? d.memoryTools
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
    /// The one correction round (`validateRecords`) was used.
    var corrected = false
    private(set) var validationProblems = 0
    private var savedRequest = false
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

    // MARK: Transcript (private, for offline replay)

    /// The first request as sent: messages and tools (the model and sampling are in run.json).
    func saveRequest(_ body: [String: Any]) {
        guard config.keepTranscript, lock.withLock({ () -> Bool in defer { savedRequest = true }; return !savedRequest }) else { return }
        var kept = body
        kept["stream"] = nil
        kept["stream_options"] = nil
        writeJSON("request.json", kept)
    }

    func recordToolCall(_ name: String, arguments: [String: Any], output: String, success: Bool, allowed: Bool) {
        guard config.keepTranscript else { return }
        let entry: [String: Any] = ["name": name, "arguments": arguments, "output": output,
                                    "success": success, "allowed": allowed]
        let line = (try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])) ?? Data()
        append(line + Data([0x0A]), to: "tools.jsonl")
    }

    /// Removes saved requests and tool results from every run folder (after the test ends).
    static func purgeTranscripts(root: URL = CantripHomeShadowConfig.folder) -> Int {
        let folder = root.appendingPathComponent("private", isDirectory: true)
        let runs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for run in runs {
            for name in ["tools.jsonl", "request.json"] {
                if (try? FileManager.default.removeItem(at: run.appendingPathComponent(name))) != nil { removed += 1 }
            }
        }
        return removed
    }

    // MARK: Records tool

    static let recordsToolName = "home_records"

    static var recordsToolSchema: [String: Any] {
        ["type": "function", "function": [
            "name": recordsToolName,
            "description": "Read the saved records of a Cantrip Home task (read-only): every field and the full record ID. "
                + "Use it instead of the command the instructions mention for printing records. Defaults to this task. "
                + "Filter with `ids` (full IDs, or their first 8 or more characters) or `query` (words found in any field); "
                + "page with `offset` and `limit` (default 20, at most 50).",
            "parameters": ["type": "object", "properties": [
                "task": ["type": "string", "description": "Task ID (default: this task)"],
                "ids": ["type": "array", "items": ["type": "string"], "description": "Record IDs or ID prefixes"],
                "query": ["type": "string", "description": "Words to look for; records with the most of them come first"],
                "offset": ["type": "integer"], "limit": ["type": "integer"],
            ] as [String: Any]],
        ] as [String: Any]]
    }

    func recordsTool(_ arguments: [String: Any]) -> String {
        let wanted = (arguments["task"] as? String).flatMap(UUID.init(uuidString:)) ?? taskID
        guard let task = tasks.first(where: { $0.id == wanted }), let workspace = task.workspace else {
            return "No task with records has that ID. Omit `task` for this task's records."
        }
        var records = workspace.records
        if let ids = arguments["ids"] as? [String], !ids.isEmpty {
            let prefixes = ids.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { $0.count >= 8 }
            records = records.filter { record in prefixes.contains { record.id.uuidString.hasPrefix($0) } }
        }
        if let query = (arguments["query"] as? String)?.lowercased(), !query.isEmpty {
            // Ranked by how many of the words a record has: a partial name still finds it.
            let words = query.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
            records = records.enumerated().map { index, record -> (Int, Int, CantripHomeTaskRecord) in
                let text = record.values.values.joined(separator: " ").lowercased()
                return (words.filter { text.contains($0) }.count, index, record)
            }.filter { $0.0 > 0 }.sorted { ($0.0, -$0.1) > ($1.0, -$1.1) }.map(\.2)
        }
        let offset = max(0, (arguments["offset"] as? NSNumber)?.intValue ?? 0)
        let limit = min(50, max(1, (arguments["limit"] as? NSNumber)?.intValue ?? 20))
        let page = records.dropFirst(offset).prefix(limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = page.map { record -> String in
            let object = ["id": record.id.uuidString, "values": record.values] as [String: Any]
            return String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        }
        let range = page.isEmpty ? "none" : "\(offset + 1)-\(offset + page.count)"
        return "Task \(task.id.uuidString) · \(task.title): \(records.count) matching records (showing \(range)); "
            + "fields: \(workspace.fields.map(\.key).joined(separator: ", ")).\n" + lines.joined(separator: "\n")
    }

    // MARK: Checking record changes

    /// Separates a reply's first record changes from the corrected ones; only blocks after it count.
    static let correctionMarker = "(Corrected record changes follow; they replace the record changes above.)"

    /// What saving these record blocks would refuse or what does nothing, checked against the
    /// snapshot. Empty when they're fine.
    func validate(_ text: String) -> [String] {
        var copy = text
        var problems: [String] = []
        for block in CantripHomeProtocol.extractBlocks(from: &copy) where block.kind == .records {
            guard let batch = try? CantripHomeProtocol.decode(CantripHomeTaskRecordBatch.self, from: block.payload) else {
                problems.append("A cantrip-task-records block isn't valid JSON for {\"taskID\", \"changes\": [...]}.")
                continue
            }
            guard let task = tasks.first(where: { $0.id == batch.taskID }), let workspace = task.workspace else {
                problems.append("taskID \(batch.taskID.uuidString) isn't a task with records.")
                continue
            }
            if batch.changes.isEmpty {
                problems.append("A block for \(task.title) has no changes; leave the block out when nothing changed.")
            }
            if batch.changes.count > 50 { problems.append("A block has \(batch.changes.count) changes; at most 50 per block.") }
            let fields = Set(workspace.fields.map(\.key))
            for change in batch.changes {
                let values = change.values ?? [:]
                for key in values.keys where !fields.contains(key) {
                    problems.append("Field \"\(key)\" isn't in \(task.title) (fields: \(fields.sorted().joined(separator: ", "))).")
                }
                guard let id = change.id else {
                    if change.operation == .delete { problems.append("A delete has no record ID.") }
                    let titleKey = workspace.list.titleField
                    if config.guards, let title = values[titleKey].map(Self.normalized), !title.isEmpty,
                       let existing = workspace.records.first(where: { Self.normalized($0.values[titleKey] ?? "") == title }) {
                        problems.append("A new record repeats existing record \(existing.id.uuidString) (\(titleKey) "
                            + "\"\(values[titleKey] ?? "")\"); update that record instead of adding one.")
                    }
                    continue
                }
                guard let record = workspace.records.first(where: { $0.id == id }) else {
                    problems.append("Record \(id.uuidString) doesn't exist in \(task.title); use a full ID from the records.")
                    continue
                }
                if change.operation == .upsert, !values.isEmpty,
                   values.allSatisfy({ record.values[$0.key] == $0.value }) {
                    problems.append("Record \(id.uuidString) is resent with unchanged values; send only fields that changed.")
                }
            }
        }
        // IDs that aren't UUIDs fail to decode: point at them.
        for match in text.matches(of: #/"id"\s*:\s*"([0-9A-Fa-f-]{4,35})"/#) {
            problems.append("\"\(match.1)\" isn't a full record ID; use the full 36-character ID (home_records shows them).")
        }
        lock.withLock { validationProblems += problems.count }
        return Array(problems.prefix(20))
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    // MARK: Guards and memory

    private var seenCalls: [String: Int] = [:]

    /// The step an identical call (same tool and arguments) was already made at, or nil (and records it).
    func repeatedCall(_ name: String, arguments: [String: Any], step: Int) -> Int? {
        let data = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data()
        let key = name + "\u{1F}" + String(decoding: data, as: UTF8.self)
        return lock.withLock {
            if let earlier = seenCalls[key] { repeats += 1; return earlier }
            seenCalls[key] = step
            return nil
        }
    }

    private(set) var repeats = 0

    static let stepsLeftNote = "(10 tool steps left. Finish looking things up and write your record changes and report.)"

    static let memoryToolNames: Set<String> = ["memory_read", "memory_search"]

    static var memoryToolSchemas: [[String: Any]] {
        [["type": "function", "function": [
            "name": "memory_read",
            "description": "Read a note from the user's memory vault (read-only), e.g. the task's procedure note named in "
                + "the instructions (\"interview-tracker.md\"). Without `note`, lists the notes. Page with `offset`/`limit` (lines).",
            "parameters": ["type": "object", "properties": [
                "note": ["type": "string"], "offset": ["type": "integer"], "limit": ["type": "integer"],
            ] as [String: Any]],
        ] as [String: Any]],
         ["type": "function", "function": [
            "name": "memory_search",
            "description": "Search the memory vault's notes for lines containing all the words (read-only). "
                + "Returns up to 40 matching lines as note:line.",
            "parameters": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]] as [String: Any],
         ] as [String: Any]]]
    }

    /// The vault's notes (Markdown, not the session logs), read-only.
    static func memoryTool(_ name: String, arguments: [String: Any], vault: URL) -> String {
        let root = vault.standardizedFileURL
        let notes = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "md" && !$0.path.contains("/sessions/") }
            .map { $0.standardizedFileURL }.sorted { $0.path < $1.path }
        func relative(_ url: URL) -> String { String(url.path.dropFirst(root.path.count + 1)) }
        if name == "memory_read" {
            let note = (arguments["note"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !note.isEmpty else { return "Notes:\n" + notes.map(relative).joined(separator: "\n") }
            guard let url = notes.first(where: { relative($0) == note || $0.lastPathComponent == (note as NSString).lastPathComponent }),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return "No note named \(note). Call memory_read without `note` to list them."
            }
            let lines = text.components(separatedBy: "\n")
            let offset = max(0, (arguments["offset"] as? NSNumber)?.intValue ?? 0)
            let limit = min(400, max(1, (arguments["limit"] as? NSNumber)?.intValue ?? 200))
            let page = lines.dropFirst(offset).prefix(limit)
            return "\(relative(url)) lines \(offset + 1)-\(offset + page.count) of \(lines.count):\n" + page.joined(separator: "\n")
        }
        let words = ((arguments["query"] as? String) ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty else { return "No matching lines." }
        var hits: [String] = []
        for url in notes {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() where words.allSatisfy(line.lowercased().contains) {
                hits.append("\(relative(url)):\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(300))")
                if hits.count >= 40 { return hits.joined(separator: "\n") }
            }
        }
        return hits.isEmpty ? "No matching lines." : hits.joined(separator: "\n")
    }

    static func correctionMessage(_ problems: [String]) -> String {
        "Your record changes can't be saved as written:\n" + problems.map { "- " + $0 }.joined(separator: "\n")
            + "\n\nSend the corrected cantrip-task-records blocks again, with full record IDs and only fields that "
            + "actually changed (no block if nothing changed), then one short summary line."
    }

    /// The run's summary: counts, labels and times only.
    func summary(status: String, endedAt: Date, error: String?, model: String, server: String) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: Any] = [
            "realRun": realRunID.uuidString, "task": taskID.uuidString, "title": title, "status": status,
            "model": model, "server": server, "steps": steps, "toolCalls": toolCalls, "refusedCalls": refusedCalls,
            "blocks": blockCounts, "promptTokens": promptTokens, "completionTokens": completionTokens,
            "seconds": Int(endedAt.timeIntervalSince(startedAt ?? endedAt)),
            "corrected": corrected, "validationProblems": validationProblems, "repeatedCalls": repeats,
            "tuning": ["instructions": !config.instructions.isEmpty, "temperature": config.temperature as Any,
                       "reasoningEffort": config.reasoningEffort, "recordsTool": config.recordsTool,
                       "validateRecords": config.validateRecords, "guards": config.guards,
                       "memoryTools": config.memoryTools] as [String: Any],
        ]
        result["startedAt"] = startedAt.map { ISO8601DateFormatter().string(from: $0) }
        result["error"] = error.map { String($0.prefix(300)) }
        return result
    }
}
