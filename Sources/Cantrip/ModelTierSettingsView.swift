import SwiftUI

/// Settings › Model tiers: each backend's models for fast, standard and deep, first choice first,
/// each with its effort. A run on a tier takes the first one its backend offers that isn't at its
/// own usage limit. Copilot's token prices show next to each model.
struct ModelTierSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var backend: BackendKind = .copilot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model tiers").font(.caption).foregroundStyle(.secondary)
            Picker("Backend", selection: $backend) {
                ForEach(ModelTierMap.backends) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            ForEach(ModelTier.allCases, id: \.self) { tier in
                cell(tier)
            }
            Text("Tabs, Home tasks, child tabs, usage-limit backups and the OpenAI-compatible API can ask for Fast, Standard or Deep instead of a model. Each backend runs its first model here that it offers and that isn't at its own usage limit, so a deep run stays deep when a backup takes over. A change applies everywhere at once.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { settings.refreshTabModelsIfNeeded(for: backend) }
        .onChange(of: backend) { _, kind in settings.refreshTabModelsIfNeeded(for: kind) }
    }

    private var catalog: TabModelCatalog { settings.tabModelCatalog(for: backend) }

    @ViewBuilder
    private func cell(_ tier: ModelTier) -> some View {
        let choices = settings.tierChoices(tier, on: backend)
        let resolved = settings.resolveTier(tier, on: backend)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(tier.label).font(.caption.weight(.semibold))
                Text("runs \(resolved.model.isEmpty ? "the default model" : settings.fallbackModelLabel(backend, resolved.model))"
                     + (resolved.effort.isEmpty ? "" : " · \(resolved.effort)"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if !settings.modelTiers.isDefault(tier, on: backend) {
                    Button("Reset") { settings.modelTiers.set(nil, for: tier, on: backend) }
                        .font(.caption2)
                        .help("Go back to Cantrip's default models for \(tier.label) on \(backend.rawValue)")
                }
            }
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                choiceRow(tier, choices: choices, index: index, choice: choice)
            }
            let free = catalog.models.filter { model in !choices.contains { $0.model == model.id } }
            if choices.count < ModelTierMap.maximumChoices, !free.isEmpty {
                Menu("Add a model") {
                    ForEach(free) { model in
                        Button(optionLabel(model.id)) {
                            set(tier, choices + [ModelTierChoice(model: model.id)])
                        }
                    }
                }
                .font(.caption)
                .fixedSize()
                .padding(.leading, 18)
            }
            if let note = resolved.note {
                Text("Now: \(note).").font(.caption2).foregroundStyle(.orange).padding(.leading, 18)
            }
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func choiceRow(_ tier: ModelTier, choices: [ModelTierChoice], index: Int, choice: ModelTierChoice) -> some View {
        let info = catalog.info(choice.model)
        let offered = catalog.models.isEmpty || info != nil
        HStack(spacing: 6) {
            Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Picker("Model", selection: Binding(get: { choice.model }, set: { model in
                var next = choices
                next[index] = ModelTierChoice(model: model)
                set(tier, next)
            })) {
                ForEach(catalog.models.filter { model in model.id == choice.model || !choices.contains { $0.model == model.id } }) {
                    Text(optionLabel($0.id)).tag($0.id)
                }
                if !offered { Text("\(choice.model) (not offered now)").tag(choice.model) }
            }
            .labelsHidden()
            .help("Model \(index + 1) for \(tier.label) on \(backend.rawValue)")
            if let efforts = info?.reasoningEfforts, !efforts.isEmpty {
                Picker("Effort", selection: Binding(get: { choice.effort }, set: { effort in
                    var next = choices
                    next[index].effort = effort
                    set(tier, next)
                })) {
                    Text("Model default").tag("")
                    ForEach(efforts, id: \.self) { Text($0).tag($0) }
                    if !choice.effort.isEmpty, !efforts.contains(choice.effort) { Text(choice.effort).tag(choice.effort) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 4)
            Button { move(tier, choices, index, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Try earlier")
            Button { move(tier, choices, index, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == choices.count - 1)
                .help("Try later")
            Button { set(tier, choices.enumerated().filter { $0.offset != index }.map(\.element)) } label: {
                Image(systemName: "minus.circle")
            }
            .disabled(choices.count == 1)
            .help("Remove \(settings.fallbackModelLabel(backend, choice.model))")
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .font(.caption)
        .padding(.leading, 18)
    }

    /// The model's name, with Copilot's token prices.
    private func optionLabel(_ id: String) -> String {
        let name = settings.fallbackModelLabel(backend, id)
        return catalog.info(id)?.price?.label.map { "\(name) — \($0)" } ?? name
    }

    private func set(_ tier: ModelTier, _ choices: [ModelTierChoice]) {
        guard !choices.isEmpty else { return }
        settings.modelTiers.set(Array(choices.prefix(ModelTierMap.maximumChoices)), for: tier, on: backend)
    }

    private func move(_ tier: ModelTier, _ choices: [ModelTierChoice], _ index: Int, by offset: Int) {
        var next = choices
        guard next.indices.contains(index + offset) else { return }
        next.swapAt(index, index + offset)
        set(tier, next)
    }
}
