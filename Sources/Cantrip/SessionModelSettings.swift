import Foundation
import CryptoKit

struct SessionModelSelection: Codable, Equatable {
    var model: String
    var effort: String
    var contextTier: String

    func validate(catalog: [CopilotModelInfo], fileDefaultModel: String?) throws {
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

struct SessionModelSettingsSnapshot: Encodable {
    let selection: SessionModelSelection
    let defaults: SessionModelSelection
    let usesDefaults: Bool
    let revision: String
    let models: [CopilotModelInfo]
    let fileDefaultModel: String?
    let fileDefaultContextTier: String?
    let unavailableReason: String?
    let catalogError: String?
    let isRefreshing: Bool
}

extension ChatSession {
    /// The backend whose model list this tab's settings use (Claude Code or Antigravity when the
    /// Mac runs one, Copilot otherwise).
    var modelSettingsBackend: BackendKind { settings.tabModelBackend }

    var modelCatalog: TabModelCatalog { settings.tabModelCatalog(for: modelSettingsBackend) }

    var defaultModelSelection: SessionModelSelection { settings.tabModelDefaults(for: modelSettingsBackend) }

    /// This tab's own settings for the current backend, nil when it follows the Mac's.
    var ownModelSelection: SessionModelSelection? { tabMetadata.modelSettings(for: modelSettingsBackend) }

    var modelSelection: SessionModelSelection { ownModelSelection ?? defaultModelSelection }

    var modelSettingsUnavailableReason: String? {
        if isLocalPrivate { return "Use Private Local Settings. This tab cannot use Copilot or Mac model defaults." }
        if !AppSettings.tabModelBackends.contains(settings.backend) || councilMode {
            return "Per-tab model settings require the Mac's Copilot, Claude Code or Antigravity backend with Council mode off."
        }
        if isStreaming || !queued.isEmpty || shell.isRunning {
            return "Wait for this tab and its queued work to finish before changing model settings."
        }
        return nil
    }

    var modelSettingsRevision: String {
        let selection = modelSelection
        let catalog = modelCatalog
        let path: String
        switch modelSettingsBackend {
        case .claudeCode: path = settings.claudePath
        case .antigravity: path = settings.agyPath
        default: path = settings.copilotPath
        }
        let fields = [settings.backend.rawValue, String(councilMode),
                      String(ownModelSelection == nil),
                      selection.model, selection.effort, selection.contextTier,
                      catalog.fileDefaultModel ?? "", catalog.fileDefaultContextTier ?? "",
                      path]
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var modelSettingsSnapshot: SessionModelSettingsSnapshot {
        let catalog = modelCatalog
        return SessionModelSettingsSnapshot(
            selection: modelSelection, defaults: defaultModelSelection,
            usesDefaults: ownModelSelection == nil, revision: modelSettingsRevision,
            models: catalog.models, fileDefaultModel: catalog.fileDefaultModel,
            fileDefaultContextTier: catalog.fileDefaultContextTier,
            unavailableReason: modelSettingsUnavailableReason,
            catalogError: catalog.refreshError, isRefreshing: catalog.isRefreshing
        )
    }

    func updateModelSettings(_ selection: SessionModelSelection?, revision: String) throws {
        guard revision == modelSettingsRevision else {
            throw SessionModelSettingsError(409, "Model settings changed on another device. Reload before saving.")
        }
        if let reason = modelSettingsUnavailableReason { throw SessionModelSettingsError(409, reason) }
        let catalog = modelCatalog
        try selection?.validate(catalog: catalog.models, fileDefaultModel: catalog.fileDefaultModel)
        try saveModelSelection(selection)
    }
}
