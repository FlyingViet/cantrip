import Foundation

/// One backup in the usage-limit chain: a backend and the model and effort it runs ("" = the
/// backend's default). The chain is unique by backend and model, so a backend whose models have
/// their own limits (Antigravity, Claude's model tiers) can be listed again with another model.
/// `model` can name a tier (`ModelTier`): the backup then runs that tier's model on its backend.
/// A backup left on its default model follows the run's tier when the run has one.
struct FallbackEntry: Codable, Hashable {
    var backend: String
    var model: String = ""
    var effort: String = ""

    var kind: BackendKind? { BackendKind(rawValue: backend) }

    /// The model and effort as a selection; nil when both are the backend's default.
    var selection: SessionModelSelection? {
        model.isEmpty && effort.isEmpty ? nil : SessionModelSelection(model: model, effort: effort, contextTier: "")
    }
}

/// What a usage-limit backup runs with: the model and effort chosen for it in the backup chain,
/// checked against the backend's real model list when the run starts.
struct FallbackRun: Equatable {
    let backend: BackendKind
    /// nil when no model or effort was chosen: the backend runs as it would on its own.
    let selection: SessionModelSelection?
    /// For the run's note, e.g. "Claude Code · claude-opus-5.5 · high".
    let label: String
    /// The tier it runs, when the backup is pinned to one or follows the run's.
    var tier: ModelTier? = nil
}

extension AppSettings {
    /// Backends whose backups can be pinned to a model and effort: the ones with a model picker.
    static var fallbackModelBackends: Set<BackendKind> { tabModelBackends }

    /// A model's name as the pickers show it.
    func fallbackModelLabel(_ kind: BackendKind, _ id: String) -> String {
        switch kind {
        case .antigravity: return agyModelLabel(id)
        case .codex: return codexModelLabel(id)
        default: return id
        }
    }

    /// The model a backend runs when `chosen` is empty: the Mac's own setting for it, or the CLI's
    /// default when Cantrip knows it ("" when it doesn't).
    func effectiveModel(_ kind: BackendKind, chosen: String) -> String {
        let trimmed = chosen.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty else { return trimmed }
        guard Self.tabModelBackends.contains(kind) else { return kind == .localModel ? localModel : "" }
        let mac = tabModelDefaults(for: kind).model.trimmingCharacters(in: .whitespaces)
        return mac.isEmpty ? (tabModelCatalog(for: kind).fileDefaultModel ?? "") : mac
    }

    /// A backend's first entry in the chain, for callers that name only the backend.
    func fallbackRun(for kind: BackendKind) -> FallbackRun {
        fallbackRun(for: limitFallbackEntries.first { $0.backend == kind.rawValue } ?? FallbackEntry(backend: kind.rawValue))
    }

    /// The backup's model and effort, or its default when the chosen model is no longer offered.
    /// A tier runs its first model the backend offers that isn't at its own limit.
    func fallbackRun(for entry: FallbackEntry, tracker: BackendLimitTracker = .shared) -> FallbackRun {
        let kind = entry.kind ?? .copilot
        if let tier = ModelTier(model: entry.model), Self.tierBackends.contains(kind) {
            let resolved = resolveTier(tier, on: kind, effort: entry.effort, tracker: tracker)
            // None of the tier's models offered: the Mac's own model for the backend.
            let defaults = tabModelDefaults(for: kind)
            let selection = resolved.model.isEmpty
                ? SessionModelSelection(model: defaults.model, effort: defaults.effort, contextTier: "") : resolved.selection
            return FallbackRun(backend: kind, selection: selection,
                               label: "\(kind.rawValue) · \(tierLabel(resolved))" + (resolved.skipped.map { " (\($0))" } ?? ""),
                               tier: tier)
        }
        guard Self.fallbackModelBackends.contains(kind), let chosen = entry.selection else {
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
