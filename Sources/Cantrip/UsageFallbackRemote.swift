import Foundation
import CryptoKit

/// `GET/POST /api/v1/usage-fallback`: the Mac-wide backups a run moves through, in order, when
/// the backend and model it's on report a usage limit, for paired clients. Each entry is a backend
/// with the model and effort it runs; a backend can be listed again with another model (the Mac's
/// own backend too, with a model other than its own). A model can be a tier ("deep"), listed
/// first in each choice's models: the backup then runs its backend's model for the tier, and an
/// entry on its default model follows a tier run's tier.
///
/// POST `{"entries","revision"}` replaces the chain. `{"backends","revision"}` (clients that know
/// only backends) replaces the order and keeps each entry's model: a backend's entries are reused
/// in order and any it lists fewer times stay after it, so duplicates never collapse.
/// `{"backend","revision"}` from the oldest clients sets the first backup ("" = off).
/// `{"resetLimits":true,"revision"}` lets every backend and model be tried again now.
struct UsageFallbackSnapshot: Encodable, Equatable {
    struct Choice: Encodable, Equatable {
        let id: String
        let label: String
        /// The models a backup on this backend can use, from the tab model picker's list; nil when
        /// the backend has no picker (it always runs its default).
        var models: [ModelChoice]? = nil
        /// Efforts for its default model; nil when unknown.
        var defaultEfforts: [String]? = nil
        /// The Mac's own model for this backend, which "default" means; nil for the CLI's default.
        var defaultModel: String? = nil
        /// The same model's ID, to tell a backend's entries apart; nil when only the CLI knows it.
        var defaultModelID: String? = nil
    }
    struct ModelChoice: Encodable, Equatable {
        let id: String
        let label: String
        /// Efforts the model accepts; empty when it takes none, nil when unknown.
        let efforts: [String]?
    }
    /// A backup and what it runs with; "" model or effort = the backend's default. The other
    /// fields are read-only (sending them back is fine).
    struct Entry: Codable, Equatable {
        let backend: String
        var model: String = ""
        var effort: String = ""
        /// "Antigravity · Gemini 4 Argon (High) · high", as run notes name it.
        var label: String? = nil
        /// When this backup can be used again, if its backend or model is at its limit.
        var limitedUntil: String? = nil
        var limitedUntilLabel: String? = nil
    }
    struct Limited: Encodable, Equatable {
        let backend: String
        let until: String
        let untilLabel: String
    }
    /// One model quota at its limit (Claude's weekly Opus limit, an Antigravity model group).
    struct LimitedModels: Encodable, Equatable {
        let backend: String
        /// `BackendLimitTracker.modelScope`: "opus", "argon", "gemini", "claude-gpt", ...
        let scope: String
        /// "Opus models", "Gemini 4 Argon".
        let label: String
        let until: String
        let untilLabel: String
    }
    /// The backups' BackendKind rawValues in the order they're tried (a backend twice when it's
    /// listed twice), empty when off.
    let backends: [String]
    /// The same chain with each backup's model and effort.
    let entries: [Entry]
    /// The first backup, "" when off, for clients from before the chain.
    let backend: String
    /// The Mac's backend.
    let primary: String
    /// Backends to add, without the Mac's own (see `primaryChoice`).
    let choices: [Choice]
    /// The Mac's own backend, to list it again with another of its models; nil without a model picker.
    let primaryChoice: Choice?
    /// Whole backends at their limit.
    let limited: [Limited]
    /// Model quotas at their limit; their backend's other models still run.
    let limitedModels: [LimitedModels]
    let revision: String
}

