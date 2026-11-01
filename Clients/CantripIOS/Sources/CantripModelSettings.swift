import Foundation
import SwiftUI

struct CantripModelSelection: Codable, Equatable {
    var model: String
    var effort: String
    var contextTier: String
}

struct CantripModelOption: Decodable, Identifiable, Equatable {
    /// Copilot's AI-credit prices per billing batch of tokens; absent on other backends and older Macs.
    struct Price: Decodable, Equatable {
        var input: Double?
        var output: Double?
        var cachedInput: Double?
        var batchSize: Int?

        /// "10 in · 50 out credits per 1M tokens".
        var label: String? {
            guard input != nil || output != nil else { return nil }
            if (input ?? 0) == 0, (output ?? 0) == 0 { return "No AI credits" }
            func number(_ value: Double?) -> String {
                guard let value else { return "?" }
                return value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
            }
            let per = batchSize.map { " per \(CantripModelOption.tokenLabel($0)) tokens" } ?? ""
            return "\(number(input)) in · \(number(output)) out credits\(per)"
        }
    }

    let id: String
    var contextWindow: Int?
    var reasoningEfforts: [String]?
    var contextTiers: [String]?
    var defaultContextPromptTokens: Int?
    var longContextPromptTokens: Int?
    var price: Price?

    /// One line under the model in the picker: its context window and Copilot's price, if known.
    var summary: String? {
        let parts = [contextWindow.map { "\(Self.tokenLabel($0)) context" }, price?.label].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func tokenLabel(_ tokens: Int) -> String {
        let divisor = tokens >= 1_000_000 ? 1_000_000 : tokens >= 1000 ? 1000 : 1
        let suffix = divisor == 1_000_000 ? "M" : divisor == 1000 ? "k" : ""
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"),
                      Double(tokens) / Double(divisor))
            .replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression) + suffix
    }

    func contextLabel(_ tier: String) -> String {
        let name = tier == "default" ? "Standard" : tier == "long_context" ? "Long" : tier
        let budget = tier == "default" ? defaultContextPromptTokens
            : tier == "long_context" ? longContextPromptTokens : nil
        return budget.map { "\(name) - \(Self.tokenLabel($0)) input" } ?? name
    }
}

/// A tier as the tab's picker offers it, from Macs with model tiers.
struct CantripModelTierOption: Decodable, Equatable, Identifiable {
    /// "fast", "standard" or "deep": the value a selection's model takes.
    let id: String
    let label: String
    /// What it runs on this backend now ("" = the backend's default) and why it skipped a model.
    let model: String
    let modelLabel: String
    let effort: String
    var note: String? = nil
}

struct CantripModelSettings: Decodable, Equatable {
    let selection: CantripModelSelection
    let defaults: CantripModelSelection
    let usesDefaults: Bool
    let revision: String
    /// The tiers first (on Macs with model tiers), then the backend's models.
    let models: [CantripModelOption]
    /// What each tier runs now; nil from Macs before tiers.
    let tiers: [CantripModelTierOption]?
    let fileDefaultModel: String?
    let fileDefaultContextTier: String?
    let unavailableReason: String?
    let catalogError: String?
    let isRefreshing: Bool

    func info(for selection: CantripModelSelection) -> CantripModelOption? {
        models.first { $0.id == (selection.model.isEmpty ? fileDefaultModel : selection.model) }
    }

    func validationError(_ selection: CantripModelSelection) -> String? {
        let info = info(for: selection)
        if !selection.model.isEmpty && info == nil { return "This model is no longer in the Mac's catalog." }
        if !selection.effort.isEmpty && info?.reasoningEfforts?.contains(selection.effort) != true {
            return "Choose an effort this model takes, or Model default."
        }
        if !selection.contextTier.isEmpty && info?.contextTiers?.contains(selection.contextTier) != true {
            return "Choose a context window this model takes, or Auto."
        }
        return nil
    }

    func tier(_ id: String) -> CantripModelTierOption? { tiers?.first { $0.id == id } }

    /// The backend's own models, without the tier entries.
    var catalogModels: [CantripModelOption] {
        let tierIDs = Set((tiers ?? []).map(\.id))
        return models.filter { !tierIDs.contains($0.id) }
    }

    /// A model or tier as the picker names it: "Deep · Claude Opus 5.5".
    func label(_ id: String) -> String {
        guard let tier = tier(id) else { return id }
        return "\(tier.label) · \(tier.modelLabel)"
    }

