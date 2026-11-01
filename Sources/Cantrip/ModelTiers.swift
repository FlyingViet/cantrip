import Foundation

/// A level of model a tab, Home task, child tab, backup or endpoint request can ask for instead of
/// a model name. Each backend maps every tier to an ordered list of its own models
/// (`ModelTierMap`), so a run keeps its level when it moves to another backend, and changing a
/// tier's model is one edit that applies everywhere. The names are reserved: no backend offers a
/// model called fast, standard or deep, so a tier and a model name never collide.
enum ModelTier: String, CaseIterable, Codable, Sendable {
    case fast, standard, deep

    /// The tier a model field names ("deep", "Deep"), nil for a model name.
    init?(model: String) {
        self.init(rawValue: model.trimmingCharacters(in: .whitespaces).lowercased())
    }

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// One model in a tier and the effort it runs at ("" = the model's default).
struct ModelTierChoice: Codable, Hashable, Sendable {
    var model: String
    var effort: String = ""
}

/// Each backend's models per tier, first choice first. Only edited cells are saved; a backend and
/// tier without one uses `defaults`, so a new build's defaults reach every cell nobody changed.
struct ModelTierMap: Codable, Equatable {
    /// BackendKind raw value → tier raw value → choices.
    var overrides: [String: [String: [ModelTierChoice]]] = [:]

    /// Backends with a model picker; Local Model runs its one model for every tier and Copilot
    /// Remote runs its server's model.
    static let backends: [BackendKind] = [.copilot, .claudeCode, .antigravity, .codex]
    static let maximumChoices = 5

    /// Only models each backend really offers. Claude Code's aliases always point at the newest
    /// model of each family, and Antigravity's names carry their effort. Codex's row comes from its
    /// `model/list`: gpt-6-luna is its default and cheapest model, gpt-5.6-terra its strongest.
    static let defaults: [BackendKind: [ModelTier: [ModelTierChoice]]] = [
        .copilot: [
            .fast: [.init(model: "claude-haiku-5.5", effort: "low"), .init(model: "gpt-5.6-sol-fast", effort: "low"),
                    .init(model: "mai-code-2-flash", effort: "low")],
            .standard: [.init(model: "gpt-5.6-sol", effort: "high"), .init(model: "claude-sonnet-5.5", effort: "high"),
                        .init(model: "gpt-6-sol", effort: "high")],
            .deep: [.init(model: "claude-opus-5.5", effort: "xhigh"), .init(model: "gpt-6.1-sol", effort: "xhigh"),
                    .init(model: "gpt-6-astra", effort: "xhigh")],
        ],
        .claudeCode: [
            .fast: [.init(model: "haiku", effort: "low")],
            .standard: [.init(model: "sonnet", effort: "high")],
            .deep: [.init(model: "opus", effort: "xhigh")],
        ],
        .antigravity: [
            .fast: [.init(model: "gemini-3.8-flash-medium"), .init(model: "gemini-3.8-flash-low")],
            .standard: [.init(model: "gemini-4-argon-medium"), .init(model: "claude-sonnet-5-5-medium")],
            .deep: [.init(model: "gemini-4-argon-high"), .init(model: "claude-opus-5-5-high")],
        ],
        .codex: [
            .fast: [.init(model: "gpt-6-luna", effort: "low"), .init(model: "gpt-5.6-luna", effort: "low")],
            .standard: [.init(model: "gpt-6-luna", effort: "medium"), .init(model: "gpt-5.6-terra", effort: "medium")],
            .deep: [.init(model: "gpt-5.6-terra", effort: "xhigh"), .init(model: "gpt-6-luna", effort: "xhigh")],
        ],
    ]

    static func defaultChoices(_ tier: ModelTier, on kind: BackendKind) -> [ModelTierChoice] {
        defaults[kind]?[tier] ?? []
    }