struct UsageFallbackError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum UsageFallbackRemote {
    static func snapshot(settings: AppSettings = .shared, tracker: BackendLimitTracker = .shared,
                         now: Date = Date()) -> UsageFallbackSnapshot {
        let limited = BackendKind.allCases.compactMap { kind -> UsageFallbackSnapshot.Limited? in
            tracker.limitedUntil(kind, now: now).map {
                .init(backend: kind.rawValue, until: ISODate.string(from: $0),
                      untilLabel: BackendFallback.untilLabel($0, now: now))
            }
        }
        let limitedModels = tracker.scopeLimits(now: now).map {
            UsageFallbackSnapshot.LimitedModels(backend: $0.backend.rawValue, scope: $0.scope,
                                                label: scopeLabel($0.backend, scope: $0.scope),
                                                until: ISODate.string(from: $0.until),
                                                untilLabel: BackendFallback.untilLabel($0.until, now: now))
        }
        func choice(_ kind: BackendKind) -> UsageFallbackSnapshot.Choice {
            var choice = UsageFallbackSnapshot.Choice(id: kind.rawValue, label: settings.backendLabel(kind))
            guard AppSettings.fallbackModelBackends.contains(kind) else { return choice }
            let catalog = settings.tabModelCatalog(for: kind)
            // The tiers first ("deep" runs the backend's deep model), so older clients offer them too.
            let tiers = settings.tierOptions(for: kind).map { tier -> UsageFallbackSnapshot.ModelChoice in
                .init(id: tier.id, label: "\(tier.label) (\(tier.modelLabel))", efforts: catalog.info(tier.model)?.reasoningEfforts)
            }
            choice.models = tiers + catalog.models.map {
                .init(id: $0.id, label: settings.fallbackModelLabel(kind, $0.id), efforts: $0.reasoningEfforts)
            }
            let defaults = settings.tabModelDefaults(for: kind)
            choice.defaultModel = defaults.model.isEmpty ? nil : settings.fallbackModelLabel(kind, defaults.model)
            let effective = settings.effectiveModel(kind, chosen: "")
            choice.defaultModelID = effective.isEmpty ? nil : effective
            choice.defaultEfforts = catalog.info(defaults.model)?.reasoningEfforts
            return choice
        }
        let choices = BackendKind.allCases.filter { $0 != settings.backend }.map(choice)
        let primaryChoice = AppSettings.fallbackModelBackends.contains(settings.backend) ? choice(settings.backend) : nil
        let entries = settings.limitFallbackEntries.map { entry -> UsageFallbackSnapshot.Entry in
            var item = UsageFallbackSnapshot.Entry(backend: entry.backend, model: entry.model, effort: entry.effort,
                                                   label: settings.fallbackRun(for: entry).label)
            if let kind = entry.kind,
               let until = tracker.limitedUntil(kind, model: settings.effectiveModel(kind, chosen: settings.resolvedModel(kind, chosen: entry.model, tracker: tracker)),
                                                now: now) {
                item.limitedUntil = ISODate.string(from: until)
                item.limitedUntilLabel = BackendFallback.untilLabel(until, now: now)
            }
            return item
        }
        let chain = entries.map(\.backend)
        let fields = [chain.joined(separator: ","), settings.backend.rawValue]
            + entries.map { "\($0.backend)=\($0.model)/\($0.effort)/\($0.limitedUntil ?? "")" }
            + limited.map { "\($0.backend)=\($0.until)" }
            + limitedModels.map { "\($0.backend)/\($0.scope)=\($0.until)" }
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let revision = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(backends: chain, entries: entries, backend: chain.first ?? "", primary: settings.backend.rawValue,
                     choices: choices, primaryChoice: primaryChoice, limited: limited, limitedModels: limitedModels,
                     revision: revision)
    }

    /// "Opus models", or the Antigravity group's own name from its last usage read.
    static func scopeLabel(_ kind: BackendKind, scope: String) -> String {
        if kind == .antigravity, let group = UsageTracker.shared.copilotUsage.antigravity?.account?.groups
            .first(where: { BackendLimitTracker.antigravityScope(group: $0.name) == scope }) {
            return group.name
        }
        switch scope {
        case "claude-gpt": return "Claude and GPT models"
        case "argon": return "Gemini 4 Argon"
        case "gemini": return "Gemini models"
        default: return scope.prefix(1).uppercased() + scope.dropFirst() + " models"
        }
    }

    static func apply(_ json: [String: Any], settings: AppSettings = .shared,
                      tracker: BackendLimitTracker = .shared, now: Date = Date()) throws -> UsageFallbackSnapshot {
        guard let revision = json["revision"] as? String else {
            throw UsageFallbackError(status: 400, message: "Provide the revision you loaded.")
        }
        guard revision == snapshot(settings: settings, tracker: tracker, now: now).revision else {
            throw UsageFallbackError(status: 409, message: "The fallback changed on another device. Reload before saving.")
        }
        let keys = Set(json.keys)
        if keys == ["revision", "resetLimits"], json["resetLimits"] as? Bool == true {
            tracker.clear()
            Log.write("usage-limit: a paired client cleared every backend's limit")
        } else if keys == ["revision", "entries"], let raw = json["entries"] as? [[String: Any]] {
            let entries = try validatedEntries(raw, settings: settings)
            settings.limitFallbackEntries = entries
            Log.write("usage-limit: a paired client set the fallbacks to " + describe(entries, settings: settings))
        } else if keys == ["revision", "backends"], let backends = json["backends"] as? [String] {
            guard backends.allSatisfy({ BackendKind(rawValue: $0) != nil }) else {
                throw UsageFallbackError(status: 400, message: "Choose from the listed backends.")
            }
            let entries = AppSettings.entries(forBackends: backends, current: settings.limitFallbackEntries,
                                              remembered: settings.limitFallbackModels)
            try checkUnique(entries, settings: settings, hint: " Choose its model in a client that shows models.")
            settings.limitFallbackEntries = entries
            Log.write("usage-limit: a paired client set the fallbacks to " + describe(entries, settings: settings))
        } else if keys == ["revision", "backend"], let backend = json["backend"] as? String {
            guard backend.isEmpty || BackendKind(rawValue: backend) != nil else {
                throw UsageFallbackError(status: 400, message: "Choose Off or one of the listed backends.")
            }
            guard backend != settings.backend.rawValue else {
                throw UsageFallbackError(status: 400, message: "A backend can't fall back on itself. Choose another one.")
            }
            // An older client only sees the first backup: replace that one with this backend's
            // first entry (or a new one), and keep the rest as they are.
            if backend.isEmpty {
                settings.limitFallbackEntries = []
            } else {
                var rest = Array(settings.limitFallbackEntries.dropFirst())
                let chosen = rest.firstIndex { $0.backend == backend }.map { rest.remove(at: $0) }
                    ?? AppSettings.entries(forBackends: [backend], current: [], remembered: settings.limitFallbackModels)[0]
                settings.limitFallbackEntries = [chosen] + rest
            }
            Log.write("usage-limit: a paired client set the first fallback to \(backend.isEmpty ? "off" : backend)")
        } else {
            throw UsageFallbackError(status: 400, message: "Send revision with entries, backends, backend or resetLimits: true.")
        }
        return snapshot(settings: settings, tracker: tracker, now: now)
    }

