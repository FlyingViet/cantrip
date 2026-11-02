import SwiftUI

/// Direct local mode in the Home window: a chat with a model served on this Mac, straight from
/// this app. It never goes through the paired Cantrip host and is never synced.
struct MacDirectLocalView: View {
    @ObservedObject var chat: DirectLocalChat
    /// Only for the shared transcript rows; nothing here reads from or sends to the host.
    @ObservedObject var remote: CantripRemoteModel
    let openSettings: () -> Void
    @State private var input = ""
    @State private var scrollRequest = 0
    @FocusState private var composerFocused: Bool

    static let readableWidth: CGFloat = 860

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                banner
                transcript(width: geometry.size.width)
                composer
                    .frame(maxWidth: Self.readableWidth)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .navigationTitle("Local Model")
        .navigationSubtitle("On this Mac · not synced")
        .onAppear { if chat.isConfigured { composerFocused = true } }
    }

    // MARK: Banner

    private var banner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "lock.laptopcomputer")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.isConfigured
                     ? "\(chat.configuration.model) on \(chat.configuration.serverLabel)"
                     : "No model chosen yet")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(bannerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(chat.isConfigured ? "Settings…" : "Set Up…", action: openSettings)
                .accessibilityIdentifier("directLocal.settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.04))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("directLocal.banner")
    }

    // MARK: Transcript

    private func transcript(width: CGFloat) -> some View {
        ChatTranscriptScrollView(scrollRequest: scrollRequest) {
            if chat.messages.isEmpty { emptyState }
            ForEach(chat.messages) { message in
                TurnView(turn: Self.turn(for: message, awaitingApproval: chat.awaitingApproval), remote: remote,
                         onApproval: { choice in respond(choice, in: message) })
                    .id(message.id)
            }
            if let status = chat.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("directLocal.status")
            }
        }
        .contentMargins(.horizontal, max(16, (width - Self.readableWidth) / 2), for: .scrollContent)
        .textSelection(.enabled)
        .accessibilityIdentifier("directLocal.transcript")
    }

    private var bannerDetail: String {
        let servers = chat.configuration.tools.enabledServers.sorted()
        guard !servers.isEmpty else {
            return "Runs on this Mac only. This conversation stays here: it doesn't go through Cantrip and isn't synced to your other devices."
        }
        return "Runs on this Mac only and isn't synced. Tools on: \(ListFormatter.localizedString(byJoining: servers)). Each tool asks before it runs unless you've allowed it."
    }

    /// Plain text, like the host's Private Local tab: a local model's Markdown can't load images.
    /// Tool calls show as the reply's steps; the one waiting for you gets the approval card.
    static func turn(for message: DirectLocalMessage, awaitingApproval: UUID? = nil) -> ChatTurn {
        var turn = ChatTurn(isLocalPrivate: true, id: message.id, role: message.role == .user ? .user : .assistant,
                            text: message.role == .user ? message.content : message.displayText,
                            streaming: message.streaming, error: message.error, thinking: message.thinking)
        let calls = message.toolCalls
        turn.tools = calls.map { call in
            ToolActivity(id: call.id.uuidString, name: call.label, arguments: call.arguments,
                         output: toolOutput(call), done: call.state.isFinished)
        }
        if let waiting = calls.first(where: { $0.id == awaitingApproval && $0.state == .waiting }) {
            turn.approval = HermesRunApproval(
                command: "\(waiting.label) \(waiting.arguments)",
                description: "Allow \(waiting.server ?? "this server") to run \(waiting.tool ?? waiting.name)? It runs on this Mac with your access.",
                choices: ["once", "always", "deny"])
        }
        return turn
    }

    private static func toolOutput(_ call: DirectLocalToolCall) -> String? {
        switch call.state {
        case .waiting: "Waiting for you to allow it."
        case .running: "Running…"
        case .done: call.result
        case .failed: call.result.map { "Failed: \($0)" } ?? "Failed."
        case .denied: call.result.map { "Not run: \($0)" } ?? "Not run."
        }
    }

    private func respond(_ choice: String, in message: DirectLocalMessage) {
        guard let id = chat.awaitingApproval, message.toolCalls.contains(where: { $0.id == id }) else { return }
        switch choice {
        case "once": chat.respond(to: id, with: .once)
        case "always": chat.respond(to: id, with: .always)
        default: chat.respond(to: id, with: .deny)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Chat with a model on this Mac")
                .font(.title3.weight(.semibold))
            Text(chat.isConfigured
                 ? "Messages go straight to \(chat.configuration.serverLabel) and stay on this Mac."
                 : "Point Cantrip Gateway at an Ollama-compatible server on this Mac, such as Ollama or mlx-serve, then pick one of its models.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if !chat.isConfigured {
                Button("Set Up…", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: Composer

    private var composer: some View {
        ChatComposer {
            EmptyView()
        } message: {
            TextField(chat.isConfigured ? "Message \(chat.configuration.model)" : "Set up a local model first",
                      text: $input, axis: .vertical)
                .focused($composerFocused)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(!chat.isConfigured)
                .onSubmit(send)
                .help("Return sends. Option-Return adds a new line.")
                .accessibilityLabel("Message to the local model")
                .accessibilityIdentifier("directLocal.message")
        } trailing: {
            Group {
                if chat.isReplying {
                    Button(action: chat.stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .help("Stop the reply")
                    .accessibilityLabel("Stop reply")
                    .accessibilityIdentifier("directLocal.stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!chat.isConfigured || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (Return)")
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("directLocal.send")
                }
            }
            .buttonStyle(.borderless)
        } accessory: {
            if let error = chat.storageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func send() {
        guard chat.isConfigured, !chat.isReplying, chat.send(input) else { return }
        input = ""
        scrollRequest += 1
    }
}

/// Server address, model, context window and system prompt for direct local mode.
struct MacDirectLocalSettingsView: View {
    @ObservedObject var chat: DirectLocalChat
    let dismiss: () -> Void
    @State private var draft: DirectLocalConfiguration
    @State private var contextText: String
    @State private var saveError: String?

    init(chat: DirectLocalChat, dismiss: @escaping () -> Void) {
        self.chat = chat
        self.dismiss = dismiss
        _draft = State(initialValue: chat.configuration)
        _contextText = State(initialValue: String(chat.configuration.contextWindow))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Server", text: $draft.baseURL, prompt: Text(DirectLocalConfiguration.defaultBaseURL))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("directLocal.settings.url")
                    Text("An Ollama-compatible server running on this Mac, such as Ollama (\(DirectLocalConfiguration.defaultBaseURL)) or mlx-serve. Plain HTTP works only for 127.0.0.1, localhost or [::1]; anything else needs HTTPS. No password or API key is ever sent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Local model server")
                }

                Section {
                    Picker("Model", selection: $draft.model) {
                        if draft.model.isEmpty { Text("Choose a model").tag("") }
                        if !draft.model.isEmpty, !chat.installedModels.contains(draft.model) {
                            Text(draft.model).tag(draft.model)
                        }
                        ForEach(chat.installedModels, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .accessibilityIdentifier("directLocal.settings.model")
                    HStack(alignment: .firstTextBaseline) {
                        Group {
                            if let error = chat.modelsError {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            } else if !chat.installedModels.isEmpty {
                                Text("\(chat.installedModels.count) installed \(chat.installedModels.count == 1 ? "model" : "models") on \(draft.serverLabel). Cloud models aren't listed.")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Load the models installed on the server, then pick one.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(chat.loadingModels ? "Loading…" : "Load Models") {
                            Task { await loadModels() }
                        }
                        .disabled(chat.loadingModels)
                        .accessibilityIdentifier("directLocal.settings.loadModels")
                    }
                } header: {
                    Text("Model")
                }

                Section {
                    TextField("Context tokens", text: $contextText)
                        .onChange(of: contextText) { _, value in
                            if let number = Int(value.filter(\.isNumber)) { draft.contextWindow = number }
                        }
                        .accessibilityIdentifier("directLocal.settings.context")
                    Text("512 to 131072. Larger windows use more memory on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draft.systemPrompt)
                        .font(.body)
                        .frame(minHeight: 80)
                        .accessibilityLabel("System prompt")
                        .accessibilityIdentifier("directLocal.settings.systemPrompt")
                    Text("\(draft.systemPrompt.count) of 8000 characters.")
                        .font(.caption)
                        .foregroundStyle(draft.systemPrompt.count > 8000 ? .red : .secondary)
                } header: {
                    Text("Context and system prompt")
                }

                MacDirectLocalToolsSection(chat: chat, settings: $draft.tools, contextWindow: draft.contextWindow,
                                           systemPromptCharacters: draft.systemPrompt.count)

                Section {
                    Text("Direct local mode talks only to this server, from this Mac. The model can use only the tools you turn on above, there is no cloud fallback, and the conversation is saved only on this Mac. The Private Local tab on your paired Cantrip is separate and unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.model.isEmpty)
                    .accessibilityIdentifier("directLocal.settings.save")
            }
            .padding(16)
        }
        .navigationTitle("Local Model Settings")
        #if DEBUG
        .task { await DirectLocalQA.settingsAppeared(self) }
        #endif
    }

    func loadModels() async {
        saveError = nil
        let models = await chat.loadModels(for: draft)
        if draft.model.isEmpty || !models.contains(draft.model), let first = models.first { draft.model = first }
    }

    func save() {
        do {
            try chat.save(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    #if DEBUG
    /// QA: choose a listed model by name.
    func select(_ model: String) { draft.model = model }
    func setServer(_ url: String) { draft.baseURL = url }
    func setTools(_ server: String, on: Bool, only: Set<String>?, all: [String]) {
        draft.tools.setEnabled(server, on)
        for tool in all { draft.tools.setEnabled(server, tool, only?.contains(tool) ?? true) }
    }
    #endif
}
