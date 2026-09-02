import SwiftUI
import MarkdownUI

/// Full-screen voice conversation mode. Compact animation + status at the top, a
/// single nicely-formatted reply card in the middle (markdown — tables, lists,
/// images), and the mic below. Talk, listen, read along.
struct VoiceModeView: View {
    @ObservedObject var voice: VoiceController
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    private var statusText: String {
        if voice.isSpeaking { return "Speaking — tap to interrupt" }
        if vm.sending { return "Thinking — tap to interrupt" }
        if voice.isListening { return "Listening" }
        return "Tap the mic to talk"
    }

    private var stateColor: Color { voice.isListening ? .red : .accentColor }

    /// Latest assistant reply — rendered as markdown in the middle.
    private var replyText: String {
        vm.turns.last(where: { $0.role == .assistant })?.text ?? ""
    }

    /// What YOU said — live partial while dictating, then the sent question
    /// while Hermes thinks/speaks, so your ask stays visible the whole turn.
    private var transcriptText: String {
        if voice.isListening { return voice.partial }
        return vm.turns.last(where: { $0.role == .user })?.text ?? ""
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.05, blue: 0.12), Color(red: 0.18, green: 0.09, blue: 0.30)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 16) {
                // ── Top: close + compact animation + status ──
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                }
                HStack(spacing: 12) {
                    Group {
                        if vm.sending, !voice.isSpeaking, !voice.isListening {
                            ThinkingView(size: 28, color: .accentColor)
                        } else {
                            WaveformView(active: voice.isListening || voice.isSpeaking, color: stateColor,
                                         barCount: 5, barWidth: 5, spacing: 4, minHeight: 8, maxHeight: 32)
                        }
                    }
                    .frame(width: 56, height: 36)
                    Text(statusText).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                        .animation(.default, value: statusText)
                    Spacer()
                    ExecutionLaneBadge(lane: vm.activeLane)
                }

                // ── Your words: live while dictating, pinned while it answers ──
                if !transcriptText.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "quote.opening")
                            .font(.caption).foregroundStyle(.white.opacity(0.45))
                            .padding(.top, 3)
                        Text(transcriptText)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(voice.isListening ? 0.9 : 0.6))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .animation(.default, value: transcriptText)
                }

                // ── Middle: the single, nicely-formatted reply (markdown + images) ──
                if !replyText.isEmpty {
                    ScrollView {
                        Markdown(replyText)
                            .markdownTextStyle { ForegroundColor(.white.opacity(0.92)) }
                            .markdownTextStyle(\.link) { ForegroundColor(.cyan) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
                    .defaultScrollAnchor(.bottom)            // follow along as it streams in
                    .environment(\.colorScheme, .dark)        // light text for headings/tables too
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer()    // your words show in the transcript line up top
                }

                // ── Mic (tap to talk, or barge-in while speaking/thinking) ──
                Button {
                    if voice.isSpeaking || vm.sending { vm.interruptAndListen() }
                    else { voice.toggleListening() }
                } label: {
                    Image(systemName: voice.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 28)).foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(voice.isListening ? Color.red : Color.white.opacity(0.16), in: Circle())
                }
                .disabled(!voice.authorized)
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
