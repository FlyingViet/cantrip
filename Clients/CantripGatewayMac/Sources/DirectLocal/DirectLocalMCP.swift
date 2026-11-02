import CryptoKit
import Darwin
import Foundation

// MARK: - Configured servers

/// An MCP server set up for the coding agents on this Mac. Direct local mode reads the same files
/// (Copilot CLI's ~/.copilot/mcp-config.json, then Claude Code's ~/.claude.json) and can start the
/// ones that run on this Mac (stdio) to offer their tools to the local model.
struct DirectLocalMCPServer: Equatable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    /// The config file it came from, e.g. "~/.copilot/mcp-config.json".
    let source: String
    var command = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var cwd: String?
    /// A remote server's address (shown, never used).
    var url: String?
    /// The tools the config file allows (its `tools` list); nil allows all ("*").
    var allowedTools: Set<String>?
    /// Why direct local mode can't start it (remote servers, no command); nil when it can.
    var unavailableReason: String?

    var isAvailable: Bool { unavailableReason == nil }

    func allows(_ tool: String) -> Bool { allowedTools?.contains(tool) ?? true }

    /// Changes whenever the way it starts changes, so a cached tool list is reloaded. Hashed
    /// because `env` can hold secrets.
    var fingerprint: String {
        let parts = [command] + args + [cwd ?? ""] + env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// "npx -y macos-mail-mcp@1.2.0" for labels (never the environment); a remote server's address.
    var commandSummary: String {
        guard !command.isEmpty else { return url ?? "" }
        return ([(command as NSString).lastPathComponent] + args).joined(separator: " ")
    }

    /// "npx -y macos-mail-mcp@1.2.0 · ~/.copilot/mcp-config.json"
    var detail: String {
        [commandSummary, source].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum DirectLocalMCPConfig {
    static var standardFiles: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".copilot/mcp-config.json"), home.appendingPathComponent(".claude.json")]
    }

    /// Every server in `files`; the first file wins when two use the same name.
    static func load(from files: [URL] = standardFiles) -> [DirectLocalMCPServer] {
        var servers: [String: DirectLocalMCPServer] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for server in parse(data, source: displayPath(file)) where servers[server.name] == nil {
                servers[server.name] = server
            }
        }
        return servers.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parse(_ data: Data, source: String) -> [DirectLocalMCPServer] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["mcpServers"] as? [String: Any] else { return [] }
        return entries.compactMap { name, value -> DirectLocalMCPServer? in
            guard let entry = value as? [String: Any], !name.isEmpty else { return nil }
            var server = DirectLocalMCPServer(name: name, source: source)
            let type = (entry["type"] as? String)?.lowercased() ?? (entry["url"] != nil ? "http" : "stdio")
            server.command = ((entry["command"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            server.args = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            server.env = (entry["env"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
            server.cwd = (entry["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            server.url = (entry["url"] as? String).flatMap { URLComponents(string: $0)?.host }
            if let tools = entry["tools"] as? [Any] {
                let names = tools.compactMap { $0 as? String }
                server.allowedTools = names.contains("*") ? nil : Set(names)
            }
            if !["stdio", "local"].contains(type) {
                server.unavailableReason = "A remote server (\(type)). Direct local mode only starts servers that run on this Mac."
            } else if server.command.isEmpty {
                server.unavailableReason = "\(source) has no command to start it."
            } else if entry["disabled"] as? Bool == true {
                server.unavailableReason = "Turned off in \(source)."
            }
            return server
        }
    }

    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

// MARK: - Tools

/// One tool an MCP server offers, as listed by `tools/list`.
struct DirectLocalMCPTool: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    var title: String?
    var description: String
    /// The tool's input JSON Schema, as the server sent it.
    var inputSchema: String
    /// The server marked it read-only (MCP `readOnlyHint`).
    var readOnly = false

    init(name: String, title: String? = nil, description: String, inputSchema: String = #"{"type":"object"}"#,
         readOnly: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
    }

    init?(listed object: [String: Any]) {
        guard let name = object["name"] as? String, !name.isEmpty else { return nil }
        let annotations = object["annotations"] as? [String: Any]
        let schema = object["inputSchema"] as? [String: Any] ?? ["type": "object"]
        self.name = name
        title = (object["title"] as? String) ?? (annotations?["title"] as? String)
        description = (object["description"] as? String) ?? ""
        inputSchema = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"type":"object"}"#
        readOnly = annotations?["readOnlyHint"] as? Bool == true
    }
}

/// What a tool call returned, as text for the model.
struct DirectLocalToolOutput: Equatable, Sendable {
    var text: String
    var isError = false

    /// Text, embedded text resources and structured content; media is described, not sent,
    /// because the local chat API only carries text.
    init(result: [String: Any]) {
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { parts.append(text) }
            case "image", "audio":
                parts.append("[\(item["type"] as? String ?? "media") (\(item["mimeType"] as? String ?? "unknown type")) not shown: the local model only reads text.]")
            case "resource":
                let resource = item["resource"] as? [String: Any]
                if let text = resource?["text"] as? String {
                    parts.append(text)
                } else {
                    parts.append("[Resource \(resource?["uri"] as? String ?? "") not shown: it isn't text.]")
                }
            case "resource_link":
                parts.append("[Link: \(item["name"] as? String ?? "") \(item["uri"] as? String ?? "")]")
            default:
                break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys, .withoutEscapingSlashes]) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        text = parts.isEmpty ? "(The tool returned nothing.)" : parts.joined(separator: "\n")
        isError = result["isError"] as? Bool == true
    }

    init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

// MARK: - Starting servers

/// The PATH a login shell gets, so commands like `npx` resolve as they do in Terminal. Apps opened
/// from the Finder only get /usr/bin:/bin:/usr/sbin:/sbin.
enum DirectLocalLoginPath {
    static let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    /// Read once (at most about 5 seconds), on first use.
    private static let resolved: String = readFromLoginShell() ?? fallback

    static func value() -> String { resolved }

    private static func readFromLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: userShell)
        // The marker skips anything a profile prints.
        process.arguments = ["-l", "-c", "printf '\\n__CANTRIP_PATH__%s\\n' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        // Read what's there without waiting for end of file: a background job the profile
        // started can hold the pipe open long after the shell exits.
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while data.count < 1_000_000 {
            let count = read(descriptor, &chunk, chunk.count)
            if count <= 0 { break }
            data.append(chunk, count: count)
        }
        try? output.fileHandleForReading.close()
        let text = String(decoding: data, as: UTF8.self)
        guard let marker = text.range(of: "__CANTRIP_PATH__", options: .backwards),
              let path = text[marker.upperBound...].split(separator: "\n").first, !path.isEmpty else { return nil }
        return String(path)
    }

    private static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// `command` as given when it has a slash (relative to `directory`), else the first match on `path`.
    static func resolve(_ command: String, path: String, directory: URL) -> URL? {
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for folder in path.split(separator: ":") where !folder.isEmpty {
            let candidate = URL(fileURLWithPath: String(folder)).appendingPathComponent(expanded)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// One running MCP server: newline-delimited JSON-RPC over the process's stdin and stdout.
final class DirectLocalMCPConnection: @unchecked Sendable {
    static let protocolVersion = "2025-06-18"

    let server: DirectLocalMCPServer
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var errorTail = ""
    private var closed = false

    private static let registryLock = NSLock()
    private static var live: [ObjectIdentifier: DirectLocalMCPConnection] = [:]

    init(server: DirectLocalMCPServer) {
        self.server = server
    }

    var isRunning: Bool { lock.withLock { !closed } && process.isRunning }

    func start() throws {
        let path = server.env["PATH"] ?? DirectLocalLoginPath.value()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = server.cwd.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: home) } ?? home
        guard let executable = DirectLocalLoginPath.resolve(server.command, path: path, directory: directory) else {
            throw DirectLocalError("Couldn't find “\(server.command)” to start \(server.name). Check its command in \(server.source).")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment.merge(server.env) { _, configured in configured }
        process.executableURL = executable
        process.arguments = server.args
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A server that quits mid-write must not take this app down with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { self?.appendError(data) }
        }
        process.terminationHandler = { [weak self] process in
            // Let its last words on stderr arrive first; they explain the exit.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                self?.terminated(status: process.terminationStatus)
            }
        }
        do {
            try process.run()
        } catch {
            throw DirectLocalError("Couldn't start \(server.name): \(error.localizedDescription)")
        }
        Self.registryLock.withLock { Self.live[ObjectIdentifier(self)] = self }
    }

    /// The MCP handshake. Generous timeout: `npx` may download the server on first use.
    func initialize(timeout: TimeInterval = 120) async throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let result = try await request("initialize", [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "cantrip-gateway-mac", "title": "Cantrip Gateway Mac", "version": version],
        ], timeout: timeout)
        guard result["protocolVersion"] is String else {
            throw DirectLocalError("\(server.name) didn't answer the MCP handshake.")
        }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func listTools(timeout: TimeInterval = 60) async throws -> [DirectLocalMCPTool] {
        var tools: [DirectLocalMCPTool] = []
        var cursor: String?
        for _ in 0..<20 {
            let result = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: timeout)
            tools += (result["tools"] as? [[String: Any]] ?? []).compactMap(DirectLocalMCPTool.init(listed:))
            cursor = result["nextCursor"] as? String
            if cursor?.isEmpty ?? true { break }
        }
        return tools
    }

    func callTool(_ name: String, arguments: [String: Any], timeout: TimeInterval = 300) async throws -> DirectLocalToolOutput {
        DirectLocalToolOutput(result: try await request("tools/call", ["name": name, "arguments": arguments], timeout: timeout))
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id: Int = lock.withLock {
            nextID += 1
            return nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                let accepted: Bool = lock.withLock {
                    guard !closed else { return false }
                    pending[id] = continuation
                    return true
                }
                guard accepted else {
                    continuation.resume(throwing: stoppedError())
                    return
                }
                if Task.isCancelled { fail(id, CancellationError()); return }
                do {
                    try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
                } catch {
                    fail(id, error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self, server] in
                    self?.fail(id, DirectLocalError("\(server.name) didn't answer \(method) within \(Int(timeout)) seconds."))
                }
            }
        } onCancel: {
            if fail(id, CancellationError()) {
                try? send(["jsonrpc": "2.0", "method": "notifications/cancelled",
                           "params": ["requestId": id, "reason": "Stopped by the user."]])
            }
        }
    }

    /// Ends the server the way MCP asks: close its input, then SIGTERM, then SIGKILL.
    func close(grace: TimeInterval = 2) {
        let waiting: [CheckedContinuation<[String: Any], Error>] = lock.withLock {
            closed = true
            defer { pending = [:] }
            return Array(pending.values)
        }
        waiting.forEach { $0.resume(throwing: stoppedError()) }
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    /// The app is quitting: every running server gets its input closed and a SIGTERM now.
    static func terminateAll() {
        let connections = registryLock.withLock { Array(live.values) }
        for connection in connections {
            connection.close(grace: 0.2)
            if connection.process.isRunning { connection.process.terminate() }
        }
    }

    // MARK: Plumbing

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        try writeLock.withLock {
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                throw stoppedError()
            }
        }
    }

    private func receive(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        for line in lines { handle(line) }
    }

    private func handle(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let method = message["method"] as? String {
            // Requests from the server. This client offers no capabilities, so only ping is answered.
            guard let id = message["id"] else { return }
            let reply: [String: Any] = method == "ping"
                ? ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
            try? send(reply)
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue ?? (message["id"] as? String).flatMap(Int.init) else { return }
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        if let error = message["error"] as? [String: Any] {
            let text = (error["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "an error"
            continuation?.resume(throwing: DirectLocalError("\(server.name) returned an error: \(text.prefix(600))"))
        } else {
            continuation?.resume(returning: message["result"] as? [String: Any] ?? [:])
        }
    }

    @discardableResult
    private func fail(_ id: Int, _ error: Error) -> Bool {
        guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return false }
        continuation.resume(throwing: error)
        return true
    }

    private func appendError(_ data: Data) {
        lock.withLock {
            errorTail = String((errorTail + String(decoding: data, as: UTF8.self)).suffix(1_500))
        }
    }

    private func terminated(status: Int32) {
        let waiting: [CheckedContinuation<[String: Any], Error>] = lock.withLock {
            closed = true
            defer { pending = [:] }
            return Array(pending.values)
        }
        let error = DirectLocalError("\(server.name) stopped (exit status \(status)).\(stderrSummary)")
        waiting.forEach { $0.resume(throwing: error) }
        _ = Self.registryLock.withLock { Self.live.removeValue(forKey: ObjectIdentifier(self)) }
    }

    private var stderrSummary: String {
        let tail = lock.withLock { errorTail }.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? "" : " It said: \(tail.suffix(400))"
    }

    private func stoppedError() -> DirectLocalError {
        DirectLocalError("\(server.name) isn't running.\(stderrSummary)")
    }
}

// MARK: - Running tools

/// Lists and calls MCP tools. The app uses `DirectLocalMCPHub.shared`; tests substitute a fake.
protocol DirectLocalToolRunning: AnyObject, Sendable {
    func tools(for server: DirectLocalMCPServer) async throws -> [DirectLocalMCPTool]
    func call(_ tool: String, arguments: [String: Any], on server: DirectLocalMCPServer) async throws -> DirectLocalToolOutput
}

/// Starts servers when their tools are first needed and stops them after `idleTimeout`, so an
/// idle Mac isn't holding a node process per server.
actor DirectLocalMCPHub: DirectLocalToolRunning {
    static let shared = DirectLocalMCPHub()

    private struct Running {
        let fingerprint: String
        let connection: DirectLocalMCPConnection
        var lastUsed = Date()
        var busy = 0
    }

    private let idleTimeout: TimeInterval
    private var running: [String: Running] = [:]
    private var starting: [String: Task<DirectLocalMCPConnection, Error>] = [:]
    private var reaper: Task<Void, Never>?

    init(idleTimeout: TimeInterval = 300) {
        self.idleTimeout = idleTimeout
    }

    func tools(for server: DirectLocalMCPServer) async throws -> [DirectLocalMCPTool] {
        let connection = try await use(server)
        defer { release(server.name) }
        return try await connection.listTools()
    }

    func call(_ tool: String, arguments: [String: Any], on server: DirectLocalMCPServer) async throws -> DirectLocalToolOutput {
        let connection = try await use(server)
        defer { release(server.name) }
        return try await connection.callTool(tool, arguments: arguments)
    }

    var runningServers: [String] { running.keys.sorted() }

    func stopAll() {
        running.values.forEach { $0.connection.close() }
        running = [:]
        reaper?.cancel()
        reaper = nil
    }

    private func use(_ server: DirectLocalMCPServer) async throws -> DirectLocalMCPConnection {
        guard server.isAvailable else { throw DirectLocalError(server.unavailableReason ?? "\(server.name) can't be used here.") }
        if var current = running[server.name] {
            if current.fingerprint == server.fingerprint, current.connection.isRunning {
                current.busy += 1
                current.lastUsed = Date()
                running[server.name] = current
                return current.connection
            }
            current.connection.close()
            running[server.name] = nil
        }
        let task = starting[server.name] ?? start(server)
        starting[server.name] = task
        // Stop must not wait for a slow start; the start carries on and registers itself.
        let connection = try await Self.cancellableValue(of: task)
        guard var current = running[server.name], current.connection === connection else {
            throw DirectLocalError("\(server.name) stopped while starting.")
        }
        current.busy += 1
        current.lastUsed = Date()
        running[server.name] = current
        return connection
    }

    /// Starts and initializes `server`, then registers it (idle, so the reaper can stop it even if
    /// everyone waiting has gone).
    private func start(_ server: DirectLocalMCPServer) -> Task<DirectLocalMCPConnection, Error> {
        Task.detached { [weak self] in
            do {
                let connection = DirectLocalMCPConnection(server: server)
                try connection.start()
                do {
                    try await connection.initialize()
                } catch {
                    connection.close(grace: 0.5)
                    throw error
                }
                await self?.started(server, connection)
                return connection
            } catch {
                await self?.startFailed(server.name)
                throw error
            }
        }
    }

    private func started(_ server: DirectLocalMCPServer, _ connection: DirectLocalMCPConnection) {
        starting[server.name] = nil
        if let previous = running[server.name], previous.connection !== connection { previous.connection.close() }
        running[server.name] = Running(fingerprint: server.fingerprint, connection: connection)
        scheduleReaper()
    }

    private func startFailed(_ name: String) {
        starting[name] = nil
    }

    /// `task.value`, except that cancelling the caller throws right away.
    private static func cancellableValue<T: Sendable>(of task: Task<T, Error>) async throws -> T {
        let waiter = DirectLocalWaiter<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.attach(continuation)
                Task {
                    do { waiter.finish(.success(try await task.value)) } catch { waiter.finish(.failure(error)) }
                }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    private func release(_ name: String) {
        guard var current = running[name] else { return }
        current.busy = max(0, current.busy - 1)
        current.lastUsed = Date()
        running[name] = current
    }

    private func scheduleReaper() {
        guard reaper == nil else { return }
        let interval = min(60, max(0.05, idleTimeout / 2))
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, await self.reapIdle() else { return }
            }
        }
    }

    /// Stops idle servers; returns whether any are still running.
    private func reapIdle() -> Bool {
        let now = Date()
        for (name, current) in running where current.busy == 0
            && (now.timeIntervalSince(current.lastUsed) >= idleTimeout || !current.connection.isRunning) {
            current.connection.close()
            running[name] = nil
        }
        if running.isEmpty { reaper = nil }
        return !running.isEmpty
    }
}

/// Resumes one continuation exactly once, whichever comes first: the result or a cancel (which
/// can arrive before the continuation exists).
private final class DirectLocalWaiter<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        let ready: Result<T, Error>? = lock.withLock {
            if result == nil { self.continuation = continuation }
            return result
        }
        if let ready { continuation.resume(with: ready) }
    }

    func finish(_ value: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: value)
    }
}
