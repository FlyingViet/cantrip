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

struct CantripModelSettingsView: View {
    @ObservedObject var model: CantripRemoteModel
    let session: CantripRemoteSession
    @State private var identity: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var settings: CantripModelSettings?
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
                    Text("Only this tab changes. Save while idle; the next prompt uses the new settings. The conversation stays visible, but Copilot rebuilds its runtime with recent history. Long context may cost more.")
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
