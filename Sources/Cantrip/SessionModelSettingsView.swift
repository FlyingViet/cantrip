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
        _usesDefaults = State(initialValue: session.tabMetadata.modelSettings == nil)
        _revision = State(initialValue: session.modelSettingsRevision)
    }

    private var info: CopilotModelInfo? {
        settings.copilotModelInfo(selection.model.isEmpty
                                  ? settings.copilotFileDefaultModel ?? "" : selection.model)
    }

    private var validationError: String? {
        guard !usesDefaults else { return nil }
        do {
            try selection.validate(catalog: settings.copilotModelCatalog,
                                   fileDefaultModel: settings.copilotFileDefaultModel)
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
                    Text("CLI default (\(settings.copilotFileDefaultModel ?? "Auto"))").tag("")
                    ForEach(CopilotModelInfo.choices(supported: settings.copilotModelCatalog.map(\.id),
                                                   fallback: [], selected: selection.model), id: \.self) {
                        Text($0).tag($0)
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
                Picker("Context window", selection: $selection.contextTier) {
                    Text("CLI default").tag("")
                    ForEach(CopilotModelInfo.choices(supported: info?.contextTiers,
                                                   fallback: [], selected: selection.contextTier), id: \.self) { tier in
                        Text(contextLabel(tier)).tag(tier)
                            .disabled(info?.contextTiers?.contains(tier) != true)
                    }
                }
            }
            .disabled(usesDefaults || session.modelSettingsUnavailableReason != nil)
            .onChange(of: usesDefaults) { _, inherited in
                if inherited { selection = session.defaultModelSelection }
            }
            if let context = info?.contextLabel {
                Text("Advertised maximum: \(context) tokens. Tier values are input budgets, not total context.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Only this tab changes. Save while idle; the next prompt uses the new settings. The conversation stays visible, but Copilot rebuilds its runtime with recent history. Long context may cost more.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = error ?? session.modelSettingsUnavailableReason ?? validationError
                ?? settings.copilotModelRefreshError {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button(settings.copilotRefreshInFlight ? "Refreshing..." : "Refresh models") {
                    settings.refreshCopilotModels()
                }.disabled(settings.copilotRefreshInFlight)
                Button("Reload settings") {
                    selection = session.modelSelection
                    usesDefaults = session.tabMetadata.modelSettings == nil
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
        .onAppear { settings.refreshCopilotModelsIfNeeded() }
    }

    private func contextLabel(_ tier: String) -> String {
        let name = tier == "default" ? "Standard" : tier == "long_context" ? "Long" : tier
        return info?.promptTokens(for: tier).map { "\(name) - \(CopilotModelInfo.tokenLabel($0)) input" } ?? name
    }
}
