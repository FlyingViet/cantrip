import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import Security
import SystemConfiguration

/// One setting's value as JSON carries it.
enum SettingValue: Equatable, Hashable {
    case bool(Bool), int(Int), double(Double), string(String)

    var json: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        }
    }

    /// A JSON value; booleans stay booleans and whole numbers stay integers.
    init?(json: Any) {
        if let number = json as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if ["d", "f"].contains(String(cString: number.objCType)) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        } else if let string = json as? String {
            self = .string(string)
        } else {
            return nil
        }
    }

    var fingerprint: String {
        switch self {
        case .bool(let value): return "b:\(value)"
        case .int(let value): return "i:\(value)"
        case .double(let value): return "d:\(value)"
        case .string(let value): return "s:\(value)"
        }
    }
}

/// A field of the settings manifest: what clients draw, and how a change is checked.
struct SettingsField {
    enum Kind: String {
        /// Bool switch.
        case toggle
        /// One of `choices` (string or integer values).
        case choice
        /// Whole number in `range`, changed in `step`s.
        case integer
        /// A TCP port typed in; 0 means `zeroLabel` when there is one.
        case port
        /// Decimal in `range` (a slider).
        case number
        /// One line of text, or several with `multiline`.
        case text
        /// A folder or file on the Mac.
        case path
        /// Write-only text: clients see only whether it is set; "" clears it.
        case secret
        /// A button; POST `{"action": key}`.
        case action
        /// A read-only line of status.
        case info
    }

    /// Who sees and changes it.
    enum Access {
        /// Every paired client.
        case anywhere
        /// Shown everywhere, changed only from Cantrip on the Mac itself.
        case atMac
        /// Only Cantrip's own Settings window on this Mac sees it (this Mac's app, not the engine).
        case macApp
    }

    struct Choice {
        var value: SettingValue
        var label: String
        var disabled = false
    }

    let key: String
    let kind: Kind
    let label: String
    var help: String? = nil
    var value: SettingValue? = nil
    var choices: [Choice] = []
    var range: ClosedRange<Double>? = nil
    var step: Double? = nil
    var unit: String? = nil
    /// "percent" for a 0–1 number shown as a percentage.
    var format: String? = nil
    var placeholder: String? = nil
    var zeroLabel: String? = nil
    /// Shown only while another field's value is one of these.
    var visibleWhen: (key: String, values: [SettingValue])? = nil
    var access: Access = .anywhere
    /// A paired device's change (it could lose that device its connection) is undone after
    /// `SettingsManifest.revertSeconds` unless the device keeps it.
    var guarded = false
    var destructive = false
    /// Asked before an action runs.
    var confirmation: String? = nil
    var multiline = false
    var maxLength = 1024
    /// Secrets: whether one is saved.
    var isSet: Bool? = nil
    /// Info lines: "warning" or "error".
    var tone: String? = nil
    /// Saves a checked value; nil saves it under `key` the way `cantrip config set` does.
    var apply: ((SettingValue) -> Void)? = nil

    /// Read-only for this request, and why.
    func readOnlyReason(local: Bool) -> String? {
        if kind == .info { return nil }
        if access == .atMac, !local { return "Change this in Cantrip's Settings on the Mac." }
        return nil
    }

    func json(local: Bool) -> [String: Any] {
        var object: [String: Any] = ["key": key, "type": kind.rawValue, "label": label]
        if let help { object["help"] = help }
        if kind == .secret {
            object["isSet"] = isSet ?? false
        } else if let value {
            object["value"] = value.json
        }
        if !choices.isEmpty {
            object["choices"] = choices.map { choice -> [String: Any] in
                var item: [String: Any] = ["value": choice.value.json, "label": choice.label]
                if choice.disabled { item["disabled"] = true }
                return item
            }
        }
        if let range {
            object["min"] = kind == .number ? range.lowerBound as Any : Int(range.lowerBound) as Any
            object["max"] = kind == .number ? range.upperBound as Any : Int(range.upperBound) as Any
        }
        if let step { object["step"] = kind == .number ? step as Any : Int(step) as Any }
        if let unit { object["unit"] = unit }
        if let format { object["format"] = format }
        if let placeholder { object["placeholder"] = placeholder }
        if let zeroLabel { object["zeroLabel"] = zeroLabel }
        if let visibleWhen {
            object["visibleWhen"] = ["key": visibleWhen.key, "values": visibleWhen.values.map(\.json)]
        }
        if let reason = readOnlyReason(local: local) {
            object["readOnly"] = true
            object["readOnlyReason"] = reason
        }
        if guarded, !local { object["guarded"] = true }
        if destructive { object["destructive"] = true }
        if let confirmation { object["confirmation"] = confirmation }
        if multiline { object["multiline"] = true }
        if [.text, .path, .secret].contains(kind) { object["maxLength"] = maxLength }
        if let tone { object["tone"] = tone }
        return object
    }
}

struct SettingsSection {
    let id: String
    let title: String
    var footer: String? = nil
    /// Clients open it as a screen of its own (a row with `summary`) instead of inline.
    var link = false
    var summary: String? = nil
    var fields: [SettingsField]
}

struct SettingsPageSpec {
    let id: String
    let title: String
    var sections: [SettingsSection]
}

struct SettingsManifestError: Error, LocalizedError {
    let status: Int
    let message: String
    /// Per-key problems for 422.
    var fields: [String: String] = [:]
    var errorDescription: String? { message }
}

/// `GET/POST /api/v1/settings`: this Mac's own settings as pages of fields that every client
/// (iPhone, Duo, Gateway Mac, Cantrip's Settings window, the browser and Windows) draws the same
/// way, so anything that can be changed on the Mac can be changed from any of them. Keys are the
/// `cantrip config` names.
///
/// GET → `{version, revision, mac, local, pages:[{id,title,sections:[{id,title,footer?,link?,
/// summary?,fields:[…]}]}], pending?}`. Rich settings (tiers, backups, MCP, skills, policy,
/// secrets) keep their own endpoints and screens.
///
/// POST bodies:
/// - `{"revision", "changes": {key: value}}` saves; 409 when the revision is stale, 422 with
///   `fields` naming each bad key (nothing is saved then).
/// - `{"action": key}` runs a button; the reply may carry `result` (`message`, `link`, `copy`).
/// - `{"keep": id}` / `{"revert": id}` answer a guarded change (`pending`): one a paired device
///   makes that could cut it off (ports, the pairing token) is undone after `revertSeconds`
///   unless that device, back over its new route, keeps it.
///
/// Requests from Cantrip's own Settings window on this Mac (`local`, see `LocalClientKey`) also
/// see the app's own settings (interface, panel, login item, this Mac's location) and may change
/// the ones paired devices only see (`atMac`: paths, Remote control itself, View Mac).
@MainActor
enum SettingsManifest {
    static let version = 1
    static var revertSeconds: TimeInterval = 60
    static let maximumBody = 65_536

    struct Pending {
        let id: String
        let keys: [String]
        let summary: String
        let previous: [String: SettingValue]
        let previousToken: String?
        let deadline: Date
    }

    private(set) static var pending: Pending?
    private static var revertWork: DispatchWorkItem?

    // MARK: - Values

