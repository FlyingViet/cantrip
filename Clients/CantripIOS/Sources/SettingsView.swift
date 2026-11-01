import SwiftUI
import AVFoundation

/// Settings: a status card, then one row per page (`SettingsPage`), the same map on every client.
/// iPhone shows the list and opens a page over it; an unfolded iPhone Duo and Gateway Mac show the
/// list and the open page side by side. Folding keeps the open page, with its back button.
struct SettingsView: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel
    let voice: VoiceController
    var canChangeGateway = true
    /// Gateway Mac's own sections for the Tools page (the local model's MCP tools).
    var macTools: AnyView? = nil
    /// The presenting chat's traits: a sheet's own window never hears the Duo's hinge.
    var displayTraits = ChatDisplayTraits()
    @Environment(\.dismiss) private var dismiss
    @State private var page: SettingsPage?
    @State private var fallback: CantripUsageFallback?
    @AppStorage(SettingsPage.lastPageKey) private var lastPage = ""

    private var showsSideBySide: Bool {
        #if os(macOS)
        true
        #else
        displayTraits.isUnfoldedDuo
        #endif
    }

    var body: some View {
        Group {
            if showsSideBySide { split } else { stack }
        }
        .task {
            fallback = await CantripUsageFallbackSection.load(remote)
            _ = await env.refreshGateway()
        }
        .onChange(of: page) { _, page in
            if let page { lastPage = page.rawValue }
        }
        .onChange(of: showsSideBySide, initial: true) { _, sideBySide in
            // Beside the list a page is always open: the last one, or Macs.
            if sideBySide, page == nil { page = Self.restoredPage(lastPage) }
        }
        #if DEBUG
        .onAppear { if let target = CantripUITestFixtures.settingsPage { page = target } }
        #endif
    }

    /// The saved page if this device shows it, else Macs.
    static func restoredPage(_ saved: String) -> SettingsPage {
        SettingsPage(rawValue: saved).flatMap { SettingsPage.available.contains($0) ? $0 : nil } ?? .macs
    }

    private var stack: some View {
        NavigationStack(path: Binding(
            get: { page.map { [$0] } ?? [] },
            set: { page = $0.last }
        )) {
            home
                .navigationDestination(for: SettingsPage.self) { pageView($0) }
        }
    }

    #if os(macOS)
    private var split: some View {
        NavigationSplitView {
            home
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            NavigationStack {
                pageView(page ?? .macs)
            }
            .id(page)
        }
        .navigationSplitViewStyle(.balanced)
    }
    #else
    /// Two columns drawn directly: a sheet is compact even on an unfolded Duo, which would
    /// collapse a `NavigationSplitView` back into a stack.
    private var split: some View {
        HStack(spacing: 0) {
            NavigationStack { home }
                .frame(width: 290)
            Divider()
                .ignoresSafeArea()
            NavigationStack {
                pageView(page ?? .macs)
            }
            .id(page)
        }
    }
    #endif

    private var home: some View {
        homeList
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
                #endif
            }
            .refreshable { fallback = await CantripUsageFallbackSection.load(remote) }
    }

    /// The Mac's sidebar selects through the list; on iOS any selection binding, even a constant
    /// one, keeps a row's NavigationLink from pushing its page.
    @ViewBuilder
    private var homeList: some View {
        #if os(macOS)
        List(selection: $page) { homeRows }
        #else
        List { homeRows }
        #endif
    }

    @ViewBuilder
    private var homeRows: some View {
        Section {
            SettingsStatusCard(remote: remote, fallback: fallback)
            SettingsPauseRow()
        }
        Section {
            ForEach(SettingsPage.available) { item in
                #if os(iOS)
                if showsSideBySide {
                    Button { page = item } label: {
                        SettingsPageRow(page: item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .listRowBackground(page == item ? Color.accentColor.opacity(0.22) : nil)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                } else {
                    NavigationLink(value: item) { SettingsPageRow(page: item) }
                }
                #else
                NavigationLink(value: item) { SettingsPageRow(page: item) }
                    .tag(item)
                #endif
            }
        }
    }

    @ViewBuilder
    private func pageView(_ page: SettingsPage) -> some View {
        switch page {
        case .macs:
            SettingsMacsPage(env: env, remote: remote, canChangeGateway: canChangeGateway)
        case .models:
            SettingsModelsPage(env: env, remote: remote, canChangeGateway: canChangeGateway, fallback: $fallback)
        case .tools:
            SettingsToolsPage(remote: remote, macTools: macTools)
        case .memory:
            SettingsMemoryPage(remote: remote)
        case .voice:
            SettingsVoicePage(env: env, remote: remote, voice: voice)
        case .notifications:
            SettingsNotificationsPage(remote: remote)
        case .appearance:
            SettingsAppearancePage()
        case .about:
            SettingsAboutPage(env: env, remote: remote)
        }
    }
}

struct BackendSettingsView: View {
    @ObservedObject var env: HermesEnv

    var body: some View {
        List {
            Section {
                ForEach(env.backendOrder) { lane in
                    Toggle(isOn: Binding(
                        get: { env.isLaneVisible(lane) },
                        set: { env.setLaneVisible(lane, isVisible: $0) }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lane.title)
                                Text(lane.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: lane.systemImage)
                                .foregroundStyle(laneTint(lane))
                        }
                    }
                    .disabled(!env.canHide(lane))
                    .accessibilityHint(
                        env.canHide(lane)
                            ? "Controls whether this backend appears in the picker."
                            : lane == .home
                                ? "Cantrip Home holds your project tabs, so it always stays visible."
                                : "At least one backend must remain visible."
                    )
                }
                .onMove(perform: env.moveBackends)
            } header: {
                Text("Shown in picker")
            } footer: {
                Text("Tap Edit, then drag backends into the order you want. Cantrip Home always stays visible: your project tabs live in its drawer.")
            }
        }
        .navigationTitle("Backends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditButton()
            }
        }
    }

    private func laneTint(_ lane: ExecutionLane) -> Color {
        switch lane {
        case .copilot: .orange
        case .local: .green
        case .cantrip: .cyan
        case .home: .purple
        }
    }
}

