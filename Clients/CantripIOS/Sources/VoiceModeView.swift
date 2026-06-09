import SwiftUI
import MarkdownUI

/// Full-screen voice conversation mode. Compact animation + status at the top,
/// the rendered reply (markdown/tables) in the middle, and a karaoke follow-along
/// transcript at the bottom that auto-scrolls and bolds the word being spoken.
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

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.05, blue: 0.12), Color(red: 0.18, green: 0.09, blue: 0.30)],
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 14) {
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
                }

                // ── Middle: rendered reply (markdown + tables) on a readable card ──
                if !replyText.isEmpty {
                    ScrollView {
                        Markdown(replyText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer()
                }

                // ── Bottom: karaoke follow-along transcript ──
                if !voice.spokenChunks.isEmpty {
                    KaraokeView(chunks: voice.spokenChunks,
                                currentChunk: voice.currentChunk,
                                wordRange: voice.currentWordRange)
                        .frame(height: 150)
                } else if voice.isListening {
                    Text(voice.partial.isEmpty ? "Listening…" : voice.partial)
                        .font(.title3).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
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

/// Follow-along transcript: shows the spoken chunks, bolds the word being read,
/// dims already-spoken lines, and auto-scrolls to keep the current line centred.
private struct KaraokeView: View {
    let chunks: [String]
    let currentChunk: Int
    let wordRange: NSRange?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chunks.indices, id: \.self) { i in
                        line(i).id(i).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onChange(of: currentChunk) { _, i in
                withAnimation { proxy.scrollTo(i, anchor: .center) }
            }
            .onChange(of: wordRange?.location) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(currentChunk, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func line(_ i: Int) -> some View {
        if i == currentChunk, let r = wordRange {
            Text(highlighted(chunks[i], r)).font(.title3)
        } else {
            Text(chunks[i]).font(.title3)
                .foregroundStyle(.white.opacity(i < currentChunk ? 0.35 : 0.6))
        }
    }

    /// AttributedString of the chunk with the current word bold + bright.
    private func highlighted(_ s: String, _ r: NSRange) -> AttributedString {
        var attr = AttributedString(s)
        attr.foregroundColor = .white.opacity(0.55)
        if let sr = Range(r, in: s),
           let lo = AttributedString.Index(sr.lowerBound, within: attr),
           let hi = AttributedString.Index(sr.upperBound, within: attr) {
            attr[lo..<hi].font = .title3.weight(.bold)
            attr[lo..<hi].foregroundColor = .white
        }
        return attr
    }
}
