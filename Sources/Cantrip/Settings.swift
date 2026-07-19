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
    /// Memory vault: folder of markdown notes backends read & maintain.
    @Published var memoryEnabled: Bool {
        didSet { d.set(memoryEnabled, forKey: "memoryEnabled") }
    }
    @Published var memoryPath: String {
        didSet { d.set(memoryPath, forKey: "memoryPath") }
    }

    /// Default model from ~/.copilot/settings.json, if set.
    var copilotFileDefaultModel: String? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.copilot/settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = obj["model"] as? String, !model.isEmpty else { return nil }
        return model
    }

    /// The model Copilot will actually use: the override if set,
    /// otherwise the default from ~/.copilot/settings.json.
    var effectiveCopilotModel: String? {
        let override = copilotModel.trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? copilotFileDefaultModel : override
    }

    /// Discover valid --model values by parsing `copilot help`
    /// (the official docs point to the --model description as the
    /// canonical list of model strings for your subscription).
    func refreshCopilotModels() {
        let configured = copilotPath.trimmingCharacters(in: .whitespaces)
        let command = configured.isEmpty ? "copilot" : configured
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-l", "-c", "exec \"$0\" help", command]
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var env = ProcessInfo.processInfo.environment
            env["NO_COLOR"] = "1"
            env["TERM"] = "dumb"
            p.environment = env
            do { try p.run() } catch {
                Log.write("model discovery: launch failed: \(error.localizedDescription)")
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return }
            let models = Self.parseModels(fromHelp: text)
            Log.write("model discovery: found \(models.count) models")
            if !models.isEmpty {
                DispatchQueue.main.async { self?.copilotAvailableModels = models }
            }
        }
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
            "copilotPath": copilotPath, "copilotModel": copilotModel,
            "copilotAllowTools": copilotAllowTools,
            "codexPath": codexPath, "codexModel": codexModel,
            "localBaseURL": localBaseURL, "localModel": localModel,
            "localSystemPrompt": localSystemPrompt,
            "allowActions": allowActions, "shareLocation": shareLocation,
            "shareCalendar": shareCalendar, "attachScreen": attachScreen,
            "voiceMode": voiceMode, "memoryEnabled": memoryEnabled,
            "memoryPath": memoryPath, "fileRAGEnabled": fileRAGEnabled,
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
        str("copilotPath") { self.copilotPath = $0 }
        str("copilotModel") { self.copilotModel = $0 }
        bool("copilotAllowTools") { self.copilotAllowTools = $0 }
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
        copilotPath = d.string(forKey: "copilotPath") ?? ""
        copilotModel = d.string(forKey: "copilotModel") ?? ""
        copilotAllowTools = d.bool(forKey: "copilotAllowTools")
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
        memoryEnabled = d.object(forKey: "memoryEnabled") == nil ? true : d.bool(forKey: "memoryEnabled")
        memoryPath = d.string(forKey: "memoryPath") ?? "\(NSHomeDirectory())/Cantrip Memory"
    }
}
