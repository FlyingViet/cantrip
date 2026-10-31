import Foundation
import CryptoKit

/// `GET/POST /api/v1/usage-fallback`: the Mac-wide backends a run moves through, in order, when
/// the one it's on reports its usage limit, for paired clients. POST `{"entries","revision"}`
/// replaces the chain with each backup's model and effort; `{"backends","revision"}` replaces only
/// the order (`[]` = off) and keeps the chosen models; `{"backend","revision"}` from older clients
/// sets its first backend ("" = off); `{"resetLimits":true,"revision"}` lets every backend be tried
/// again now.
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
    }
    struct ModelChoice: Encodable, Equatable {
        let id: String
        let label: String
        /// Efforts the model accepts; empty when it takes none, nil when unknown.
        let efforts: [String]?
    }
    /// A backup and what it runs with; "" model or effort = the backend's default.
    struct Entry: Codable, Equatable {
        let backend: String
        var model: String = ""
        var effort: String = ""
    }
    struct Limited: Encodable, Equatable {
        let backend: String
        let until: String
        let untilLabel: String
    }
    /// The fallbacks' BackendKind rawValues in the order they're tried, empty when off.
    let backends: [String]
    /// The same chain with each backup's model and effort.
    let entries: [Entry]
    /// The first fallback, "" when off, for clients from before the chain.
    let backend: String
    /// The Mac's backend; it's skipped if the chain names it.
    let primary: String
    let choices: [Choice]
    let limited: [Limited]
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
        let choices = BackendKind.allCases.filter { $0 != settings.backend }.map { kind -> UsageFallbackSnapshot.Choice in
            var choice = UsageFallbackSnapshot.Choice(id: kind.rawValue, label: settings.backendLabel(kind))
            guard AppSettings.fallbackModelBackends.contains(kind) else { return choice }
            let catalog = settings.tabModelCatalog(for: kind)
            choice.models = catalog.models.map {
                .init(id: $0.id, label: settings.fallbackModelLabel(kind, $0.id), efforts: $0.reasoningEfforts)
            }
            let defaults = settings.tabModelDefaults(for: kind)
            choice.defaultModel = defaults.model.isEmpty ? nil : settings.fallbackModelLabel(kind, defaults.model)
            choice.defaultEfforts = catalog.info(defaults.model)?.reasoningEfforts
            return choice
        }
        let chain = settings.limitFallbackBackends
        let entries = chain.map { backend in
            let chosen = settings.limitFallbackModels[backend]
            return UsageFallbackSnapshot.Entry(backend: backend, model: chosen?.model ?? "", effort: chosen?.effort ?? "")
        }
        let fields = [chain.joined(separator: ","), settings.backend.rawValue]
            + entries.map { "\($0.backend)=\($0.model)/\($0.effort)" }
            + limited.map { "\($0.backend)=\($0.until)" }
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let revision = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(backends: chain, entries: entries, backend: chain.first ?? "", primary: settings.backend.rawValue,
                     choices: choices, limited: limited, revision: revision)
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
            var models = settings.limitFallbackModels
            for entry in entries {
                models[entry.backend] = entry.model.isEmpty && entry.effort.isEmpty
                    ? nil : SessionModelSelection(model: entry.model, effort: entry.effort, contextTier: "")
            }
            settings.limitFallbackModels = models
            settings.limitFallbackBackends = entries.map(\.backend)
            Log.write("usage-limit: a paired client set the fallbacks to "
                      + (entries.isEmpty ? "off" : entries.map { settings.fallbackRun(for: BackendKind(rawValue: $0.backend)!).label }
                            .joined(separator: " → ")))
        } else if keys == ["revision", "backends"], let backends = json["backends"] as? [String] {
            guard backends.allSatisfy({ BackendKind(rawValue: $0) != nil }) else {
                throw UsageFallbackError(status: 400, message: "Choose from the listed backends.")
            }
            guard Set(backends).count == backends.count else {
                throw UsageFallbackError(status: 400, message: "Each backend can be in the chain once.")
            }
            settings.limitFallbackBackends = backends
            Log.write("usage-limit: a paired client set the fallbacks to \(backends.isEmpty ? "off" : backends.joined(separator: " → "))")
        } else if keys == ["revision", "backend"], let backend = json["backend"] as? String {
            guard backend.isEmpty || BackendKind(rawValue: backend) != nil else {
                throw UsageFallbackError(status: 400, message: "Choose Off or one of the listed backends.")
            }
            guard backend != settings.backend.rawValue else {
                throw UsageFallbackError(status: 400, message: "A backend can't fall back on itself. Choose another one.")
            }
            // An older client only sees the first fallback: replace that one, keep the rest.
            let rest = settings.limitFallbackBackends.dropFirst().filter { $0 != backend }
            settings.limitFallbackBackends = backend.isEmpty ? [] : [backend] + rest
            Log.write("usage-limit: a paired client set the first fallback to \(backend.isEmpty ? "off" : backend)")
        } else {
            throw UsageFallbackError(status: 400, message: "Send revision with entries, backends, backend or resetLimits: true.")
        }
        return snapshot(settings: settings, tracker: tracker, now: now)
    }

    /// Known backends, each once, with a model the backend offers and an effort that model takes.
    static func validatedEntries(_ raw: [[String: Any]], settings: AppSettings) throws -> [UsageFallbackSnapshot.Entry] {
        let entries = try raw.map { item -> UsageFallbackSnapshot.Entry in
            guard Set(item.keys).isSubset(of: ["backend", "model", "effort"]),
                  let backend = item["backend"] as? String, let kind = BackendKind(rawValue: backend),
                  item["model"] == nil || item["model"] is String, item["effort"] == nil || item["effort"] is String else {
                throw UsageFallbackError(status: 400, message: "Each entry needs a listed backend, and model and effort as text.")
            }
            let model = (item["model"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let effort = (item["effort"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard AppSettings.fallbackModelBackends.contains(kind) || (model.isEmpty && effort.isEmpty) else {
                throw UsageFallbackError(status: 400, message: "\(backend) runs its default model; it has no model or effort to choose.")
            }
            let catalog = settings.tabModelCatalog(for: kind)
            if !model.isEmpty, !catalog.models.contains(where: { $0.id == model }) {
                throw UsageFallbackError(status: 400, message: "\(backend) doesn't offer \(model). Choose one of its listed models.")
            }
            let efforts = catalog.info(model.isEmpty ? settings.tabModelDefaults(for: kind).model : model)?.reasoningEfforts
            if !effort.isEmpty, let efforts, !efforts.contains(effort) {
                throw UsageFallbackError(status: 400, message: "That model doesn't take \(effort) effort.")
            }
            return .init(backend: backend, model: model, effort: effort)
        }
        guard Set(entries.map(\.backend)).count == entries.count else {
            throw UsageFallbackError(status: 400, message: "Each backend can be in the chain once.")
        }
        return entries
    }
}
