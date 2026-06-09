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
                        VoiceListView(env: env, voice: voice)
                    } label: {
                        HStack {
                            Label("Reply voice", systemImage: "speaker.wave.2")
                            Spacer()
                            Text(currentVoiceName).foregroundStyle(.secondary)
                        }
                    }
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
