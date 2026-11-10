import Foundation
import CryptoKit

struct SessionModelSelection: Codable, Equatable {
    var model: String
    var effort: String
    var contextTier: String

    func validate(catalog: [CopilotModelInfo], fileDefaultModel: String?) throws {
        // A tier runs its own models' context windows; its effort applies where its model takes it.
        if ModelTier(model: model) != nil {
            let efforts = Set(catalog.flatMap { $0.reasoningEfforts ?? [] })
            guard effort.isEmpty || efforts.isEmpty || efforts.contains(effort) else {
                throw SessionModelSettingsError(400, "Choose a supported effort or the tier's own.")
            }
            guard contextTier.isEmpty else {
                throw SessionModelSettingsError(400, "A model tier uses its models' default context window.")
            }
            return
        }
        let modelID = model.isEmpty ? fileDefaultModel : model
        let info = catalog.first { $0.id == modelID }
        guard model.isEmpty || info != nil else {
            throw SessionModelSettingsError(400, "This model is not in the Mac's catalog. Reload the options.")
        }
        guard effort.isEmpty || info?.reasoningEfforts?.contains(effort) == true else {
            throw SessionModelSettingsError(400, "Choose a supported effort or Model default.")
        }
        guard contextTier.isEmpty || info?.contextTiers?.contains(contextTier) == true else {
            throw SessionModelSettingsError(400, "Choose a supported context window or CLI default.")
        }
    }
}

struct SessionModelSettingsError: LocalizedError {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    var errorDescription: String? { message }
}

/// A tier as the tab model picker offers it: what it runs on this backend now.
struct ModelTierOption: Encodable, Equatable {
    /// "fast", "standard" or "deep", the value a selection's `model` takes.
    let id: String
    let label: String
    /// The backend's model for it now ("" = the backend's default) and its effort.
    let model: String
    let modelLabel: String
    let effort: String
    /// Why it isn't on the tier's first model, if it isn't.
    let note: String?
}

/// A backend a tab can run on instead of the Mac's.
struct TabBackendChoice: Encodable, Equatable {
    /// The backend's name, as `BackendKind` and the usage-fallback API spell it ("Claude Code").
    let id: String
    let label: String
    /// False when its CLI isn't installed on the Mac.
    let available: Bool
    /// Why it may not run now (not installed, signed out, at its usage limit).
    let note: String?
}

/// A model settings save's backend: unchanged, back to the Mac's, or one of `AppSettings.tabBackends`.
enum TabBackendChange: Equatable {
    case unchanged
    case mac
    case backend(BackendKind)
}

struct SessionModelSettingsSnapshot: Encodable {
    /// The backend these settings are for: the tab's, or the one asked about (`?backend=`).
    let backend: String
    /// The tab's own backend; nil when it follows the Mac's.
    let ownBackend: String?
    let macBackend: String
    /// What the tab can run on besides the Mac's backend; empty when it can't choose (Cantrip Home).
    let backends: [TabBackendChoice]
    /// Why the backend can't change now (the tab is working, Council mode); nil when it can.
    let backendUnavailableReason: String?
    let selection: SessionModelSelection
    let defaults: SessionModelSelection
    let usesDefaults: Bool
    let revision: String
    /// The tiers first (ids "fast", "standard", "deep", with their model's efforts), so clients
    /// that list `models` offer them too, then the backend's models.
    let models: [CopilotModelInfo]
    /// What each tier runs on this backend now.
    let tiers: [ModelTierOption]
    let fileDefaultModel: String?
    let fileDefaultContextTier: String?
    let unavailableReason: String?
    let catalogError: String?
    let isRefreshing: Bool
}

extension ChatSession {
    /// The backend whose model list this tab's settings use: the tab's backend, or Copilot's list
    /// when it runs on one without per-tab models.
    var modelSettingsBackend: BackendKind { AppSettings.tabModelBackend(for: effectiveBackendKind) }

    var modelCatalog: TabModelCatalog { settings.tabModelCatalog(for: modelSettingsBackend) }

    var defaultModelSelection: SessionModelSelection { settings.tabModelDefaults(for: modelSettingsBackend) }

    /// This tab's own settings for the current backend, nil when it follows the Mac's.
    var ownModelSelection: SessionModelSelection? { tabMetadata.modelSettings(for: modelSettingsBackend) }

    var modelSelection: SessionModelSelection { ownModelSelection ?? defaultModelSelection }

    /// Whether this tab can run on a backend of its own (Cantrip Home and Private Local can't).
    var supportsTabBackend: Bool {
        !isLocalPrivate && !isCantripHomeBackground && !SessionManager.isCantripHomeReserved(self)
    }

    /// Why this tab's backend and model can't change now, or nil.
    var tabSettingsBusyReason: String? {
        if councilMode { return "Turn Council mode off to choose this tab's backend and model." }
        if isStreaming || !queued.isEmpty || shell.isRunning {
            return "Wait for this tab and its queued work to finish before changing model settings."
        }
        return nil
    }

    var modelSettingsUnavailableReason: String? { modelSettingsUnavailableReason(on: effectiveBackendKind) }

