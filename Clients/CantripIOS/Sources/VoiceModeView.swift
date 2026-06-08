import SwiftUI

/// Full-screen voice conversation mode (opened by the ∞ button) — a large
/// centered waveform that "talks back" through the listen → reply → speak loop,
/// like a hands-free call. Dismiss to return to the chat transcript.
struct VoiceModeView: View {
    @ObservedObject var voice: VoiceController
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    private var isActive: Bool { voice.isListening || voice.isSpeaking || vm.sending }

    private var statusText: String {
        if voice.isSpeaking { return "Hermes is speaking" }
        if vm.sending { return "Thinking…" }
        if voice.isListening { return "Listening" }
        return "Tap the mic to talk"
    }

    private var stateColor: Color { voice.isListening ? .red : .accentColor }

    /// Live partial while listening, otherwise the latest assistant reply.
    private var caption: String {
        if voice.isListening, !voice.partial.isEmpty { return voice.partial }
        if let last = vm.turns.last, last.role == .assistant, !last.text.isEmpty { return last.text }
        return ""
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.05, blue: 0.12), Color(red: 0.18, green: 0.09, blue: 0.30)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 28) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                            .padding(12).background(.ultraThinMaterial, in: Circle())
                    }
                }

                Spacer()

                Text(statusText)
                    .font(.title3.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                    .animation(.default, value: statusText)

                WaveformView(active: isActive, color: stateColor, barCount: 7,
                             barWidth: 10, spacing: 9, minHeight: 18, maxHeight: 150)
                    .frame(height: 160)
                    .shadow(color: stateColor.opacity(0.45), radius: 28)

                if !caption.isEmpty {
                    ScrollView {
                        Text(caption)
                            .font(.title3).foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: 170)
                }

                Spacer()

                Button { voice.toggleListening() } label: {
                    Image(systemName: voice.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 30)).foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        .background(voice.isListening ? Color.red : Color.white.opacity(0.16), in: Circle())
                }
                .disabled(!voice.authorized)
                .padding(.bottom, 24)
            }
            .padding()
        }
        .onAppear {
            voice.handsFree = true
            if !voice.isListening, !voice.isSpeaking, !vm.sending { voice.startListening() }
        }
        .onDisappear {
            voice.handsFree = false
            voice.stopListening(finalize: false)
            voice.stopSpeaking()
        }
    }
}
