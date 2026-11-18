import Foundation
import Network

/// Private Local's read-only tools: the read-only tools of Cantrip's shared MCP servers, called
/// through Cantrip's MCP relay on this Mac. Results go only to the Private Local server; service
/// servers answer from their own service, as they do for other tabs. Off unless switched on.
struct PrivateLocalToolSettings: Codable, Equatable {
    var enabled = false
    /// Servers it may use; nil means every available one.
    var servers: [String]?

    func validate() throws {
        guard (servers?.count ?? 0) <= 100,
              servers?.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) ?? true else {
            throw SessionModelSettingsError(400, "Choose at most 100 tool servers by name.")
        }
    }

    func uses(_ server: String) -> Bool { servers?.contains(server) ?? true }
}

/// One server as Private Local's settings show it: the tools it may use and those left out.
struct PrivateLocalToolServer: Codable, Equatable {
    var name: String
    /// Allowed tools (read-only).
    var tools: [String]
    /// Tools left out because they could change something, or their effect is unclear.
    var excluded: [String]
    /// Offered when the model asks for them (`search_tools`), to keep each request small.
    var onDemand: Bool
    /// About how many tokens the allowed tools' descriptions take.
    var tokens: Int
    /// Where a service server sends queries (its host); nil for servers that run on this Mac.
    var service: String?
    /// Why it can't be used now (sign-in, not answering), or why it never can.
    var problem: String?
    /// Never offered (passwords, browsers, files, builds…), whatever the settings say.
    var blocked: Bool
}

// MARK: - Relay client

/// One connection to Cantrip's MCP relay (`MCPRelay`) for one server: the relay runs the server
/// with its keychain secrets or sign-in and applies its tool limit and per-tab switches.
final class MCPRelayClient: @unchecked Sendable {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    private let connection: NWConnection
    private let hello: [String: String]
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var closed = false