    func choices(_ tier: ModelTier, on kind: BackendKind) -> [ModelTierChoice] {
        overrides[kind.rawValue]?[tier.rawValue] ?? Self.defaultChoices(tier, on: kind)
    }

    func isDefault(_ tier: ModelTier, on kind: BackendKind) -> Bool {
        overrides[kind.rawValue]?[tier.rawValue] == nil
    }

    /// Sets one cell; nil, or the default list, goes back to the default.
    mutating func set(_ choices: [ModelTierChoice]?, for tier: ModelTier, on kind: BackendKind) {
        var row = overrides[kind.rawValue] ?? [:]
        row[tier.rawValue] = choices == Self.defaultChoices(tier, on: kind) ? nil : choices
        overrides[kind.rawValue] = row.isEmpty ? nil : row
    }

    /// Known backends and tiers only, each cell with 1-5 distinct models that aren't tier names.
    static func cleaned(_ raw: [String: [String: [ModelTierChoice]]]) -> ModelTierMap {
        var map = ModelTierMap()
        for (backend, row) in raw {
            guard let kind = BackendKind(rawValue: backend), backends.contains(kind) else { continue }
            for (name, choices) in row {
                guard let tier = ModelTier(rawValue: name) else { continue }
                var seen = Set<String>()
                let list = choices.map {
                    ModelTierChoice(model: $0.model.trimmingCharacters(in: .whitespaces),
                                    effort: $0.effort.trimmingCharacters(in: .whitespaces).lowercased())
                }.filter { !$0.model.isEmpty && ModelTier(model: $0.model) == nil && seen.insert($0.model).inserted }
                guard !list.isEmpty else { continue }
                map.set(Array(list.prefix(maximumChoices)), for: tier, on: kind)
            }
        }
        return map
    }
}

/// The model a tier runs on one backend now: its first choice the backend offers and that isn't at
/// its own usage limit.
struct ModelTierResolution: Equatable {
    let tier: ModelTier
    let backend: BackendKind
    /// "" when none of the tier's models is offered: the backend's default model runs.
    let model: String
    let effort: String
    /// Why the run isn't on the tier's first choice ("Gemini 4 Argon (High) is at its usage limit
    /// until 9:40 PM, so Claude Opus 5.5 (High)"); nil when it is.
    let note: String?
    /// The skipped models alone ("Gemini 4 Argon (High) is at its usage limit until 9:40 PM").
    var skipped: String? = nil

    var selection: SessionModelSelection { SessionModelSelection(model: model, effort: effort, contextTier: "") }
}

extension AppSettings {
    /// Backends whose runs can ask for a tier.
    static var tierBackends: Set<BackendKind> { Set(ModelTierMap.backends) }

    func tierChoices(_ tier: ModelTier, on kind: BackendKind) -> [ModelTierChoice] {
        modelTiers.choices(tier, on: kind)
    }

