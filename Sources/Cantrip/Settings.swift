import Foundation
import Security
import ServiceManagement
import LocalAuthentication

enum BackendKind: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case copilot = "Copilot"
    case copilotRemote = "Copilot Remote"
    case codex = "Codex"
    case antigravity = "Antigravity"
    case localModel = "Local Model"
    var id: String { rawValue }
}

/// A council seat: a backend plus a model override, so the same backend
/// can appear twice with different models (e.g. Copilot · gpt-5.6-sol AND
/// Copilot · claude-opus-4.8).
struct CouncilMember: Codable, Equatable, Identifiable {
    var backend: String     // BackendKind rawValue
    var model: String       // model override; empty = backend's configured model
    var id: String { backend + "|" + model }
    var kind: BackendKind? { BackendKind(rawValue: backend) }

    var label: String {
        let name = kind?.rawValue ?? backend
        return model.isEmpty ? name : "\(name) · \(model)"
    }
}

/// UserDefaults-backed settings.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard
    private let launchAtLoginBundlePathKey = "launchAtLoginBundlePath"
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var remoteControlError: String?
    @Published private(set) var remoteControlCredentialRevision = 0

    /// Opt-in for loopback HTTP through Tailscale and encrypted Bonjour LAN access.
    @Published var remoteControlEnabled: Bool {
        didSet { d.set(remoteControlEnabled, forKey: "remoteControlEnabled") }
    }
    /// Cantrip's interface on this Mac: the floating panel, or Cantrip Gateway's Home window
    /// (`HomeWindow`, macOS 26). Both run on this host; the window talks to its server on loopback.
    @Published var interfaceMode: InterfaceMode {
        didSet { d.set(interfaceMode.rawValue, forKey: "interfaceMode") }
    }
    @Published var remoteControlPort: Int {
        didSet { d.set(remoteControlPort, forKey: "remoteControlPort") }
    }
    /// Fixed port for the encrypted (TLS-PSK) LAN listener, so a client can save this Mac's
    /// direct address (e.g. through a Tailscale subnet router). 0 = automatic (dynamic) port.
    @Published var remoteLANPort: Int {
        didSet { d.set(remoteLANPort, forKey: "remoteLANPort") }
    }
    /// Where the encrypted LAN listener is actually listening; nil while it is off.
    @Published private(set) var remoteLANStatus: RemoteLANStatus?
    /// Permanent hidden session used by Cantrip Agent's focused Home mode.
    @Published var cantripHomeEnabled: Bool {
        didSet { d.set(cantripHomeEnabled, forKey: "cantripHomeEnabled") }
    }
    /// How many Home background jobs may run at once, each in its own hidden session.
    @Published var cantripHomeParallelRuns: Int {
        didSet {
            let clamped = min(max(cantripHomeParallelRuns, 1),
                              CantripHomeBackgroundRunner.maximumParallelLimit)
            if clamped != cantripHomeParallelRuns { cantripHomeParallelRuns = clamped }
            d.set(cantripHomeParallelRuns, forKey: "cantripHomeParallelRuns")
        }
    }

    /// Daily cleanup of agent session folders and worktrees nothing uses (`StorageUpkeep`).
    @Published var storageUpkeepEnabled: Bool {
        didSet { d.set(storageUpkeepEnabled, forKey: "storageUpkeepEnabled") }
    }
    /// Days an unused Copilot session folder is kept before the cleanup removes it.
    @Published var storageSessionRetentionDays: Int {
        didSet {
            let range = StorageUpkeep.sessionRetentionDays
            let clamped = min(max(storageSessionRetentionDays, range.lowerBound), range.upperBound)
            if clamped != storageSessionRetentionDays { storageSessionRetentionDays = clamped }
            d.set(storageSessionRetentionDays, forKey: "storageSessionRetentionDays")
        }
    }

    var remoteControlToken: String {
        do { return try RemoteControlCredentials.load() ?? "" }
        catch {
            MacAttention.report(.keychain)
            return ""
        }
    }

    @discardableResult
    func ensureRemoteControlToken() -> String? {
        do {
            if let existing = try RemoteControlCredentials.load(), !existing.isEmpty {
                remoteControlError = nil
                return existing
            }
        } catch {
            // A headless host reached over SSH can't use the locked login Keychain.
            if HostMode.isHeadless { return useRemoteTokenFile(because: "Keychain unavailable (\(error.localizedDescription))") }
            MacAttention.report(.keychain)
            remoteControlError = "Keychain access is blocked. Review Cantrip's access on the Mac; the existing pairing token was not replaced."
            return nil
        }
        guard let token = RemoteControlCredentials.generate() else {
            remoteControlError = "Could not generate a secure pairing token."
            return nil
        }
        let status = RemoteControlCredentials.store(token)
        guard status == errSecSuccess else {
            if HostMode.isHeadless { return useRemoteTokenFile(because: "Keychain save failed (OSStatus \(status))") }
            remoteControlError = "Could not save the pairing token in Keychain (OSStatus \(status))."
            return nil
        }
        remoteControlError = nil
        remoteControlCredentialRevision += 1
        return token
    }

    /// Replaces the pairing token in whichever store holds it; paired devices must pair again.
    @discardableResult
    func regenerateRemoteControlToken() -> Bool {
        guard let token = RemoteControlCredentials.generate() else {
            remoteControlError = "Could not generate a secure pairing token."
            return false
        }
        let status = RemoteControlCredentials.store(token)
        if status == errSecSuccess {
            remoteControlError = nil
            remoteControlCredentialRevision += 1
            return true
        }
        if HostMode.isHeadless, !RemoteTokenFile.inUse {
            return useRemoteTokenFile(because: "Keychain save failed (OSStatus \(status))", token: token) != nil
        }
        remoteControlError = RemoteTokenFile.inUse
            ? "Could not save the pairing token file at \(RemoteTokenFile.url.path)."
            : "Could not save the pairing token in Keychain (OSStatus \(status))."
        return false
    }

    /// Moves the token to a file only this user can read. From then on the app uses it too.
    private func useRemoteTokenFile(because reason: String, token: String? = nil) -> String? {
        do {
            if token == nil, let existing = try RemoteTokenFile.load() {
                remoteControlError = nil
                return existing
            }
            guard let token = token ?? RemoteControlCredentials.generate() else {
                remoteControlError = "Could not generate a secure pairing token."
                return nil
            }
            try RemoteTokenFile.store(token)
            Log.write("remote-control: \(reason); the pairing token is now in \(RemoteTokenFile.url.path)")
            remoteControlError = nil
            remoteControlCredentialRevision += 1
            return token
        } catch {
            remoteControlError = "Could not save the pairing token file at \(RemoteTokenFile.url.path): \(error.localizedDescription)"
            return nil
        }
    }

    func reportRemoteControlError(_ message: String?) {
        remoteControlError = message
    }

    func reportRemoteLANStatus(_ status: RemoteLANStatus?) {
        if remoteLANStatus != status { remoteLANStatus = status }
    }

    @Published var backend: BackendKind {
        didSet { d.set(backend.rawValue, forKey: "backend") }
    }
    /// Path to the `claude` binary. Empty = auto-detect via login shell.
    @Published var claudePath: String {
        didSet {
            d.set(claudePath, forKey: "claudePath")
            claudeCatalogUpdatedAt = nil
        }
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
        didSet {
            d.set(copilotPath, forKey: "copilotPath")
            copilotCatalogUpdatedAt = nil
        }
    }
    /// host:port of a Copilot CLI ACP server (`copilot --acp --port N`).
    /// It binds loopback by default, so remote instances are reached via
    /// a tunnel (ssh -L / tailscale) — the address here is where the
    /// tunnel lands, e.g. 127.0.0.1:3000.
    @Published var acpAddress: String {
        didSet { d.set(acpAddress, forKey: "acpAddress") }
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
        ("xhigh", "XHigh — very high reasoning"),
        ("max", "Max — maximum reasoning"),
        ("none", "None — no reasoning"),
        ("minimal", "Minimal"),
    ]
    /// Context tier passed as --context. Empty = ~/.copilot/settings.json default.
    @Published var copilotContextTier: String {
        didSet { d.set(copilotContextTier, forKey: "copilotContextTier") }
    }
    /// Let Copilot delegate to subagents, guided toward token-saving uses.
    /// Off removes the subagent tools from the session entirely.
    /// Auto-fork: a queued message sent with Auto delivery that the planner rates independent
    /// starts in a child tab on its own (ChildTabCoordinator.considerAutoFork).
    @Published var childTabsAutoFork: Bool {
        didSet { d.set(childTabsAutoFork, forKey: "childTabsAutoFork") }
    }
    @Published var copilotAllowSubagents: Bool {
        didSet { d.set(copilotAllowSubagents, forKey: "copilotAllowSubagents") }
    }
    /// Opt Copilot sessions into MCP Apps so tools such as Mobbin's searches
    /// return interactive views that render inline in the chat.
    @Published var copilotMCPApps: Bool {
        didSet { d.set(copilotMCPApps, forKey: "copilotMCPApps") }
    }
    /// Fetch Open Graph metadata and preview images on the Mac for public web links in replies.
    @Published var linkPreviewsEnabled: Bool {
        didSet { d.set(linkPreviewsEnabled, forKey: "linkPreviewsEnabled") }
    }
    /// Minutes a tab's Copilot runtime may sit idle before Cantrip stops it to free memory;
    /// the next prompt resumes the same session in a new runtime. 0 keeps runtimes running.
    @Published var copilotIdleReleaseMinutes: Int {
        didSet { d.set(copilotIdleReleaseMinutes, forKey: "copilotIdleReleaseMinutes") }
    }
    static let copilotIdleReleaseChoices: [(minutes: Int, label: String)] = [
        (10, "10 minutes"), (30, "30 minutes"), (60, "1 hour"), (120, "2 hours"), (0, "Never"),
    ]
    /// Cached account model list from the configured Copilot runtime.
    @Published var copilotAvailableModels: [String] {
        didSet { d.set(copilotAvailableModels, forKey: "copilotAvailableModels") }
    }
    /// Per-model metadata matching copilotAvailableModels.
    @Published var copilotModelCatalog: [CopilotModelInfo] {
        didSet {
            if let data = try? JSONEncoder().encode(copilotModelCatalog) {
                d.set(data, forKey: "copilotModelCatalog")
            }
        }
    }
    @Published private(set) var copilotRefreshInFlight = false
    @Published private(set) var copilotModelRefreshError: String?
    @Published private(set) var copilotCatalogUpdatedAt: Date? {
        didSet { d.set(copilotCatalogUpdatedAt, forKey: "copilotCatalogUpdatedAt") }
    }

    /// Claude Code's models (from its `initialize` reply) for per-tab model settings.
    @Published var claudeModelCatalog: [CopilotModelInfo] {
        didSet {
            if let data = try? JSONEncoder().encode(claudeModelCatalog) { d.set(data, forKey: "claudeModelCatalog") }
        }
    }
    @Published var claudeRefreshInFlight = false
    @Published var claudeModelRefreshError: String?
    @Published var claudeCatalogUpdatedAt: Date? {
        didSet { d.set(claudeCatalogUpdatedAt, forKey: "claudeCatalogUpdatedAt") }
    }

    func copilotModelInfo(_ id: String) -> CopilotModelInfo? {
        copilotModelCatalog.first { $0.id == id }
    }
    /// Council seats for multi-model runs (backend + model pairs).
    @Published var councilMembers: [CouncilMember] {
        didSet {
            if let data = try? JSONEncoder().encode(councilMembers) {
                d.set(data, forKey: "councilMembers")
            }
        }
    }
    /// When councils convene: "planReview" (default — execution prompts
    /// go straight to the single worker) or "always".
    @Published var councilScope: String {
        didSet { d.set(councilScope, forKey: "councilScope") }
    }
    /// Backends (BackendKind rawValues), in order, a run moves through when the backend it's on
    /// reports its usage limit (`BackendFallback`). Empty = off: the run stops with the error.
    @Published var limitFallbackBackends: [String] {
        didSet {
            let cleaned = Self.fallbackChain(limitFallbackBackends)
            // Setting a property inside its own didSet doesn't run didSet again.
            if cleaned != limitFallbackBackends { limitFallbackBackends = cleaned }
            d.set(cleaned, forKey: "limitFallbackBackends")
        }
    }

    /// The model and effort each backup runs with, by BackendKind rawValue; a backend with none
    /// (or empty fields) uses its default. Kept apart from the chain so clients that only edit the
    /// order can't drop them.
    @Published var limitFallbackModels: [String: SessionModelSelection] {
        didSet {
            if let data = try? JSONEncoder().encode(limitFallbackModels) { d.set(data, forKey: "limitFallbackModels") }
        }
    }

    /// Known backends only, each once, in the order given.
    static func fallbackChain(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.filter { BackendKind(rawValue: $0) != nil && seen.insert($0).inserted }
    }
    /// Union of the account models' advertised reasoning efforts.
    @Published var copilotEffortChoices: [String] {
        didSet { d.set(copilotEffortChoices, forKey: "copilotEffortChoices") }
    }
    /// Union of the account models' advertised context tiers.
    @Published var copilotContextTierChoices: [String] {
        didSet { d.set(copilotContextTierChoices, forKey: "copilotContextTierChoices") }
    }
    /// Path to the `codex` binary. Empty = login-shell lookup.
    @Published var codexPath: String {
        didSet { d.set(codexPath, forKey: "codexPath") }
    }
    /// Optional model override passed as -m (e.g. gpt-5-codex).
    @Published var codexModel: String {
        didSet { d.set(codexModel, forKey: "codexModel") }
    }
    /// Path to the `agy` binary. Empty = login-shell lookup.
    @Published var agyPath: String {
        didSet { d.set(agyPath, forKey: "agyPath") }
    }
    /// Optional model override passed as --model (from `agy models`).
    @Published var agyModel: String {
        didSet { d.set(agyModel, forKey: "agyModel") }
    }
    /// Reasoning effort passed as --effort (low, medium, high).
    @Published var agyEffort: String {
        didSet { d.set(agyEffort, forKey: "agyEffort") }
    }
    /// Permission mode for `agy` ("default", "sandbox", "bypassPermissions").
    @Published var agyPermissionMode: String {
        didSet { d.set(agyPermissionMode, forKey: "agyPermissionMode") }
    }
    /// Model slugs advertised by `agy models`, used until the first lookup
    /// (`refreshAntigravityModels`) replaces them with the signed-in account's list.
    static let agyDefaultModels: [String] = [
        "gemini-4-argon-medium",
        "gemini-4-argon-high",
        "gemini-4-argon-low",
        "gemini-3.8-flash-high",
        "gemini-3.8-flash-medium",
        "gemini-3.8-flash-low",
        "claude-opus-5-5-low",
        "claude-opus-5-5-medium",
        "claude-opus-5-5-high",
        "claude-sonnet-5-5-low",
        "claude-sonnet-5-5-medium",
        "claude-sonnet-5-5-high",
        "gpt-oss-120b-medium",
    ]
    static let agyDefaultModelNames: [String: String] = [
        "gemini-4-argon-medium": "Gemini 4 Argon (Medium)",
        "gemini-4-argon-high": "Gemini 4 Argon (High)",
        "gemini-4-argon-low": "Gemini 4 Argon (Low)",
        "gemini-3.8-flash-high": "Gemini 3.8 Flash (High)",
        "gemini-3.8-flash-medium": "Gemini 3.8 Flash (Medium)",
        "gemini-3.8-flash-low": "Gemini 3.8 Flash (Low)",
        "claude-opus-5-5-low": "Claude Opus 5.5 (Low)",
        "claude-opus-5-5-medium": "Claude Opus 5.5 (Medium)",
        "claude-opus-5-5-high": "Claude Opus 5.5 (High)",
        "claude-sonnet-5-5-low": "Claude Sonnet 5.5 (Low)",
        "claude-sonnet-5-5-medium": "Claude Sonnet 5.5 (Medium)",
        "claude-sonnet-5-5-high": "Claude Sonnet 5.5 (High)",
        "gpt-oss-120b-medium": "GPT-OSS 120B (Medium)",
    ]
    /// Opt-in: Antigravity's Gemini Flash also routes, plans and checks "Done when" for tabs on
    /// other backends (their messages then go to Google). Off: only Antigravity tabs use it.
    @Published var agyAuxiliaryRouting: Bool {
        didSet { d.set(agyAuxiliaryRouting, forKey: "agyAuxiliaryRouting") }
    }
    /// Opt-in: memory consolidation runs on Antigravity's Gemini Flash first (the vault's notes
    /// then go to Google). Off: memory stays on Cantrip's own Claude Code / Copilot pass.
    @Published var agyMemoryConsolidation: Bool {
        didSet { d.set(agyMemoryConsolidation, forKey: "agyMemoryConsolidation") }
    }
    @Published var agyAvailableModels: [String] {
        didSet { d.set(agyAvailableModels, forKey: "agyAvailableModels") }
    }
    /// Display names from `agy models`, keyed by slug.
    @Published var agyModelNames: [String: String] = [:] {
        didSet { d.set(agyModelNames, forKey: "agyModelNames") }
    }
    @Published var agyCatalogUpdatedAt: Date? = nil
    @Published var agyRefreshInFlight = false
    @Published var agyModelRefreshError: String? = nil
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

    /// Remote polls read these per tab, so the file is parsed again only after it changes.
    private let copilotFileLock = NSLock()
    private var copilotFileCache: (modified: Date, size: Int, object: [String: Any]?)?

    private func copilotFileSetting(_ key: String) -> String? {
        let path = NSHomeDirectory() + "/.copilot/settings.json"
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        let object: [String: Any]? = copilotFileLock.withLock {
            if let cache = copilotFileCache, cache.modified == modified, cache.size == size {
                return cache.object
            }
            let parsed = FileManager.default.contents(atPath: path)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            copilotFileCache = (modified, size, parsed)
            return parsed
        }
        guard let value = object?[key] as? String, !value.isEmpty else { return nil }
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

    func refreshCopilotModels(
        using loader: (String, @escaping (Result<[CopilotModelInfo], Error>) -> Void) -> Void = CopilotModelFetcher.fetch
    ) {
        guard !copilotRefreshInFlight else { return }
        copilotRefreshInFlight = true
        copilotModelRefreshError = nil
        let configured = copilotPath.trimmingCharacters(in: .whitespaces)
        let command = ToolLocator.shared.copilotCommand(configured: configured)
        loader(command) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.copilotRefreshInFlight = false
                guard self.copilotPath.trimmingCharacters(in: .whitespaces) == configured else {
                    self.copilotModelRefreshError = "Copilot path changed during refresh. Refresh again for the new installation."
                    return
                }
                switch result {
                case .success(let catalog) where !catalog.isEmpty:
                    self.copilotModelCatalog = catalog
                    self.copilotAvailableModels = catalog.map(\.id)
                    self.copilotEffortChoices = CopilotModelInfo.choices(
                        supported: nil, fallback: catalog.flatMap { $0.reasoningEfforts ?? [] }, selected: "")
                    self.copilotContextTierChoices = CopilotModelInfo.choices(
                        supported: nil, fallback: catalog.flatMap { $0.contextTiers ?? [] }, selected: "")
                    self.copilotCatalogUpdatedAt = Date()
                    Log.write("model discovery: found \(catalog.count) entries via Copilot runtime")
                case .success, .failure:
                    let error: CopilotModelError
                    if case .failure(let failure) = result {
                        error = (failure as? CopilotModelError) ?? .runtime
                    } else {
                        error = .response
                    }
                    self.copilotModelRefreshError = error.localizedDescription
                    Log.write("model discovery failed: \(error.rawValue); keeping cached catalog")
                }
            }
        }
    }

    func refreshCopilotModelsIfNeeded() {
        if copilotCatalogUpdatedAt.map({ Date().timeIntervalSince($0) < 6 * 60 * 60 }) != true {
            refreshCopilotModels()
        }
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
        case .copilotRemote:
            let address = acpAddress.trimmingCharacters(in: .whitespaces)
            return "Copilot Remote · \(address.isEmpty ? "127.0.0.1:3000" : address)"
        case .codex:
            let model = codexModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Codex" : "Codex · \(model)"
        case .antigravity:
            let model = agyModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Antigravity" : "Antigravity · \(agyModelLabel(model))"
        case .localModel:
            return "Local · \(localModel)"
        }
    }

    // MARK: - Dotfile config (~/.cantriprc)

    private var rcURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cantriprc")
    }

    /// Settings by their ~/.cantriprc names; `cantrip config` reads and writes the same names.
    var dotfileValues: [String: Any] {
        [
            "backend": backend.rawValue,
            "claudePath": claudePath, "claudeWorkdir": claudeWorkdir,
            "claudeModel": claudeModel, "claudePermissionMode": claudePermissionMode,
            "claudeEffort": claudeEffort,
            "copilotPath": copilotPath, "copilotModel": copilotModel,
            "acpAddress": acpAddress,
            "copilotAllowTools": copilotAllowTools, "copilotEffort": copilotEffort,
            "copilotContextTier": copilotContextTier,
            "codexPath": codexPath, "codexModel": codexModel,
            "agyPath": agyPath, "agyModel": agyModel,
            "agyEffort": agyEffort, "agyPermissionMode": agyPermissionMode,
            "localBaseURL": localBaseURL, "localModel": localModel,
            "localSystemPrompt": localSystemPrompt,
            "councilScope": councilScope, "limitFallbackBackends": limitFallbackBackends,
            "allowActions": allowActions, "shareLocation": shareLocation,
            "shareCalendar": shareCalendar, "attachScreen": attachScreen,
            "voiceMode": voiceMode, "memoryEnabled": memoryEnabled,
            "memoryPath": memoryPath, "fileRAGEnabled": fileRAGEnabled,
            "panelOpacity": panelOpacity,
            "remoteControlEnabled": remoteControlEnabled,
            "remoteControlPort": remoteControlPort,
            "remoteLANPort": remoteLANPort,
            "cantripHomeEnabled": cantripHomeEnabled,
            "cantripHomeParallelRuns": cantripHomeParallelRuns,
            "copilotAllowSubagents": copilotAllowSubagents,
            "childTabsAutoFork": childTabsAutoFork,
            "linkPreviewsEnabled": linkPreviewsEnabled,
            "copilotIdleReleaseMinutes": copilotIdleReleaseMinutes,
            "storageUpkeepEnabled": storageUpkeepEnabled,
            "storageSessionRetentionDays": storageSessionRetentionDays,
        ]
    }

    func exportDotfile() {
        if let data = try? JSONSerialization.data(
            withJSONObject: dotfileValues, options: [.prettyPrinted, .sortedKeys]) {
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
        applySettings(dict)
        Log.write("dotfile: imported from \(rcURL.path)")
    }

    /// Applies settings by their ~/.cantriprc names and returns the names it accepted; unknown
    /// names and values of the wrong type are skipped.
    @discardableResult
    func applySettings(_ dict: [String: Any]) -> [String] {
        var applied: [String] = []
        func str(_ key: String, _ apply: (String) -> Void) {
            if let v = dict[key] as? String { apply(v); applied.append(key) }
        }
        func bool(_ key: String, _ apply: (Bool) -> Void) {
            if let v = dict[key] as? NSNumber, CFGetTypeID(v) == CFBooleanGetTypeID() {
                apply(v.boolValue); applied.append(key)
            }
        }
        func int(_ key: String, _ range: ClosedRange<Int>, _ apply: (Int) -> Void) {
            if let v = dict[key] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(),
               v.doubleValue == Double(v.intValue), range.contains(v.intValue) {
                apply(v.intValue); applied.append(key)
            }
        }
        if let raw = dict["backend"] as? String, let kind = BackendKind(rawValue: raw) {
            backend = kind
            applied.append("backend")
        }
        str("claudePath") { self.claudePath = $0 }
        str("claudeWorkdir") { self.claudeWorkdir = $0 }
        str("claudeModel") { self.claudeModel = $0 }
        str("claudePermissionMode") { self.claudePermissionMode = $0 }
        str("claudeEffort") { self.claudeEffort = $0 }
        str("copilotPath") { self.copilotPath = $0 }
        str("acpAddress") { self.acpAddress = $0 }
        str("copilotModel") { self.copilotModel = $0 }
        bool("copilotAllowTools") { self.copilotAllowTools = $0 }
        str("copilotEffort") { self.copilotEffort = $0 }
        str("copilotContextTier") { self.copilotContextTier = $0 }
        str("codexPath") { self.codexPath = $0 }
        str("codexModel") { self.codexModel = $0 }
        str("agyPath") { self.agyPath = $0 }
        str("agyModel") { self.agyModel = $0 }
        str("agyEffort") { self.agyEffort = $0 }
        str("agyPermissionMode") { self.agyPermissionMode = $0 }
        str("localBaseURL") { self.localBaseURL = $0 }
        str("localModel") { self.localModel = $0 }
        str("localSystemPrompt") { self.localSystemPrompt = $0 }
        str("councilScope") { self.councilScope = $0 }
        if let raw = dict["limitFallbackBackends"] as? [String], raw.allSatisfy({ BackendKind(rawValue: $0) != nil }) {
            limitFallbackBackends = raw
            applied.append("limitFallbackBackends")
        }
        // Older ~/.cantriprc files name one backend.
        if let raw = dict["limitFallbackBackend"] as? String, raw.isEmpty || BackendKind(rawValue: raw) != nil {
            limitFallbackBackends = raw.isEmpty ? [] : [raw]
            applied.append("limitFallbackBackend")
        }
        bool("allowActions") { self.allowActions = $0 }
        bool("shareLocation") { self.shareLocation = $0 }
        bool("shareCalendar") { self.shareCalendar = $0 }
        bool("attachScreen") { self.attachScreen = $0 }
        bool("voiceMode") { self.voiceMode = $0 }
        bool("memoryEnabled") { self.memoryEnabled = $0 }
        str("memoryPath") { self.memoryPath = $0 }
        bool("fileRAGEnabled") { self.fileRAGEnabled = $0 }
        bool("remoteControlEnabled") { self.remoteControlEnabled = $0 }
        bool("cantripHomeEnabled") { self.cantripHomeEnabled = $0 }
        bool("copilotAllowSubagents") { self.copilotAllowSubagents = $0 }
        bool("childTabsAutoFork") { self.childTabsAutoFork = $0 }
        bool("linkPreviewsEnabled") { self.linkPreviewsEnabled = $0 }
        int("cantripHomeParallelRuns", 1...CantripHomeBackgroundRunner.maximumParallelLimit) {
            self.cantripHomeParallelRuns = $0
        }
        int("copilotIdleReleaseMinutes", 0...1440) { self.copilotIdleReleaseMinutes = $0 }
        bool("storageUpkeepEnabled") { self.storageUpkeepEnabled = $0 }
        int("storageSessionRetentionDays", StorageUpkeep.sessionRetentionDays) {
            self.storageSessionRetentionDays = $0
        }
        int("remoteControlPort", 1...65535) { self.remoteControlPort = $0 }
        int("remoteLANPort", 0...65535) { self.remoteLANPort = $0 }
        if let opacity = dict["panelOpacity"] as? NSNumber, CFGetTypeID(opacity) != CFBooleanGetTypeID(),
           opacity.doubleValue.isFinite {
            panelOpacity = min(max(opacity.doubleValue, 0.5), 1.0)
            applied.append("panelOpacity")
        }
        return applied
    }

    /// Launch at login via SMAppService (source of truth is the system).
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    if SMAppService.mainApp.status == .enabled,
                       d.string(forKey: launchAtLoginBundlePathKey) != Bundle.main.bundlePath {
                        try SMAppService.mainApp.unregister()
                    }
                    registerCurrentBundleForLogin(retryOnce: true)
                } else {
                    try SMAppService.mainApp.unregister()
                    d.removeObject(forKey: launchAtLoginBundlePathKey)
                    launchAtLoginError = nil
                    Log.write("launchAtLogin: unregistered")
                }
            } catch {
                recordLaunchAtLoginFailure(error)
            }
        }
    }

    /// Existing registrations can retain the URL of an older checkout.
    /// Refresh once per bundle path so login always opens this exact build.
    func refreshLaunchAtLoginRegistrationIfNeeded() {
        guard SMAppService.mainApp.status == .enabled else {
            d.removeObject(forKey: launchAtLoginBundlePathKey)
            return
        }
        let currentPath = Bundle.main.bundlePath
        guard d.string(forKey: launchAtLoginBundlePathKey) != currentPath else { return }
        do {
            try SMAppService.mainApp.unregister()
            registerCurrentBundleForLogin(retryOnce: true)
        } catch {
            recordLaunchAtLoginFailure(error)
        }
    }

    private func registerCurrentBundleForLogin(retryOnce: Bool) {
        do {
            try SMAppService.mainApp.register()
            d.set(Bundle.main.bundlePath, forKey: launchAtLoginBundlePathKey)
            launchAtLoginError = nil
            Log.write("launchAtLogin: registered \(Bundle.main.bundlePath)")
        } catch {
            recordLaunchAtLoginFailure(error)
            guard retryOnce else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.registerCurrentBundleForLogin(retryOnce: false)
            }
        }
    }

    private func recordLaunchAtLoginFailure(_ error: Error) {
        let message = "Launch at login could not be updated: \(error.localizedDescription)"
        launchAtLoginError = message
        Log.write("launchAtLogin failed: \(error.localizedDescription)")
    }

    private init() {
        remoteControlEnabled = d.bool(forKey: "remoteControlEnabled")
        interfaceMode = InterfaceMode(rawValue: d.string(forKey: "interfaceMode") ?? "") ?? .panel
        let storedRemotePort = d.integer(forKey: "remoteControlPort")
        remoteControlPort = storedRemotePort == 0 ? 8765 : storedRemotePort
        remoteLANPort = min(max(d.integer(forKey: "remoteLANPort"), 0), 65535)
        cantripHomeEnabled = d.bool(forKey: "cantripHomeEnabled")
        storageUpkeepEnabled = d.object(forKey: "storageUpkeepEnabled") == nil ? true : d.bool(forKey: "storageUpkeepEnabled")
        storageSessionRetentionDays = StorageUpkeep.Configuration.retentionDays(d)
        let storedParallelRuns = d.integer(forKey: "cantripHomeParallelRuns")
        cantripHomeParallelRuns = storedParallelRuns == 0
            ? CantripHomeBackgroundRunner.defaultParallelRuns
            : min(max(storedParallelRuns, 1), CantripHomeBackgroundRunner.maximumParallelLimit)
        backend = BackendKind(rawValue: d.string(forKey: "backend") ?? "") ?? .claudeCode
        claudePath = d.string(forKey: "claudePath") ?? ""
        claudeWorkdir = d.string(forKey: "claudeWorkdir") ?? NSHomeDirectory()
        claudeModel = d.string(forKey: "claudeModel") ?? ""
        claudePermissionMode = d.string(forKey: "claudePermissionMode") ?? "default"
        claudeEffort = d.string(forKey: "claudeEffort") ?? ""
        copilotPath = d.string(forKey: "copilotPath") ?? ""
        acpAddress = d.string(forKey: "acpAddress") ?? "127.0.0.1:3000"
        copilotModel = d.string(forKey: "copilotModel") ?? ""
        copilotAllowTools = d.bool(forKey: "copilotAllowTools")
        copilotEffort = d.string(forKey: "copilotEffort") ?? ""
        copilotContextTier = d.string(forKey: "copilotContextTier") ?? ""
        // Replaces the old prompt-only "discourage" preference, whose default was on.
        copilotAllowSubagents = d.object(forKey: "copilotAllowSubagents") == nil
            ? true : d.bool(forKey: "copilotAllowSubagents")
        childTabsAutoFork = d.object(forKey: "childTabsAutoFork") == nil
            ? true : d.bool(forKey: "childTabsAutoFork")
        copilotMCPApps = d.object(forKey: "copilotMCPApps") == nil
            ? true : d.bool(forKey: "copilotMCPApps")
        linkPreviewsEnabled = d.object(forKey: "linkPreviewsEnabled") == nil
            ? true : d.bool(forKey: "linkPreviewsEnabled")
        copilotIdleReleaseMinutes = d.object(forKey: "copilotIdleReleaseMinutes") as? Int ?? 30
        copilotAvailableModels = d.stringArray(forKey: "copilotAvailableModels") ?? []
        copilotModelCatalog = (d.data(forKey: "copilotModelCatalog")
            .flatMap { try? JSONDecoder().decode([CopilotModelInfo].self, from: $0) }) ?? []
        copilotCatalogUpdatedAt = d.object(forKey: "copilotCatalogUpdatedAt") as? Date
        claudeModelCatalog = (d.data(forKey: "claudeModelCatalog"))
            .flatMap { try? JSONDecoder().decode([CopilotModelInfo].self, from: $0) } ?? []
        claudeCatalogUpdatedAt = d.object(forKey: "claudeCatalogUpdatedAt") as? Date
        copilotEffortChoices = d.stringArray(forKey: "copilotEffortChoices") ?? []
        copilotContextTierChoices = d.stringArray(forKey: "copilotContextTierChoices") ?? []
        councilMembers = (d.data(forKey: "councilMembers")
            .flatMap { try? JSONDecoder().decode([CouncilMember].self, from: $0) }) ?? []
        councilScope = d.string(forKey: "councilScope") ?? "planReview"
        // Before the chain, one backend was saved under limitFallbackBackend.
        limitFallbackModels = d.data(forKey: "limitFallbackModels")
            .flatMap { try? JSONDecoder().decode([String: SessionModelSelection].self, from: $0) } ?? [:]
        limitFallbackBackends = Self.fallbackChain(d.stringArray(forKey: "limitFallbackBackends")
            ?? [d.string(forKey: "limitFallbackBackend") ?? ""])
        codexPath = d.string(forKey: "codexPath") ?? ""
        codexModel = d.string(forKey: "codexModel") ?? ""
        agyPath = d.string(forKey: "agyPath") ?? ""
        agyModel = d.string(forKey: "agyModel") ?? ""
        agyEffort = d.string(forKey: "agyEffort") ?? ""
        agyPermissionMode = d.string(forKey: "agyPermissionMode") ?? "default"
        agyAvailableModels = d.stringArray(forKey: "agyAvailableModels") ?? Self.agyDefaultModels
        agyAuxiliaryRouting = d.bool(forKey: "agyAuxiliaryRouting")
        agyMemoryConsolidation = d.bool(forKey: "agyMemoryConsolidation")
        agyModelNames = (d.dictionary(forKey: "agyModelNames") as? [String: String]) ?? Self.agyDefaultModelNames
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

/// The pairing token as a file only this user can read: used when a headless host can't reach
/// the Keychain (SSH-only Macs, later Linux). Once it exists, the app reads it too.
enum RemoteTokenFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cantrip/remote-token")
    }

    static var inUse: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func load() throws -> String? {
        guard inUse else { return nil }
        // Never trust a token others could have read or replaced.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard mode & 0o077 == 0, (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CocoaError(.fileReadNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "\(url.path) must belong to you and be readable only by you (chmod 600)."
            ])
        }
        let token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func store(_ token: String) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".remote-token-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data((token + "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private enum RemoteControlCredentials {
    private static let service = "com.brian.agentspotlight.remote-control"
    private static let account = "pairing-token"

    static func load() throws -> String? {
        if RemoteTokenFile.inUse { return try RemoteTokenFile.load() }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        query[kSecUseAuthenticationContext as String] = context
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else { throw CocoaError(.coderReadCorrupt) }
        Task { @MainActor in MacAttention.shared.clear(.keychain) }
        return token
    }

    static func store(_ token: String) -> OSStatus {
        if RemoteTokenFile.inUse {
            do { try RemoteTokenFile.store(token) } catch { return errSecIO }
            return errSecSuccess
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return updateStatus }
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        var item = baseQuery
        for (key, value) in attributes { item[key] = value }
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
