import Foundation
import CryptoKit
import Combine

// MARK: - Manifest

/// One plugin = one folder under ~/.config/cantrip/plugins/<id>/ holding a
/// manifest.json plus whatever files the plugin needs. Two layers:
///   - `panel`: an HTML dashboard rendered in a Cantrip side pane (with a
///     small `window.cantrip` JS bridge back into the app).
///   - `mcpServers`: standard MCP servers exposed to the models — passed to
///     the Claude CLI via --mcp-config, to Codex via -c overrides, and to
///     the local-model backend through MCPManager. (Copilot manages its own
///     servers via `copilot mcp add` — see PLUGINS.md.)
struct PluginManifest: Codable {
    struct PanelSpec: Codable {
        let html: String        // entry file, relative to the plugin folder
        let title: String?      // pane header; defaults to the plugin name
    }
    struct MCPServerSpec: Codable {
        let command: String
        let args: [String]?
        let env: [String: String]?
    }
    let name: String
    let version: String?
    let description: String?
    let panel: PanelSpec?
    let mcpServers: [String: MCPServerSpec]?
}

struct Plugin: Identifiable {
    let id: String              // folder name
    let directory: URL
    let manifest: PluginManifest
    let manifestHash: String    // SHA-256 of manifest.json — approval is per-hash

    /// Resolved, validated panel entry file (must stay inside the folder;
    /// symlinks are resolved before the containment check).
    var panelURL: URL? {
        guard let panel = manifest.panel else { return nil }
        let url = directory.appendingPathComponent(panel.html)
            .standardizedFileURL.resolvingSymlinksInPath()
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(root + "/") else { return nil }
        return url
    }

    var panelTitle: String { manifest.panel?.title ?? manifest.name }

    /// Human-readable capability list, shown in the approval card.
    var capabilitySummary: [String] {
        var lines: [String] = []
        if let panel = manifest.panel {
            lines.append("UI panel: \(panel.html)")
        }
        for (name, server) in (manifest.mcpServers ?? [:]).sorted(by: { $0.key < $1.key }) {
            let cmd = ([server.command] + (server.args ?? [])).joined(separator: " ")
            lines.append("MCP server “\(name)”: \(cmd)")
        }
        return lines
    }
}

// MARK: - Manager