    static func describe(_ entries: [FallbackEntry], settings: AppSettings) -> String {
        entries.isEmpty ? "off" : entries.map { settings.fallbackRun(for: $0).label }.joined(separator: " → ")
    }

    /// Known backends with a model the backend offers and an effort that model takes, each backend
    /// and model once; the Mac's own backend only with a model other than its own.
    static func validatedEntries(_ raw: [[String: Any]], settings: AppSettings) throws -> [FallbackEntry] {
        let entries = try raw.map { item -> FallbackEntry in
            // A snapshot's read-only fields may come back with the entry.
            guard Set(item.keys).isSubset(of: ["backend", "model", "effort", "label", "limitedUntil", "limitedUntilLabel"]),
                  let backend = item["backend"] as? String, let kind = BackendKind(rawValue: backend),
                  item["model"] == nil || item["model"] is String, item["effort"] == nil || item["effort"] is String else {
                throw UsageFallbackError(status: 400, message: "Each entry needs a listed backend, and model and effort as text.")
            }
            var model = (item["model"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let effort = (item["effort"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard AppSettings.fallbackModelBackends.contains(kind) || (model.isEmpty && effort.isEmpty) else {
                throw UsageFallbackError(status: 400, message: "\(backend) runs its default model; it has no model or effort to choose.")
            }
            let catalog = settings.tabModelCatalog(for: kind)
            let tier = ModelTier(model: model)
            if let tier { model = tier.rawValue }
            if !model.isEmpty, tier == nil, !catalog.models.contains(where: { $0.id == model }) {
                throw UsageFallbackError(status: 400, message: "\(backend) doesn't offer \(model). Choose one of its listed models or a tier.")
            }
            // A tier's effort is checked against the model it runs now.
            let runs = model.isEmpty ? settings.tabModelDefaults(for: kind).model : settings.resolvedModel(kind, chosen: model)
            let efforts = catalog.info(runs)?.reasoningEfforts
            if !effort.isEmpty, let efforts, !efforts.contains(effort) {
                throw UsageFallbackError(status: 400, message: "That model doesn't take \(effort) effort.")
            }
            return FallbackEntry(backend: backend, model: model, effort: effort)
        }
        try checkUnique(entries, settings: settings)
        return entries
    }

    /// Each backend and model once (a default model counts as the model it runs), and the Mac's
    /// own backend only with another model.
    static func checkUnique(_ entries: [FallbackEntry], settings: AppSettings, hint: String = "") throws {
        var seen = Set<FallbackEntry>()
        let primaryModel = settings.effectiveModel(settings.backend, chosen: "")
        for entry in entries {
            guard let kind = entry.kind else { continue }
            let model = settings.effectiveModel(kind, chosen: entry.model)
            if kind == settings.backend, model == primaryModel {
                throw UsageFallbackError(status: 400, message: kind.rawValue + (model.isEmpty ? "" : " · \(settings.fallbackModelLabel(kind, model))")
                    + " is the Mac's own backend and model; a backup on it needs another model." + hint)
            }
            guard seen.insert(FallbackEntry(backend: entry.backend, model: model)).inserted else {
                throw UsageFallbackError(status: 400, message: kind.rawValue + (model.isEmpty ? "" : " · \(settings.fallbackModelLabel(kind, model))")
                    + " is in the chain twice. Each backend and model can be listed once." + hint)
            }
        }
    }
}
