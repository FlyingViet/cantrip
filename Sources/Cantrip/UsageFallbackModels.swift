import Foundation

/// What a usage-limit backup runs with: the model and effort chosen for it in the backup chain,
/// checked against the backend's real model list when the run starts.
struct FallbackRun: Equatable {
    let backend: BackendKind
    /// nil when no model or effort was chosen: the backend runs as it would on its own.
    let selection: SessionModelSelection?
    /// For the run's note, e.g. "Claude Code · claude-opus-5.5 · high".
    let label: String
}

extension AppSettings {
    /// Backends whose backups can be pinned to a model and effort: the ones with a model picker.
    static var fallbackModelBackends: Set<BackendKind> { tabModelBackends }

    /// A model's name as the pickers show it.
    func fallbackModelLabel(_ kind: BackendKind, _ id: String) -> String {
        kind == .antigravity ? agyModelLabel(id) : id
    }

    /// The backup's model and effort, or its default when the chosen model is no longer offered.
    func fallbackRun(for kind: BackendKind) -> FallbackRun {
        guard Self.fallbackModelBackends.contains(kind), let chosen = limitFallbackModels[kind.rawValue],
              !(chosen.model.isEmpty && chosen.effort.isEmpty) else {
            return FallbackRun(backend: kind, selection: nil, label: backendLabel(kind))
        }
        let catalog = tabModelCatalog(for: kind)
        var model = chosen.model
        var effort = chosen.effort
        var note = ""
        // An empty list hasn't loaded yet: trust the choice rather than drop it.
        if !model.isEmpty, !catalog.models.isEmpty, !catalog.models.contains(where: { $0.id == model }) {
            note = " (\(fallbackModelLabel(kind, model)) isn't available now, so its default model)"
            model = ""
            effort = ""
        }
        // "Default" means the Mac's own setting for that backend, as when it runs on its own.
        let defaults = tabModelDefaults(for: kind)
        if model.isEmpty { model = defaults.model }
        if effort.isEmpty { effort = defaults.effort }
        if !effort.isEmpty, let efforts = catalog.info(model)?.reasoningEfforts, !efforts.contains(effort) {
            effort = ""
        }
        var parts = [kind.rawValue]
        parts.append(model.isEmpty ? "default model" : fallbackModelLabel(kind, model))
        if !effort.isEmpty { parts.append(effort) }
        return FallbackRun(backend: kind, selection: SessionModelSelection(model: model, effort: effort, contextTier: ""),
                           label: parts.joined(separator: " · ") + note)
    }
}
