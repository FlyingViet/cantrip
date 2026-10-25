import Foundation

/// A Home task's own Copilot model and effort. Tasks without one follow Home's selection.
enum CantripHomeTaskModels {
    /// The model and settings a hidden run uses, and why it fell back to Home's model.
    struct Resolution: Equatable {
        /// Set only when the run's selection differs from Home's.
        let selection: SessionModelSelection?
        /// The model ID the run is recorded with.
        let model: String
        let note: String?
    }

    /// IDs the model picker offers; empty until the Mac has loaded its Copilot catalog.
    static func offered(_ settings: AppSettings) -> [String] {
        var ids = settings.copilotModelCatalog.map(\.id)
        for id in settings.copilotAvailableModels where !ids.contains(id) { ids.append(id) }
        return ids
    }

    /// Validates a task block's `model` and `effort`: nil keeps the saved value and "" clears
    /// it. Returns the values to store.
    static func validated(
        model: String?, effort: String?, saved: (model: String?, effort: String?),
        settings: AppSettings
    ) throws -> (model: String?, effort: String?) {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEffort = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nextModel = trimmedModel.map { $0.isEmpty ? nil : $0 } ?? saved.model
        let nextEffort = trimmedEffort.map { $0.isEmpty ? nil : $0 } ?? saved.effort
        let offered = offered(settings)
        if let trimmedModel, !trimmedModel.isEmpty {
            let wellFormed = trimmedModel.count <= 80
                && trimmedModel.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil
            guard wellFormed, offered.isEmpty || offered.contains(trimmedModel) else {
                throw CantripHomeError(
                    400, "Unknown model \(trimmedModel). Use one the model picker offers: "
                        + offered.joined(separator: ", ") + "."
                )
            }
        }
        if let trimmedEffort, !trimmedEffort.isEmpty {
            let target = nextModel ?? homeSelection(settings: settings).model
            let advertised = settings.copilotModelInfo(target)?.reasoningEfforts
            let supported = advertised ?? settings.copilotEffortChoices
            let unknown = advertised == nil && supported.isEmpty
                && trimmedEffort.range(of: #"^[a-z_]{1,20}$"#, options: .regularExpression) != nil
            guard unknown || supported.contains(trimmedEffort) else {
                throw CantripHomeError(
                    400, "\(target) doesn't support effort \(trimmedEffort). Use "
                        + (supported.isEmpty ? "\"\"" : supported.joined(separator: ", ") + ", or \"\"")
                        + " for the model's default."
                )
            }
        }
        return (nextModel, nextEffort)
    }

    /// Home's selection, which every task without its own model follows.
    static func homeSelection(settings: AppSettings) -> SessionModelSelection {
        SessionTabMetadata.load(id: ChatSession.cantripHomeID).modelSettings
            ?? SessionModelSelection(model: settings.copilotModel, effort: settings.copilotEffort,
                                     contextTier: settings.copilotContextTier)
    }

    static func resolve(task: CantripHomeTask?, settings: AppSettings) -> Resolution {
        let home = homeSelection(settings: settings)
        let homeModel = home.model.isEmpty
            ? (settings.copilotFileDefaultModel ?? "Copilot's default model") : home.model
        guard let task, task.model != nil || task.effort != nil else {
            return .init(selection: nil, model: homeModel, note: nil)
        }
        guard settings.backend == .copilot else {
            return .init(
                selection: nil, model: settings.backend.rawValue,
                note: "Ran with Home's \(settings.backend.rawValue) backend: task models need Copilot."
            )
        }
        let offered = offered(settings)
        if let model = task.model, !offered.isEmpty, !offered.contains(model) {
            return .init(
                selection: nil, model: homeModel,
                note: "Ran on Home's model, \(homeModel): \(model) isn't available on this Mac right now."
            )
        }
        let model = task.model ?? home.model
        let info = settings.copilotModelInfo(task.model ?? homeModel)
        // Home's effort and context window carry over when the task's model supports them.
        var effort = task.effort ?? home.effort
        if let efforts = info?.reasoningEfforts, !effort.isEmpty, !efforts.contains(effort) {
            effort = ""
        }
        var tier = home.contextTier
        if let tiers = info?.contextTiers, !tier.isEmpty, !tiers.contains(tier) { tier = "" }
        return .init(
            selection: .init(model: model, effort: effort, contextTier: tier),
            model: task.model ?? homeModel, note: nil
        )
    }
}
