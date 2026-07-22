import Foundation
import ServiceManagement

enum BackendKind: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case copilot = "Copilot"
    case codex = "Codex"
    case localModel = "Local Model"
    var id: String { rawValue }
}

/// UserDefaults-backed settings.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var backend: BackendKind {
        didSet { d.set(backend.rawValue, forKey: "backend") }
    }
    /// Path to the `claude` binary. Empty = auto-detect via login shell.
    @Published var claudePath: String {
        didSet { d.set(claudePath, forKey: "claudePath") }
    }
    /// Working directory for Claude Code runs (its tool/file context).
    @Published var claudeWorkdir: String {
        didSet { d.set(claudeWorkdir, forKey: "claudeWorkdir") }
    }
    /// Model passed to claude via --model. Empty = account default.
    /// Aliases (sonnet, opus, haiku, fable) resolve to the newest in family.
    @Published var claudeModel: String {
        didSet { d.set(claudeModel, forKey: "claudeModel") }
    }
    static let claudeModelAliases = ["sonnet", "opus", "haiku", "fable", "opusplan", "sonnet[1m]"]
    /// Reasoning effort passed as --effort. Empty = CLI default.
    @Published var claudeEffort: String {
        didSet { d.set(claudeEffort, forKey: "claudeEffort") }
    }
    static let claudeEffortLevels: [(value: String, label: String)] = [
        ("", "Default"),
        ("low", "Low — fast & cheap"),
        ("medium", "Medium"),
        ("high", "High — deeper reasoning"),
        ("max", "Max — thinks hardest (supported models)"),
    ]
    /// Claude Code --permission-mode. In headless runs nobody can approve
    /// prompts, so tools are denied unless this loosens the policy.
    @Published var claudePermissionMode: String {
        didSet { d.set(claudePermissionMode, forKey: "claudePermissionMode") }
    }
    static let claudePermissionModes: [(value: String, label: String)] = [
        ("default", "Safe — answers only, no actions"),
        ("acceptEdits", "Allow file edits"),
        ("bypassPermissions", "Allow everything (run commands, send messages…)"),
    ]
    /// Path to the `copilot` binary. Empty = auto-detect.
    @Published var copilotPath: String {
        didSet { d.set(copilotPath, forKey: "copilotPath") }
    }
    /// Optional model override passed as --model.
    @Published var copilotModel: String {
        didSet { d.set(copilotModel, forKey: "copilotModel") }
    }
    /// Pass --allow-all-tools so Copilot can run tools headlessly.
    @Published var copilotAllowTools: Bool {
        didSet { d.set(copilotAllowTools, forKey: "copilotAllowTools") }
    }
    /// Reasoning effort passed as --reasoning-effort. Empty = default.
    @Published var copilotEffort: String {
        didSet { d.set(copilotEffort, forKey: "copilotEffort") }
    }
    static let copilotEffortLevels: [(value: String, label: String)] = [
        ("", "Default"),
        ("low", "Low — fast & cheap"),
        ("medium", "Medium"),
        ("high", "High — deeper reasoning"),
        ("xhigh", "XHigh — hardest (supported models)"),
    ]
    /// Context tier passed as --context. Empty = ~/.copilot/settings.json default.
    @Published var copilotContextTier: String {
        didSet { d.set(copilotContextTier, forKey: "copilotContextTier") }
    }
    /// Ask Copilot to work inline instead of delegating to (slow,
    /// server-side) subagents.
    @Published var copilotDiscourageSubagents: Bool {
        didSet { d.set(copilotDiscourageSubagents, forKey: "copilotDiscourageSubagents") }
    }
    /// Cached model list discovered from `copilot help`.
    @Published var copilotAvailableModels: [String] {
        didSet { d.set(copilotAvailableModels, forKey: "copilotAvailableModels") }
    }
    /// Path to the `codex` binary. Empty = login-shell lookup.
    @Published var codexPath: String {
        didSet { d.set(codexPath, forKey: "codexPath") }
    }
    /// Optional model override passed as -m (e.g. gpt-5-codex).
    @Published var codexModel: String {
        didSet { d.set(codexModel, forKey: "codexModel") }
    }
    /// OpenAI-compatible base URL, e.g. http://hermes.local:8000/v1
    @Published var localBaseURL: String {
        didSet { d.set(localBaseURL, forKey: "localBaseURL") }
    }
    @Published var localModel: String {
        didSet { d.set(localModel, forKey: "localModel") }
    }
    @Published var localAPIKey: String {
        didSet { d.set(localAPIKey, forKey: "localAPIKey") }
    }
    @Published var localSystemPrompt: String {
        didSet { d.set(localSystemPrompt, forKey: "localSystemPrompt") }
    }
    /// Global autonomy switch: let any CLI backend take actions without
    /// per-tool approval (claude --permission-mode bypassPermissions,
    /// copilot --allow-all-tools). Overrides the per-backend settings.
    @Published var allowActions: Bool {
        didSet { d.set(allowActions, forKey: "allowActions") }
    }
    /// Attach the user's current location as context to every query.
    @Published var shareLocation: Bool {
        didSet { d.set(shareLocation, forKey: "shareLocation") }
    }
    /// Inject file-content excerpts (Spotlight index) matching queries.
    @Published var fileRAGEnabled: Bool {
        didSet { d.set(fileRAGEnabled, forKey: "fileRAGEnabled") }
    }
    /// Attach upcoming calendar events (via Calendar.app AppleScript).
    @Published var shareCalendar: Bool {
        didSet { d.set(shareCalendar, forKey: "shareCalendar") }
    }
    /// Attach a screenshot of the screen (taken when the panel is summoned).
    @Published var attachScreen: Bool {
        didSet { d.set(attachScreen, forKey: "attachScreen") }
    }
    /// Voice mode: speak replies aloud and auto-listen for follow-ups.
    @Published var voiceMode: Bool {
        didSet { d.set(voiceMode, forKey: "voiceMode") }
    }
    /// Whole-panel opacity (0.5–1.0).
    @Published var panelOpacity: Double {
        didSet { d.set(panelOpacity, forKey: "panelOpacity") }
    }
    /// Memory vault: folder of markdown notes backends read & maintain.
    @Published var memoryEnabled: Bool {
        didSet { d.set(memoryEnabled, forKey: "memoryEnabled") }
    }
    @Published var memoryPath: String {
        didSet { d.set(memoryPath, forKey: "memoryPath") }
    }

    /// Default model from ~/.copilot/settings.json, if set.
    var copilotFileDefaultModel: String? {
        copilotFileSetting("model")
    }

    /// Default context tier from ~/.copilot/settings.json, if set.
    var copilotFileContextTier: String? {
        copilotFileSetting("contextTier")
    }

    private func copilotFileSetting(_ key: String) -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.copilot/settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// The model Copilot will actually use: the override if set,
    /// otherwise the default from ~/.copilot/settings.json.
    var effectiveCopilotModel: String? {
        let override = copilotModel.trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? copilotFileDefaultModel : override
    }

    var effectiveCopilotContextTier: String? {
        let override = copilotContextTier.trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? copilotFileContextTier : override
    }

    /// Discover valid --model values by parsing `copilot help`
    /// (the official docs point to the --model description as the
    /// canonical list of model strings for your subscription).
    func refreshCopilotModels() {
        let configured = copilotPath.trimmingCharacters(in: .whitespaces)
        let command = configured.isEmpty ? "copilot" : configured
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // A: Copilot's own models API — the source editors use; returns
            // the account's actual entitled models. Internal but stable-ish.
            var models = Self.copilotAPIModels()
            var source = "copilot API"
            // B: model lists cached in ~/.copilot JSON state.
            if models.count < 2 {
                models = Self.parseModelTokens(from: Self.shellOutput(
                    "cat ~/.copilot/*.json 2>/dev/null", timeout: 5) ?? "")
                source = "state files"
            }
            // C: legacy help-text parse (older CLIs listed models there).
            if models.count < 2 {
                models = Self.parseModels(fromHelp: Self.shellOutput(
                    "\(command) help 2>&1", timeout: 15) ?? "")
                source = "help text"
            }
            // D: curated baseline — the CLI stopped publishing its model
            // list anywhere scrapable. Kept current in the repo; a model
            // your plan lacks simply errors visibly in the panel.
            if models.count < 2 {
                // Top/current models only — one per family tier.
                models = ["auto",
                          "gpt-5.6-sol", "gpt-5.6-luna",
                          "claude-opus-4.8", "claude-sonnet-4.6",
                          "claude-haiku-4.5",
                          "gemini-2.5-pro"]
                source = "curated list"
            }
            Log.write("model discovery: found \(models.count) models via \(source)")
            if !models.isEmpty {
                DispatchQueue.main.async { self?.copilotAvailableModels = models }
            }
        }
    }

    /// The account's entitled Copilot models, via the same internal API
    /// editor integrations use (gh token → Copilot session token → /models).
    private static func copilotAPIModels() -> [String] {
        let cmd = """
        OAUTH=$(cat ~/.config/github-copilot/apps.json ~/.config/github-copilot/hosts.json ~/.copilot/*.json 2>/dev/null \
          | grep -o '"oauth_token"[^,}]*' | head -1 | grep -o '[A-Za-z0-9_]*$'); \
        [ -z "$OAUTH" ] && OAUTH=$(gh auth token 2>/dev/null); \
        TOKEN=$(curl -sf --max-time 10 https://api.github.com/copilot_internal/v2/token \
          -H "Authorization: token $OAUTH" | grep -o '"token":"[^"]*"' | cut -d'"' -f4); \
        [ -n "$TOKEN" ] && curl -sf --max-time 10 https://api.githubcopilot.com/models \
          -H "Authorization: Bearer $TOKEN" \
          -H "Copilot-Integration-Id: vscode-chat" \
          -H "Editor-Version: vscode/1.99.0"
        """
        guard let out = shellOutput(cmd, timeout: 25),
              let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var models: [String] = []
        for item in list {
            guard let id = item["id"] as? String, !id.isEmpty,
                  !seen.contains(id) else { continue }
            // Respect the picker flag when present (hides dupes/aliases).
            if let pickerEnabled = item["model_picker_enabled"] as? Bool,
               !pickerEnabled { continue }
            seen.insert(id)
            models.append(id)
        }
        return models
    }

    /// Run a login-shell command and capture combined output.
    private static func shellOutput(_ command: String, timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", command]
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        p.environment = env
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate() }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8)
    }

    /// Extract model IDs from arbitrary text, whitelisted by family prefix
    /// so flags, versions, and other junk can't reach the dropdown.
    static func parseModelTokens(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b[a-z][a-z0-9]*(?:-[a-z0-9.]+)+\\b") else { return [] }
        let families = ["gpt-", "claude-", "gemini-", "o1-", "o3-", "o4-",
                        "grok-", "llama-", "codex-"]
        let ns = text.lowercased() as NSString
        var seen = Set<String>()
        var models: [String] = []
        for match in regex.matches(in: text.lowercased(),
                                   range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            guard token.rangeOfCharacter(from: .decimalDigits) != nil,
                  token.count >= 4,
                  families.contains(where: { token.hasPrefix($0) }),
                  !seen.contains(token) else { continue }
            seen.insert(token)
            models.append(token)
        }
        return models
    }

    /// Extract model-ID-looking tokens (e.g. claude-sonnet-4.6, gpt-5.2)
    /// from the text following the --model flag in the help output.
    static func parseModels(fromHelp text: String) -> [String] {
        guard let r = text.range(of: "--model") else { return [] }
        let section = String(text[r.upperBound...].prefix(1200))
        guard let regex = try? NSRegularExpression(
            pattern: "[a-z][a-z0-9]*(?:[.-][a-z0-9.]+)+") else { return [] }
        let ns = section as NSString
        var seen = Set<String>()
        var models: [String] = []
        for match in regex.matches(in: section, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            // Real model IDs contain a digit; skips words like "premium-request".
            guard token.rangeOfCharacter(from: .decimalDigits) != nil,
                  !seen.contains(token) else { continue }
            seen.insert(token)
            models.append(token)
        }
        return models
    }

    /// Backend + current model, for pickers and badges.
    func backendLabel(_ kind: BackendKind) -> String {
        switch kind {
        case .claudeCode:
            let model = claudeModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Claude Code" : "Claude Code · \(model)"
        case .copilot:
            if let model = effectiveCopilotModel { return "Copilot · \(model)" }
            return "Copilot"
        case .codex:
            let model = codexModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Codex" : "Codex · \(model)"
        case .localModel:
            return "Local · \(localModel)"
        }
    }

    // MARK: - Dotfile config (~/.cantriprc)

    private var rcURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cantriprc")
    }

    func exportDotfile() {
        let dict: [String: Any] = [
            "backend": backend.rawValue,
            "claudePath": claudePath, "claudeWorkdir": claudeWorkdir,
            "claudeModel": claudeModel, "claudePermissionMode": claudePermissionMode,
            "claudeEffort": claudeEffort,
            "copilotPath": copilotPath, "copilotModel": copilotModel,
            "copilotAllowTools": copilotAllowTools, "copilotEffort": copilotEffort,
            "copilotContextTier": copilotContextTier,
            "codexPath": codexPath, "codexModel": codexModel,
            "localBaseURL": localBaseURL, "localModel": localModel,
            "localSystemPrompt": localSystemPrompt,
            "allowActions": allowActions, "shareLocation": shareLocation,
            "shareCalendar": shareCalendar, "attachScreen": attachScreen,
            "voiceMode": voiceMode, "memoryEnabled": memoryEnabled,
            "memoryPath": memoryPath, "fileRAGEnabled": fileRAGEnabled,
            "panelOpacity": panelOpacity,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: rcURL)
            Log.write("dotfile: exported to \(rcURL.path)")
        }
    }

    func importDotfile() {
        guard let data = try? Data(contentsOf: rcURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Log.write("dotfile: nothing to import at \(rcURL.path)")
            return
        }
        func str(_ key: String, _ apply: (String) -> Void) {
            if let v = dict[key] as? String { apply(v) }
        }
        func bool(_ key: String, _ apply: (Bool) -> Void) {
            if let v = dict[key] as? Bool { apply(v) }
        }
        str("backend") { if let k = BackendKind(rawValue: $0) { self.backend = k } }
        str("claudePath") { self.claudePath = $0 }
        str("claudeWorkdir") { self.claudeWorkdir = $0 }
        str("claudeModel") { self.claudeModel = $0 }
        str("claudePermissionMode") { self.claudePermissionMode = $0 }
        str("claudeEffort") { self.claudeEffort = $0 }
        str("copilotPath") { self.copilotPath = $0 }
        str("copilotModel") { self.copilotModel = $0 }
        bool("copilotAllowTools") { self.copilotAllowTools = $0 }
        str("copilotEffort") { self.copilotEffort = $0 }
        str("copilotContextTier") { self.copilotContextTier = $0 }
        str("codexPath") { self.codexPath = $0 }
        str("codexModel") { self.codexModel = $0 }
        str("localBaseURL") { self.localBaseURL = $0 }
        str("localModel") { self.localModel = $0 }
        str("localSystemPrompt") { self.localSystemPrompt = $0 }
        bool("allowActions") { self.allowActions = $0 }
        bool("shareLocation") { self.shareLocation = $0 }
        bool("shareCalendar") { self.shareCalendar = $0 }
        bool("attachScreen") { self.attachScreen = $0 }
        bool("voiceMode") { self.voiceMode = $0 }
        bool("memoryEnabled") { self.memoryEnabled = $0 }
        str("memoryPath") { self.memoryPath = $0 }
        bool("fileRAGEnabled") { self.fileRAGEnabled = $0 }
        if let opacity = dict["panelOpacity"] as? Double {
            panelOpacity = min(max(opacity, 0.5), 1.0)
        }
        Log.write("dotfile: imported from \(rcURL.path)")
    }

    /// Launch at login via SMAppService (source of truth is the system).
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                Log.write("launchAtLogin: \(newValue ? "registered" : "unregistered")")
            } catch {
                Log.write("launchAtLogin failed: \(error.localizedDescription)")
            }
        }
    }

    private init() {
        backend = BackendKind(rawValue: d.string(forKey: "backend") ?? "") ?? .claudeCode
        claudePath = d.string(forKey: "claudePath") ?? ""
        claudeWorkdir = d.string(forKey: "claudeWorkdir") ?? NSHomeDirectory()
        claudeModel = d.string(forKey: "claudeModel") ?? ""
        claudePermissionMode = d.string(forKey: "claudePermissionMode") ?? "default"
        claudeEffort = d.string(forKey: "claudeEffort") ?? ""
        copilotPath = d.string(forKey: "copilotPath") ?? ""
        copilotModel = d.string(forKey: "copilotModel") ?? ""
        copilotAllowTools = d.bool(forKey: "copilotAllowTools")
        copilotEffort = d.string(forKey: "copilotEffort") ?? ""
        copilotContextTier = d.string(forKey: "copilotContextTier") ?? ""
        copilotDiscourageSubagents = d.object(forKey: "copilotDiscourageSubagents") == nil
            ? true : d.bool(forKey: "copilotDiscourageSubagents")
        copilotAvailableModels = d.stringArray(forKey: "copilotAvailableModels") ?? []
        codexPath = d.string(forKey: "codexPath") ?? ""
        codexModel = d.string(forKey: "codexModel") ?? ""
        localBaseURL = d.string(forKey: "localBaseURL") ?? "http://localhost:8000/v1"
        localModel = d.string(forKey: "localModel") ?? "hermes"
        localAPIKey = d.string(forKey: "localAPIKey") ?? ""
        localSystemPrompt = d.string(forKey: "localSystemPrompt") ?? "You are a helpful assistant. Be concise."
        allowActions = d.bool(forKey: "allowActions")
        // Default ON so the app proactively requests Location Services.
        shareLocation = d.object(forKey: "shareLocation") == nil ? true : d.bool(forKey: "shareLocation")
        attachScreen = d.bool(forKey: "attachScreen")
        voiceMode = d.bool(forKey: "voiceMode")
        fileRAGEnabled = d.object(forKey: "fileRAGEnabled") == nil ? true : d.bool(forKey: "fileRAGEnabled")
        // Default ON — first use triggers the Calendar Automation prompt.
        shareCalendar = d.object(forKey: "shareCalendar") == nil ? true : d.bool(forKey: "shareCalendar")
        let storedOpacity = d.double(forKey: "panelOpacity")
        panelOpacity = storedOpacity == 0 ? 1.0 : min(max(storedOpacity, 0.5), 1.0)
        memoryEnabled = d.object(forKey: "memoryEnabled") == nil ? true : d.bool(forKey: "memoryEnabled")
        memoryPath = d.string(forKey: "memoryPath") ?? "\(NSHomeDirectory())/Cantrip Memory"
    }
}
