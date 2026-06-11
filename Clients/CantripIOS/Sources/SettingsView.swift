import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject var env: HermesEnv
    let voice: VoiceController
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var testing = false
    @State private var testResult: Bool?
    @AppStorage("hermes.voicePause") private var voicePause = 2.5
    @AppStorage("hermes.showSteps") private var showSteps = false
    @AppStorage("hermes.voiceEngine") private var voiceEngine = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-gateway.example.com", text: $env.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("API key (API_SERVER_KEY)", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: key) { _, v in env.setAPIKey(v) }
                    TextField("Model", text: $env.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Hermes Gateway") }
                footer: { Text("The gateway's OpenAI-compatible API server (/v1/responses). Use the LAN address at home or the Cloudflare tunnel hostname anywhere.") }

                Section {
                    NavigationLink {
                        QwenVoiceSettingsView()
                    } label: {
                        HStack {
                            Label("Voice engine", systemImage: "waveform")
                            Spacer()
                            Text(voiceEngine == "qwen" ? "Qwen3 (Neural)" : "System").foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink {
                        VoiceListView(env: env, voice: voice)
                    } label: {
                        HStack {
                            Label("Reply voice", systemImage: "speaker.wave.2")
                            Spacer()
                            Text(currentVoiceName).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(voiceEngine == "qwen")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Pause before sending", systemImage: "timer")
                            Spacer()
                            Text(String(format: "%.1fs", voicePause)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $voicePause, in: 1.5...5.0, step: 0.5)
                    }
                } header: { Text("Voice") }
                footer: { Text("How long to wait after you stop talking before sending. Raise it if a thinking or breathing pause sends your prompt too early.") }

                Section {
                    Toggle(isOn: $showSteps) {
                        Label("Show reasoning steps", systemImage: "list.bullet.indent")
                    }
                } header: { Text("Replies") }
                footer: { Text("Off: just the final answer. On: stream the agent's step-by-step narration as it works. Tool activity still shows either way.") }

                Section {
                    Button { Task { await test() } } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if testing { ProgressView() }
                            else if let ok = testResult {
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ok ? .green : .red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { key = env.apiKey }
        }
    }

    private func test() async {
        testing = true; testResult = nil
        testResult = await env.client?.health() ?? false
        testing = false
    }

    private var currentVoiceName: String {
        guard !env.voiceId.isEmpty, let v = AVSpeechSynthesisVoice(identifier: env.voiceId) else { return "Default" }
        return v.name
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
                        Button("Delete model", role: .destructive) { engine.deleteModel() }
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
            }
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