    /// The Mac's default for this tab, as Auto names it.
    var autoLabel: String {
        let model = defaults.model.isEmpty ? fileDefaultModel : defaults.model
        return model.map { "Auto (Mac default: \(label($0)))" } ?? "Auto (Mac default)"
    }
}

struct CantripModelSettingsChange: Encodable {
    let revision: String
    let usesDefaults: Bool
    let model: String?
    let effort: String?
    let contextTier: String?

    init(revision: String, selection: CantripModelSelection?) {
        self.revision = revision
        usesDefaults = selection == nil
        model = selection?.model
        effort = selection?.effort
        contextTier = selection?.contextTier
    }
}

/// `GET/POST /api/v1/usage-fallback`: the backups, in order, the Mac moves a run through when the
/// backend (or model) it's on reports its usage limit. Each backup is a backend with the model and
/// effort it runs; a backend can be listed again with another model, the Mac's own backend too.
/// Backups are edited by position, since the same backend can be in the chain more than once.
struct CantripUsageFallback: Decodable, Equatable {
    struct Choice: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        /// The models a backup on this backend can use; nil when it always runs its default.
        var models: [ModelChoice]? = nil
        /// Efforts for its default model.
        var defaultEfforts: [String]? = nil
        /// The Mac's own model for this backend, which "Default" means.
        var defaultModel: String? = nil
        /// The ID of the model "Default" runs, to tell a backend's backups apart; nil when only
        /// the CLI knows it (and from Macs before a backend could be listed again).
        var defaultModelID: String? = nil
    }
    struct ModelChoice: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        /// Efforts the model takes; empty when none, nil when unknown.
        var efforts: [String]? = nil
    }
    /// A backup and what it runs with; "" = the backend's default. The Mac sends the other fields
    /// read-only; `change` never sends them back.
    struct Entry: Codable, Equatable {
        let backend: String
        var model: String = ""
        var effort: String = ""
        /// "Antigravity · Gemini 3.8 Flash (Medium)", as run notes name it.
        var label: String? = nil
        /// When this backup can run again, while its backend or model is at its limit.
        var limitedUntil: String? = nil
        var limitedUntilLabel: String? = nil

        /// What a POST takes: backend, model and effort (a Mac from before repeats takes no more).
        var editable: Entry { Entry(backend: backend, model: model, effort: effort) }
    }
    /// A whole backend at its limit.
    struct Limited: Decodable, Equatable {
        let backend: String
        let until: String
        let untilLabel: String
    }
    /// One model quota at its limit (Claude's weekly Opus limit, an Antigravity model group); the
    /// backend's other models still run.
    struct LimitedModel: Decodable, Equatable {
        let backend: String
        let scope: String
        /// "Gemini 4 Argon", "Opus models".
        let label: String
        let until: String
        let untilLabel: String
    }
    /// The chain's first entry, "" when off; all a Mac from before the chain sends.
    let backend: String
    /// The whole chain in the order tried (a backend twice when it's listed twice); nil from Macs
    /// before the chain.
    var backends: [String]? = nil
    /// The chain with each backup's model and effort; nil from Macs before backup models.
    var entries: [Entry]? = nil
    let primary: String
    /// Backends to add, without the Mac's own.
    let choices: [Choice]
    /// The Mac's own backend, to add again with another model; nil when it has no model picker
    /// (and from Macs before a backend could be listed again).
    var primaryChoice: Choice? = nil
    let limited: [Limited]
    /// Nil from Macs before per-model limits.
    var limitedModels: [LimitedModel]? = nil
    let revision: String

    /// Whether the Mac takes more than one backup; older Macs keep a chain of one.
    var supportsChain: Bool { backends != nil }

    /// Whether the Mac takes each backup's model.
    var supportsModels: Bool { entries != nil }

    /// Whether the Mac takes a backend again with another model; earlier Macs list each backend
    /// once (they send no `limitedModels`).
    var listsBackendsAgain: Bool { supportsModels && limitedModels != nil }

    /// The backups in the order tried, one per row.
    var rows: [Entry] { entries ?? chain.map { Entry(backend: $0) } }

    var chain: [String] { entries?.map(\.backend) ?? backends ?? (backend.isEmpty ? [] : [backend]) }

    func choice(_ backend: String) -> Choice? {
        choices.first { $0.id == backend } ?? (primaryChoice?.id == backend ? primaryChoice : nil)
    }

    /// The model a backup runs: its own, or the one "Default" means ("" when only the CLI knows).
    func effectiveModel(_ backend: String, model: String) -> String {
        model.isEmpty ? choice(backend)?.defaultModelID ?? "" : model
    }

    /// The models `backend`'s backups other than row `index` run, plus the Mac's own model on its
    /// own backend: a new or changed backup on it needs another one.
    func takenModels(_ backend: String, except index: Int? = nil) -> Set<String> {
        var taken = Set(rows.enumerated()
            .filter { $0.offset != index && $0.element.backend == backend }
            .map { effectiveModel(backend, model: $0.element.model) })
        if backend == primary { taken.insert(effectiveModel(backend, model: "")) }
        return taken
    }

    /// The model a new backup on `backend` would run, nil when it has none left: "Default" first,
    /// then its first model no backup runs. A backend without models can be added once.
    func freeModel(_ backend: String) -> String? {
        guard listsBackendsAgain else {
            guard supportsChain || chain.isEmpty, backend != primary, !chain.contains(backend) else { return nil }
            return ""
        }
        let taken = takenModels(backend)
        if !taken.contains(effectiveModel(backend, model: "")) { return "" }
        return choice(backend)?.models?.map(\.id).first { !taken.contains($0) }
    }

    /// Backends that could still be added, the Mac's own (with another model) last.
    var addable: [Choice] {
        (choices + (primaryChoice.map { [$0] } ?? [])).filter { freeModel($0.id) != nil }
    }

    /// "Antigravity with another model" once it's in the chain (or it's the Mac's own backend).
    func addLabel(_ choice: Choice) -> String {
        choice.id == primary || chain.contains(choice.id) ? "\(choice.id) with another model" : choice.label
    }

    /// The backend's label, from its choice.
    func label(_ id: String) -> String {
        choice(id)?.label ?? id
    }

    /// Row `index`'s name: what it runs, or its backend; marked when the Mac skips it because it's
    /// the Mac's own backend and model.
    func title(at index: Int) -> String {
        let entry = rows[index]
        let name = entry.label.flatMap { $0.isEmpty ? nil : $0 } ?? label(entry.backend)
        let skipped = entry.backend == primary
            && (primaryChoice == nil || effectiveModel(entry.backend, model: entry.model) == effectiveModel(entry.backend, model: ""))
        return skipped ? "\(name) (skipped: the Mac's backend)" : name
    }

    /// Whole backends and model quotas at their limit: "Antigravity Gemini 4 Argon until 8:00 PM".
    var limitDescriptions: [String] {
        limited.map { "\($0.backend) until \($0.untilLabel)" }
            + (limitedModels ?? []).map { "\($0.backend) \($0.label) until \($0.untilLabel)" }
    }

    /// Whether "Try every backend again" has anything to clear.
    var canResetLimits: Bool { !limitDescriptions.isEmpty }

    var status: String {
        let limits = limitDescriptions
        if !limits.isEmpty {
            return "At its usage limit: " + limits.joined(separator: ", ") + "."
        }
        if chain.isEmpty { return "Off: a usage limit stops the run with the error." }
        return "New messages from every tab move there until the limit resets. "
            + (limitedModels == nil ? "" : "Where a backend's models have their own limits, only that model is skipped. ")
            + "Council seats and Private Local tabs don't switch."
    }

    /// Models row `index` can switch to, or nil when this Mac doesn't take backup models or the
    /// backend has no model picker: the backend's models other backups of it don't run (nor the
    /// Mac's own on its own backend), always with the row's current one.
    func models(at index: Int) -> [ModelChoice]? {
        guard supportsModels, rows.indices.contains(index) else { return nil }
        let entry = rows[index]
        guard let models = choice(entry.backend)?.models else { return nil }
        let taken = takenModels(entry.backend, except: index)
        return models.filter { $0.id == entry.model || !taken.contains($0.id) }
    }

    /// Whether row `index` can pick "Default": it's free, or the row runs it now.
    func offersDefault(at index: Int) -> Bool {
        let entry = rows[index]
        return entry.model.isEmpty
            || !takenModels(entry.backend, except: index).contains(effectiveModel(entry.backend, model: ""))
    }

    /// Efforts for row `index`'s chosen model (or its default model).
    func efforts(at index: Int) -> [String] {
        let entry = rows[index]
        let choice = choice(entry.backend)
        return (entry.model.isEmpty ? choice?.defaultEfforts : choice?.models?.first { $0.id == entry.model }?.efforts) ?? []
    }

    /// The change that saves `rows` as the whole chain: each backup's backend, model and effort
    /// for a Mac that sends them; otherwise just the backends (only the first for a Mac from
    /// before the chain).
    func change(to rows: [Entry]) -> CantripUsageFallbackChange {
        if supportsModels { return CantripUsageFallbackChange(revision: revision, entries: rows.map(\.editable)) }
        let chain = rows.map(\.backend)
        return supportsChain
            ? CantripUsageFallbackChange(revision: revision, backends: chain)
            : CantripUsageFallbackChange(revision: revision, backend: chain.first ?? "")
    }

    /// Adds a backup on `backend` at the end, running its free model; nil when it has none.
    func adding(_ backend: String) -> CantripUsageFallbackChange? {
        freeModel(backend).map { change(to: rows + [Entry(backend: backend, model: $0)]) }
    }

    /// Sets row `index`'s model and effort, keeping the other backups.
    func setting(_ index: Int, model: String, effort: String) -> CantripUsageFallbackChange {
        var next = rows
        next[index] = Entry(backend: next[index].backend, model: model, effort: effort)
        return change(to: next)
    }

    /// Swaps row `index` with the one `offset` (-1 or 1) away.
    func moving(_ index: Int, by offset: Int) -> CantripUsageFallbackChange {
        var next = rows
        next.swapAt(index, index + offset)
        return change(to: next)
    }

    func removing(_ index: Int) -> CantripUsageFallbackChange {
        var next = rows
        next.remove(at: index)
        return change(to: next)
    }

    /// One identity per row that follows a backup when it moves, unique when a backend and model
    /// repeat (an older Mac's chain).
    var rowIDs: [String] {
        var seen: [String: Int] = [:]
        return rows.map { entry in
            let key = "\(entry.backend)\u{1F}\(entry.model)"
            seen[key, default: 0] += 1
            return "\(key)\u{1F}\(seen[key]!)"
        }
    }
}

