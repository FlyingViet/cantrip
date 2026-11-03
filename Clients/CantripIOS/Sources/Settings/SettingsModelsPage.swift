import SwiftUI

/// Settings › Models: what this device's chat runs on, and for every tab on the Mac its default
/// model (read-only), model tiers, usage-limit backups and usage limits.
struct SettingsModelsPage: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel
    var canChangeGateway = true
    @Binding var fallback: CantripUsageFallback?
    @State private var tiers: CantripModelTiers?
    @State private var tiersError: String?
    @State private var tierBackend = ""
    @StateObject private var usage = CopilotUsageModel()

    var body: some View {
        Form {
            if env.hermesLanesShown {
                SettingsRunOnSection(env: env, remote: remote, canChange: canChangeGateway)
            }
            Section { SettingsScopeLabel.allTabs(on: remote.macName) }
            // The Mac's default backend and each backend's model; older Macs only report them.
            SettingsManifestSections(page: "models") {
                Section {
                    if let fallback {
                        LabeledContent("Backend", value: fallback.primary)
                        if let model = fallback.primaryChoice?.defaultModel {
                            LabeledContent("Model", value: model)
                        }
                    } else if !remote.isConfigured {
                        Text("Pair a Mac to see its models.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("New tabs")
                } footer: {
                    Text("What a tab runs until you pick its own model. Update Cantrip on the Mac to change it from here.")
                }
            }
            tiersSection
            CantripUsageFallbackSection(model: remote, fallback: $fallback)
            Section {
                NavigationLink {
                    CopilotUsageView(model: usage, remote: remote, embedded: true)
                        .task {
                            usage.useSource(remote.usageIdentity)
                            await usage.refresh { try await remote.copilotUsage() }
                        }
                } label: {
                    Label("Usage Limits", systemImage: "gauge.with.dots.needle.33percent")
                }
                .disabled(!remote.isConfigured)
                .accessibilityIdentifier("settings.usageLimits")
            } footer: {
                Text("How much of each backend's plan is used, and when it resets.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var tiersSection: some View {
        if let tiers, let backend = tiers.backend(tierBackend) ?? tiers.backends.first {
            Section {
                Picker("Backend", selection: Binding(get: { backend.id }, set: { tierBackend = $0 })) {
                    ForEach(tiers.backends) { Text($0.label).tag($0.id) }
                }
                .accessibilityIdentifier("tiers.backend")
                ForEach(backend.cells) { cell in
                    NavigationLink {
                        SettingsTierEditor(remote: remote, tiers: $tiers, backendID: backend.id, tier: cell.tier)
                    } label: {
                        SettingsTierRow(cell: cell, runs: backend.runs(cell))
                    }
                    .accessibilityIdentifier("tiers.cell.\(cell.tier)")
                }
            } header: {
                Text("Model tiers")
            } footer: {
                Text("Tabs, Home tasks and backups can ask for Fast, Standard or Deep instead of a model. Each backend runs its first model here that it offers and that isn't at its limit, so a run keeps its level on a backup.")
            }
        } else if let tiersError {
            Section {
                Text(tiersError).font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Model tiers")
            }
        }
    }

    @MainActor
    private func load() async {
        guard remote.isConfigured else { return }
        async let loadedFallback = CantripUsageFallbackSection.load(remote)
        do {
            let loaded = try await remote.modelTiers()
            tiers = loaded
            tiersError = nil
            if tierBackend.isEmpty || loaded.backend(tierBackend) == nil {
                tierBackend = loaded.backend(fallback?.primary ?? "")?.id ?? loaded.backends.first?.id ?? ""
            }
        } catch {
            tiers = nil
            tiersError = error.localizedDescription
        }
        fallback = await loadedFallback
    }
}

/// A tier's row: its name, what it's for, and the model it runs now.
struct SettingsTierRow: View {
    let cell: CantripModelTiers.Cell
    let runs: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(cell.label)
                if !cell.isDefault {
                    Text("Edited").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("Runs \(runs)").font(.caption).foregroundStyle(.secondary)
            if let note = cell.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One tier on one backend: its models in order, each with an effort; add, remove, reorder or go
/// back to Cantrip's defaults. Each change saves on the Mac at once.
struct SettingsTierEditor: View {
    @ObservedObject var remote: CantripRemoteModel
    @Binding var tiers: CantripModelTiers?
    let backendID: String
    let tier: String
    @State private var saving = false
    @State private var error: String?

    private var backend: CantripModelTiers.Backend? { tiers?.backend(backendID) }
    private var cell: CantripModelTiers.Cell? { backend?.cells.first { $0.tier == tier } }

    var body: some View {
        Form {
            if let backend, let cell {
                Section {
                    SettingsScopeLabel.allTabs(on: remote.macName)
                    Text(CantripModelTiers.summary(tier)).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(Array(cell.choices.enumerated()), id: \.element.model) { index, choice in
                        choiceRow(backend, cell: cell, index: index, choice: choice)
                    }
                    .onMove { from, to in
                        var next = cell.choices
                        next.move(fromOffsets: from, toOffset: to)
                        save(.set(cell, on: backendID, to: next, revision: tiers?.revision ?? ""))
                    }
                    .onDelete { offsets in
                        var next = cell.choices
                        next.remove(atOffsets: offsets)
                        guard !next.isEmpty else { return }
                        save(.set(cell, on: backendID, to: next, revision: tiers?.revision ?? ""))
                    }
                    addPicker(backend, cell: cell)
                } header: {
                    Text("Tried in order")
                } footer: {
                    Text(cell.note.map { "Now: \($0)." } ?? "Runs \(backend.runs(cell)) now. A model the backend doesn't offer, or that's at its own usage limit, is skipped for the next one.")
                }
                if !cell.isDefault {
                    Section {
                        Button("Use Cantrip's Defaults") { save(.resetting(cell, on: backendID, revision: tiers?.revision ?? "")) }
                            .disabled(saving)
                            .accessibilityIdentifier("tiers.reset")
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(saving)
        .navigationTitle("\(CantripModelTiers.label(tier)) · \(backend?.label ?? backendID)")
        .navigationBarTitleDisplayMode(.inline)
        #if os(iOS)
        .toolbar { EditButton() }
        #endif
    }

    private func choiceRow(_ backend: CantripModelTiers.Backend, cell: CantripModelTiers.Cell, index: Int,
                           choice: CantripModelTiers.Choice) -> some View {
        let model = backend.model(choice.model)
        let efforts = model?.efforts ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model?.label ?? choice.label ?? choice.model)
                    if model == nil, choice.offered == false {
                        Text("Not offered now").font(.caption).foregroundStyle(.orange)
                    }
                    if let price = model?.price ?? choice.price {
                        Text(price).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !efforts.isEmpty {
                Picker("Effort", selection: Binding(get: { choice.effort }, set: { effort in
                    var next = cell.choices
                    next[index].effort = effort
                    save(.set(cell, on: backendID, to: next, revision: tiers?.revision ?? ""))
                })) {
                    Text("Model default").tag("")
                    ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .accessibilityLabel("\(model?.label ?? choice.model) effort")
            }
        }
    }

    @ViewBuilder
    private func addPicker(_ backend: CantripModelTiers.Backend, cell: CantripModelTiers.Cell) -> some View {
        let free = backend.models.filter { model in !cell.choices.contains { $0.model == model.id } }
        if cell.choices.count < CantripModelTiers.maximumChoices, !free.isEmpty {
            Picker("Add a model", selection: Binding(get: { "" }, set: { id in
                guard !id.isEmpty else { return }
                save(.set(cell, on: backendID, to: cell.choices + [.init(model: id)], revision: tiers?.revision ?? ""))
            })) {
                Text("Choose…").tag("")
                ForEach(free) { model in
                    Text(model.price.map { "\(model.label) — \($0)" } ?? model.label).tag(model.id)
                }
            }
            .accessibilityIdentifier("tiers.add")
        }
    }

    private func save(_ change: CantripModelTiersChange) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            if let updated = await remote.updateModelTiers(change) {
                tiers = updated
                error = nil
            } else {
                error = remote.errorMessage ?? "The tier couldn't be saved."
                tiers = try? await remote.modelTiers()
            }
        }
    }
}

/// Which agent this device's chat talks to: Cantrip on the Mac, or a Hermes gateway. Shown only
/// while a Hermes backend is in the picker; the order and which ones show are under Backends.
struct SettingsRunOnSection: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel
    var canChange = true

    var body: some View {
        Section {
            SettingsScopeLabel.thisDevice()
            ForEach(env.selectableLanes) { lane in
                Button {
                    env.select(lane)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: lane.systemImage).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lane.title).foregroundStyle(.primary)
                            Text(lane.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if lane == env.executionLane.pickerLane {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!env.isAvailable(lane) || !canChange || remote.isMutating)
                .accessibilityAddTraits(lane == env.executionLane.pickerLane ? [.isSelected] : [])
            }
            NavigationLink {
                BackendSettingsView(env: env)
            } label: {
                LabeledContent {
                    Text("\(env.selectableLanes.count) shown")
                } label: {
                    Label("Backends", systemImage: "line.3.horizontal.decrease")
                }
            }
        } header: {
            Text("Run on")
        } footer: {
            Text("Cantrip runs on your Mac; a Hermes gateway runs on the server you set up. Each keeps its own conversation.")
        }
    }
}