struct VoiceListView: View {
    @ObservedObject var env: HermesEnv
    let voice: VoiceController

    var body: some View {
        List {
            Section {
                ForEach(VoiceController.voices(), id: \.identifier) { v in
                    Button {
                        env.voiceId = v.identifier
                        voice.preview(voiceId: v.identifier)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: env.voiceId == v.identifier ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(env.voiceId == v.identifier ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.name)
                                Text("\(v.language) · \(qualityLabel(v.quality))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.circle").foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
            } header: {
                Text("Premium / Enhanced voices sound close to Siri — Default ones are robotic.")
                    .textCase(nil)
            } footer: {
                Text("Tap a voice to select it and hear a sample. Don't see a Premium voice? Download one in iOS Settings → Accessibility → Spoken Content → Voices → English.")
            }
        }
        .navigationTitle("Reply Voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
}

/// Voice-engine picker + Qwen3-TTS model management (download / speaker / delete).
struct QwenVoiceSettingsView: View {
    @ObservedObject private var engine = QwenVoiceEngine.shared
    @AppStorage("hermes.voiceEngine") private var voiceEngine = "system"
    @AppStorage("hermes.qwenPreset") private var presetId = "serena-gentle"
    @AppStorage("hermes.qwenRate") private var rate = 1.15
    @AppStorage("hermes.qwenModelQuality") private var modelQuality = "compact"
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $voiceEngine) {
                    Text("System").tag("system")
                    Text("Qwen3 (Neural)").tag("qwen")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Qwen3 runs a neural voice entirely on-device (MLX). Much more natural than the system voice; needs a one-time ~800 MB model download and uses the GPU while speaking. Replies fall back to the system voice until the model is ready.")
            }

            if voiceEngine == "qwen" {
                Section {
                    Picker("Model quality", selection: $modelQuality) {
                        Text("Compact · 808 MB").tag("compact")
                        Text("High · 1.5 GB").tag("high")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: modelQuality) { _, _ in engine.refreshModelState() }
                    if let err = engine.loadError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.footnote)
                    }
                } footer: {
                    Text("Compact is 4-bit quantized — on a small voice model that can surface as occasional slurred words. High is the same voice at full precision (lossless), at the cost of a bigger download and noticeably more memory while speaking (not all devices have the headroom).")
                }

                Section("Model") {
                    switch engine.download {
                    case .idle:
                        Button {
                            engine.downloadModel()
                        } label: {
                            Label("Download model (~800 MB)", systemImage: "arrow.down.circle")
                        }
                    case .downloading(let p):
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Downloading…")
                                Spacer()
                                Text("\(Int(p * 100))%").foregroundStyle(.secondary).monospacedDigit()
                            }
                            ProgressView(value: p)
                        }
                        Button("Cancel", role: .destructive) { engine.cancelDownload() }
                    case .ready:
                        HStack {
                            Label("Model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: engine.modelSizeBytes, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    case .failed(let msg):
                        Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button("Retry download") { engine.downloadModel() }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Reading speed", systemImage: "gauge.with.needle")
                            Spacer()
                            Text(String(format: "%.2f×", rate)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $rate, in: 1.0...1.5, step: 0.05)
                    }
                } footer: {
                    Text("Speeds up playback without changing pitch — more reliable than making the voice itself talk faster.")
                }

                presetSection(QwenVoiceEngine.gentlePresets, header: "Gentle presets",
                              footer: "Female voices tuned for a soft tone with crisp articulation. Tap to select and hear a sample (once the model is downloaded).")
                presetSection(QwenVoiceEngine.plainPresets, header: "All speakers",
                              footer: "The model's built-in speakers, unstyled. Download on Wi-Fi — it's a one-time ~800 MB fetch from Hugging Face.")
                if engine.download == .ready {
                    Section {
                        Button("Delete model…", role: .destructive) { confirmingDelete = true }
                            .accessibilityIdentifier("voice.deleteModel")
                    } footer: {
                        Text("Frees the space on this device. Replies use the system voice until you download it again.")
                    }
                }
            }
        }
        .confirmationDialog("Delete the Qwen3 voice model?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete model", role: .destructive) { engine.deleteModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It frees \(ByteCountFormatter.string(fromByteCount: engine.modelSizeBytes, countStyle: .file)). Downloading it again takes a while.")
        }
        .navigationTitle("Voice Engine")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { QwenVoiceEngine.shared.stop() }
    }

    @ViewBuilder private func presetSection(_ presets: [QwenPreset], header: String, footer: String) -> some View {
        Section {
            ForEach(presets) { p in
                Button {
                    presetId = p.id
                    if engine.download == .ready { engine.preview() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: presetId == p.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(presetId == p.id ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                            Text(p.blurb).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "play.circle").foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
        } header: {
            Text(header)
        } footer: {
            Text(footer)
        }
    }
}
