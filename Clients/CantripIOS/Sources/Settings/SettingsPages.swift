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
                    .settingsBack(to: SettingsPage.voice.title)
            } label: {
                LabeledContent {
                    Text(voiceEngine == "qwen" ? "Qwen3 (Neural)" : "System")
                } label: {
                    Label("Voice engine", systemImage: "waveform")
                }
            }
            NavigationLink {
                VoiceListView(env: env, voice: voice)
                    .settingsBack(to: SettingsPage.voice.title)
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

/// The mascot and how much of a reply's work shows. Saved on this device. In Cantrip's own
/// Settings window on the Mac, also the panel and ⌥Space (the Mac app's settings).
struct SettingsAppearancePage: View {
    @AppStorage("hermes.showSteps") private var showSteps = false
    @AppStorage(CantripMascotName.storageKey) private var mascotName = ""

    var body: some View {
        Form {
            Section { SettingsScopeLabel.thisDevice() }
            SettingsManifestSections(page: "appearance")
            Section {
                NavigationLink {
                    CantripMascotCustomizationView(embedded: true)
                        .settingsBack(to: SettingsPage.appearance.title)
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

/// Cantrip Home, child tabs and what new tabs start with, for every tab on the Mac.
struct SettingsHomeTabsPage: View {
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        Form {
            Section { SettingsScopeLabel.allTabs(on: remote.macName) }
            SettingsManifestSections(page: "home") {
                Section {
                    Text(remote.isConfigured ? CantripRemoteError.settingsUnsupported.localizedDescription
                                             : "Pair a Mac to change its settings.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Home & tabs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What Cantrip remembers on the paired Mac: whether it does and where, and its notes, read-only.
struct SettingsMemoryPage: View {
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        CantripMemoryView(remote: remote, embedded: true,
                          leading: AnyView(SettingsManifestSections(page: "memory")))
            .safeAreaInset(edge: .top, spacing: 0) {
                SettingsScopeLabel.allTabs(on: remote.macName)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
    }
}

/// The Mac's agent backends and their sign-ins, its shared MCP servers; on Gateway Mac also its
/// local model's tools.
struct SettingsToolsPage: View {
    @ObservedObject var remote: CantripRemoteModel
    var macTools: AnyView? = nil
    /// Opens Cantrip Home's chat, where GitHub's sign-in code shows.
    var onOpenHome: () -> Void = {}

    var body: some View {
        CantripMCPServersView(remote: remote, tabID: nil, embedded: true, extra: macTools,
                              leading: AnyView(Group {
                                  CantripBackendsSection(remote: remote)
                                  SettingsGitHubSection(remote: remote, onOpenHome: onOpenHome)
                                  SettingsRulesAndSecretsSection(remote: remote)
                                  SettingsManifestSections(page: "tools")
                              }))
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

/// GitHub on the Mac (the `gh` CLI every backend uses for pushes, pull requests and GitHub Builds):
/// Sign In runs GitHub's device sign-in in Cantrip Home, whose chat shows the code to enter at
/// github.com. It's the Mac's sign-in, so it's here rather than in a tab's menu.
struct SettingsGitHubSection: View {
    @ObservedObject var remote: CantripRemoteModel
    let onOpenHome: () -> Void
    @State private var working = false
    @State private var started = false
    @State private var error: String?

    /// Why Sign In can't run now; nil when it can.
    static func unavailableReason(isConfigured: Bool, home: CantripRemoteSession?) -> String? {
        guard isConfigured, let home else { return "Connect to your Mac to sign in." }
        guard home.supportsInputRequests == true else { return "Update and reopen Cantrip on your Mac to sign in from here." }
        return nil
    }

    var body: some View {
        let unavailable = Self.unavailableReason(isConfigured: remote.isConfigured, home: remote.homeSummary)
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub on your Mac")
                    Text(unavailable ?? (started ? "Started in Cantrip Home: its chat shows GitHub's code."
                                         : "GitHub CLI (gh), shared by every backend"))
                        .font(.caption)
                        .foregroundStyle(unavailable == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                Button(started ? "Open Home" : "Sign In…") { started ? onOpenHome() : signIn() }
                    .disabled(unavailable != nil || working || remote.isMutating)
                    .fixedSize()
                    .accessibilityIdentifier("settings.github.signIn")
            }
            #if os(macOS)
            // macOS draws a section footer on one line; in the section it wraps.
            Text(Self.explanation).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Sign-ins")
        } footer: {
            #if os(iOS)
            Text(Self.explanation)
            #endif
        }
    }

    static let explanation = "Signs the Mac's GitHub CLI in to github.com with GitHub's device sign-in, for pushes, pull requests and GitHub Builds in every backend. It runs in Cantrip Home, whose chat shows a code to enter at github.com/login/device; no password goes through Cantrip."

    private func signIn() {
        guard let home = remote.homeSummary else { return }
        working = true
        Task {
            defer { working = false }
            if await remote.send("/login github", mode: .queue, sessionID: home.id) {
                started = true
                error = nil
                onOpenHome()
            } else {
                error = remote.errorMessage ?? "The sign-in didn't start."
            }
        }
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
                        .settingsBack(to: SettingsPage.about.title)
                } label: {
                    Label("Update & rebuild Cantrip", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("settings.maintenance")
                NavigationLink {
                    CantripMacAccessView(remote: remote)
                        .settingsBack(to: SettingsPage.about.title)
                } label: {
                    Label("Mac permissions & View Mac", systemImage: "display")
                }
                .accessibilityIdentifier("settings.macAccess")
                NavigationLink {
                    CantripSkillsView(remote: remote, embedded: true)
                        .settingsBack(to: SettingsPage.about.title)
                } label: {
                    Label(CantripSkills.title, systemImage: "books.vertical")
                }
                .accessibilityIdentifier("settings.skills")
            } header: {
                Text("Cantrip on \(remote.macName)")
            } footer: {
                Text("Update pulls Cantrip's latest version on the Mac and reopens it when no tab is working. Permissions shows what the Mac lets Cantrip do, and lets you view its screen. Skills & Rules turns the Mac's shared skills on or off for every backend.")
            }
            .disabled(!remote.isConfigured)
            SettingsManifestSections(page: "about")
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