    /// Every setting's current value by key, for the revision and the fields.
    static func values(_ s: AppSettings) -> [String: SettingValue] {
        [
            "remoteControlEnabled": .bool(s.remoteControlEnabled),
            "remoteControlPort": .int(s.remoteControlPort),
            "remoteLANPort": .int(s.remoteLANPort),
            "watchInternetRouteEnabled": .bool(s.watchInternetRouteEnabled),
            "backend": .string(s.backend.rawValue),
            "allowActions": .bool(s.allowActions),
            "claudeModel": .string(s.claudeModel),
            "claudeEffort": .string(s.claudeEffort),
            "claudePermissionMode": .string(s.claudePermissionMode),
            "copilotModel": .string(s.copilotModel),
            "copilotEffort": .string(s.copilotEffort),
            "copilotContextTier": .string(s.copilotContextTier),
            "copilotAllowTools": .bool(s.copilotAllowTools),
            "copilotAllowSubagents": .bool(s.copilotAllowSubagents),
            "copilotMCPApps": .bool(s.copilotMCPApps),
            "codexModel": .string(s.codexModel),
            "codexEffort": .string(s.codexEffort),
            "codexPermissionMode": .string(s.codexPermissionMode),
            "agyModel": .string(s.agyModel),
            "agyEffort": .string(s.agyEffort),
            "agyPermissionMode": .string(s.agyPermissionMode),
            "agyAuxiliaryRouting": .bool(s.agyAuxiliaryRouting),
            "localBaseURL": .string(s.localBaseURL),
            "localModel": .string(s.localModel),
            "localAPIKey": .bool(!s.localAPIKey.isEmpty),
            "localSystemPrompt": .string(s.localSystemPrompt),
            "acpAddress": .string(s.acpAddress),
            "claudePath": .string(s.claudePath),
            "copilotPath": .string(s.copilotPath),
            "codexPath": .string(s.codexPath),
            "agyPath": .string(s.agyPath),
            "openAIEndpointEnabled": .bool(s.openAIEndpointEnabled),
            "openAIEndpointPort": .int(s.openAIEndpointPort),
            "openAIEndpointModel": .string(s.openAIEndpointModel),
            "openAIEndpointEffort": .string(s.openAIEndpointEffort),
            "openAIEndpointContextTier": .string(s.openAIEndpointContextTier),
            "cantripHomeEnabled": .bool(s.cantripHomeEnabled),
            "cantripHomeParallelRuns": .int(s.cantripHomeParallelRuns),
            "childTabsAutoFork": .bool(s.childTabsAutoFork),
            "childTabsPerParentLimit": .int(s.childTabsPerParentLimit),
            "childTabsOverallLimit": .int(s.childTabsOverallLimit),
            "buildQueueEnabled": .bool(s.buildQueueEnabled),
            "buildQueueSlots": .int(s.buildQueueSlots),
            "claudeWorkdir": .string(s.claudeWorkdir),
            "copilotIdleReleaseMinutes": .int(s.copilotIdleReleaseMinutes),
            "linkPreviewsEnabled": .bool(s.linkPreviewsEnabled),
            "memoryEnabled": .bool(s.memoryEnabled),
            "memoryPath": .string(s.memoryPath),
            "memorySearchIndex": .bool(s.memorySearchIndex),
            "skillsAutoLink": .bool(s.skillsAutoLink),
            "agyMemoryConsolidation": .bool(s.agyMemoryConsolidation),
            "fileRAGEnabled": .bool(s.fileRAGEnabled),
            "shareCalendar": .bool(s.shareCalendar),
            "storageUpkeepEnabled": .bool(s.storageUpkeepEnabled),
            "storageSessionRetentionDays": .int(s.storageSessionRetentionDays),
            "storageSimulatorCleanup": .bool(s.storageSimulatorCleanup),
            "buildRoot": .string(s.buildRoot),
            "simulatorPoolPhone": .string(s.simulatorPoolPhone),
            "simulatorPoolPhoneOS": .string(s.simulatorPoolPhoneOS),
            "simulatorPoolDuoOS": .string(s.simulatorPoolDuoOS),
            "simulatorPoolMaxBooted": .int(s.simulatorPoolMaxBooted),
            "simulatorPoolMinFreeMemoryGB": .int(s.simulatorPoolMinFreeMemoryGB),
            "simulatorPoolWaitMinutes": .int(s.simulatorPoolWaitMinutes),
            "simulatorPoolIdleMinutes": .int(s.simulatorPoolIdleMinutes),
            "remoteDesktopEnabled": .bool(RemoteDesktop.shared.enabled),
            "interfaceMode": .string(s.interfaceMode.rawValue),
            "panelOpacity": .double(s.panelOpacity),
            "attachScreen": .bool(s.attachScreen),
            "voiceMode": .bool(s.voiceMode),
            "shareLocation": .bool(s.shareLocation),
            "backgroundEngine": .bool(BackgroundEngine.isEnabled),
        ]
    }

    /// Changes when any setting does; clients with Settings open reload when it moves (it rides
    /// along in the tab list every client already polls).
    static func revision(_ s: AppSettings = .shared) -> String {
        let text = values(s).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.fingerprint)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Pages