/// Discovers plugins, tracks enable/approval state, and regenerates the
/// merged MCP config that the model backends consume.
///
/// Trust model: approve-on-install. Enabling a plugin the first time (or
/// after its manifest changes — approval is keyed to the manifest hash)
/// requires an explicit approval showing what the plugin provides. Only
/// enabled AND approved plugins are active.
@MainActor
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    @Published private(set) var plugins: [Plugin] = []
    @Published private(set) var enabledIDs: Set<String>
    @Published private(set) var approvedHashes: [String: String]

    private let d = UserDefaults.standard
    private static let enabledKey = "enabledPlugins"
    private static let approvedKey = "approvedPluginHashes"

    nonisolated static var pluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cantrip/plugins")
    }
    /// Merged MCP servers from active plugins, in the standard
    /// {"mcpServers": {...}} shape. Claude reads it via --mcp-config;
    /// MCPManager reads it for the local-model backend. nonisolated:
    /// backends read these paths from their own queues.
    nonisolated static var mergedMCPConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cantrip/plugin-mcp.json")
    }

    private init() {
        enabledIDs = Set(d.stringArray(forKey: Self.enabledKey) ?? [])
        approvedHashes = (d.dictionary(forKey: Self.approvedKey) as? [String: String]) ?? [:]
        reload()
    }

    // MARK: Discovery

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.pluginsDirectory,
                                withIntermediateDirectories: true)
        var found: [Plugin] = []
        let dirs = (try? fm.contentsOfDirectory(at: Self.pluginsDirectory,
                                                includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL) else { continue }
            guard let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
                Log.write("plugins: \(dir.lastPathComponent) has an unreadable manifest.json")
                continue
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            found.append(Plugin(id: dir.lastPathComponent, directory: dir,
                                manifest: manifest, manifestHash: hash))
        }
        plugins = found.sorted { $0.manifest.name.lowercased() < $1.manifest.name.lowercased() }
        rewriteMergedMCPConfig()
    }

    // MARK: State

    func isEnabled(_ plugin: Plugin) -> Bool { enabledIDs.contains(plugin.id) }

    /// Approval is tied to the exact manifest content: editing the manifest
    /// (new tools, new commands) requires re-approval.
    func isApproved(_ plugin: Plugin) -> Bool {
        approvedHashes[plugin.id] == plugin.manifestHash
    }

    func isActive(_ plugin: Plugin) -> Bool { isEnabled(plugin) && isApproved(plugin) }

    var activePlugins: [Plugin] { plugins.filter { isActive($0) } }

    func setEnabled(_ plugin: Plugin, _ enabled: Bool) {
        if enabled { enabledIDs.insert(plugin.id) } else { enabledIDs.remove(plugin.id) }
        d.set(Array(enabledIDs).sorted(), forKey: Self.enabledKey)
        rewriteMergedMCPConfig()
        Log.write("plugins: \(plugin.id) \(enabled ? "enabled" : "disabled")")
    }

    func approve(_ plugin: Plugin) {
        approvedHashes[plugin.id] = plugin.manifestHash
        d.set(approvedHashes, forKey: Self.approvedKey)
        rewriteMergedMCPConfig()
        Log.write("plugins: \(plugin.id) approved (\(plugin.manifestHash.prefix(12)))")
    }

    func revokeApproval(_ plugin: Plugin) {
        approvedHashes.removeValue(forKey: plugin.id)
        d.set(approvedHashes, forKey: Self.approvedKey)
        setEnabled(plugin, false)
    }

    // MARK: MCP plumbing

    /// Active plugins' servers, keyed by a sanitized unique name. A server
    /// name already claimed by an earlier plugin gets prefixed with the
    /// plugin id so both keep working.
    private func activeMCPServers() -> [(name: String, spec: PluginManifest.MCPServerSpec)] {
        var seen = Set<String>()
        var result: [(String, PluginManifest.MCPServerSpec)] = []
        for plugin in activePlugins {
            for (rawName, spec) in (plugin.manifest.mcpServers ?? [:])
                .sorted(by: { $0.key < $1.key }) {
                var name = Self.sanitize(rawName)
                if seen.contains(name) { name = Self.sanitize("\(plugin.id)_\(rawName)") }
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                result.append((name, spec))
            }
        }
        return result
    }

    /// TOML/JSON-safe server name: letters, digits, dash, underscore.
    /// nonisolated: also used from codexMCPOverrides on backend queues.
    private nonisolated static func sanitize(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    /// Regenerate ~/.config/cantrip/plugin-mcp.json from the active set.
    /// Written eagerly on every state change so backends spawned later
    /// (they re-read at process start) always see the current truth.
    private func rewriteMergedMCPConfig() {
        let servers = activeMCPServers()
        let fm = FileManager.default
        guard !servers.isEmpty else {
            try? fm.removeItem(at: Self.mergedMCPConfigURL)
            return
        }
        var dict: [String: Any] = [:]
        for (name, spec) in servers {
            var entry: [String: Any] = ["command": spec.command]
            if let args = spec.args { entry["args"] = args }
            if let env = spec.env { entry["env"] = env }
            dict[name] = entry
        }
        let payload: [String: Any] = ["mcpServers": dict]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys, .prettyPrinted])
        else { return }
        try? data.write(to: Self.mergedMCPConfigURL, options: .atomic)
    }

    /// Path for the Claude CLI's --mcp-config, or nil when no active plugin
    /// declares servers.
    nonisolated static func claudeMCPConfigPath() -> String? {
        let path = mergedMCPConfigURL.path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Codex has no config-file flag for one-off servers; it takes dotted
    /// `-c` overrides parsed as TOML. Values are built here, not shell-
    /// quoted — they're passed as separate argv entries.
    nonisolated static func codexMCPOverrides() -> [String] {
        guard let path = claudeMCPConfigPath(),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: [String: Any]]
        else { return [] }
        var args: [String] = []
        for (name, spec) in servers.sorted(by: { $0.key < $1.key }) {
            guard let command = spec["command"] as? String else { continue }
            args += ["-c", "mcp_servers.\(name).command=\(tomlString(command))"]
            if let serverArgs = spec["args"] as? [String], !serverArgs.isEmpty {
                let list = serverArgs.map(tomlString).joined(separator: ", ")
                args += ["-c", "mcp_servers.\(name).args=[\(list)]"]
            }
            if let env = spec["env"] as? [String: String], !env.isEmpty {
                let table = env.sorted(by: { $0.key < $1.key })
                    .map { "\(sanitize($0.key)) = \(tomlString($0.value))" }
                    .joined(separator: ", ")
                args += ["-c", "mcp_servers.\(name).env={\(table)}"]
            }
        }
        return args
    }

    /// TOML basic string: escape backslashes, quotes, and control chars
    /// (a raw newline or tab inside a basic string is invalid TOML and
    /// would make codex reject the whole -c override).
    private nonisolated static func tomlString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