    init(server: String, tab: UUID?, backend: String, path: String = MCPRelay.socketPath) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
        var hello = ["server": server, "backend": backend]
        if let tab { hello["tab"] = tab.uuidString }
        self.hello = hello
    }

    /// Every way out resumes the caller once: connected, failed, closed, timed out or cancelled.
    func open(timeout: TimeInterval = 15) async throws {
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = OnceFlag()
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        if once.take() { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        if once.take() { continuation.resume(throwing: Failure(message: "Cantrip's MCP relay isn't answering (\(error.localizedDescription)).")) }
                        self?.close()
                    case .cancelled:
                        if once.take() { continuation.resume(throwing: Failure(message: "The MCP connection closed.")) }
                    default: break
                    }
                }
                // Cancelled before it started: the handler below already ran and found nothing to stop.
                if Task.isCancelled {
                    if once.take() { continuation.resume(throwing: CancellationError()) }
                    return
                }
                connection.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if once.take() { continuation.resume(throwing: Failure(message: "Cantrip's MCP relay didn't answer in time.")) }
                }
            }
        } onCancel: {
            connection.cancel()
        }
        receive()
        write(try JSONSerialization.data(withJSONObject: hello))
        _ = try await request("initialize", [
            "protocolVersion": "2025-03-26", "capabilities": [String: Any](),
            "clientInfo": ["name": "cantrip-private-local", "version": "1"],
        ], timeout: timeout)
        write(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
    }

    func listTools(timeout: TimeInterval = 15) async throws -> [[String: Any]] {
        var tools: [[String: Any]] = []
        var cursor: String?
        repeat {
            let result = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: timeout)
            tools += result["tools"] as? [[String: Any]] ?? []
            cursor = result["nextCursor"] as? String
        } while cursor != nil && tools.count < 1_000
        return tools
    }

    /// The tool's text content, and whether the server reported an error.
    func callTool(_ name: String, arguments: [String: Any], timeout: TimeInterval = 90) async throws -> (text: String, isError: Bool) {
        let result = try await request("tools/call", ["name": name, "arguments": arguments], timeout: timeout)
        let parts = (result["content"] as? [[String: Any]] ?? []).map { part -> String in
            if let text = part["text"] as? String { return text }
            return "[\(part["type"] as? String ?? "content") left out]"
        }
        var text = parts.joined(separator: "\n")
        if text.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            text = String(decoding: data, as: UTF8.self)
        }
        return (text, result["isError"] as? Bool == true)
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = lock.withLock { () -> Int in defer { nextID += 1 }; return nextID }
        let message = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registered = lock.withLock { () -> Bool in
                    guard !closed else { return false }
                    pending[id] = { continuation.resume(with: $0) }
                    return true
                }
                guard registered else {
                    return continuation.resume(throwing: Failure(message: "The MCP connection closed."))
                }
                // Cancelled before it was registered: `onCancel` already ran and found nothing to finish.
                if Task.isCancelled { return finish(id, .failure(CancellationError())) }
                write(message)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(id, .failure(Failure(message: "The tool server didn't answer within \(Int(timeout)) seconds.")))
                }
            }
        } onCancel: { [weak self] in
            self?.finish(id, .failure(CancellationError()))
        }
    }

    func close() {
        let waiting = lock.withLock { () -> [(Result<[String: Any], Error>) -> Void] in
            guard !closed else { return [] }
            closed = true
            defer { pending = [:] }
            return Array(pending.values)
        }
        waiting.forEach { $0(.failure(Failure(message: "The MCP connection closed."))) }
        connection.cancel()
    }

    private func finish(_ id: Int, _ result: Result<[String: Any], Error>) {
        lock.withLock { pending.removeValue(forKey: id) }?(result)
    }

    private func write(_ line: Data) {
        connection.send(content: line + Data([0x0A]), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var lines: [Data] = []
            self.lock.withLock {
                if let data { self.buffer.append(data) }
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    lines.append(self.buffer.subdata(in: self.buffer.startIndex..<newline))
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                }
            }
            for line in lines {
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = (object["id"] as? NSNumber)?.intValue else { continue }
                if let error = object["error"] as? [String: Any] {
                    self.finish(id, .failure(Failure(message: error["message"] as? String ?? "The tool server reported an error.")))
                } else {
                    self.finish(id, .success(object["result"] as? [String: Any] ?? [:]))
                }
            }
            if done || error != nil { self.close() } else { self.receive() }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

// MARK: - Catalog

final class PrivateLocalTools: @unchecked Sendable {
    static let shared = PrivateLocalTools()

    /// Servers never offered: passwords, browser control, files and forms, builds, runtime capture.
    static let blockedServers: Set<String> = ["bitwarden", "agent_chrome", "forms", "xcode", "rea"]
    static let blockedWords = ["password", "keychain", "vault", "1password", "chrome", "browser", "playwright",
                               "puppeteer", "shell", "terminal", "filesystem", "computer"]
    /// A tool whose name has one of these words can change something, run something or cost
    /// something; it's left out whatever the server says.
    static let writeWords: Set<String> = [
        "create", "update", "delete", "remove", "set", "send", "edit", "write", "post", "put", "patch", "move",
        "rename", "unlock", "lock", "generate", "sync", "upload", "fill", "approve", "archive", "publish",
        "execute", "exec", "call", "toggle", "turn", "add", "mark", "reply", "trash", "save", "submit", "cancel",
        "run", "install", "uninstall", "restore", "revert", "undo", "mutate", "unpublish", "expire", "link",
        "unlink", "invite", "assign", "apply", "deploy", "trigger", "start", "stop", "test", "validate",
        "prepare", "render", "analyze", "push", "pull", "click", "type", "press", "navigate", "open", "close",
        "upsert", "insert", "import", "export", "book", "purchase", "buy", "pay", "transfer", "merge", "fork",
        "comment", "react", "like", "follow", "subscribe", "unsubscribe", "enable", "disable", "reset", "clear",
        "kill", "launch", "build", "switch", "invoke", "schedule", "notify", "share", "grant", "revoke", "rotate",
    ]
    /// A tool may be offered when its name says it reads.
    static let readWords: Set<String> = [
        "search", "get", "list", "read", "find", "status", "lookup", "query", "retrieve", "fetch", "view", "show",
        "describe", "count", "history", "whoami", "info", "details",
    ]
    static let resultCharacters = 16_000
    static let maxSteps = 25
    /// Servers whose tools together fit in about this many tokens are offered up front. Loading a server
    /// on demand costs a whole extra model step (search_tools, then the call), more than its schemas.
    /// Sized so personal (~3K) and homelab (~2.5K) stay direct beside a small service server.
    static let directServerTokens = 3_500
    static let directTotalTokens = 8_000

    struct Tool {
        let server: String
        let name: String
        let description: String
        let schema: [String: Any]
        var outputSchema: [String: Any]? = nil
        var functionName: String { "mcp__\(server)__\(name)" }
        var tokens: Int { HomeLocalProfile.estimate(String(decoding: (try? JSONSerialization.data(withJSONObject: openAI)) ?? Data(), as: UTF8.self)) }
        var openAI: [String: Any] {
            ["type": "function", "function": [
                "name": functionName, "description": String(description.prefix(500)), "parameters": schema,
            ] as [String: Any]]
        }
    }

    struct Server {
        var name: String
        var service: String?
        var tools: [Tool] = []
        var excluded: [String] = []
        var problem: String?
        var blocked = false
        var tokens: Int { tools.reduce(0) { $0 + $1.tokens } }
    }

    /// Tests replace these.
    var registry: () -> [MCPServer] = { MCPRegistry.load()?.servers ?? [] }
    var socketPath: () -> String = { MCPRelay.socketPath }
    var cacheLifetime: TimeInterval = 10 * 60
    /// How long a server may take to connect and to list its tools.
    var listTimeout: TimeInterval = 15

    private let lock = NSLock()
    private var cached: (at: Date, key: String, servers: [Server])?
    /// The listing in progress: callers that arrive meanwhile wait for it instead of opening
    /// their own connection to every server.
    private var building: (key: String, task: Task<[Server], Never>)?

    static func isBlocked(server: String) -> Bool {
        let name = server.lowercased()
        return blockedServers.contains(name) || blockedWords.contains { name.contains($0) }
    }

    static func words(_ name: String) -> Set<String> {
        let spaced = name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression)
        return Set(spaced.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// Read-only: no write word in the name, not marked as changing anything, and either a read
    /// word in the name or a server that declares every one of its tools read-only.
    static func isReadOnly(_ tool: [String: Any], serverDeclaresReadOnly: Bool) -> Bool {
        guard let name = tool["name"] as? String, !name.isEmpty,
              name.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil else { return false }
        let annotations = tool["annotations"] as? [String: Any] ?? [:]
        let words = words(name)
        guard words.isDisjoint(with: writeWords), annotations["readOnlyHint"] as? Bool != false,
              annotations["destructiveHint"] as? Bool != true else { return false }
        return !words.isDisjoint(with: readWords)
            || (serverDeclaresReadOnly && annotations["readOnlyHint"] as? Bool == true)
    }

    static func split(server: String, tools: [[String: Any]]) -> (allowed: [Tool], excluded: [String]) {
        let declares = !tools.isEmpty && tools.allSatisfy { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true }
        var allowed: [Tool] = [], excluded: [String] = []
        for tool in tools {
            let name = tool["name"] as? String ?? ""
            if isReadOnly(tool, serverDeclaresReadOnly: declares) {
                allowed.append(Tool(server: server, name: name, description: tool["description"] as? String ?? "",
                                    schema: tool["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()],
                                    outputSchema: tool["outputSchema"] as? [String: Any]))
            } else if !name.isEmpty {
                excluded.append(name)
            }
        }
        return (allowed, excluded)
    }

    /// Every enabled server and its read-only tools, listed through the relay (cached). Callers
    /// that arrive while a listing runs share it, `refresh` included.
    func catalog(refresh: Bool = false) async -> [Server] {
        let servers = registry().filter(\.enabled)
        let key = servers.map { "\($0.name)|\($0.url ?? $0.command ?? "")|\($0.tools ?? [])" }.joined(separator: ";")
        let path = socketPath(), timeout = listTimeout, lifetime = cacheLifetime
        enum Lookup { case cached([Server]), listing(Task<[Server], Never>) }
        let lookup = lock.withLock { () -> Lookup in
            if !refresh, let cached, cached.key == key, Date().timeIntervalSince(cached.at) < lifetime {
                return .cached(cached.servers)
            }
            if let building, building.key == key { return .listing(building.task) }
            let task = Task { await Self.list(servers, path: path, timeout: timeout) }
            building = (key, task)
            return .listing(task)
        }
        switch lookup {
        case .cached(let servers):
            return servers
        case .listing(let task):
            let listed = await task.value
            lock.withLock {
                guard building?.task == task else { return }
                building = nil
                cached = (Date(), key, listed)
            }
            return listed
        }
    }

    /// One connection per server, all at once.
    private static func list(_ servers: [MCPServer], path: String, timeout: TimeInterval) async -> [Server] {
        await withTaskGroup(of: (Int, Server).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    var entry = Server(name: server.name, service: server.url.flatMap { URL(string: $0)?.host })
                    if Self.isBlocked(server: server.name) {
                        entry.blocked = true
                        entry.problem = "Never available in Private Local (it can sign in, browse, edit files or run things)."
                        return (index, entry)
                    }
                    let client = MCPRelayClient(server: server.name, tab: ChatSession.privateLocalID,
                                                backend: "Private Local", path: path)
                    defer { client.close() }
                    do {
                        try await client.open(timeout: timeout)
                        let (allowed, excluded) = Self.split(server: server.name, tools: try await client.listTools(timeout: timeout))
                        entry.tools = allowed
                        entry.excluded = excluded
                    } catch {
                        entry.problem = error.localizedDescription
                    }
                    return (index, entry)
                }
            }
            var result: [(Int, Server)] = []
            for await item in group { result.append(item) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Which servers' tools go in every request; the rest load on demand.
    static func directServers(_ servers: [Server]) -> Set<String> {
        var total = 0, direct = Set<String>()
        for server in servers.filter({ !$0.tools.isEmpty }).sorted(by: { ($0.tokens, $0.name) < ($1.tokens, $1.name) }) {
            guard server.tokens <= directServerTokens, total + server.tokens <= directTotalTokens else { continue }
            total += server.tokens
            direct.insert(server.name)
        }
        return direct
    }

    func summary(_ servers: [Server]) -> [PrivateLocalToolServer] {
        let direct = Self.directServers(servers)
        return servers.map {
            PrivateLocalToolServer(name: $0.name, tools: $0.tools.map(\.name), excluded: $0.excluded,
                                   onDemand: !$0.tools.isEmpty && !direct.contains($0.name), tokens: $0.tokens,
                                   service: $0.service, problem: $0.problem, blocked: $0.blocked)
        }
    }

    func session(_ settings: PrivateLocalToolSettings) async -> PrivateLocalToolSession {
        let servers = await catalog().filter { !$0.blocked && $0.problem == nil && settings.uses($0.name) }
        return PrivateLocalToolSession(servers: servers, direct: Self.directServers(servers), socketPath: socketPath())
    }
}

// MARK: - One reply's tools

/// The tools one Private Local reply may use, and the connections it opened.
final class PrivateLocalToolSession: @unchecked Sendable {
    static let searchName = "search_tools"

    let servers: [PrivateLocalTools.Server]
    private let direct: Set<String>
    private let socketPath: String
    private let lock = NSLock()
    private var loaded: [String: PrivateLocalTools.Tool] = [:]
    private var clients: [String: MCPRelayClient] = [:]
    /// Calls by tool name, refused calls by tool name.
    private(set) var calls: [String: Int] = [:]
    private(set) var refused: [String: Int] = [:]

    /// Code mode for this reply (`CodeMode.isEnabled` when the session opened); tests set it.
    var codeMode: Bool
    var recipes: [CodeModeRecipe] = CodeModeRecipes.all()
    var shapes: CodeModeShapes = .shared
    /// Programs run and the calls they made, for the run's counts.
    private(set) var programs = 0
    private(set) var programCalls = 0

    init(servers: [PrivateLocalTools.Server], direct: Set<String>, socketPath: String, codeMode: Bool = CodeMode.isEnabled) {
        self.servers = servers
        self.direct = direct
        self.socketPath = socketPath
        self.codeMode = codeMode
    }

    private var codeModeTools: [CodeModeTool] { servers.flatMap(\.tools).map(CodeModeTool.init) }
    private var codeModeLimits: CodeMode.Limits {
        var limits = CodeMode.Limits()
        limits.outputCharacters = PrivateLocalTools.resultCharacters
        return limits
    }

    var isEmpty: Bool { servers.allSatisfy { $0.tools.isEmpty } }
    private var onDemand: [PrivateLocalTools.Tool] { servers.filter { !direct.contains($0.name) }.flatMap(\.tools) }

    /// The tools to offer this step: the always-offered servers', any loaded on demand, and the search.
    func openAITools() -> [[String: Any]] {
        let always = servers.filter { direct.contains($0.name) }.flatMap(\.tools)
        let extra = lock.withLock { loaded.values.sorted { $0.functionName < $1.functionName } }
        var tools = (always + extra).map(\.openAI)
        if !onDemand.isEmpty {
            tools.append(["type": "function", "function": [
                "name": Self.searchName,
                "description": "Load more read-only tools from the servers listed in your instructions, by tool name or topic (for example \"sentry issues\" or \"notion search\"). Returns up to 8 tools you can call right after.",
                "parameters": ["type": "object", "properties": [
                    "query": ["type": "string", "description": "Tool names or a topic"],
                ], "required": ["query"]],
            ] as [String: Any]])
        }
        if codeMode, !isEmpty {
            let tools2 = codeModeTools, recipes = recipes.filter { $0.available(with: tools2) }
            let description = CodeModeAPI.runDescription(tools2, recipes: recipes, shapes: shapes, limits: codeModeLimits,
                                                         inlineLimit: 9_000)
            tools.append(["type": "function", "function": [
                "name": CodeMode.runTool, "description": description, "parameters": CodeModeAPI.runInputSchema,
            ] as [String: Any]])
            if description.contains(CodeMode.apiTool) {
                tools.append(["type": "function", "function": [
                    "name": CodeMode.apiTool, "description": "TypeScript declarations of the tools and recipes run_tool_script's programs can use, for the servers named.",
                    "parameters": CodeModeAPI.apiInputSchema,
                ] as [String: Any]])
            }
        }
        return tools
    }

    /// What the model is told about its tools (added to the system prompt).
    func instructions(now: Date = Date(), zone: TimeZone = .current) -> String {
        // Short on purpose: tool names that differ from the attached functions, or notes about earlier
        // no-tools replies, made the model skip tools more often (Studio Qwen, 2026-11-17).
        var text = """
        Tools: you can look things up with read-only tools (attached to this request as functions). They only \
        read: you can't send, create, change, delete, buy or run anything. If asked to, say that Private Local \
        can only read and suggest asking in another Cantrip tab. Use a tool when the answer depends on the \
        user's data or a service; quote what you found briefly, without inventing details. Data changes: look \
        it up again for each new question, even if this conversation already answered something similar.
        """
        let always = servers.filter { direct.contains($0.name) && !$0.tools.isEmpty }
        if !always.isEmpty {
            text += "\n\nServers attached now: " + always.map { "\($0.name) (\($0.tools.count) tools)" }.joined(separator: ", ") + "."
        }
        let groups = servers.filter { !direct.contains($0.name) && !$0.tools.isEmpty }
        if !groups.isEmpty {
            text += "\n\nMore read-only tools load on demand with \(Self.searchName) (by name or topic):\n"
                + groups.map { "- \($0.name): " + $0.tools.map(\.name).joined(separator: ", ") }.joined(separator: "\n")
        }
        // The date only, so the prompt (and the server's cache of it) changes once a day. Without
        // it the model guessed dates for "today" (2026-11-17: a July date).
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = zone
        day.dateFormat = "EEEE, MMMM d, yyyy"
        return text + "\n\nToday is \(day.string(from: now)) (time zone \(zone.identifier))."
    }

    func search(_ query: String) -> String {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let scored = onDemand.map { tool -> (PrivateLocalTools.Tool, Int) in
            let name = tool.name.lowercased(), full = "\(tool.server)__\(tool.name)".lowercased()
            let description = tool.description.lowercased()
            var score = query.lowercased().contains(full) || query.lowercased().contains(name) ? 100 : 0
            for word in words {
                if tool.server.lowercased() == word { score += 5 }
                if PrivateLocalTools.words(tool.name).contains(word) { score += 3 }
                if description.contains(word) { score += 1 }
            }
            return (tool, score)
        }.filter { $0.1 > 0 }.sorted { ($0.1, $1.0.functionName) > ($1.1, $0.0.functionName) }.prefix(8).map(\.0)
        guard !scored.isEmpty else {
            return "No read-only tool matches \"\(query)\". The servers and their tools are listed in your instructions."
        }
        lock.withLock { for tool in scored { loaded[tool.functionName] = tool } }
        return "Loaded these tools; call them directly:\n"
            + scored.map { "- \($0.functionName): \($0.description.prefix(160))" }.joined(separator: "\n")
    }

    /// Runs an offered tool. `allowed` is false when it was refused (not offered, or not read-only).
    func call(_ functionName: String, arguments: [String: Any]) async -> (output: String, success: Bool, allowed: Bool) {
        if functionName == Self.searchName {
            return (search(arguments["query"] as? String ?? ""), true, true)
        }
        if codeMode, functionName == CodeMode.runTool || functionName == CodeMode.apiTool {
            return await codeModeCall(functionName, arguments: arguments)
        }
        let tool = lock.withLock { () -> PrivateLocalTools.Tool? in
            if let loaded = loaded[functionName] { return loaded }
            return servers.filter { direct.contains($0.name) }.flatMap(\.tools).first { $0.functionName == functionName }
        } ?? onDemand.first { $0.functionName == functionName }
        guard let tool else {
            lock.withLock { refused[functionName, default: 0] += 1 }
            return ("Refused: \(functionName) isn't available. Private Local can only use read-only tools (search, read, list, status); nothing was sent, created, changed or deleted.", false, false)
        }
        lock.withLock { calls[functionName, default: 0] += 1 }
        do {
            let client = try await connection(tool.server)
            let (text, isError) = try await client.callTool(tool.name, arguments: arguments)
            return (text.isEmpty ? "(no output)" : text, !isError, true)
        } catch is CancellationError {
            return ("Stopped.", false, true)
        } catch {
            lock.withLock { clients[tool.server]?.close(); clients[tool.server] = nil }
            return ("The \(tool.server) tool server failed: \(error.localizedDescription)", false, true)
        }
    }

    /// A program's calls are this session's own calls: the same read-only tools and refusals.
    private func codeModeCall(_ name: String, arguments: [String: Any]) async -> (output: String, success: Bool, allowed: Bool) {
        let tools = codeModeTools, recipes = recipes.filter { $0.available(with: tools) }
        if name == CodeMode.apiTool {
            let wanted = Set((arguments["servers"] as? [String] ?? []).map { $0.lowercased() })
            let chosen = wanted.isEmpty ? tools : tools.filter { wanted.contains($0.server.lowercased()) }
            return (CodeModeAPI.declarations(chosen, recipes: recipes, shapes: shapes), true, true)
        }
        guard let script = arguments["script"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("run_tool_script needs a `script`: the body of an async function that returns the result.", false, true)
        }
        let limits = codeModeLimits
        let program = lock.withLock { programs + 1 }
        guard program <= limits.programsPerTask else { return (CodeMode.budgetRefusal(limits), false, true) }
        let runner = CodeModeRunner(tools: tools, recipes: recipes, limits: limits, shapes: shapes) { [weak self] tool, arguments in
            guard let self else { return .refused("Stopped.") }
            let result = await self.call(PrivateLocalTools.Tool(server: tool.server, name: tool.name, description: "", schema: [:]).functionName,
                                         arguments: arguments)
            return result.allowed ? .output(result.output, isError: !result.success) : .refused(result.output)
        }
        let result = await runner.run(script, arguments: arguments["args"] as? [String: Any] ?? [:])
        lock.withLock {
            programs += 1
            programCalls += result.toolCalls
        }
        Log.write("code mode: Private Local ran a program: \(result.toolCalls) calls, \(result.refused) refused, "
                  + String(format: "%.1f s", result.seconds) + (result.error == nil ? "" : ", ended with an error"))
        return (result.reply + CodeMode.budgetNote(program: program, limits: limits), result.error == nil, true)
    }

    private func connection(_ server: String) async throws -> MCPRelayClient {
        if let client = lock.withLock({ clients[server] }) { return client }
        let client = MCPRelayClient(server: server, tab: ChatSession.privateLocalID, backend: "Private Local", path: socketPath)
        try await client.open()
        lock.withLock { clients[server] = client }
        return client
    }

    func close() {
        let open = lock.withLock { () -> [MCPRelayClient] in defer { clients = [:] }; return Array(clients.values) }
        open.forEach { $0.close() }
    }
}
