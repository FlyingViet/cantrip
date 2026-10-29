import SwiftUI

struct SessionModelSettingsView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SessionModelSelection
    @State private var usesDefaults: Bool
    @State private var revision: String
    @State private var error: String?

    init(session: ChatSession) {
        self.session = session
        _selection = State(initialValue: session.modelSelection)
        _usesDefaults = State(initialValue: session.ownModelSelection == nil)
        _revision = State(initialValue: session.modelSettingsRevision)
    }

    private var catalog: TabModelCatalog { settings.tabModelCatalog(for: session.modelSettingsBackend) }
    private var isClaude: Bool { session.modelSettingsBackend == .claudeCode }
    private var isAntigravity: Bool { session.modelSettingsBackend == .antigravity }
    /// Only Copilot has context-window tiers.
    private var showsContextTiers: Bool { !isClaude && !isAntigravity }

    private func modelLabel(_ id: String) -> String {
        isAntigravity ? settings.agyModelLabel(id) : id
    }

    private var info: CopilotModelInfo? { catalog.info(selection.model) }

    private var validationError: String? {
        guard !usesDefaults else { return nil }
        do {
            try selection.validate(catalog: catalog.models, fileDefaultModel: catalog.fileDefaultModel)
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Model Settings").font(.headline)
            Text(session.title).foregroundStyle(.secondary).lineLimit(2)
            Toggle("Use Mac defaults", isOn: $usesDefaults)
            Form {
                Picker("Model", selection: Binding(get: { selection.model }, set: { value in
                    selection.model = value
                    selection.effort = ""
                    selection.contextTier = info?.contextTiers?.contains("default") == true ? "default" : ""
                })) {
                    Text("CLI default (\(catalog.fileDefaultModel.map(modelLabel) ?? "Auto"))").tag("")
                    ForEach(CopilotModelInfo.choices(supported: catalog.models.map(\.id),
                                                   fallback: [], selected: selection.model), id: \.self) {
                        Text(modelLabel($0)).tag($0)
                    }
                }
                Picker("Effort", selection: $selection.effort) {
                    Text("Model default").tag("")
                    ForEach(CopilotModelInfo.choices(supported: info?.reasoningEfforts,
                                                   fallback: [], selected: selection.effort), id: \.self) {
                        Text($0.capitalized).tag($0)
                            .disabled(info?.reasoningEfforts?.contains($0) != true)
                    }
                }
                if showsContextTiers {
                Picker("Context window", selection: $selection.contextTier) {
                    Text("CLI default").tag("")
                    ForEach(CopilotModelInfo.choices(supported: info?.contextTiers,
                                                   fallback: [], selected: selection.contextTier), id: \.self) { tier in
                        Text(contextLabel(tier)).tag(tier)
                            .disabled(info?.contextTiers?.contains(tier) != true)
                    }
                }
                }
            }
            .disabled(usesDefaults || session.modelSettingsUnavailableReason != nil)
            .onChange(of: usesDefaults) { _, inherited in
                if inherited { selection = session.defaultModelSelection }
            }
            if showsContextTiers, let context = info?.contextLabel {
                Text("Advertised maximum: \(context) tokens. Tier values are input budgets, not total context.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(isClaude
                 ? "Only this tab changes. Save while idle; the next prompt restarts Claude Code with the new settings and resumes the same conversation."
                 : isAntigravity
                 ? "Only this tab changes. Save while idle; the next prompt restarts Antigravity with the new model and resumes the same conversation."
                 : "Only this tab changes. Save while idle; the next prompt uses the new settings. The conversation stays visible, but Copilot rebuilds its runtime with recent history. Long context may cost more.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = error ?? session.modelSettingsUnavailableReason ?? validationError
                ?? catalog.refreshError {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button(catalog.isRefreshing ? "Refreshing..." : "Refresh models") {
                    settings.refreshTabModels(for: session.modelSettingsBackend)
                }.disabled(catalog.isRefreshing)
                Button("Reload settings") {
                    selection = session.modelSelection
                    usesDefaults = session.ownModelSelection == nil
                    revision = session.modelSettingsRevision
                    error = nil
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try session.updateModelSettings(usesDefaults ? nil : selection, revision: revision)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .disabled(session.modelSettingsUnavailableReason != nil || validationError != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { settings.refreshTabModelsIfNeeded(for: session.modelSettingsBackend) }
    }

    private func contextLabel(_ tier: String) -> String {
        let name = tier == "default" ? "Standard" : tier == "long_context" ? "Long" : tier
        return info?.promptTokens(for: tier).map { "\(name) - \(CopilotModelInfo.tokenLabel($0)) input" } ?? name
    }
}
