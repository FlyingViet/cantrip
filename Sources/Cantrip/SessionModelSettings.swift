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
    var defaultModelSelection: SessionModelSelection {
        SessionModelSelection(model: settings.copilotModel, effort: settings.copilotEffort,
                              contextTier: settings.copilotContextTier)
    }

    var modelSelection: SessionModelSelection { tabMetadata.modelSettings ?? defaultModelSelection }

    var modelSettingsUnavailableReason: String? {
        if settings.backend != .copilot || councilMode {
            return "Per-tab model settings require the Mac's Copilot backend with Council mode off."
        }
        if isStreaming || !queued.isEmpty || shell.isRunning {
            return "Wait for this tab and its queued work to finish before changing model settings."
        }
        return nil
    }

    var modelSettingsRevision: String {
        let selection = modelSelection
        let fields = [settings.backend.rawValue, String(councilMode),
                      String(tabMetadata.modelSettings == nil),
                      selection.model, selection.effort, selection.contextTier,
                      settings.copilotFileDefaultModel ?? "", settings.copilotFileContextTier ?? "",
                      settings.copilotPath]
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var modelSettingsSnapshot: SessionModelSettingsSnapshot {
        SessionModelSettingsSnapshot(
            selection: modelSelection, defaults: defaultModelSelection,
            usesDefaults: tabMetadata.modelSettings == nil, revision: modelSettingsRevision,
            models: settings.copilotModelCatalog, fileDefaultModel: settings.copilotFileDefaultModel,
            fileDefaultContextTier: settings.copilotFileContextTier,
            unavailableReason: modelSettingsUnavailableReason,
            catalogError: settings.copilotModelRefreshError, isRefreshing: settings.copilotRefreshInFlight
        )
    }

    func updateModelSettings(_ selection: SessionModelSelection?, revision: String) throws {
        guard revision == modelSettingsRevision else {
            throw SessionModelSettingsError(409, "Model settings changed on another device. Reload before saving.")
        }
        if let reason = modelSettingsUnavailableReason { throw SessionModelSettingsError(409, reason) }
        try selection?.validate(catalog: settings.copilotModelCatalog,
                                fileDefaultModel: settings.copilotFileDefaultModel)
        try saveModelSelection(selection)
    }
}
