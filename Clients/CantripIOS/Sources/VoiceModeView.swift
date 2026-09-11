import SwiftUI
import MarkdownUI

/// Full-screen voice conversation mode. Compact animation + status at the top, a
/// single nicely-formatted reply card in the middle (markdown — tables, lists,
/// images), and the mic below or beside it. Talk, listen, read along.
struct VoiceModeView: View {
    @ObservedObject var voice: VoiceController
    @ObservedObject var vm: ChatViewModel
    let onClose: () -> Void

    private var statusText: String {
        if voice.isSpeaking { return "Speaking — tap to interrupt" }
        if voice.isPreparingRecognition {
            return voice.recognitionStatusText ?? "Preparing speech recognition"
        }
        if vm.isWorking {
            return vm.runStatusText ?? "Thinking — tap to interrupt"
        }
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

            GeometryReader { geometry in
                VStack(spacing: 16) {
                    statusHeader
                    if !transcriptText.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "quote.opening")
                                .font(.caption).foregroundStyle(.white.opacity(0.45))
                                .padding(.top, 3)
                            Text(transcriptText)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(voice.isListening ? 0.9 : 0.6))
                                .lineLimit(geometry.size.height < 500 ? 1 : 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .animation(.default, value: transcriptText)
                    }

                    VoiceConversationLayout {
                        reply
                    } controls: {
                        microphone
                    }
                }
            }
            .padding()
        }
        .onAppear {
            vm.enterVoiceMode()
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Group {
                if vm.isWorking, !voice.isSpeaking, !voice.isListening {
                    ThinkingView(size: 28, color: .accentColor)
                } else {
                    WaveformView(active: voice.isListening || voice.isSpeaking, color: stateColor,
                                 barCount: 5, barWidth: 5, spacing: 4, minHeight: 8, maxHeight: 32)
                }
            }
            .frame(width: 56, height: 36)
            Text(statusText)
                .font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.default, value: statusText)
            ViewThatFits(in: .horizontal) {
                ExecutionLaneBadge(lane: vm.activeLane).fixedSize()
                ExecutionLaneBadge(lane: vm.activeLane, iconOnly: true)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close voice mode")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder private var reply: some View {
        if !replyText.isEmpty {
            ScrollView {
                Markdown(replyText)
                    .markdownTextStyle { ForegroundColor(.white.opacity(0.92)) }
                    .markdownTextStyle(\.link) { ForegroundColor(.cyan) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            .defaultScrollAnchor(.bottom)
            .environment(\.colorScheme, .dark)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    private var microphone: some View {
        Button {
            if voice.isSpeaking || vm.isWorking { vm.interruptAndListen() }
            else { voice.toggleListening() }
        } label: {
            Image(systemName: voice.isListening ? "mic.fill" : "mic")
                .font(.system(size: 28)).foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(voice.isListening ? Color.red : Color.white.opacity(0.16), in: Circle())
        }
        .disabled(!voice.authorized || voice.isPreparingRecognition)
        .accessibilityLabel(voice.isListening ? "Stop listening" : "Talk to your agent")
    }
}

struct VoiceConversationLayout<Reply: View, Controls: View>: View {
    @ViewBuilder var reply: () -> Reply
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= 600
                && geometry.size.width > geometry.size.height
            let layout = sideBySide
                ? AnyLayout(HStackLayout(spacing: 16))
                : AnyLayout(VStackLayout(spacing: 16))
            layout {
                reply().frame(maxWidth: .infinity, maxHeight: .infinity)
                controls()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