    static func pages(_ s: AppSettings, local: Bool) -> [SettingsPageSpec] {
        let v = values(s)
        func field(_ key: String, _ kind: SettingsField.Kind, _ label: String, help: String? = nil) -> SettingsField {
            SettingsField(key: key, kind: kind, label: label, help: help, value: v[key])
        }
        func on(_ key: String) -> (key: String, values: [SettingValue]) { (key, [.bool(true)]) }
        let mac = displayName
        let agyInstalled = AntigravityBackend.isInstalled(customPath: s.agyPath)

        // Macs
        var remoteEnabled = field("remoteControlEnabled", .toggle, "Remote control",
                                  help: "Lets paired iPhones, Macs, PCs and browsers use this Mac's tabs. Turn it off at the Mac: a paired device would lose its connection.")
        remoteEnabled.access = .atMac
        var httpPort = field("remoteControlPort", .port, "HTTP port",
                             help: "Loopback only, for Tailscale Serve (https → 127.0.0.1:port). Devices that come through Tailscale need Serve pointed at a new port.")
        httpPort.range = 1024...65535
        httpPort.placeholder = "8765"
        httpPort.guarded = true
        httpPort.visibleWhen = on("remoteControlEnabled")
        var lanPort = field("remoteLANPort", .port, "Direct port",
                            help: "The encrypted local-network port. Pin one (for example 8766) to save this Mac's direct address in a client.")
        lanPort.range = 0...65535
        lanPort.zeroLabel = "Automatic"
        lanPort.placeholder = "Automatic"
        lanPort.guarded = true
        lanPort.visibleWhen = on("remoteControlEnabled")
        var lanStatus = SettingsField(key: "remoteLANStatus", kind: .info, label: "Local network",
                                      value: .string(RemoteLANStatusText.describe(s.remoteLANStatus, pinnedPort: s.remoteLANPort,
                                                                                  addresses: RemoteLANAddresses.ipv4())))
        lanStatus.visibleWhen = on("remoteControlEnabled")
        if s.remoteLANStatus?.fellBack == true { lanStatus.tone = "warning" }
        var remoteFields = [remoteEnabled, httpPort, lanPort, lanStatus]
        if let error = s.remoteControlError {
            remoteFields.append(SettingsField(key: "remoteControlError", kind: .info, label: "Problem", value: .string(error), tone: "error"))
        }
        var rotate = SettingsField(key: "rotatePairingToken", kind: .action, label: "Replace Pairing Token",
                                   help: "Every device paired with this Mac has to pair again\(local ? "" : "; this one stays paired").")
        rotate.destructive = true
        rotate.guarded = true
        rotate.confirmation = local
            ? "Every device paired with this Mac has to pair again."
            : "Every other device paired with \(mac) has to pair again. This one stays paired."
        rotate.visibleWhen = on("remoteControlEnabled")
        remoteFields.append(rotate)
        var pairing = SettingsField(key: "showPairingCode", kind: .action, label: "Show Pairing Code",
                                    help: "A code to scan with Cantrip Agent on iPhone, or a link to open in Cantrip Gateway or another Mac's Cantrip.")
        pairing.access = .macApp
        pairing.visibleWhen = on("remoteControlEnabled")
        var watch = field("watchInternetRouteEnabled", .toggle, "Reach Home from Apple Watch over the internet",
                          help: "Off: watches reach this Mac through the iPhone's Tailscale. On: Tailscale Funnel publishes port \(WatchInternetRoute.publicPort) to the internet for signed voice requests from your watches only.")
        watch.visibleWhen = on("cantripHomeEnabled")

        // Models
        var backend = field("backend", .choice, "Backend")
        backend.choices = BackendKind.allCases.map { .init(value: .string($0.rawValue), label: $0.rawValue) }
        let actions = field("allowActions", .toggle, "Act on my behalf",
                            help: "Run what the agent policy doesn't block or ask about, without asking, on every backend. Every tool call is still checked against the policy.")
        var claudeModel = field("claudeModel", .choice, "Model")
        claudeModel.choices = [.init(value: .string(""), label: "Default (account setting)")]
            + Self.unique(AppSettings.claudeModelAliases + s.claudeModelCatalog.map(\.id), current: s.claudeModel)
                .map { .init(value: .string($0), label: $0 == "sonnet[1m]" ? "sonnet[1m] · 1M context" : $0) }
        var claudeEffort = field("claudeEffort", .choice, "Effort")
        claudeEffort.choices = Self.labeled(AppSettings.claudeEffortLevels, current: s.claudeEffort)
        var claudePermissions = field("claudePermissionMode", .choice, "Permissions")
        claudePermissions.choices = Self.labeled(AppSettings.claudePermissionModes, current: s.claudePermissionMode)

        let copilotInfo = s.effectiveCopilotModel.flatMap { s.copilotModelInfo($0) }
        var copilotModel = field("copilotModel", .choice, "Model")
        copilotModel.choices = [.init(value: .string(""), label: "Default (\(s.copilotFileDefaultModel ?? "Copilot's choice"))")]
            + Self.unique(s.copilotModelCatalog.map(\.id), current: s.copilotModel).map { id in
                let context = s.copilotModelInfo(id)?.contextLabel.map { " · \($0)" } ?? ""
                return .init(value: .string(id), label: id + context)
            }
        var copilotEffort = field("copilotEffort", .choice, "Effort")
        let efforts = CopilotModelInfo.choices(supported: copilotInfo?.reasoningEfforts, fallback: s.copilotEffortChoices,
                                               selected: s.copilotEffort)
        copilotEffort.choices = [.init(value: .string(""), label: copilotInfo?.reasoningEfforts == [] ? "Default (effort not supported)" : "Default")]
            + efforts.map { value in
                let name = AppSettings.copilotEffortLevels.first { $0.value == value }?.label ?? value.capitalized
                let unsupported = copilotInfo?.reasoningEfforts?.contains(value) == false
                return .init(value: .string(value), label: name + (unsupported ? " (not supported)" : ""), disabled: unsupported)
            }
        var copilotContext = field("copilotContextTier", .choice, "Context window")
        copilotContext.choices = [.init(value: .string(""), label: "Default (\(s.copilotFileContextTier ?? "standard"))")]
            + CopilotModelInfo.choices(supported: copilotInfo?.contextTiers, fallback: s.copilotContextTierChoices,
                                       selected: s.copilotContextTier).map { tier in
                let unsupported = copilotInfo?.contextTiers?.contains(tier) == false
                let name = tier == "default" ? "Standard" : tier == "long_context" ? "Long" : tier.replacingOccurrences(of: "_", with: " ").capitalized
                let tokens = copilotInfo?.promptTokens(for: tier).map { " · \(CopilotModelInfo.tokenLabel($0)) input" } ?? ""
                return .init(value: .string(tier), label: name + (unsupported ? " (not supported)" : tokens), disabled: unsupported)
            }
        let copilotTools = field("copilotAllowTools", .toggle, "Allow all tools",
                                 help: "--allow-all-tools: Copilot runs commands without asking.")
        let subagents = field("copilotAllowSubagents", .toggle, "Allow subagents",
                              help: "For broad searches, noisy builds and tests, and parallel work. Off removes them.")
        let mcpApps = field("copilotMCPApps", .toggle, "Show MCP App views in chat",
                            help: "Interactive views (Mobbin galleries, for example) inline in replies.")
        let refreshCopilot = SettingsField(key: "refreshCopilotModels", kind: .action, label: "Refresh Models",
                                           help: Self.refreshNote(s.copilotRefreshInFlight, s.copilotModelRefreshError, s.copilotCatalogUpdatedAt))

        let codexSelected = s.codexAvailableModels.first { $0.id == s.codexModel } ?? s.codexAvailableModels.first(where: \.isDefault)
        var codexModel = field("codexModel", .choice, "Model")
        codexModel.choices = [.init(value: .string(""), label: "Default (\(s.codexAvailableModels.first(where: \.isDefault)?.displayName ?? "Codex's choice"))")]
            + Self.unique(s.codexAvailableModels.map(\.id), current: s.codexModel)
                .map { .init(value: .string($0), label: s.codexModelLabel($0)) }
        var codexEffort = field("codexEffort", .choice, "Effort")
        codexEffort.choices = [.init(value: .string(""), label: "Default (\(codexSelected?.defaultEffort?.capitalized ?? "model default"))")]
            + CopilotModelInfo.choices(supported: codexSelected?.efforts, fallback: ["low", "medium", "high"], selected: s.codexEffort)
                .map { .init(value: .string($0), label: $0.capitalized) }
        var codexPermissions = field("codexPermissionMode", .choice, "Permissions")
        codexPermissions.choices = [.init(value: .string("default"), label: "Ask before edits, commands and MCP tools"),
                                    .init(value: .string("bypassPermissions"), label: "Full access (no sandbox, no approvals)")]
        let refreshCodex = SettingsField(key: "refreshCodexModels", kind: .action, label: "Refresh Models",
                                         help: Self.refreshNote(s.codexRefreshInFlight, s.codexModelRefreshError, s.codexCatalogUpdatedAt))

        var agyModel = field("agyModel", .choice, "Model")
        agyModel.choices = [.init(value: .string(""), label: "Default (Auto)")]
            + s.agyModelOptions.map { .init(value: .string($0), label: s.agyModelLabel($0)) }
        var agyEffort = field("agyEffort", .choice, "Effort")
        agyEffort.choices = Self.labeled([("", "Default"), ("low", "Low"), ("medium", "Medium"), ("high", "High")], current: s.agyEffort)
        var agyPermissions = field("agyPermissionMode", .choice, "Permissions")
        agyPermissions.choices = Self.labeled([("default", "Ask before edits and commands"), ("sandbox", "Sandbox (--sandbox)"),
                                               ("bypassPermissions", "Allow everything (--dangerously-skip-permissions)")],
                                              current: s.agyPermissionMode)
        let refreshAgy = SettingsField(key: "refreshAntigravityModels", kind: .action, label: "Refresh Models",
                                       help: Self.refreshNote(s.agyRefreshInFlight, s.agyModelRefreshError, s.agyCatalogUpdatedAt))
        var agyFields = [agyModel, agyEffort, agyPermissions, refreshAgy]
        if agyInstalled {
            agyFields.append(field("agyAuxiliaryRouting", .toggle, "Gemini Flash for routing in every tab",
                                   help: "Routing, queue plans and Done-when checks in tabs on other backends too. Sends those messages to Google."))
        }

        var localURL = field("localBaseURL", .text, "Base URL")
        localURL.placeholder = "http://localhost:8000/v1"
        var localModel = field("localModel", .text, "Model")
        localModel.placeholder = "hermes"
        var localKey = SettingsField(key: "localAPIKey", kind: .secret, label: "API key",
                                     help: "Optional. Saved on the Mac; clients only see whether one is set.")
        localKey.isSet = !s.localAPIKey.isEmpty
        localKey.maxLength = 4096
        localKey.apply = { value in if case .string(let key) = value { s.localAPIKey = key } }
        var localPrompt = field("localSystemPrompt", .text, "System prompt")
        localPrompt.multiline = true
        localPrompt.maxLength = 16_000
        var acp = field("acpAddress", .text, "ACP server (host:port)",
                        help: "A Copilot CLI started with `copilot --acp --port 3000`, reached through a tunnel when it's on another machine.")
        acp.placeholder = "127.0.0.1:3000"

        // Tools
        let endpointOn = field("openAIEndpointEnabled", .toggle, "OpenAI-compatible API for apps on this Mac",
                               help: "Apps call http://127.0.0.1:\(s.openAIEndpointPort)/v1. Each call is stateless and tool-free.")
        var endpointPort = field("openAIEndpointPort", .port, "Port")
        endpointPort.range = 1024...65535
        endpointPort.placeholder = String(OpenAIEndpoint.defaultPort)
        endpointPort.visibleWhen = on("openAIEndpointEnabled")
        var endpointFields = [endpointOn, endpointPort]
        if let reason = OneShotCompletion.unsupportedReason(s.backend) {
            endpointFields.append(SettingsField(key: "openAIEndpointNote", kind: .info, label: "Model",
                                                value: .string("\(reason) Calls go to the usage-limit backups."),
                                                visibleWhen: on("openAIEndpointEnabled"), tone: "warning"))
        } else if s.backend != .localModel {
            endpointFields += Self.endpointModelFields(s, values: v, visibleWhen: on("openAIEndpointEnabled"))
        }
        endpointFields.append(SettingsField(key: "openAIEndpointStatus", kind: .info, label: "Status",
                                            value: .string(s.openAIEndpointStatusText),
                                            visibleWhen: on("openAIEndpointEnabled"),
                                            tone: s.openAIEndpointError == nil ? nil : "error"))
        let hasKey = s.openAIEndpointKey != nil
        var makeKey = SettingsField(key: "makeOpenAIEndpointKey", kind: .action, label: hasKey ? "Replace Proxy Key" : "Make Proxy Key",
                                    help: "Requests through a proxy such as Tailscale Serve need it. \(hasKey ? "A key is set." : "No key is set.") The new key is shown once.")
        makeKey.access = .atMac
        makeKey.visibleWhen = on("openAIEndpointEnabled")
        if hasKey { makeKey.confirmation = "Apps using the current key stop working until they get the new one." }
        endpointFields.append(makeKey)
        if hasKey {
            var removeKey = SettingsField(key: "removeOpenAIEndpointKey", kind: .action, label: "Remove Proxy Key")
            removeKey.destructive = true
            removeKey.confirmation = "Requests through a proxy stop working."
            removeKey.visibleWhen = on("openAIEndpointEnabled")
            endpointFields.append(removeKey)
        }
        func cliPath(_ key: String, _ label: String, _ placeholder: String) -> SettingsField {
            var path = field(key, .path, label)
            path.placeholder = "Automatic (\(placeholder))"
            path.access = .atMac
            return path
        }

        // Home & tabs
        let homeOn = field("cantripHomeEnabled", .toggle, "Cantrip Home",
                           help: "The always-on assistant behind Home's Chat, Tasks and Artifacts. Scheduled tasks need Cantrip running on the Mac.")
        var parallel = field("cantripHomeParallelRuns", .integer, "Background jobs at once",
                             help: "Each scheduled task or incident runs in its own hidden session. Lower it if the Mac is short on memory.")
        parallel.range = 1...Double(CantripHomeBackgroundRunner.maximumParallelLimit)
        parallel.step = 1
        parallel.visibleWhen = on("cantripHomeEnabled")
        parallel.apply = { value in
            if case .int(let runs) = value { s.cantripHomeParallelRuns = runs }
            CantripHomeStore.shared.checkNow()
        }
        let autoFork = field("childTabsAutoFork", .toggle, "Start independent queued messages in child tabs",
                             help: "Each runs in its own tab and git branch and merges back when done.")
        var perParent = field("childTabsPerParentLimit", .integer, "Child tabs per tab")
        perParent.range = 1...Double(ChildTabCapacity.maximumPerParent)
        perParent.step = 1
        var overall = field("childTabsOverallLimit", .integer, "Child tabs in all")
        overall.range = 1...Double(ChildTabCapacity.maximumOverall)
        overall.step = 1
        let buildQueue = field("buildQueueEnabled", .toggle, "Heavy builds take turns",
                               help: "Xcode and Swift builds and test runs that agents, their terminals and this Mac's GitHub runners start wait for a free slot. Your tabs go first, then child tabs and CI jobs, then Home's background runs.")
        var buildSlots = field("buildQueueSlots", .integer, "Builds at once",
                               help: "One at a time while the Mac is busy or short of memory.")
        buildSlots.range = 1...Double(BuildQueue.maximumSlots)
        buildSlots.step = 1
        buildSlots.visibleWhen = on("buildQueueEnabled")
        var workdir = field("claudeWorkdir", .path, "Default working folder",
                            help: "Where new tabs start when they don't name a folder.")
        workdir.access = .atMac
        workdir.placeholder = NSHomeDirectory()
        var idle = field("copilotIdleReleaseMinutes", .choice, "Free an idle Copilot tab's memory after",
                         help: "A tab's Copilot runtime holds 0.5–3 GB. A freed tab picks up on your next message, about 3 seconds slower.")
        idle.choices = AppSettings.copilotIdleReleaseChoices.map { .init(value: .int($0.minutes), label: $0.label) }
        if !AppSettings.copilotIdleReleaseChoices.contains(where: { $0.minutes == s.copilotIdleReleaseMinutes }) {
            idle.choices.append(.init(value: .int(s.copilotIdleReleaseMinutes), label: "\(s.copilotIdleReleaseMinutes) minutes"))
        }
        let previews = field("linkPreviewsEnabled", .toggle, "Link preview cards under replies")

        // Memory
        let memoryOn = field("memoryEnabled", .toggle, "Memory vault",
                             help: "Markdown notes of procedures that worked, read and kept by every backend (Obsidian-compatible).")
        var memoryPath = field("memoryPath", .path, "Vault folder")
        memoryPath.access = .atMac
        memoryPath.placeholder = "\(NSHomeDirectory())/Cantrip Memory"
        memoryPath.visibleWhen = on("memoryEnabled")
        var searchIndex = field("memorySearchIndex", .toggle, "Search memory with a local index",
                                help: "Picks the notes and session entries closest to each message with a full-text index on this Mac (SQLite), instead of counting words. Built from the vault and rebuilt when notes change; turning it off deletes it.")
        searchIndex.visibleWhen = on("memoryEnabled")
        var memoryFields = [memoryOn, memoryPath, searchIndex]
        if agyInstalled {
            var consolidation = field("agyMemoryConsolidation", .toggle, "Consolidate memory with Gemini Flash",
                                      help: "Sends your memory notes to Google through Antigravity.")
            consolidation.visibleWhen = on("memoryEnabled")
            memoryFields.append(consolidation)
        }
        let rag = field("fileRAGEnabled", .toggle, "Search my documents as context",
                        help: "Excerpts from the Mac's Spotlight index that match a prompt.")
        var calendar = field("shareCalendar", .toggle, "Share my calendar as context",
                             help: "The next 48 hours, through Calendar on the Mac.")
        calendar.apply = { value in
            if case .bool(let share) = value { s.shareCalendar = share; if share { CalendarProvider.shared.refresh() } }
        }

        // This Mac's app
        var shareLocation = field("shareLocation", .toggle, "Share this Mac's location",
                                  help: "Prompts from the panel and this window carry where this Mac is (for weather and places). Other devices send their own.")
        shareLocation.access = .macApp
        shareLocation.apply = { value in
            if case .bool(let share) = value { s.shareLocation = share; if share { LocationProvider.shared.refresh() } }
        }
        var interface = field("interfaceMode", .choice, "Open with ⌥Space",
                              help: "⌥Space and the menu bar icon open this; the other stays in the menu bar menu.")
        interface.access = .macApp
        interface.choices = [.init(value: .string(InterfaceMode.panel.rawValue), label: "Panel"),
                             .init(value: .string(InterfaceMode.window.rawValue), label: "Home window",
                                   disabled: !HomeWindow.isAvailable)]
        var opacity = field("panelOpacity", .number, "Panel opacity")
        opacity.access = .macApp
        opacity.range = 0.5...1.0
        opacity.step = 0.05
        opacity.format = "percent"
        var screen = field("attachScreen", .toggle, "Attach the screen when the panel opens",
                           help: "A screenshot goes with the next prompt from the panel.")
        screen.access = .macApp
        var voice = field("voiceMode", .toggle, "Voice mode in the panel",
                          help: "Speaks replies and listens for a follow-up.")
        voice.access = .macApp
        // Read from the system here only: the revision (polled) leaves it out.
        var login = SettingsField(key: "launchAtLogin", kind: .toggle, label: "Open at login", value: .bool(s.launchAtLogin))
        login.access = .macApp
        login.apply = { value in if case .bool(let open) = value { s.launchAtLogin = open } }
        var loginFields = [login]
        if let error = s.launchAtLoginError {
            var problem = SettingsField(key: "launchAtLoginError", kind: .info, label: "Problem", value: .string(error), tone: "error")
            problem.access = .macApp
            loginFields.append(problem)
        }
        loginFields += backgroundEngineFields()

        // About
        var cliStatus = SettingsField(key: "commandLineToolStatus", kind: .info, label: "cantrip command",
                                      value: .string(CantripInstall.commandLineToolStatus()))
        cliStatus.access = .macApp
        var cliFields = [cliStatus]
        switch CantripInstall.commandLineTool() {
        case .missing, .otherCantrip:
            var install = SettingsField(key: "installCommandLineTool", kind: .action, label: "Install Command-Line Tool")
            install.access = .macApp
            cliFields.append(install)
        case .installed, .blocked:
            break
        }
        var desktop = field("remoteDesktopEnabled", .toggle, "Allow paired devices to view and control this Mac",
                            help: "Off by default. Screen Recording and Accessibility must be granted on the Mac. Frames and typed text aren't saved or sent to models.")
        desktop.access = .atMac
        desktop.apply = { value in if case .bool(let enabled) = value { RemoteDesktop.shared.enabled = enabled } }
        var screenSettings = SettingsField(key: "openScreenRecordingSettings", kind: .action, label: "Screen Recording Settings…")
        screenSettings.access = .macApp
        var accessibilitySettings = SettingsField(key: "openAccessibilitySettings", kind: .action, label: "Accessibility Settings…")
        accessibilitySettings.access = .macApp
        let upkeep = field("storageUpkeepEnabled", .toggle, "Clean up unused agent sessions and worktrees daily",
                           help: "Removes session folders and clean, pushed worktrees nothing has used; anything uncommitted, unpushed or open stays. Runs early when free space falls under 20 GB.")
        var retention = field("storageSessionRetentionDays", .integer, "Keep unused sessions for")
        retention.range = Double(StorageUpkeep.sessionRetentionDays.lowerBound)...Double(StorageUpkeep.sessionRetentionDays.upperBound)
        retention.step = 1
        retention.unit = "days"
        retention.visibleWhen = on("storageUpkeepEnabled")
        var simulatorCleanup = field("storageSimulatorCleanup", .toggle,
                                     "Also remove simulators unused for \(SimulatorPool.SweepOptions().unusedDays) days",
                                     help: "Pool simulators are always tidied. This also deletes other simulators nobody used, and ones whose iOS runtime is gone.")
        simulatorCleanup.visibleWhen = on("storageUpkeepEnabled")
        var buildRoot = field("buildRoot", .path, "Build disk",
                              help: "Exported to agents as CANTRIP_BUILD_ROOT for large build output; builds stay local while it isn't mounted.")
        buildRoot.access = .atMac
        buildRoot.placeholder = "None (build locally)"
        let status = StorageUpkeepStatus.shared
        let storageStatus = SettingsField(key: "storageStatus", kind: .info, label: "Last cleanup", value: .string(status.statusText))
        let cleanNow = SettingsField(key: "cleanUpStorageNow", kind: .action, label: status.isRunning ? "Cleaning Up…" : "Clean Up Now")
        func pool(_ key: String, _ label: String, _ range: ClosedRange<Int>, unit: String? = nil) -> SettingsField {
            var item = field(key, .integer, label)
            item.range = Double(range.lowerBound)...Double(range.upperBound)
            item.step = 1
            item.unit = unit
            return item
        }
        var phone = field("simulatorPoolPhone", .text, "iPhone model", help: "The pool's one iPhone, by its simulator device type name.")
        phone.placeholder = "iPhone 17 Pro"
        var phoneOS = field("simulatorPoolPhoneOS", .text, "iPhone iOS version")
        phoneOS.placeholder = "Newest that runs it"
        var duoOS = field("simulatorPoolDuoOS", .text, "iPhone Duo iOS version", help: "When a lease names none.")
        duoOS.placeholder = "Newest"

        var pages: [SettingsPageSpec] = [
            SettingsPageSpec(id: "macs", title: "Macs", sections: [
                SettingsSection(id: "remote", title: "Remote control",
                                footer: "Tailscale Serve reaches the HTTP port from anywhere on your tailnet; on the same network, devices connect directly over an encrypted connection.",
                                fields: remoteFields),
                SettingsSection(id: "pairing", title: "Pair a device", fields: [pairing]),
                SettingsSection(id: "watch", title: "Apple Watch", fields: [watch]),
            ]),
            SettingsPageSpec(id: "models", title: "Models", sections: [
                SettingsSection(id: "defaults", title: "New tabs",
                                footer: "What a tab runs until you pick its own model. Each backend's model is below.",
                                fields: [backend, actions]),
                SettingsSection(id: "claude", title: "Claude Code", link: true,
                                summary: Self.summary([s.claudeModel, s.claudeEffort]), fields: [claudeModel, claudeEffort, claudePermissions]),
                SettingsSection(id: "copilot", title: "Copilot", link: true,
                                summary: Self.summary([s.copilotModel, s.copilotEffort]),
                                fields: [copilotModel, copilotEffort, copilotContext, copilotTools, subagents, mcpApps, refreshCopilot]),
                SettingsSection(id: "codex", title: "Codex", link: true,
                                summary: Self.summary([s.codexModel.isEmpty ? "" : s.codexModelLabel(s.codexModel), s.codexEffort]),
                                fields: [codexModel, codexEffort, codexPermissions, refreshCodex]),
                SettingsSection(id: "antigravity", title: "Antigravity", link: true,
                                summary: Self.summary([s.agyModel.isEmpty ? "" : s.agyModelLabel(s.agyModel), s.agyEffort]),
                                fields: agyFields),
                SettingsSection(id: "local", title: "Local model", link: true, summary: s.localModel,
                                fields: [localURL, localModel, localKey, localPrompt]),
                SettingsSection(id: "copilotRemote", title: "Copilot Remote", link: true, summary: s.acpAddress, fields: [acp]),
            ]),
            SettingsPageSpec(id: "tools", title: "Tools & sign-ins", sections: [
                SettingsSection(id: "endpoint", title: "OpenAI-compatible API",
                                footer: "Apps name themselves with /consumer/NAME/v1 for the usage screen. The model auto uses this Mac's backend, then its backups.",
                                fields: endpointFields),
                SettingsSection(id: "cli", title: "Command-line tools", footer: "Where each agent's CLI is on the Mac.", link: true,
                                summary: "Paths to claude, copilot, codex and agy",
                                fields: [cliPath("claudePath", "claude", "/usr/local/bin/claude"),
                                         cliPath("copilotPath", "copilot", "/opt/homebrew/bin/copilot"),
                                         cliPath("codexPath", "codex", "~/.local/bin/codex"),
                                         cliPath("agyPath", "agy", "~/.local/bin/agy")]),
                SettingsSection(id: "skills", title: "Skills",
                                footer: "Skills live in Cantrip's skills library; `cantrip skills` lists them and which backends see each.",
                                fields: [field("skillsAutoLink", .toggle, "Link new skills automatically",
                                               help: "When a skill in the library is added, changed or removed, Cantrip links it for every backend about a minute later, as `cantrip skills sync` does. A skill with a value that looks like a credential stays unlinked.")]),
            ]),
            SettingsPageSpec(id: "home", title: "Home & tabs", sections: [
                SettingsSection(id: "home", title: "Cantrip Home", fields: [homeOn, parallel]),
                SettingsSection(id: "childTabs", title: "Child tabs",
                                footer: "Run in Child Tab stops at these limits. Auto-start also waits while the Mac is busy, disk is short or no simulator is free.",
                                fields: [autoFork, perParent, overall]),
                SettingsSection(id: "tabs", title: "Tabs", fields: [workdir, idle, previews]),
                SettingsSection(id: "builds", title: "Builds on this Mac",
                                footer: "Each build's card says when it's waiting for a slot. `cantrip build-queue` shows what runs and waits.",
                                fields: [buildQueue, buildSlots]),
            ]),
            SettingsPageSpec(id: "memory", title: "Memory", sections: [
                SettingsSection(id: "memory", title: "Memory", fields: memoryFields),
                SettingsSection(id: "context", title: "Context", fields: [rag, calendar]),
            ]),
            SettingsPageSpec(id: "location", title: "Location", sections: [
                SettingsSection(id: "mac", title: "This Mac", fields: [shareLocation]),
            ]),
            SettingsPageSpec(id: "appearance", title: "Appearance", sections: [
                SettingsSection(id: "panel", title: "Cantrip on this Mac", fields: [interface, opacity, screen, voice]),
            ]),
            SettingsPageSpec(id: "about", title: "About & Updates", sections: [
                SettingsSection(id: "startup", title: "Startup", fields: loginFields),
                SettingsSection(id: "cli", title: "Command-line tool",
                                footer: "Links ~/.local/bin/cantrip to this app's cantrip command, and adds ~/.local/bin to PATH in ~/.zshrc if no startup file has it.",
                                fields: cliFields),
                SettingsSection(id: "access", title: "View Mac", fields: [desktop, screenSettings, accessibilitySettings]),
                SettingsSection(id: "storage", title: "Storage upkeep",
                                fields: [upkeep, retention, simulatorCleanup, buildRoot, storageStatus, cleanNow]),
                SettingsSection(id: "simulators", title: "Simulator pool",
                                footer: "Tabs lease simulators with `cantrip sim acquire`.", link: true,
                                summary: "\(s.simulatorPoolPhone), up to \(s.simulatorPoolMaxBooted) booted",
                                fields: [phone, phoneOS, duoOS,
                                         pool("simulatorPoolMaxBooted", "Booted at once", SimulatorPool.Policy.maxBootedRange),
                                         pool("simulatorPoolMinFreeMemoryGB", "Free memory to boot one", SimulatorPool.Policy.minFreeMemoryRange, unit: "GB"),
                                         pool("simulatorPoolWaitMinutes", "Longest wait for a free one", SimulatorPool.Policy.waitRange, unit: "minutes"),
                                         pool("simulatorPoolIdleMinutes", "Shut down after idle", SimulatorPool.Policy.idleRange, unit: "minutes")]),
            ]),
        ]
        // The background engine's app has no panel yet (`ClientAppDelegate`).
        if HostMode.isEngine {
            let panelOnly: Set<String> = ["interfaceMode", "panelOpacity", "attachScreen", "voiceMode"]
            for index in pages.indices {
                for section in pages[index].sections.indices {
                    pages[index].sections[section].fields.removeAll { panelOnly.contains($0.key) }
                }
                pages[index].sections.removeAll { $0.fields.isEmpty }
            }
            pages.removeAll { $0.sections.isEmpty }
        }
        // Paired devices don't see this Mac's app settings at all.
        if !local {
            for index in pages.indices {
                for section in pages[index].sections.indices {
                    pages[index].sections[section].fields.removeAll { $0.access == .macApp }
                }
                pages[index].sections.removeAll { $0.fields.isEmpty }
            }
            pages.removeAll { $0.sections.isEmpty }
        }
        return pages
    }

    /// About › Startup: "Keep agents running when Cantrip quits" (`BackgroundEngine`), and a line
    /// while a switch waits for tabs or after one failed.
    private static func backgroundEngineFields() -> [SettingsField] {
        var fields: [SettingsField] = []
        let reason = BackgroundEngine.unavailableReason
        if reason == nil || BackgroundEngine.isEnabled || HostMode.isEngine {
            var toggle = SettingsField(key: "backgroundEngine", kind: .toggle, label: "Keep agents running when Cantrip quits",
                                       help: "Tabs, Cantrip Home and paired devices run in a background process that starts at login, so quitting or updating Cantrip doesn't stop them. Switching waits until nothing is working.",
                                       value: .bool(BackgroundEngine.isEnabled))
            toggle.access = .macApp
            toggle.apply = { value in if case .bool(let on) = value { BackgroundEngine.setEnabled(on) } }
            fields.append(toggle)
            if let status = BackgroundEngine.status(busy: HostServices.running?.busyWork ?? 0) {
                var line = SettingsField(key: "backgroundEngineStatus", kind: .info, label: "Background agents",
                                         value: .string(status.text), tone: status.tone)
                line.access = .macApp
                fields.append(line)
            }
        } else if let reason {
            var line = SettingsField(key: "backgroundEngineStatus", kind: .info, label: "Background agents", value: .string(reason))
            line.access = .macApp
            fields.append(line)
        }
        return fields
    }

    private static func endpointModelFields(_ s: AppSettings, values v: [String: SettingValue],
                                            visibleWhen: (key: String, values: [SettingValue])) -> [SettingsField] {
        let primary = s.backend
        let catalog = s.tabModelCatalog(for: primary)
        let tiers = s.tierOptions(for: primary)
        var model = SettingsField(key: "openAIEndpointModel", kind: .choice, label: "Model", value: v["openAIEndpointModel"])
        model.choices = [.init(value: .string(""), label: "Same as tabs")]
            + tiers.map { .init(value: .string(OpenAIEndpointModel.name(primary, model: $0.id)), label: "\($0.label) — \($0.modelLabel)") }
            + catalog.models.map { .init(value: .string(OpenAIEndpointModel.name(primary, model: $0.id)),
                                         label: s.fallbackModelLabel(primary, $0.id)) }
        if !s.openAIEndpointModel.isEmpty, !model.choices.contains(where: { $0.value == .string(s.openAIEndpointModel) }) {
            model.choices.append(.init(value: .string(s.openAIEndpointModel), label: "\(s.openAIEndpointModel) (not offered now)"))
        }
        model.visibleWhen = visibleWhen
        var chosen = ""
        if case .backend(let kind, let name) = OpenAIEndpointModel.parse(s.openAIEndpointModel), kind == primary { chosen = name }
        let info = s.tabModelChoices(for: primary).first { $0.id == chosen } ?? catalog.info(chosen)
        var fields = [model]
        if let efforts = info?.reasoningEfforts, !efforts.isEmpty {
            var effort = SettingsField(key: "openAIEndpointEffort", kind: .choice, label: "Effort", value: v["openAIEndpointEffort"])
            effort.choices = [.init(value: .string(""), label: "Same as tabs")]
                + Self.unique(efforts, current: s.openAIEndpointEffort).map { .init(value: .string($0), label: $0) }
            effort.visibleWhen = visibleWhen
            fields.append(effort)
        }
        if primary == .copilot, let contexts = info?.contextTiers, !contexts.isEmpty {
            var context = SettingsField(key: "openAIEndpointContextTier", kind: .choice, label: "Context", value: v["openAIEndpointContextTier"])
            context.choices = [.init(value: .string(""), label: "Same as tabs")]
                + Self.unique(contexts, current: s.openAIEndpointContextTier).map { .init(value: .string($0), label: $0) }
            context.visibleWhen = visibleWhen
            fields.append(context)
        }
        return fields
    }

    private static func unique(_ items: [String], current: String) -> [String] {
        var seen = Set<String>()
        return (items + [current.trimmingCharacters(in: .whitespaces)]).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Fixed choices plus the saved value when it isn't one of them (set from a settings file).
    private static func labeled(_ items: [(value: String, label: String)], current: String) -> [SettingsField.Choice] {
        var choices = items.map { SettingsField.Choice(value: .string($0.value), label: $0.label) }
        if !items.contains(where: { $0.value == current }) { choices.append(.init(value: .string(current), label: current)) }
        return choices
    }

    private static func summary(_ parts: [String]) -> String {
        let shown = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return shown.isEmpty ? "Default" : shown.joined(separator: " · ")
    }

    private static func refreshNote(_ busy: Bool, _ error: String?, _ date: Date?) -> String {
        if busy { return "Refreshing the model list…" }
        if let error { return "\(error) Cached models are unchanged." }
        if let date { return "Models refreshed \(date.formatted(date: .abbreviated, time: .shortened))." }
        return "Reads the model list from the CLI. No chat or model request is made."
    }

    /// The Mac's name as people know it ("Studio"), not its network name.
    static var displayName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? HostControl.hostName
    }

    // MARK: - JSON

    static func manifest(_ s: AppSettings = .shared, local: Bool) -> [String: Any] {
        var object: [String: Any] = [
            "version": version,
            "revision": revision(s),
            "mac": displayName,
            "local": local,
            "pages": pages(s, local: local).map { page in
                ["id": page.id, "title": page.title, "sections": page.sections.map { section -> [String: Any] in
                    var item: [String: Any] = ["id": section.id, "title": section.title,
                                               "fields": section.fields.map { $0.json(local: local) }]
                    if let footer = section.footer { item["footer"] = footer }
                    if section.link { item["link"] = true }
                    if let summary = section.summary { item["summary"] = summary }
                    return item
                }] as [String: Any]
            },
        ]
        if let pending { object["pending"] = pendingJSON(pending) }
        return object
    }

    private static func pendingJSON(_ pending: Pending, now: Date = Date()) -> [String: Any] {
        ["id": pending.id, "keys": pending.keys, "summary": pending.summary,
         "secondsLeft": max(0, Int(pending.deadline.timeIntervalSince(now).rounded(.up))),
         "revertsAt": ISODate.string(from: pending.deadline)]
    }

    // MARK: - Changes

    /// Answers a POST; returns the manifest after it (and `result` for actions).
    static func handle(_ json: [String: Any], settings s: AppSettings = .shared, local: Bool) async throws -> [String: Any] {
        if let id = json["keep"] as? String {
            guard let held = pending, held.id == id else {
                throw SettingsManifestError(status: 409, message: "That change was already undone. Make it again if you still want it.")
            }
            finishPending()
            Log.write("settings: kept \(held.summary)")
            return manifest(s, local: local)
        }
        if let id = json["revert"] as? String {
            if pending?.id == id { revert(reason: "undone from a paired device", settings: s) }
            return manifest(s, local: local)
        }
        if let action = json["action"] as? String {
            let result = try await perform(action, settings: s, local: local)
            var object = manifest(s, local: local)
            if !result.isEmpty { object["result"] = result }
            return object
        }
        guard let changes = json["changes"] as? [String: Any], !changes.isEmpty else {
            throw SettingsManifestError(status: 400, message: "Send changes with the revision you loaded, or an action.")
        }
        guard let revision = json["revision"] as? String else {
            throw SettingsManifestError(status: 400, message: "Provide the revision you loaded.")
        }
        guard revision == self.revision(s) else {
            throw SettingsManifestError(status: 409, message: "Settings changed on another device. They've been reloaded; try again.")
        }
        try apply(changes, settings: s, local: local)
        return manifest(s, local: local)
    }

    /// Checks every change first, then saves them all; nothing is saved when one is refused.
    static func apply(_ changes: [String: Any], settings s: AppSettings = .shared, local: Bool) throws {
        let fields = Dictionary(pages(s, local: local).flatMap { $0.sections.flatMap(\.fields) }.map { ($0.key, $0) },
                                uniquingKeysWith: { first, _ in first })
        var checked: [(SettingsField, SettingValue)] = []
        var problems: [String: String] = [:]
        for (key, raw) in changes.sorted(by: { $0.key < $1.key }) {
            guard let field = fields[key], ![.action, .info].contains(field.kind) else {
                problems[key] = "There's no setting \(key) to change."
                continue
            }
            if let reason = field.readOnlyReason(local: local) {
                problems[key] = reason
                continue
            }
            do { checked.append((field, try check(raw, for: field))) }
            catch let error as SettingsManifestError { problems[key] = error.message }
        }
        let port = checked.first { $0.0.key == "remoteControlPort" }?.1 ?? .int(s.remoteControlPort)
        let lan = checked.first { $0.0.key == "remoteLANPort" }?.1 ?? .int(s.remoteLANPort)
        if port == lan, checked.contains(where: { ["remoteControlPort", "remoteLANPort"].contains($0.0.key) }) {
            problems["remoteLANPort"] = "The direct port can't be the HTTP port."
        }
        guard problems.isEmpty else {
            throw SettingsManifestError(status: 422, message: problems.count == 1 ? problems.values.first! : "Some settings weren't saved.",
                                        fields: problems)
        }
        let guardedKeys = local ? [] : checked.filter { $0.0.guarded && values(s)[$0.0.key] != $0.1 }.map(\.0.key)
        if !guardedKeys.isEmpty, pending != nil {
            throw SettingsManifestError(status: 409, message: "Keep or undo the last connection change first.")
        }
        let before = values(s)
        for (field, value) in checked where before[field.key] != value || field.kind == .secret {
            save(field, value, settings: s)
        }
        let changed = checked.map(\.0.key).filter { before[$0] != values(s)[$0] }
        if !changed.isEmpty {
            Log.write("settings: \(local ? "Cantrip's Settings window" : "a paired device") changed \(changed.joined(separator: ", "))")
        }
        if !guardedKeys.isEmpty {
            let summary = guardedKeys.map { key in
                "\(fields[key]?.label ?? key) \(values(s)[key].map(display) ?? "")"
            }.joined(separator: ", ")
            hold(Pending(id: UUID().uuidString, keys: guardedKeys, summary: summary,
                         previous: before.filter { guardedKeys.contains($0.key) }, previousToken: nil,
                         deadline: Date().addingTimeInterval(revertSeconds)), settings: s)
        }
    }

    private static func display(_ value: SettingValue) -> String {
        if case .int(0) = value { return "Automatic" }
        if case .string(let text) = value { return text }
        return "\(value.json)"
    }

    private static func check(_ raw: Any, for field: SettingsField) throws -> SettingValue {
        func refuse(_ message: String) -> SettingsManifestError { SettingsManifestError(status: 422, message: message) }
        guard let value = SettingValue(json: raw) else { throw refuse("\(field.label) needs a value.") }
        switch field.kind {
        case .toggle:
            guard case .bool = value else { throw refuse("\(field.label) is on or off.") }
            return value
        case .choice:
            let match = field.choices.first { choice in
                choice.value == value || (choice.value.json as? Int).map { value == .double(Double($0)) } == true
            }
            guard let match, !match.disabled else { throw refuse("Choose one of \(field.label)'s options.") }
            return match.value
        case .integer, .port:
            let number: Int
            switch value {
            case .int(let whole): number = whole
            case .double(let decimal) where decimal == decimal.rounded(): number = Int(decimal)
            case .string(let text) where Int(text.trimmingCharacters(in: .whitespaces)) != nil:
                number = Int(text.trimmingCharacters(in: .whitespaces))!
            case .string(let text) where field.zeroLabel != nil && text.trimmingCharacters(in: .whitespaces).isEmpty:
                number = 0
            default: throw refuse("\(field.label) is a whole number.")
            }
            let range = field.range ?? 0...Double(Int.max)
            guard range.contains(Double(number)) || (number == 0 && field.zeroLabel != nil) else {
                if field.kind == .port, field.zeroLabel != nil {
                    throw refuse("\(field.label) is \(Int(max(range.lowerBound, 1)))–\(Int(range.upperBound)), or empty for \(field.zeroLabel!.lowercased()).")
                }
                throw refuse("\(field.label) is \(Int(range.lowerBound))–\(Int(range.upperBound)).")
            }
            return .int(number)
        case .number:
            let number: Double
            switch value {
            case .int(let whole): number = Double(whole)
            case .double(let decimal) where decimal.isFinite: number = decimal
            default: throw refuse("\(field.label) is a number.")
            }
            guard field.range?.contains(number) ?? true else { throw refuse("\(field.label) is out of range.") }
            return .double(number)
        case .text, .path, .secret:
            guard case .string(let text) = value else { throw refuse("\(field.label) is text.") }
            guard text.count <= field.maxLength else { throw refuse("\(field.label) is too long.") }
            if field.kind == .path || !field.multiline {
                guard !text.contains("\n") else { throw refuse("\(field.label) is one line.") }
            }
            return .string(field.kind == .path ? text.trimmingCharacters(in: .whitespaces) : text)
        case .action, .info:
            throw refuse("\(field.label) can't be set.")
        }
    }

    private static func save(_ field: SettingsField, _ value: SettingValue, settings s: AppSettings) {
        if let apply = field.apply {
            apply(value)
        } else {
            s.applySettings([field.key: value.json])
        }
    }

    // MARK: - Guarded changes

    private static func hold(_ change: Pending, settings s: AppSettings) {
        revertWork?.cancel()
        pending = change
        let id = change.id
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard pending?.id == id else { return }
                revert(reason: "not kept within \(Int(revertSeconds)) seconds", settings: s)
            }
        }
        revertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + revertSeconds, execute: work)
        Log.write("settings: holding \(change.summary) until a paired device keeps it")
    }

    private static func finishPending() {
        revertWork?.cancel()
        revertWork = nil
        pending = nil
    }

    private static func revert(reason: String, settings s: AppSettings) {
        guard let held = pending else { return }
        finishPending()
        if let token = held.previousToken {
            if !s.replaceRemoteControlToken(with: token) {
                Log.write("settings: couldn't restore the previous pairing token")
            }
        }
        let fields = Dictionary(pages(s, local: true).flatMap { $0.sections.flatMap(\.fields) }.map { ($0.key, $0) },
                                uniquingKeysWith: { first, _ in first })
        for (key, value) in held.previous {
            if let field = fields[key] { save(field, value, settings: s) } else { s.applySettings([key: value.json]) }
        }
        Log.write("settings: undid \(held.summary) (\(reason))")
    }

    // MARK: - Actions

    private static func perform(_ key: String, settings s: AppSettings, local: Bool) async throws -> [String: Any] {
        let fields = pages(s, local: local).flatMap { $0.sections.flatMap(\.fields) }
        guard let field = fields.first(where: { $0.key == key && $0.kind == .action }) else {
            throw SettingsManifestError(status: 422, message: "There's no action \(key).")
        }
        if let reason = field.readOnlyReason(local: local) { throw SettingsManifestError(status: 422, message: reason) }
        switch key {
        case "rotatePairingToken":
            if !local, pending != nil {
                throw SettingsManifestError(status: 409, message: "Keep or undo the last connection change first.")
            }
            let previous = s.remoteControlToken
            guard let token = AppSettings.makePairingToken() else {
                throw SettingsManifestError(status: 500, message: "Couldn't make a new pairing token.")
            }
            Log.write("settings: \(local ? "Cantrip's Settings window" : "a paired device") replaced the pairing token")
            if local {
                guard s.replaceRemoteControlToken(with: token) else {
                    throw SettingsManifestError(status: 500, message: s.remoteControlError ?? "Couldn't save the new pairing token.")
                }
                return ["message": "Replaced. Pair your devices again."]
            }
            // After this reply is on its way: the server then switches tokens and listeners.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard s.replaceRemoteControlToken(with: token) else {
                        if pending?.previousToken != nil { finishPending() }
                        return
                    }
                }
            }
            hold(Pending(id: UUID().uuidString, keys: ["pairingToken"], summary: "the new pairing token", previous: [:],
                         previousToken: previous.isEmpty ? nil : previous,
                         deadline: Date().addingTimeInterval(revertSeconds)), settings: s)
            return ["message": "Replaced. Other devices have to pair again.", "pairingToken": token]
        case "showPairingCode":
            let port = s.remoteControlPort
            let url = await Task.detached { Tailscale.serveURL(forPort: port) }.value
            let direct = s.remoteLANStatus.flatMap { status in RemoteLANAddresses.ipv4().first.map { "\($0):\(status.port)" } }
            let token = s.remoteControlToken
            guard !token.isEmpty else {
                throw SettingsManifestError(status: 500, message: s.remoteControlError ?? "The pairing token isn't available.")
            }
            let link = CantripCLI.pairingLink(name: HostControl.hostName, token: token, url: url, direct: direct)
            return ["title": "Pair with \(displayName)",
                    "message": "Scan with the iPhone camera, or open the link on the device. Anyone with it can use this Mac's agents.",
                    "link": link, "qr": true]
        case "makeOpenAIEndpointKey":
            guard let key = s.generateOpenAIEndpointKey() else {
                throw SettingsManifestError(status: 500, message: "The Keychain didn't save the key.")
            }
            return ["message": "Copy the new key now: Cantrip won't show it again.", "copy": key]
        case "removeOpenAIEndpointKey":
            s.clearOpenAIEndpointKey()
            return ["message": "Removed."]
        case "refreshCopilotModels":
            s.refreshCopilotModels()
            return ["message": "Refreshing Copilot's models."]
        case "refreshCodexModels":
            s.refreshCodexModels()
            return ["message": "Refreshing Codex's models."]
        case "refreshAntigravityModels":
            s.refreshAntigravityModels()
            return ["message": "Refreshing Antigravity's models."]
        case "installCommandLineTool":
            do {
                return ["message": try CantripInstall.installCommandLineTool()]
            } catch {
                throw SettingsManifestError(status: 422, message: error.localizedDescription)
            }
        case "cleanUpStorageNow":
            let status = StorageUpkeepStatus.shared
            if !status.isRunning { status.runNow() }
            return ["message": "Cleaning up. Results show under Last cleanup."]
        case "openScreenRecordingSettings":
            ScreenCapture.shared.requestAccess()
            try? MacAttention.shared.openSettings(.screenRecording)
            return [:]
        case "openAccessibilitySettings":
            if !AXIsProcessTrusted() {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            try? MacAttention.shared.openSettings(.accessibility)
            return [:]
        default:
            throw SettingsManifestError(status: 422, message: "There's no action \(key).")
        }
    }
}

/// The key Cantrip's own Home and Settings windows send (header `X-Cantrip-Local-Key`) so the
/// server knows a request is this Mac's app and not a paired device: Tailscale Serve's requests
/// arrive on loopback too. Made fresh each launch and handed to the window in-process.
enum LocalClientKey {
    static let value: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    static let header = "x-cantrip-local-key"

    static func matches(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        let lhs = Array(candidate.utf8), rhs = Array(value.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
