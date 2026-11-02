import Foundation

/// `GET/POST /api/v1/model-tiers`: each backend's models for fast, standard and deep, first choice
/// first, each with an effort. A run on a tier takes the first one its backend offers that isn't
/// at its own usage limit; one edit applies to every tab, Home task and backup that asks for it.
struct CantripModelTiers: Decodable, Equatable {
    struct Choice: Codable, Equatable, Hashable {
        let model: String
        var effort: String = ""
        /// Read-only from the Mac: the model's name, whether the backend offers it now, Copilot's price.
        var label: String? = nil
        var offered: Bool? = nil
        var price: String? = nil

        /// What a POST takes.
        var editable: Choice { Choice(model: model, effort: effort) }
    }

    struct Model: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        /// Efforts it takes; empty when none, nil when unknown.
        var efforts: [String]? = nil
        /// Copilot's token prices, e.g. "10 in · 50 out credits per 1M tokens".
        var price: String? = nil
    }

    struct Cell: Decodable, Equatable, Identifiable {
        let tier: String
        let label: String
        let choices: [Choice]
        let isDefault: Bool
        /// What the tier runs now ("" = the backend's default model) and why it isn't the first choice.
        let model: String
        let effort: String
        var note: String? = nil
        var id: String { tier }
    }

    struct Backend: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        let cells: [Cell]
        let models: [Model]

        func model(_ id: String) -> Model? { models.first { $0.id == id } }

        /// The tier that lists `model`, the first one when several do.
        func tier(of model: String) -> Cell? { cells.first { $0.choices.contains { $0.model == model } } }

        /// "Gemini 4 Argon (High) · high", or the default model.
        func runs(_ cell: Cell) -> String {
            let name = cell.model.isEmpty ? "the default model" : model(cell.model)?.label ?? cell.model
            return cell.effort.isEmpty ? name : "\(name) · \(cell.effort)"
        }
    }

    /// "fast", "standard", "deep".
    let tiers: [String]
    let backends: [Backend]
    let revision: String

    func backend(_ id: String) -> Backend? { backends.first { $0.id == id } }

    /// One line on what each tier is for, as the pickers show it.
    static func summary(_ tier: String) -> String {
        switch tier {
        case "fast": return "Quick answers and small edits, at the lowest cost."
        case "standard": return "Everyday coding, writing and research."
        case "deep": return "Hard problems and long reasoning, at the highest cost."
        default: return ""
        }
    }

    static func label(_ tier: String) -> String { tier.prefix(1).uppercased() + tier.dropFirst() }

    static let maximumChoices = 5
}

struct CantripModelTiersChange: Encodable, Equatable {
    let revision: String
    var backend: String? = nil
    var tier: String? = nil
    var choices: [CantripModelTiers.Choice]? = nil
    var reset: Bool? = nil

    static func set(_ cell: CantripModelTiers.Cell, on backend: String, to choices: [CantripModelTiers.Choice],
                    revision: String) -> Self {
        Self(revision: revision, backend: backend, tier: cell.tier, choices: choices.map(\.editable))
    }

    static func resetting(_ cell: CantripModelTiers.Cell, on backend: String, revision: String) -> Self {
        Self(revision: revision, backend: backend, tier: cell.tier, reset: true)
    }
}
