import Foundation

/// Which MCP servers and tools direct local mode offers the model, and which run without asking.
/// Tools are keyed "server/tool".
struct DirectLocalToolSettings: Codable, Equatable {
    var enabledServers: Set<String> = []
    var disabledTools: Set<String> = []
    /// Tools that run without asking first ("Run Automatically" or "Always Allow").
    var automaticTools: Set<String> = []

    static func key(_ server: String, _ tool: String) -> String { "\(server)/\(tool)" }

    func isEnabled(_ server: String) -> Bool { enabledServers.contains(server) }
    func isEnabled(_ server: String, _ tool: String) -> Bool { !disabledTools.contains(Self.key(server, tool)) }
    func isAutomatic(_ server: String, _ tool: String) -> Bool { automaticTools.contains(Self.key(server, tool)) }

    mutating func setEnabled(_ server: String, _ on: Bool) {
        if on { enabledServers.insert(server) } else { enabledServers.remove(server) }
    }

    mutating func setEnabled(_ server: String, _ tool: String, _ on: Bool) {
        if on { disabledTools.remove(Self.key(server, tool)) } else { disabledTools.insert(Self.key(server, tool)) }
    }

    mutating func setAutomatic(_ server: String, _ tool: String, _ on: Bool) {
        if on { automaticTools.insert(Self.key(server, tool)) } else { automaticTools.remove(Self.key(server, tool)) }
    }
}

/// The tool lists last loaded from each server, so the model can be offered tools without
/// starting every server first. Kept beside the conversation, never synced.
struct DirectLocalToolCatalogEntry: Codable, Equatable {
    var fingerprint: String
    var tools: [DirectLocalMCPTool]
    var loaded: Date
}

/// A tool as offered to the model in one request.
struct DirectLocalOfferedTool {
    /// The function name the model sees: the tool's own name, made safe and unique.
    let functionName: String
    let server: DirectLocalMCPServer
    let tool: DirectLocalMCPTool
    let automatic: Bool

    var label: String { "\(server.name) · \(tool.name)" }

    /// The Ollama `/api/chat` tool definition.
    var definition: [String: Any] {
        var schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) as? [String: Any] ?? [:]
        schema["$schema"] = nil
        if schema["type"] == nil { schema["type"] = "object" }
        let description = tool.description.isEmpty ? (tool.title ?? tool.name) : tool.description
        return ["type": "function", "function": [
            "name": functionName,
            "description": String(description.prefix(2_000)),
            "parameters": schema,
        ] as [String: Any]]
    }
}

enum DirectLocalTools {
    /// Rounds of tool calls in one reply before it is stopped.
    static let maxRounds = 8
    /// Tool calls the model may make at once.
    static let maxCallsPerRound = 8
    /// Turned-on tool descriptions may take at most this share of the context window.
    static let maxContextShare = 0.6

    /// Added to the system prompt when tools are offered; small models need the nudge.
    static let systemNote = "You can call the provided tools to get information from this Mac or act on it. Call one when the request needs data you don't have, use what it returns, and never make up tool results."

    /// The tools to offer: turned-on tools of turned-on servers that can run here, from their
    /// cached lists, within each config file's own `tools` allow-list.
    static func offered(servers: [DirectLocalMCPServer], catalog: [String: DirectLocalToolCatalogEntry],
                        settings: DirectLocalToolSettings) -> [DirectLocalOfferedTool] {
        var picked: [(DirectLocalMCPServer, DirectLocalMCPTool)] = []
        for server in servers where server.isAvailable && settings.isEnabled(server.name) {
            guard let entry = catalog[server.name], entry.fingerprint == server.fingerprint else { continue }
            for tool in entry.tools where server.allows(tool.name) && settings.isEnabled(server.name, tool.name) {
                picked.append((server, tool))
            }
        }
        var taken = Set<String>()
        let plain = Dictionary(grouping: picked, by: { functionName($0.1.name) }).filter { $0.value.count == 1 }
        return picked.map { server, tool in
            var name = functionName(tool.name)
            if plain[name] == nil { name = functionName("\(server.name)_\(tool.name)") }
            var unique = name
            var suffix = 2
            while taken.contains(unique) {
                unique = String(name.prefix(60)) + "_\(suffix)"
                suffix += 1
            }
            taken.insert(unique)
            return DirectLocalOfferedTool(functionName: unique, server: server, tool: tool,
                                          automatic: tool.readOnly || settings.isAutomatic(server.name, tool.name))
        }
    }

    /// Function names allow letters, digits, `_` and `-`, up to 64 characters.
    static func functionName(_ name: String) -> String {
        let safe = String(name.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" ? Character($0) : "_"
        })
        return String((safe.isEmpty ? "tool" : safe).prefix(64))
    }

    /// Characters the tool definitions add to every request.
    static func characters(_ tools: [DirectLocalOfferedTool]) -> Int {
        guard !tools.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: tools.map(\.definition)) else { return 0 }
        return data.count
    }

    /// Rough tokens (about three characters each, as the history trim assumes).
    static func tokens(characters: Int) -> Int { (characters + 2) / 3 }

    /// Tool results are cut to this many characters (about a third of the context window).
    static func resultLimit(contextWindow: Int) -> Int { min(32_000, max(2_000, contextWindow)) }

    static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[Cut to \(limit) of \(text.count) characters to fit the context window.]"
    }

    /// Arguments as compact JSON, for storage and display.
    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }
}
