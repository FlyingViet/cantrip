import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var turns: [ChatTurn] = []
    @Published var sending = false
    private(set) var previousResponseId: String?

    let env: HermesEnv
    let voice: VoiceController
    private var streamTask: Task<Void, Never>?

    init(env: HermesEnv, voice: VoiceController) {
        self.env = env
        self.voice = voice
        let snap = ChatStore.load()           // restore the prior transcript
        self.turns = snap.turns
        self.previousResponseId = snap.previousResponseId
        voice.onFinalTranscript = { [weak self] text in self?.send(text, spoken: true) }
    }

    func send(_ raw: String, spoken: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client = env.client, !sending else { return }

        turns.append(ChatTurn(role: .user, text: text))
        turns.append(ChatTurn(role: .assistant, streaming: true))
        let idx = turns.count - 1
        sending = true

        streamTask = Task {
            do {
                for try await ev in client.stream(input: text, previousResponseId: previousResponseId) {
                    apply(ev, at: idx)
                }
            } catch is CancellationError {
            } catch {
                turns[idx].error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            turns[idx].streaming = false
            sending = false
            // Never leave a silently-empty bubble — surface that the turn produced
            // nothing so it's debuggable instead of looking like a hang.
            if turns[idx].text.isEmpty, turns[idx].tools.isEmpty, turns[idx].error == nil {
                turns[idx].error = "No response received (the gateway answered but sent no text)."
            }
            ChatStore.save(turns: turns, previousResponseId: previousResponseId)   // persist the transcript
            if (spoken || voice.handsFree), turns[idx].error == nil { voice.speak(turns[idx].text) }
        }
    }

    func stop() {
        streamTask?.cancel()
        sending = false
        if let i = turns.indices.last { turns[i].streaming = false }
    }

    func newConversation() {
        stop()
        turns.removeAll()
        previousResponseId = nil
        ChatStore.clear()
    }

    private func apply(_ ev: HermesStreamEvent, at idx: Int) {
        guard turns.indices.contains(idx) else { return }
        switch ev {
        case .responseCreated(let id):
            previousResponseId = id
        case .textDelta(let t):
            turns[idx].text += t
        case .finalText(let t):
            if turns[idx].text.isEmpty { turns[idx].text = t }   // fallback if deltas were missed
        case .toolStarted(let id, let name):
            turns[idx].tools.append(ToolActivity(id: id, name: name))
        case .toolArgumentsDelta(let id, let delta):
            if let i = toolIndex(id, in: idx) { turns[idx].tools[i].arguments += delta }
        case .toolCompleted(let id):
            if let i = toolIndex(id, in: idx) { turns[idx].tools[i].done = true }
        case .toolOutput(let id, let output):
            if let i = toolIndex(id, in: idx, awaitingOutput: true) {
                turns[idx].tools[i].output = output
                turns[idx].tools[i].done = true
            }
        case .completed:
            break
        case .failed(let m):
            turns[idx].error = m
        }
    }

    /// Match a tool event to its activity by id, falling back to the most recent
    /// tool still awaiting output (the Responses API uses different ids for the
    /// call item vs its output, so exact-id matches don't always line up).
    private func toolIndex(_ id: String, in idx: Int, awaitingOutput: Bool = false) -> Int? {
        if let i = turns[idx].tools.firstIndex(where: { $0.id == id }) { return i }
        return turns[idx].tools.lastIndex(where: { awaitingOutput ? $0.output == nil : true })
    }
}

struct ChatView: View {
    private let env: HermesEnv
    @StateObject private var voice: VoiceController
    @StateObject private var vm: ChatViewModel
    @State private var input = ""
    @State private var showSettings = false
    @State private var showVoiceMode = false
    @State private var showSkills = false
    @State private var commands: [HermesCommand] = []

    /// Filtered "/" suggestions: shown while the user is typing a command name
    /// (starts with "/", no space yet).
    private var suggestions: [HermesCommand] {
        guard input.hasPrefix("/"), !input.contains(" ") else { return [] }
        let q = input.lowercased()
        return Array(commands.filter { $0.command.lowercased().hasPrefix(q) }.prefix(6))
    }

