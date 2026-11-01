import SwiftUI
import AVFoundation

/// Speech recognition, dictation vocabulary and the reply voice. Saved on this device.
struct SettingsVoicePage: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel
    let voice: VoiceController
    @ObservedObject private var parakeet = ParakeetSpeechEngine.shared
    @AppStorage("hermes.sttEngine") private var sttEngine = SpeechInputEngine.parakeet.rawValue
    @AppStorage("hermes.voicePause") private var voicePause = 2.5
    @AppStorage("hermes.voiceEngine") private var voiceEngine = "system"

    var body: some View {
        Form {
            Section { SettingsScopeLabel.thisDevice() }
            speechRecognition
            DictationSettingsSection(remote: remote)
            replyVoice
        }
        .formStyle(.grouped)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var speechRecognition: some View {
        Section {
            Picker("Engine", selection: $sttEngine) {
                ForEach(SpeechInputEngine.allCases) { engine in
                    Text(engine.title).tag(engine.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: sttEngine) { _, _ in voice.requestAuth() }
            if sttEngine == SpeechInputEngine.parakeet.rawValue {
                ParakeetStateRow(state: parakeet.state)
                switch parakeet.state {
                case .idle, .cached, .failed:
                    Button(parakeet.isPrepared ? "Load Parakeet" : "Download Parakeet",
                           systemImage: "waveform.badge.magnifyingglass", action: prepareParakeet)
                case .preparing, .ready:
                    EmptyView()
                }
            }
        } header: {
            Text("Speech recognition")
        } footer: {
            Text("Parakeet runs entirely on this device and answers fastest; it needs a one-time download. Apple Speech needs no download.")
        }
    }

    private var replyVoice: some View {
        Section {
            NavigationLink {
                QwenVoiceSettingsView()
            } label: {
                LabeledContent {
                    Text(voiceEngine == "qwen" ? "Qwen3 (Neural)" : "System")
                } label: {
                    Label("Voice engine", systemImage: "waveform")
                }
            }
            NavigationLink {
                VoiceListView(env: env, voice: voice)
            } label: {
                LabeledContent {
                    Text(currentVoiceName)
                } label: {
                    Label("Reply voice", systemImage: "speaker.wave.2")
                }
            }
            .disabled(voiceEngine == "qwen")
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent {
                    Text(String(format: "%.1fs", voicePause)).monospacedDigit()
                } label: {
                    Label("Pause before sending", systemImage: "timer")
                }
                Slider(value: $voicePause, in: 1.5...5.0, step: 0.5)
                    .accessibilityLabel("Pause before sending")
                    .accessibilityValue(String(format: "%.1f seconds", voicePause))
            }
        } header: {
            Text("Replies")
        } footer: {
            Text("How long to wait after you stop talking before sending. Raise it if a thinking or breathing pause sends your message too early.")
        }
    }

    private var currentVoiceName: String {
        guard !env.voiceId.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: env.voiceId) else { return "Default" }
        return voice.name
    }

    private func prepareParakeet() {
        Task {
            do {
                await QwenVoiceEngine.shared.releaseMemory()
                try await ParakeetSpeechEngine.shared.prepareIfNeeded()
            } catch {
                // The engine publishes the actionable error in its state row.
            }
        }
    }
}

/// Parakeet's download and load state.
struct ParakeetStateRow: View {
    let state: ParakeetSpeechEngine.ModelState

