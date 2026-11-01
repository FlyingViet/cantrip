import Foundation
import CryptoKit

/// `GET/POST /api/v1/model-tiers`: the Mac-wide tier map for paired clients (Remote in a browser
/// or the Mac, iPhone and Duo, Gateway). Each backend with a model picker maps fast, standard and
/// deep to an ordered list of its own models, each with an effort; a run on a tier takes the
/// first one the backend offers that isn't at its own usage limit. One edit applies to every tab,
/// Home task, backup and endpoint call that asks for the tier.
///
/// POST `{"revision","backend","tier","choices":[{"model","effort"}]}` replaces one cell (1-5
/// distinct models the backend offers, each with an effort it takes or ""). `{"revision","backend",
/// "tier","reset":true}` returns a cell to its default, and `{"revision","reset":true}` every cell.
struct ModelTierSnapshot: Encodable, Equatable {
    struct Choice: Encodable, Equatable {
        let model: String
        let effort: String
        /// "Gemini 4 Argon (High)", as pickers name it.
        let label: String
        /// False when the backend doesn't offer the model now (it's skipped).
        let offered: Bool
        /// Copilot's token prices, e.g. "10 in · 50 out credits per 1M tokens".
        let price: String?
    }
    struct Model: Encodable, Equatable {
        let id: String
        let label: String
        /// Efforts it takes; empty when none, nil when unknown.
        let efforts: [String]?
        let price: String?
    }
    struct Cell: Encodable, Equatable {
        let tier: String
        let label: String
        let choices: [Choice]
        let isDefault: Bool
        /// What the tier runs on this backend now ("" = the backend's default model) and why it
        /// isn't the first choice, if it isn't.
        let model: String
        let effort: String
        let note: String?
    }
    struct Backend: Encodable, Equatable {
        let id: String
        let label: String
        let cells: [Cell]
        /// The models a cell can list, from the backend's own catalog.
        let models: [Model]
    }
    /// "fast", "standard", "deep".
    let tiers: [String]
    let backends: [Backend]
    let revision: String
}

struct ModelTierError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum ModelTierRemote {
    static let maximumBody = 4096

    static func snapshot(settings: AppSettings = .shared) -> ModelTierSnapshot {
        let backends = ModelTierMap.backends.map { kind -> ModelTierSnapshot.Backend in
            let catalog = settings.tabModelCatalog(for: kind)
            let ids = Set(catalog.models.map(\.id))
            let cells = ModelTier.allCases.map { tier -> ModelTierSnapshot.Cell in
                let resolved = settings.resolveTier(tier, on: kind)
                let choices = settings.tierChoices(tier, on: kind).map {
                    ModelTierSnapshot.Choice(model: $0.model, effort: $0.effort, label: settings.fallbackModelLabel(kind, $0.model),
                                             offered: ids.isEmpty || ids.contains($0.model), price: catalog.info($0.model)?.price?.label)
                }
                return .init(tier: tier.rawValue, label: tier.label, choices: choices,
                             isDefault: settings.modelTiers.isDefault(tier, on: kind),
                             model: resolved.model, effort: resolved.effort, note: resolved.note)
            }
            let models = catalog.models.map {
                ModelTierSnapshot.Model(id: $0.id, label: settings.fallbackModelLabel(kind, $0.id),
                                        efforts: $0.reasoningEfforts, price: $0.price?.label)
            }
            return .init(id: kind.rawValue, label: kind.rawValue, cells: cells, models: models)
        }
        // Changes when the map or what a cell can offer changes, not when a limit comes and goes.
        let fields = backends.flatMap { backend in
            [backend.id, backend.models.map(\.id).joined(separator: ",")]
                + backend.cells.map { "\($0.tier)=" + $0.choices.map { "\($0.model)/\($0.effort)" }.joined(separator: ",") }
        }
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let revision = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(tiers: ModelTier.allCases.map(\.rawValue), backends: backends, revision: revision)
    }