    init(env: HermesEnv) {
        self.env = env
        let v = VoiceController()
        _voice = StateObject(wrappedValue: v)
        _vm = StateObject(wrappedValue: ChatViewModel(env: env, voice: v))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcriptList
                inputBar
            }
            .navigationTitle("Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showSkills = true } label: { Label("Skills", systemImage: "wand.and.stars") }
                        Button { showVoiceMode = true } label: { Label("Voice mode", systemImage: "waveform") }
                        Divider()
                        Button(role: .destructive) { vm.newConversation() } label: {
                            Label("New conversation", systemImage: "square.and.pencil")
                        }
                        .disabled(vm.turns.isEmpty)
                    } label: { Image(systemName: "line.3.horizontal") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(env: env, voice: voice) }
            .sheet(isPresented: $showSkills) {
                SkillsView(skills: commands.filter { $0.kind == .skill }) { skill in
                    showSkills = false
                    vm.send(skill.command)        // run it → returns to chat showing the interaction
                }
            }
            .fullScreenCover(isPresented: $showVoiceMode) { VoiceModeView(voice: voice, vm: vm) }
        }
        .onAppear { voice.requestAuth() }
        .task { commands = await env.client?.commands() ?? [] }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.turns.isEmpty { emptyState }
                    ForEach(vm.turns) { turn in TurnView(turn: turn).id(turn.id) }
                }
                .padding()
            }
            .onChange(of: vm.turns.last?.text) { _, _ in
                if let id = vm.turns.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: env.isConfigured ? "waveform.circle.fill" : "gearshape.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.tint)
            if env.isConfigured {
                Text("Talk to Hermes").font(.title3.weight(.semibold))
                Text("Type, or tap the mic to start a voice conversation. Toggle hands-free to keep the loop going.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("Connect your gateway").font(.title3.weight(.semibold))
                Text("Open Settings and enter your Hermes gateway URL + API key to start.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open Settings") { showSettings = true }.buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 80).padding(.horizontal, 30)
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if !suggestions.isEmpty { suggestionList }
            voiceStatus
            HStack(spacing: 10) {
                Button { showVoiceMode = true } label: { Image(systemName: "infinity") }
                    .buttonStyle(.bordered).help("Voice mode")

                TextField("Message Hermes…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    .onSubmit(sendText)

                if vm.sending {
                    Button { vm.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                } else if input.isEmpty {
                    Button { voice.toggleListening() } label: {
                        Image(systemName: voice.isListening ? "mic.fill" : "mic")
                            .font(.title2).foregroundStyle(voice.isListening ? Color.red : Color.accentColor)
                    }
                    .disabled(!voice.authorized)
                } else {
                    Button(action: sendText) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    /// "/" autocomplete — the command/skill menu, like Telegram/Discord.
    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { cmd in
                Button { input = cmd.command + " " } label: {
                    HStack(spacing: 8) {
                        Text(cmd.command).font(.callout.monospaced().weight(.semibold)).foregroundStyle(.tint)
                        Text(cmd.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 7).padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                if cmd.id != suggestions.last?.id { Divider() }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Animated waveform status — "talking back" while listening, replying, or speaking.
    @ViewBuilder private var voiceStatus: some View {
        if voice.isListening {
            HStack(spacing: 10) {
                WaveformView(active: true, color: .red)
                Text(voice.partial.isEmpty ? "Listening…" : voice.partial)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
        } else if voice.isSpeaking {
            HStack(spacing: 10) {
                WaveformView(active: true, color: .accentColor)
                Text("Hermes is speaking").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { voice.stopSpeaking() } label: { Image(systemName: "stop.circle").font(.title3) }
            }
        } else if vm.sending && voice.handsFree {
            HStack(spacing: 10) {
                WaveformView(active: true, color: .accentColor)
                Text("Hermes is replying…").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func sendText() {
        let text = input
        input = ""
        vm.send(text)
    }
}

/// A row of bars that wave while `active` (voice "talking back"); flat otherwise.
/// Parameterized so it works both small (input bar) and large (voice mode).
struct WaveformView: View {
    var active: Bool
    var color: Color = .accentColor
    var barCount = 5
    var barWidth: CGFloat = 3.5
    var spacing: CGFloat = 3
    var minHeight: CGFloat = 6
    var maxHeight: CGFloat = 24

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let amp = active ? (sin(t * 7 + Double(i) * 0.9) * 0.5 + 0.5) : 0.18
                    Capsule().fill(color)
                        .frame(width: barWidth, height: minHeight + amp * (maxHeight - minHeight))
                }
            }
        }
    }
}

private struct TurnView: View {
    let turn: ChatTurn

    /// Parse inline markdown (bold/italic/code/links) while preserving the
    /// newlines streamed from the agent; falls back to plain text on a partial
    /// (mid-stream) markdown token.
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    var body: some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(turn.tools) { ToolRow(tool: $0) }
                if !turn.text.isEmpty {
                    Text(Self.markdown(turn.text)).textSelection(.enabled)
                }
                if turn.streaming && turn.text.isEmpty && turn.tools.isEmpty {
                    ProgressView().controlSize(.small)
                }
                if let err = turn.error {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Collapsible tool/skill activity row — the "see Hermes working" surface.
private struct ToolRow: View {
    let tool: ToolActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: tool.done ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(tool.done ? .green : .secondary)
                        .symbolEffect(.pulse, isActive: !tool.done)
                    Text(tool.label).font(.caption.weight(.semibold).monospaced())
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                if !tool.arguments.isEmpty {
                    Text(tool.arguments).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                if let out = tool.output, !out.isEmpty {
                    Text(out).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(12)
                }
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