    var body: some View {
        switch state {
        case .idle:
            Label("Model not downloaded", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        case .cached:
            Label("Model downloaded", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .ready:
            Label("Parakeet ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .preparing(let progress, let phase):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(phase)
                    Spacer()
                    Text("\(Int(progress * 100))%").foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: progress)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        }
    }
}

/// Alerts when a tab finishes or needs you, the widget and the Live Activity. iPhone only.
struct SettingsNotificationsPage: View {
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        Form {
            Section { SettingsScopeLabel.thisDevice() }
            CantripNotificationSettingsSection(remote: remote)
            #if os(iOS)
            CantripLiveStatusSettingsSection()
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The mascot and how much of a reply's work shows. Saved on this device.
struct SettingsAppearancePage: View {
    @AppStorage("hermes.showSteps") private var showSteps = false
    @AppStorage(CantripMascotName.storageKey) private var mascotName = ""

    var body: some View {
        Form {
            Section { SettingsScopeLabel.thisDevice() }
            Section {
                NavigationLink {
                    CantripMascotCustomizationView(embedded: true)
                } label: {
                    LabeledContent {
                        Text(CantripMascotName.display(mascotName))
                    } label: {
                        Label("Mascot", systemImage: "tshirt")
                    }
                }
                .accessibilityIdentifier("settings.mascot")
            } footer: {
                Text("Its name and look in Cantrip Home.")
            }
            Section {
                Toggle(isOn: $showSteps) {
                    Label("Show reasoning steps", systemImage: "list.bullet.indent")
                }
            } footer: {
                Text("Off shows only the final answer. On also shows the agent's notes as it works. Tool steps show either way.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What Cantrip remembers on the paired Mac, read-only.
struct SettingsMemoryPage: View {
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        CantripMemoryView(remote: remote, embedded: true)
            .safeAreaInset(edge: .top, spacing: 0) {
                SettingsScopeLabel.allTabs(on: remote.macName)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
    }
}

/// The Mac's shared MCP servers and their sign-ins; on Gateway Mac also its local model's tools.
struct SettingsToolsPage: View {
    @ObservedObject var remote: CantripRemoteModel
    var macTools: AnyView? = nil

    var body: some View {
        CantripMCPServersView(remote: remote, tabID: nil, embedded: true, extra: macTools)
            .safeAreaInset(edge: .top, spacing: 0) {
                SettingsScopeLabel.allTabs(on: remote.macName)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
            .navigationTitle("Tools & sign-ins")
    }
}

/// This app's version, Cantrip's update on the Mac, and the Mac's permissions.
struct SettingsAboutPage: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Self.version)
            } header: {
                Text("This app")
            }
            Section {
                NavigationLink {
                    CantripMaintenanceView(remote: remote)
                        .navigationTitle("Update Cantrip")
                } label: {
                    Label("Update & rebuild Cantrip", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("settings.maintenance")
                NavigationLink {
                    CantripMacAccessView(remote: remote)
                } label: {
                    Label("Mac permissions & View Mac", systemImage: "display")
                }
                .accessibilityIdentifier("settings.macAccess")
            } header: {
                Text("Cantrip on \(remote.macName)")
            } footer: {
                Text("Update pulls Cantrip's latest version on the Mac and reopens it when no tab is working. Permissions shows what the Mac lets Cantrip do, and lets you view its screen.")
            }
            .disabled(!remote.isConfigured)
            if env.hermesLanesShown {
                SettingsHermesConnectionSection(env: env)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About & Updates")
        .navigationBarTitleDisplayMode(.inline)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

/// Checks the selected Hermes gateway, shown only while a Hermes backend is in the picker.
struct SettingsHermesConnectionSection: View {
    @ObservedObject var env: HermesEnv
    @State private var testing = false

    var body: some View {
        Section {
            Button {
                Task {
                    testing = true
                    _ = await env.refreshGateway()
                    testing = false
                }
            } label: {
                HStack {
                    Text("Test Hermes gateway")
                    Spacer()
                    indicator
                }
            }
            .disabled(env.client(for: .copilot) == nil || testing)
            if case .failed(let message) = env.connectionState {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Hermes")
        } footer: {
            Text("Checks that the selected Hermes gateway answers with its API key.")
        }
    }

    @ViewBuilder private var indicator: some View {
        if testing || env.connectionState == .checking {
            ProgressView()
        } else if env.connectionState == .connected {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Connected")
        } else if case .failed = env.connectionState {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        }
    }
}

extension HermesEnv {
    /// Whether Hermes' settings show: only with a Hermes gateway saved on this device and a Hermes
    /// backend in the picker. Everyone else sees Cantrip's settings alone.
    var hermesLanesShown: Bool {
        !servers.servers.isEmpty && selectableLanes.contains { !$0.usesCantripRemote }
    }
}
