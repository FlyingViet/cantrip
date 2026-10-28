import Foundation
import SwiftUI

struct CantripModelSelection: Codable, Equatable {
    var model: String
    var effort: String
    var contextTier: String
}

struct CantripModelOption: Decodable, Identifiable, Equatable {
    let id: String
    var contextWindow: Int?
    var reasoningEfforts: [String]?
    var contextTiers: [String]?
    var defaultContextPromptTokens: Int?
    var longContextPromptTokens: Int?

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

struct CantripModelSettings: Decodable, Equatable {
    let selection: CantripModelSelection
    let defaults: CantripModelSelection
    let usesDefaults: Bool
    let revision: String
    let models: [CantripModelOption]
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
            return "Choose a supported effort or Model default."
        }
        if !selection.contextTier.isEmpty && info?.contextTiers?.contains(selection.contextTier) != true {
            return "Choose a supported context window or CLI default."
        }
        return nil
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

/// `GET/POST /api/v1/usage-fallback`: the backend the Mac moves runs to at a usage limit.
struct CantripUsageFallback: Decodable, Equatable {
    struct Choice: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
    }
    struct Limited: Decodable, Equatable {
        let backend: String
        let until: String
        let untilLabel: String
    }
    /// "" when off.
    let backend: String
    let primary: String
    let choices: [Choice]
    let limited: [Limited]
    let revision: String

    /// The picker's value: "" when off or set to a backend that is now the Mac's own.
    var selection: String { choices.contains { $0.id == backend } ? backend : "" }

    var status: String {
        limited.isEmpty
            ? "New messages from every tab move there until the limit resets. Council seats and Private Local tabs don't switch."
            : "At its usage limit: " + limited.map { "\($0.backend) until \($0.untilLabel)" }.joined(separator: ", ") + "."
    }
}

struct CantripUsageFallbackChange: Encodable {
    let revision: String
    var backend: String?
    var resetLimits: Bool?
}

/// Mac-wide, so it saves on change, apart from the tab's Save. The sheet loads it (`load`): a
/// hidden section has no view to run a task from.
struct CantripUsageFallbackSection: View {
    @ObservedObject var model: CantripRemoteModel
    @Binding var fallback: CantripUsageFallback?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Group {
            if let fallback {
                Section {
                    Picker("Continue on", selection: Binding(get: { fallback.selection }, set: { value in
                        Task { await save(CantripUsageFallbackChange(revision: fallback.revision, backend: value)) }
                    })) {
                        Text("Off - stop and show the error").tag("")
                        ForEach(fallback.choices) { Text($0.label).tag($0.id) }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("usageFallback.picker")
                    if !fallback.limited.isEmpty {
                        Button("Try every backend again") {
                            Task { await save(CantripUsageFallbackChange(revision: fallback.revision, resetLimits: true)) }
                        }
                        .disabled(saving)
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                } header: {
                    Text("Usage limit fallback (all tabs)")
                } footer: {
                    Text("When the Mac's backend says its plan's usage limit is reached. " + fallback.status)
                }
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
