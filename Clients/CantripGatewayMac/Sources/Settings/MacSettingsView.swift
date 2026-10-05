import AVFoundation
import SwiftUI

/// Settings (⌘,): pairing with Cantrip and voice. Built from the same shared sections as
/// the iOS Settings screen, minus the iOS-only lanes, push alerts and Live Activities.
struct MacSettingsView: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject var voice: VoiceController

    var body: some View {
        TabView {
            Tab("Connection", systemImage: "antenna.radiowaves.left.and.right") {
                MacConnectionSettings(remote: remote)
            }
            Tab("Voice", systemImage: "waveform") {
                MacVoiceSettings(env: env, voice: voice)
            }
        }
        .frame(width: 620, height: 600)
    }
}

struct MacConnectionSettings: View {
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        Form {
            Section {
                Label("Connect to Cantrip", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Text("Enter the pairing token from Cantrip's Remote control settings. Cantrip Gateway prefers your saved Tailscale Serve URL, even on the same network. Direct LAN is used if Tailscale is unavailable or no URL is saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Circle()
                        .fill(remote.isConnected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(remote.isConnected ? "Connected to \(remote.endpointHost)" : remote.connectionLabel)
                        .font(.callout)
                }
                .accessibilityElement(children: .combine)
            }
            CantripRemoteSettingsSection(model: remote)
        }
        .formStyle(.grouped)
    }
}

struct MacVoiceSettings: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var voice: VoiceController
    @ObservedObject private var parakeet = ParakeetSpeechEngine.shared
    @AppStorage("hermes.sttEngine") private var sttEngine = SpeechInputEngine.parakeet.rawValue
    @AppStorage("hermes.voicePause") private var voicePause = 2.5
    @AppStorage("hermes.voiceEngine") private var voiceEngine = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Engine", selection: $sttEngine) {
                        ForEach(SpeechInputEngine.allCases) { engine in
                            Text(engine.title).tag(engine.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: sttEngine) { _, _ in voice.requestAuth() }
                    if sttEngine == SpeechInputEngine.parakeet.rawValue {
                        parakeetState
                        switch parakeet.state {
                        case .idle, .cached, .failed:
                            Button(parakeet.isPrepared ? "Load Parakeet" : "Download Parakeet",
                                   systemImage: "waveform.badge.magnifyingglass", action: prepareParakeet)
                        case .preparing, .ready:
                            EmptyView()
                        }
                    }
                } header: {
                    Text("Speech Recognition")
                } footer: {
                    Text("Parakeet EOU runs entirely on this Mac and is the recommended low-latency engine. Apple Speech remains available as a no-download fallback.")
                }

                Section {
                    NavigationLink {
                        QwenVoiceSettingsView()
                    } label: {
                        LabeledContent("Voice engine") {
                            Text(voiceEngine == "qwen" ? "Qwen3 (Neural)" : "System")
                        }
                    }
                    NavigationLink {
                        VoiceListView(env: env, voice: voice)
                    } label: {
                        LabeledContent("Reply voice") { Text(currentVoiceName) }
                    }
                    .disabled(voiceEngine == "qwen")
                    LabeledContent("Pause before sending") {
                        HStack {
                            Slider(value: $voicePause, in: 1.5...5.0, step: 0.5)
                                .frame(width: 200)
                            Text(String(format: "%.1fs", voicePause)).monospacedDigit()
                        }
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("How long to wait after you stop talking before sending. Raise it if a thinking or breathing pause sends your prompt too early.")
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder private var parakeetState: some View {
        switch parakeet.state {
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

    private var currentVoiceName: String {
        guard !env.voiceId.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: env.voiceId) else {
            return "Default"
        }
        return voice.name
    }

    private func prepareParakeet() {
        Task {
            do {
                await QwenVoiceEngine.shared.releaseMemory()
                try await parakeet.prepareIfNeeded()
            } catch {
                // The engine publishes the actionable error in its state row.
            }
        }
    }
}