    /// The tier's model on `kind`. A choice the backend doesn't offer, or whose own quota is used
    /// up (Claude's Opus limit, an Antigravity model group), is skipped for the next one; a limit
    /// on the whole backend (Copilot's shared quota) is left to the backup chain. `effort` is the
    /// tab's or task's own pick, used when the model takes it.
    func resolveTier(_ tier: ModelTier, on kind: BackendKind, effort requested: String = "",
                     tracker: BackendLimitTracker = .shared, now: Date = Date()) -> ModelTierResolution {
        if kind == .localModel {
            return ModelTierResolution(tier: tier, backend: kind, model: localModel, effort: "", note: nil)
        }
        guard Self.tierBackends.contains(kind) else {
            return ModelTierResolution(tier: tier, backend: kind, model: "", effort: "", note: nil)
        }
        let catalog = tabModelCatalog(for: kind)
        let choices = tierChoices(tier, on: kind)
        // An empty list hasn't loaded yet: trust the choices.
        let ids = Set(catalog.models.map(\.id))
        let offered = choices.filter { ids.isEmpty || ids.contains($0.model) }
        let backendLimited = tracker.limitedUntil(kind, now: now) != nil
        var skipped: [(choice: ModelTierChoice, reason: String)] = []
        var picked: ModelTierChoice?
        for choice in choices {
            guard offered.contains(choice) else {
                skipped.append((choice, "isn't offered"))
                continue
            }
            if !backendLimited, let until = tracker.limitedUntil(kind, model: choice.model, now: now) {
                skipped.append((choice, "is at its usage limit until \(BackendFallback.untilLabel(until, now: now))"))
                continue
            }
            picked = choice
            break
        }
        // Every offered model at its own limit: the first one runs, and the chain moves on from it.
        if picked == nil, let first = offered.first {
            picked = first
            skipped = Array(skipped.prefix { $0.choice != first })
        }
        let reasons = skipped.map { "\(fallbackModelLabel(kind, $0.choice.model)) \($0.reason)" }.joined(separator: ", ")
        guard let choice = picked else {
            let note = choices.isEmpty ? nil : "\(reasons), so \(backendLabel(kind))'s default model"
            return ModelTierResolution(tier: tier, backend: kind, model: "", effort: "", note: note,
                                       skipped: choices.isEmpty ? nil : reasons)
        }
        let efforts = catalog.info(choice.model)?.reasoningEfforts
        func takes(_ effort: String) -> Bool { !effort.isEmpty && (efforts == nil || efforts?.contains(effort) == true) }
        let wanted = requested.trimmingCharacters(in: .whitespaces).lowercased()
        let effort = takes(wanted) ? wanted : takes(choice.effort) ? choice.effort : ""
        let note = skipped.isEmpty ? nil : "\(reasons), so \(fallbackModelLabel(kind, choice.model))"
        return ModelTierResolution(tier: tier, backend: kind, model: choice.model, effort: effort, note: note,
                                   skipped: skipped.isEmpty ? nil : reasons)
    }

    /// A model field's model on `kind`: a tier resolves to its model there, anything else is the
    /// model itself ("" for the backend's default).
    func resolvedModel(_ kind: BackendKind, chosen: String, tracker: BackendLimitTracker = .shared) -> String {
        guard let tier = ModelTier(model: chosen) else { return chosen }
        return resolveTier(tier, on: kind, tracker: tracker).model
    }

    /// "Deep · claude-opus-5.5 · xhigh", for labels and run notes.
    func tierLabel(_ resolution: ModelTierResolution) -> String {
        var parts = [resolution.tier.label]
        parts.append(resolution.model.isEmpty ? "default model" : fallbackModelLabel(resolution.backend, resolution.model))
        if !resolution.effort.isEmpty { parts.append(resolution.effort) }
        return parts.joined(separator: " · ")
    }

    /// What each tier runs on `kind` now, for the tab model picker.
    func tierOptions(for kind: BackendKind) -> [ModelTierOption] {
        guard Self.tierBackends.contains(kind) else { return [] }
        return ModelTier.allCases.map { tier in
            let resolved = resolveTier(tier, on: kind)
            return ModelTierOption(id: tier.rawValue, label: tier.label, model: resolved.model,
                                   modelLabel: resolved.model.isEmpty ? "default model" : fallbackModelLabel(kind, resolved.model),
                                   effort: resolved.effort, note: resolved.note)
        }
    }

    /// The tab model picker's list: the tiers first, each with its model's efforts, then the
    /// backend's models.
    func tabModelChoices(for kind: BackendKind) -> [CopilotModelInfo] {
        let catalog = tabModelCatalog(for: kind)
        guard Self.tierBackends.contains(kind) else { return catalog.models }
        let tiers = ModelTier.allCases.map { tier -> CopilotModelInfo in
            let model = resolveTier(tier, on: kind).model
            return CopilotModelInfo(id: tier.rawValue, reasoningEfforts: catalog.info(model)?.reasoningEfforts, contextTiers: [])
        }
        return tiers + catalog.models
    }
}