struct CantripUsageFallbackChange: Encodable {
    let revision: String
    var backend: String?
    var backends: [String]?
    var entries: [CantripUsageFallback.Entry]?
    var resetLimits: Bool?
}

/// Mac-wide, so each change saves right away. Settings › Models loads it (`load`) and shows it
/// with the tiers.
struct CantripUsageFallbackSection: View {
    @ObservedObject var model: CantripRemoteModel
    @Binding var fallback: CantripUsageFallback?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Group {
            if let fallback {
                Section {
                    ForEach(Array(zip(fallback.rows.indices, fallback.rowIDs)), id: \.1) { index, _ in
                        row(fallback, index: index)
                    }
                    if !fallback.addable.isEmpty {
                        Picker("Add a backup", selection: Binding(get: { "" }, set: { id in
                            guard !id.isEmpty, let change = fallback.adding(id) else { return }
                            Task { await save(change) }
                        })) {
                            Text(fallback.chain.isEmpty ? "Off - choose a backend" : "Choose a backend").tag("")
                            ForEach(fallback.addable) { Text(fallback.addLabel($0)).tag($0.id) }
                        }
                        .disabled(saving)
                        .accessibilityIdentifier("usageFallback.add")
                    }
                    if fallback.canResetLimits {
                        Button("Try every backend again") {
                            Task { await save(CantripUsageFallbackChange(revision: fallback.revision, resetLimits: true)) }
                        }
                        .disabled(saving)
                        .accessibilityIdentifier("usageFallback.reset")
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                } header: {
                    Text("Usage-limit backups")
                } footer: {
                    Text("When a backend hits its usage limit, the task continues on the first backup here that isn't at its limit too. A backup can run a tier (Fast, Standard, Deep); one left on its default model keeps the tier of a run that has one. "
                         + fallback.status)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ fallback: CantripUsageFallback, index: Int) -> some View {
        CantripUsageFallbackRow(fallback: fallback, index: index, saving: saving) { change in
            Task { await save(change) }
        }
        modelPickers(fallback, index: index, name: CantripUsageFallbackRow.name(fallback, index: index))
    }

    /// The backup's model and effort, from the backend's own lists ("Default" = the Mac's setting),
    /// without a model another backup of the backend runs.
    @ViewBuilder
    private func modelPickers(_ fallback: CantripUsageFallback, index: Int, name: String) -> some View {
        if let models = fallback.models(at: index) {
            let entry = fallback.rows[index]
            let choice = fallback.choice(entry.backend)
            let identifier = "\(index + 1).\(entry.backend)"
            Picker("Model", selection: Binding(get: { entry.model }, set: { model in
                Task { await save(fallback.setting(index, model: model, effort: "")) }
            })) {
                if fallback.offersDefault(at: index) {
                    Text(choice?.defaultModel.map { "Default (\($0))" } ?? "Default model").tag("")
                }
                ForEach(models) { Text($0.label).tag($0.id) }
                if !entry.model.isEmpty, !models.contains(where: { $0.id == entry.model }) {
                    Text("\(entry.model) (not offered now)").tag(entry.model)
                }
            }
            .disabled(saving)
            .accessibilityLabel("\(name) model")
            .accessibilityIdentifier("usageFallback.model.\(identifier)")
            let efforts = fallback.efforts(at: index)
            if !efforts.isEmpty {
                Picker("Effort", selection: Binding(get: { entry.effort }, set: { effort in
                    Task { await save(fallback.setting(index, model: entry.model, effort: effort)) }
                })) {
                    Text("Default effort").tag("")
                    ForEach(efforts, id: \.self) { Text($0).tag($0) }
                }
                .disabled(saving)
                .accessibilityLabel("\(name) effort")
                .accessibilityIdentifier("usageFallback.effort.\(identifier)")
            }
        }
    }

    /// Older Macs don't offer it; the section stays hidden.
    @MainActor
    static func load(_ model: CantripRemoteModel) async -> CantripUsageFallback? {
        try? await model.usageFallback()
    }

    @MainActor
    private func save(_ change: CantripUsageFallbackChange) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        if let updated = await model.updateUsageFallback(change) {
            fallback = updated
            error = nil
        } else {
            error = model.errorMessage ?? "The fallback could not be saved."
            fallback = await Self.load(model)
        }
    }
}

/// One backup: its number, what it runs and whether it's at its limit, then up, down and Remove
/// beside it, or under it when they don't fit (a folded Duo, large text).
struct CantripUsageFallbackRow: View {
    let fallback: CantripUsageFallback
    let index: Int
    let saving: Bool
    let save: (CantripUsageFallbackChange) -> Void

    /// "Antigravity backup 2": VoiceOver tells a backend's backups apart by their number.
    static func name(_ fallback: CantripUsageFallback, index: Int) -> String {
        "\(fallback.rows[index].backend) backup \(index + 1)"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                summary
                Spacer(minLength: 0)
                controls
            }
            VStack(alignment: .leading, spacing: 8) {
                summary
                controls
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usageFallback.backup.\(index + 1).\(fallback.rows[index].backend)")
    }

    private var summary: some View {
        let title = fallback.title(at: index)
        let until = fallback.rows[index].limitedUntilLabel
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let until {
                    Text("At its limit until \(until)").font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Backup \(index + 1): \(title)" + (until.map { ", at its limit until \($0)" } ?? ""))
    }

    private var controls: some View {
        let name = Self.name(fallback, index: index)
        return HStack(spacing: 14) {
            Button { save(fallback.moving(index, by: -1)) } label: { Image(systemName: "arrow.up") }
                .disabled(saving || index == 0)
                .accessibilityLabel("Try \(name) earlier")
            Button { save(fallback.moving(index, by: 1)) } label: { Image(systemName: "arrow.down") }
                .disabled(saving || index == fallback.rows.count - 1)
                .accessibilityLabel("Try \(name) later")
            Button("Remove", role: .destructive) { save(fallback.removing(index)) }
                .disabled(saving)
                .accessibilityLabel("Remove \(name)")
        }
        #if os(macOS)
        // Borderless symbols are tiny, grey click targets on the Mac.
        .buttonStyle(.bordered)
        .controlSize(.small)
        #else
        .buttonStyle(.borderless)
        #endif
    }
}

struct CantripModelSettingsView: View {
    @ObservedObject var model: CantripRemoteModel
    let session: CantripRemoteSession
    @State private var identity: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var settings: CantripModelSettings?
    @State private var fallback: CantripUsageFallback?
    @State private var selection = CantripModelSelection(model: "", effort: "", contextTier: "")
    @State private var usesDefaults = true
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?

    init(model: CantripRemoteModel, session: CantripRemoteSession, identity: UUID) {
        self.model = model
        self.session = session
        _identity = State(initialValue: identity)
    }

    private var info: CantripModelOption? { settings?.info(for: selection) }
    private var validationError: String? { usesDefaults ? nil : settings?.validationError(selection) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(session.title).font(.headline)
                    Toggle("Use Mac defaults", isOn: $usesDefaults)
                        .disabled(settings == nil || settings?.unavailableReason != nil)
                    pickers
                        .disabled(usesDefaults || settings == nil || settings?.unavailableReason != nil)
                } footer: {
                    Text("Only this tab changes. Save while idle; the next prompt uses the new settings and continues the same conversation. Long context may cost more.")
                }
                if let tokens = info?.contextWindow {
                    Section {
                        LabeledContent("Advertised maximum", value: "\(CantripModelOption.tokenLabel(tokens)) tokens")
                        Text("Tier values are input budgets, not total context.").font(.footnote)
                    }
                }
                if let message = error ?? settings?.unavailableReason ?? validationError ?? settings?.catalogError {
                    Section { Text(message).foregroundStyle(.orange).accessibilityIdentifier("modelSettings.error") }
                }
                CantripUsageFallbackSection(model: model, fallback: $fallback)
                Section {
                    Button("Reload settings") { Task { await load(replaceDraft: true) } }
                    Button("Refresh models") { Task { await load(refreshModels: true) } }
                    if loading || settings?.isRefreshing == true { ProgressView("Loading model options...") }
                }
            }
            .disabled(saving || loading)
            .navigationTitle("Model Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let settings else { return }
                        let change = CantripModelSettingsChange(revision: settings.revision,
                                                               selection: usesDefaults ? nil : selection)
                        saving = true
                        Task {
                            if await model.updateModelSettings(id: session.id, change: change, identity: identity) {
                                dismiss()
                            } else { error = model.errorMessage ?? "Model settings could not be saved." }
                            saving = false
                        }
                    }
                    .disabled(settings == nil || saving || loading || model.isMutating
                              || settings?.unavailableReason != nil || validationError != nil)
                    .accessibilityIdentifier("modelSettings.save")
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .task { await load(replaceDraft: true) }
        .task { fallback = await CantripUsageFallbackSection.load(model) }
        .onChange(of: model.usageIdentity) { _, _ in dismiss() }
    }

    private var pickers: some View {
        Group {
            Picker("Model", selection: Binding(get: { selection.model }, set: { value in
                selection.model = value
                selection.effort = ""
                selection.contextTier = info?.contextTiers?.contains("default") == true ? "default" : ""
            })) {
                Text("CLI default (\(settings?.fileDefaultModel ?? "Auto"))").tag("")
                ForEach(choices(settings?.models.map(\.id), selected: selection.model), id: \.self) {
                    Text($0).tag($0)
                }
            }
            Picker("Effort", selection: $selection.effort) {
                Text("Model default").tag("")
                ForEach(choices(info?.reasoningEfforts, selected: selection.effort), id: \.self) {
                    Text($0.capitalized).tag($0).disabled(info?.reasoningEfforts?.contains($0) != true)
                }
            }
            Picker("Context window", selection: $selection.contextTier) {
                Text("CLI default").tag("")
                ForEach(choices(info?.contextTiers, selected: selection.contextTier), id: \.self) {
                    Text(info?.contextLabel($0) ?? $0).tag($0).disabled(info?.contextTiers?.contains($0) != true)
                }
            }
        }
        .onChange(of: usesDefaults) { _, inherited in
            if inherited, let settings { selection = settings.defaults }
        }
    }

    private func choices(_ values: [String]?, selected: String) -> [String] {
        var seen = Set<String>()
        return ((values ?? []) + [selected]).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    @MainActor
    private func load(replaceDraft: Bool = false, refreshModels: Bool = false) async {
        guard !loading, !saving else { return }
        loading = true
        defer { loading = false }
        do {
            var value = try await model.modelSettings(id: session.id, refreshModels: refreshModels)
            if replaceDraft {
                selection = value.selection
                usesDefaults = value.usesDefaults
                settings = value
            }
            // Do not silently rebase an edited form over another device's changes.
            let originalRevision = settings?.revision ?? value.revision
            for _ in 0..<30 where value.isRefreshing {
                try await Task.sleep(for: .seconds(1))
                value = try await model.modelSettings(id: session.id)
            }
            guard model.usageIdentity == identity else { throw CancellationError() }
            guard value.revision == originalRevision else {
                error = "Model settings changed on another device. Reload before saving."
                return
            }
            settings = value
            error = value.isRefreshing ? "Model lookup is still running. Reload in a moment." : nil
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
    }
}
