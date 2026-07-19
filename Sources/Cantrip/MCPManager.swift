import Foundation

/// Minimal MCP client (stdio transport, newline-delimited JSON-RPC).
/// Servers come from ~/.config/cantrip/mcp.json:
///   {"mcpServers": {"name": {"command": "npx", "args": ["-y", "..."], "env": {}}}}
/// Their tools are exposed to the local-model backend as OpenAI functions
/// named mcp__<server>__<tool>.
final class MCPManager {
    static let shared = MCPManager()
    private var connections: [String: MCPServerConnection] = [:]
    private var loaded = false
    private let lock = NSLock()
    private init() {}

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cantrip/mcp.json")
    }

    private func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = (obj["mcpServers"] ?? obj["servers"]) as? [String: [String: Any]]
        else { return }
        for (name, spec) in servers {
            guard let command = spec["command"] as? String else { continue }
            let args = spec["args"] as? [String] ?? []
            let env = spec["env"] as? [String: String] ?? [:]
            if let connection = MCPServerConnection(name: name, command: command,
                                                    args: args, extraEnv: env) {
                connections[name] = connection
                Log.write("mcp: \(name) connected with \(connection.tools.count) tools")
            } else {
                Log.write("mcp: \(name) failed to start")
            }
        }
    }

    /// Tools formatted for the OpenAI chat-completions `tools` parameter.
    func openAITools() -> [[String: Any]] {
        loadIfNeeded()
        var result: [[String: Any]] = []
        for (server, connection) in connections {
            for tool in connection.tools {
                result.append([
                    "type": "function",
                    "function": [
                        "name": "mcp__\(server)__\(tool.name)",
                        "description": String(tool.description.prefix(500)),
                        "parameters": tool.schema,
                    ],
                ])
            }
        }
        return result
    }

    func call(_ fullName: String, arguments: [String: Any]) -> (String, Bool) {
        loadIfNeeded()
        let parts = fullName.components(separatedBy: "__")
        guard parts.count >= 3, let connection = connections[parts[1]] else {
            return ("Unknown MCP tool \(fullName)", false)
        }
        let toolName = parts.dropFirst(2).joined(separator: "__")
        return connection.callTool(toolName, arguments: arguments)
    }
}

// MARK: - Connection

final class MCPServerConnection {
    struct Tool {
        let name: String
        let description: String
        let schema: [String: Any]
    }

    let name: String
    private(set) var tools: [Tool] = []
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private let stateLock = NSLock()
    private var results: [Int: [String: Any]] = [:]
    private var semaphores: [Int: DispatchSemaphore] = [:]

    init?(name: String, command: String, args: [String], extraEnv: [String: String]) {
        self.name = name
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "exec \"$0\" \"$@\"", command] + args
        var env = ProcessInfo.processInfo.environment
        extraEnv.forEach { env[$0.key] = $0.value }
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        do { try process.run() } catch { return nil }

        // Handshake.
        guard request("initialize", params: [
            "protocolVersion": "2025-03-26",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "Cantrip", "version": "1.0"],
        ], timeout: 10) != nil else {
            process.terminate()
            return nil
        }
        notify("notifications/initialized", params: [:])
        guard let listed = request("tools/list", params: [:], timeout: 10),
              let toolList = listed["tools"] as? [[String: Any]] else {
            process.terminate()
            return nil
        }
        tools = toolList.compactMap { spec in
            guard let toolName = spec["name"] as? String else { return nil }
            return Tool(name: toolName,
                        description: spec["description"] as? String ?? "",
                        schema: spec["inputSchema"] as? [String: Any]
                            ?? ["type": "object", "properties": [:] as [String: Any]])
        }
    }

    func callTool(_ toolName: String, arguments: [String: Any]) -> (String, Bool) {
        Log.write("mcp: \(name).\(toolName)")
        guard let result = request("tools/call",
                                   params: ["name": toolName, "arguments": arguments],
                                   timeout: 60) else {
            return ("MCP call timed out", false)
        }
        let isError = result["isError"] as? Bool ?? false
        var text = ""
        for item in result["content"] as? [[String: Any]] ?? [] {
            if let t = item["text"] as? String { text += t + "\n" }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "(empty result)" : String(trimmed.prefix(6000)), !isError)
    }

    // MARK: JSON-RPC plumbing

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int else { continue }
            stateLock.lock()
            results[id] = (obj["result"] as? [String: Any])
                ?? ["_error": obj["error"] ?? "unknown"]
            let semaphore = semaphores.removeValue(forKey: id)
            stateLock.unlock()
            semaphore?.signal()
        }
    }

    @discardableResult
    private func request(_ method: String, params: [String: Any],
                         timeout: TimeInterval) -> [String: Any]? {
        stateLock.lock()
        let id = nextID
        nextID += 1
        let semaphore = DispatchSemaphore(value: 0)
        semaphores[id] = semaphore
        stateLock.unlock()

        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            stateLock.lock(); semaphores[id] = nil; stateLock.unlock()
            return nil
        }
        stateLock.lock()
        let result = results.removeValue(forKey: id)
        stateLock.unlock()
        if let result, result["_error"] != nil {
            Log.write("mcp: \(name) error on \(method)")
            return nil
        }
        return result
    }

    private func notify(_ method: String, params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        stdinPipe.fileHandleForWriting.write(data)
    }
}
