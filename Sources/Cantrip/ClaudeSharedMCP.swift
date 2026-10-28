import Foundation

/// The Copilot CLI's own MCP servers (`~/.copilot/mcp-config.json`) for Claude Code tabs, so both
/// backends reach the same tools (homelab, the agent vault and so on). Only local (stdio) servers
/// are shared: remote ones sign in through Copilot's own OAuth, which a headless Claude can't repeat.
/// A server Claude Code already has under the same name keeps Claude's own definition.
enum ClaudeSharedMCP {
    static var copilotConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/mcp-config.json")
    }
    static var claudeConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }
    static var output: URL { CantripPaths.cache("claude-shared-mcp.json") }

    /// Writes the shared servers' config and returns its path, or nil when there is nothing to share.
    static func configPath(copilotConfig: URL = copilotConfig, claudeConfig: URL = claudeConfig,
                           output: URL = output, alsoDefined: Set<String> = pluginServerNames()) -> String? {
        let servers = shared(copilot: object(at: copilotConfig), claudeNames: claudeServerNames(at: claudeConfig)
                                .union(alsoDefined))
        guard !servers.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers],
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        if (try? Data(contentsOf: output)) != data {
            do { try PrivateFile.write(data, to: output) } catch {
                Log.write("claude: could not share Copilot's MCP servers: \(error.localizedDescription)")
                return nil
            }
        }
        return output.path
    }

    /// Copilot's local servers in Claude Code's format, minus the names Claude already defines.
    static func shared(copilot: [String: Any]?, claudeNames: Set<String>) -> [String: [String: Any]] {
        let servers = (copilot?["mcpServers"] ?? copilot?["servers"]) as? [String: [String: Any]] ?? [:]
        var result: [String: [String: Any]] = [:]
        for (name, spec) in servers where !claudeNames.contains(name) {
            let type = (spec["type"] as? String ?? "stdio").lowercased()
            guard ["stdio", "local"].contains(type), let command = spec["command"] as? String,
                  !command.isEmpty else { continue }
            var server: [String: Any] = ["type": "stdio", "command": command]
            if let args = spec["args"] as? [String], !args.isEmpty { server["args"] = args }
            if let env = spec["env"] as? [String: String], !env.isEmpty { server["env"] = env }
            if let cwd = spec["cwd"] as? String, !cwd.isEmpty { server["cwd"] = cwd }
            result[name] = server
        }
        return result
    }

    /// Server names in Claude Code's own user config.
    static func claudeServerNames(at url: URL) -> Set<String> {
        Set((object(at: url)?["mcpServers"] as? [String: Any] ?? [:]).keys)
    }

    /// Plugin servers Cantrip already hands Claude in its own config file.
    static func pluginServerNames() -> Set<String> {
        guard let path = PluginManager.claudeMCPConfigPath() else { return [] }
        return claudeServerNames(at: URL(fileURLWithPath: path))
    }

    private static func object(at url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
