import Foundation

/// Cantrip's MCP server list in each backend's own config format. Relayed servers become a
/// `cantrip-mcp NAME` command; plain local servers keep their own command. No entry carries a
/// secret: the relay adds those in the host.
enum MCPBackendConfig {
    /// `Scripts/cantrip-mcp` in the checkout Cantrip runs from.
    static var relayScript: String {
        let checkout = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let script = (checkout as NSString).appendingPathComponent("Scripts/cantrip-mcp")
        if FileManager.default.isExecutableFile(atPath: script) { return script }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Coding/Cantrip/Scripts/cantrip-mcp").path
    }

    /// Per-tab switches, `TabDefaults`-style.
    static func tabDisabledKey(_ tab: UUID) -> String { "mcpDisabledServers.\(tab.uuidString)" }

    static func tabDisabled(_ tab: UUID?, defaults: UserDefaults = .standard) -> Set<String> {
        guard let tab else { return [] }
        return Set(defaults.stringArray(forKey: tabDisabledKey(tab)) ?? [])
    }

    /// A Copilot run's disabled servers: the run's own (a scheduled task's) plus the tab's switches.
    static func disabledForRun(_ run: [String]?, tab: UUID?) -> [String]? {
        let all = Set(run ?? []).union(tabDisabled(tab))
        return all.isEmpty ? nil : all.sorted()
    }

    /// The servers a backend gets, minus `excluded` (a tab's switches or a scheduled task's limits).
    static func included(_ snapshot: MCPRegistry.Snapshot, backend: BackendKind, excluded: Set<String> = []) -> [MCPServer] {
        snapshot.servers.filter { $0.isEnabled(for: backend.rawValue) && !excluded.contains($0.name) }
    }

    /// A stdio command entry: the relay for relayed servers, the server itself otherwise.
    static func command(_ server: MCPServer, backend: BackendKind, relay: String = relayScript) -> [String: Any] {
        if server.isRelayed {
            return ["command": relay, "args": [server.name, "--backend", backend.rawValue]]
        }
        var entry: [String: Any] = ["command": server.command ?? "", "args": server.args]
        if !server.env.isEmpty { entry["env"] = server.env }
        if let cwd = server.cwd { entry["cwd"] = cwd }
        return entry
    }

    // MARK: - Claude Code (--mcp-config)

    static func claude(_ snapshot: MCPRegistry.Snapshot, excluded: Set<String> = [], relay: String = relayScript) -> [String: Any] {
        var servers: [String: Any] = [:]
        for server in included(snapshot, backend: .claudeCode, excluded: excluded) {
            var entry = command(server, backend: .claudeCode, relay: relay)
            entry["type"] = "stdio"
            servers[server.name] = entry
        }
        return ["mcpServers": servers]
    }

    /// Writes this run's Claude config (one file per tab, so tabs' switches don't collide).
    static func claudeConfigPath(tab: UUID?, excluded: Set<String>, snapshot: MCPRegistry.Snapshot) -> String? {
        let config = claude(snapshot, excluded: excluded)
        guard let servers = config["mcpServers"] as? [String: Any], !servers.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        let file = CantripPaths.cache("mcp/claude-\(tab?.uuidString ?? "shared").json")
        if (try? Data(contentsOf: file)) != data {
            do { try PrivateFile.write(data, to: file) } catch {
                Log.write("mcp: couldn't write Claude's MCP config: \(error.localizedDescription)")
                return nil
            }
        }
        return file.path
    }

    // MARK: - Copilot (~/.copilot/mcp-config.json, read by the CLI and the SDK)

    static func copilot(_ snapshot: MCPRegistry.Snapshot, relay: String = relayScript) -> [String: Any] {
        var servers: [String: Any] = [:]
        for server in included(snapshot, backend: .copilot) {
            var entry = command(server, backend: .copilot, relay: relay)
            entry["type"] = "local"
            // The relay limits tools itself; Copilot needs the field.
            entry["tools"] = server.isRelayed ? ["*"] : (server.tools ?? ["*"])
            servers[server.name] = entry
        }
        return ["mcpServers": servers]
    }

    // MARK: - Codex (-c overrides)

    static func codexArgs(_ snapshot: MCPRegistry.Snapshot, excluded: Set<String> = [], relay: String = relayScript) -> [String] {
        var args: [String] = []
        for server in included(snapshot, backend: .codex, excluded: excluded) {
            let entry = command(server, backend: .codex, relay: relay)
            let key = "mcp_servers.\(tomlKey(server.name))"
            args += ["-c", "\(key).command=\(toml(entry["command"] as? String ?? ""))"]
            let list = (entry["args"] as? [String] ?? []).map(toml).joined(separator: ",")
            args += ["-c", "\(key).args=[\(list)]"]
            if let env = entry["env"] as? [String: String], !env.isEmpty {
                let table = env.sorted { $0.key < $1.key }.map { "\(tomlKey($0.key))=\(toml($0.value))" }.joined(separator: ",")
                args += ["-c", "\(key).env={\(table)}"]
            }
        }
        return args
    }

    static func toml(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func tomlKey(_ key: String) -> String {
        key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil ? key : toml(key)
    }

    // MARK: - Antigravity (~/.gemini/config/mcp_config.json; agy has no per-run option)

    static var antigravityFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config/mcp_config.json")
    }

    /// Antigravity's config with Cantrip's servers in it; servers Antigravity has that Cantrip
    /// doesn't manage stay. `managed` names what Cantrip wrote last time (to remove dropped ones).
    static func antigravity(existing: [String: Any]?, snapshot: MCPRegistry.Snapshot, managed: Set<String>,
                            relay: String = relayScript) -> (config: [String: Any], managed: Set<String>) {
        var config = existing ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        for name in managed { servers[name] = nil }
        var written = Set<String>()
        for server in included(snapshot, backend: .antigravity) {
            servers[server.name] = command(server, backend: .antigravity, relay: relay)
            written.insert(server.name)
        }
        config["mcpServers"] = servers
        return (config, written)
    }
}