    static func apply(_ json: [String: Any], settings: AppSettings = .shared) throws -> ModelTierSnapshot {
        guard let revision = json["revision"] as? String else {
            throw ModelTierError(status: 400, message: "Provide the revision you loaded.")
        }
        guard revision == snapshot(settings: settings).revision else {
            throw ModelTierError(status: 409, message: "The model tiers changed on another device. Reload before saving.")
        }
        let keys = Set(json.keys)
        if keys == ["revision", "reset"], json["reset"] as? Bool == true {
            settings.modelTiers = ModelTierMap()
            Log.write("model-tiers: a paired client reset every tier to its defaults")
            return snapshot(settings: settings)
        }
        guard let backend = json["backend"] as? String, let kind = BackendKind(rawValue: backend),
              ModelTierMap.backends.contains(kind) else {
            throw ModelTierError(status: 400, message: "Choose one of: "
                + ModelTierMap.backends.map(\.rawValue).joined(separator: ", ") + ".")
        }
        guard let name = json["tier"] as? String, let tier = ModelTier(rawValue: name) else {
            throw ModelTierError(status: 400, message: "Choose fast, standard or deep.")
        }
        if keys == ["revision", "backend", "tier", "reset"], json["reset"] as? Bool == true {
            settings.modelTiers.set(nil, for: tier, on: kind)
        } else if keys == ["revision", "backend", "tier", "choices"], let raw = json["choices"] as? [[String: Any]] {
            let choices = try validated(raw, kind: kind, settings: settings)
            settings.modelTiers.set(choices, for: tier, on: kind)
        } else {
            throw ModelTierError(status: 400, message: "Send revision, backend and tier with choices or reset: true.")
        }
        Log.write("model-tiers: a paired client set \(tier.rawValue) on \(kind.rawValue) to "
            + settings.tierChoices(tier, on: kind).map { $0.model + ($0.effort.isEmpty ? "" : " (\($0.effort))") }.joined(separator: ", "))
        return snapshot(settings: settings)
    }

    /// 1-5 distinct models `kind` offers (any well-formed name while its list hasn't loaded), each
    /// with an effort the model takes or "".
    static func validated(_ raw: [[String: Any]], kind: BackendKind, settings: AppSettings) throws -> [ModelTierChoice] {
        guard (1...ModelTierMap.maximumChoices).contains(raw.count) else {
            throw ModelTierError(status: 400, message: "List 1 to \(ModelTierMap.maximumChoices) models, first choice first.")
        }
        let catalog = settings.tabModelCatalog(for: kind)
        var seen = Set<String>()
        return try raw.map { item in
            // A snapshot's read-only fields may come back with the choice.
            guard Set(item.keys).isSubset(of: ["model", "effort", "label", "offered", "price"]),
                  let model = (item["model"] as? String)?.trimmingCharacters(in: .whitespaces), !model.isEmpty,
                  item["effort"] == nil || item["effort"] is String else {
                throw ModelTierError(status: 400, message: "Each choice needs a model, and effort as text.")
            }
            let effort = (item["effort"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard ModelTier(model: model) == nil else {
                throw ModelTierError(status: 400, message: "A tier lists models, not other tiers.")
            }
            let wellFormed = model.count <= 80
                && model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*(\[[0-9a-z]+\])?$"#, options: .regularExpression) != nil
            guard wellFormed, catalog.models.isEmpty || catalog.models.contains(where: { $0.id == model }) else {
                throw ModelTierError(status: 400, message: "\(kind.rawValue) doesn't offer \(model). Choose one of its listed models.")
            }
            guard seen.insert(model).inserted else {
                throw ModelTierError(status: 400, message: "\(model) is listed twice. List each model once.")
            }
            if !effort.isEmpty, let efforts = catalog.info(model)?.reasoningEfforts, !efforts.contains(effort) {
                throw ModelTierError(status: 400, message: "\(settings.fallbackModelLabel(kind, model)) doesn't take \(effort) effort.")
            }
            return ModelTierChoice(model: model, effort: effort)
        }
    }
}
