import SwiftUI

struct SessionModelSettingsView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SessionModelSelection
    @State private var usesDefaults: Bool
    @State private var revision: String
    @State private var error: String?
    /// The tab's own backend; nil follows the Mac's.
    @State private var tabBackend: BackendKind?

    init(session: ChatSession) {
        self.session = session
        _selection = State(initialValue: session.modelSelection)
        _usesDefaults = State(initialValue: session.ownModelSelection == nil)
        _revision = State(initialValue: session.modelSettingsRevision)
        _tabBackend = State(initialValue: session.tabMetadata.backend)
    }

    /// The backend the tab runs on with the choices here, and the one whose models it lists.
    private var runsOn: BackendKind { session.isLocalPrivate ? .localModel : tabBackend ?? settings.backend }
    private var modelBackend: BackendKind { AppSettings.tabModelBackend(for: runsOn) }
    private var backendChange: TabBackendChange {
        tabBackend == session.tabMetadata.backend ? .unchanged : tabBackend.map { .backend($0) } ?? .mac
    }
    private var unavailableReason: String? { session.modelSettingsUnavailableReason(on: runsOn) }

    private var catalog: TabModelCatalog { settings.tabModelCatalog(for: modelBackend) }
    private var isClaude: Bool { modelBackend == .claudeCode }
    private var isAntigravity: Bool { modelBackend == .antigravity }
    private var isCodex: Bool { modelBackend == .codex }
    /// Only Copilot has context-window tiers.
    private var showsContextTiers: Bool { !isClaude && !isAntigravity && !isCodex }

    private func modelLabel(_ id: String) -> String {
        if let tier = ModelTier(model: id), let option = tierOptions.first(where: { $0.id == tier.rawValue }) {
            return "\(option.label) — \(option.modelLabel)" + (option.effort.isEmpty ? "" : " · \(option.effort)")
        }
        return isAntigravity ? settings.agyModelLabel(id) : isCodex ? settings.codexModelLabel(id) : id
    }

    /// Fast, Standard and Deep first, then the backend's models.
    private var choices: [CopilotModelInfo] { settings.tabModelChoices(for: modelBackend) }
    private var tierOptions: [ModelTierOption] { settings.tierOptions(for: modelBackend) }

    private var info: CopilotModelInfo? { choices.first { $0.id == selection.model } ?? catalog.info(selection.model) }

    private var validationError: String? {
        guard !usesDefaults, unavailableReason == nil else { return nil }
        do {
            try selection.validate(catalog: catalog.models, fileDefaultModel: catalog.fileDefaultModel)
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Model Settings").font(.headline)
            Text(session.title).foregroundStyle(.secondary).lineLimit(2)
            if session.supportsTabBackend {
                Picker("Backend", selection: Binding(get: { tabBackend }, set: chooseBackend)) {
                    Text("Mac's (\(settings.backend.rawValue))").tag(BackendKind?.none)
                    ForEach(session.tabBackendChoices, id: \.id) { choice in
                        Text(choice.note.map { "\(choice.label) — \($0)" } ?? choice.label)
                            .tag(BackendKind(rawValue: choice.id))
                    }
                }
                .disabled(session.tabSettingsBusyReason != nil)
            }
            Toggle("Use Mac defaults", isOn: $usesDefaults)
                .disabled(unavailableReason != nil)
            Form {
                Picker("Model", selection: Binding(get: { selection.model }, set: { value in
                    selection.model = value
                    selection.effort = ""
                    selection.contextTier = info?.contextTiers?.contains("default") == true ? "default" : ""
                })) {
                    Text("CLI default (\(catalog.fileDefaultModel.map(modelLabel) ?? "Auto"))").tag("")
                    ForEach(CopilotModelInfo.choices(supported: choices.map(\.id),
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
            .disabled(usesDefaults || unavailableReason != nil)
            .onChange(of: usesDefaults) { _, inherited in
                if inherited { selection = settings.tabModelDefaults(for: modelBackend) }
            }
            if let tier = ModelTier(model: selection.model) {
                let note = tierOptions.first { $0.id == tier.rawValue }?.note
                Text("\(tier.label) runs each backend's \(tier.rawValue) model (Settings ▸ Model tiers), here and on a usage-limit backup."
                     + (note.map { " Now: \($0)." } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            } else if showsContextTiers, let context = info?.contextLabel {
                Text("Advertised maximum: \(context) tokens. Tier values are input budgets, not total context.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(isClaude
                 ? "Only this tab changes. Save while idle; the next prompt restarts Claude Code with the new settings and resumes the same conversation."
                 : isAntigravity
                 ? "Only this tab changes. Save while idle; the next prompt restarts Antigravity with the new model and resumes the same conversation."
                 : isCodex
                 ? "Only this tab changes. Save while idle; the next prompt uses the new model and effort in the same Codex thread."
                 : "Only this tab changes. Save while idle; the next prompt uses the new settings. The conversation stays visible, but Copilot rebuilds its runtime with recent history. Long context may cost more.")
                .font(.caption).foregroundStyle(.secondary)
            if backendChange != .unchanged {
                Text("The next prompt runs on \(runsOn.rawValue) and continues this conversation: it gets the recent history. At a usage limit the tab moves to the Mac's backend, then its backups.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = error ?? session.tabSettingsBusyReason ?? (backendChange == .unchanged ? unavailableReason : nil)
                ?? validationError ?? catalog.refreshError {
                Text(message).font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button(catalog.isRefreshing ? "Refreshing..." : "Refresh models") {
                    settings.refreshTabModels(for: modelBackend)
                }.disabled(catalog.isRefreshing)
                Button("Reload settings") {
                    tabBackend = session.tabMetadata.backend
                    selection = session.modelSelection
                    usesDefaults = session.ownModelSelection == nil
                    revision = session.modelSettingsRevision
                    error = nil
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        // On a backend without per-tab models only the backend is saved.
                        try session.updateModelSettings(usesDefaults ? nil : selection, revision: revision,
                                                        backend: backendChange, keepsSelection: unavailableReason != nil)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .disabled(session.tabSettingsBusyReason != nil || validationError != nil
                          || (unavailableReason != nil && backendChange == .unchanged))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { settings.refreshTabModelsIfNeeded(for: modelBackend) }
    }

    /// Shows `backend`'s models with the tab's own pick there (or the Mac's); saved with Save.
    private func chooseBackend(_ backend: BackendKind?) {
        tabBackend = backend
        let kind = AppSettings.tabModelBackend(for: backend ?? settings.backend)
        let own = session.tabMetadata.modelSettings(for: kind)
        selection = own ?? settings.tabModelDefaults(for: kind)
        usesDefaults = own == nil
        error = nil
        settings.refreshTabModelsIfNeeded(for: kind)
    }

    private func contextLabel(_ tier: String) -> String {
        let name = tier == "default" ? "Standard" : tier == "long_context" ? "Long" : tier
        return info?.promptTokens(for: tier).map { "\(name) - \(CopilotModelInfo.tokenLabel($0)) input" } ?? name
    }
}