    /// Why the model can't be chosen for this tab running on `backend`, or nil.
    func modelSettingsUnavailableReason(on backend: BackendKind) -> String? {
        if isLocalPrivate { return "Use Private Local Settings. This tab cannot use Copilot or Mac model defaults." }
        if !AppSettings.tabModelBackends.contains(backend) {
            return supportsTabBackend
                ? "\(backend.rawValue) has no per-tab models. Choose Copilot, Claude Code, Codex or Antigravity for this tab."
                : "Per-tab model settings require the Mac's Copilot, Claude Code, Codex or Antigravity backend with Council mode off."
        }
        return tabSettingsBusyReason
    }

    /// The backends this tab can choose, with whether each can run now.
    var tabBackendChoices: [TabBackendChoice] {
        guard supportsTabBackend else { return [] }
        return AppSettings.tabBackends.map { kind in
            let status = MonitoredBackend(kind: kind).flatMap { BackendStatusMonitor.shared.status($0) }
            let note: String?
            switch status?.state {
            case .notInstalled: note = "Not installed on the Mac"
            case .signedOut: note = "Signed out on the Mac"
            case .outOfQuota: note = "At its usage limit"
            default: note = nil
            }
            return TabBackendChoice(id: kind.rawValue, label: kind.rawValue,
                                    available: status?.state != .notInstalled, note: note)
        }
    }

    var modelSettingsRevision: String {
        let selection = modelSelection
        let catalog = modelCatalog
        let path: String
        switch modelSettingsBackend {
        case .claudeCode: path = settings.claudePath
        case .antigravity: path = settings.agyPath
        case .codex: path = settings.codexPath
        default: path = settings.copilotPath
        }
        let fields = [settings.backend.rawValue, tabMetadata.backend?.rawValue ?? "mac", String(councilMode),
                      String(ownModelSelection == nil),
                      selection.model, selection.effort, selection.contextTier,
                      catalog.fileDefaultModel ?? "", catalog.fileDefaultContextTier ?? "",
                      path]
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var modelSettingsSnapshot: SessionModelSettingsSnapshot { modelSettingsSnapshot(on: nil) }

    /// This tab's settings as they are, or as they'd be on `backend` (nothing is saved): its own
    /// model for that backend, else the Mac's.
    func modelSettingsSnapshot(on backend: BackendKind?) -> SessionModelSettingsSnapshot {
        let runsOn = backend ?? effectiveBackendKind
        let kind = AppSettings.tabModelBackend(for: runsOn)
        let catalog = settings.tabModelCatalog(for: kind)
        let defaults = settings.tabModelDefaults(for: kind)
        let own = tabMetadata.modelSettings(for: kind)
        return SessionModelSettingsSnapshot(
            backend: runsOn.rawValue, ownBackend: tabMetadata.backend?.rawValue, macBackend: settings.backend.rawValue,
            backends: tabBackendChoices, backendUnavailableReason: supportsTabBackend ? tabSettingsBusyReason : nil,
            selection: own ?? defaults, defaults: defaults,
            usesDefaults: own == nil, revision: modelSettingsRevision,
            models: settings.tabModelChoices(for: kind), tiers: settings.tierOptions(for: kind),
            fileDefaultModel: catalog.fileDefaultModel,
            fileDefaultContextTier: catalog.fileDefaultContextTier,
            unavailableReason: modelSettingsUnavailableReason(on: runsOn),
            catalogError: catalog.refreshError, isRefreshing: catalog.isRefreshing
        )
    }

    /// Saves this tab's backend and its model for that backend. `keepsSelection` changes only the
    /// backend: the tab runs the model it last chose there (or the Mac's).
    func updateModelSettings(_ selection: SessionModelSelection?, revision: String,
                             backend change: TabBackendChange = .unchanged, keepsSelection: Bool = false) throws {
        guard revision == modelSettingsRevision else {
            throw SessionModelSettingsError(409, "Model settings changed on another device. Reload before saving.")
        }
        var updated = tabMetadata
        switch change {
        case .unchanged: break
        case .mac: updated.backend = nil
        case .backend(let kind):
            guard AppSettings.tabBackends.contains(kind) else {
                throw SessionModelSettingsError(400, "A tab can run on Copilot, Claude Code, Codex or Antigravity.")
            }
            updated.backend = kind
        }
        if change != .unchanged {
            guard supportsTabBackend else {
                throw SessionModelSettingsError(409, "Cantrip Home runs on the Mac's backend. Change it in Settings.")
            }
            if let reason = tabSettingsBusyReason { throw SessionModelSettingsError(409, reason) }
        }
        let runsOn = isLocalPrivate ? BackendKind.localModel : updated.backend ?? settings.backend
        let kind = AppSettings.tabModelBackend(for: runsOn)
        if !keepsSelection {
            if let reason = modelSettingsUnavailableReason(on: runsOn) { throw SessionModelSettingsError(409, reason) }
            let catalog = settings.tabModelCatalog(for: kind)
            try selection?.validate(catalog: catalog.models, fileDefaultModel: catalog.fileDefaultModel)
            var saved = selection
            if let tier = selection.flatMap({ ModelTier(model: $0.model) }) { saved?.model = tier.rawValue }
            updated.setModelSettings(saved, for: kind)
        }
        if updated.backend != tabMetadata.backend {
            Log.write("tab \(id.uuidString.prefix(8)): backend \(updated.backend?.rawValue ?? "Mac's (\(settings.backend.rawValue))")")
        }
        try saveTabMetadata(updated)
        applyModelSelection()
    }
}
