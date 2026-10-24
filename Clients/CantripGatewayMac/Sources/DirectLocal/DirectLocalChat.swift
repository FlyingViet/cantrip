import Foundation

/// Your answer to a tool call that asks first.
enum DirectLocalApproval {
    case once, always, deny
}

/// The direct local conversation on this Mac: settings, the stored messages, and one reply at a
/// time. A reply can take several rounds: the model calls tools from the MCP servers you turned
/// on, each runs (after you allow it, unless it runs automatically), and the results go back to
/// the model until it answers.
@MainActor
final class DirectLocalChat: ObservableObject {
    @Published private(set) var configuration: DirectLocalConfiguration
    @Published private(set) var messages: [DirectLocalMessage]
    @Published private(set) var isReplying = false
    @Published private(set) var status: String?
    /// Models the server listed on the last load (settings sheet).
    @Published private(set) var installedModels: [String] = []
    @Published private(set) var loadingModels = false
    @Published private(set) var modelsError: String?
    /// Saving the conversation failed; shown until the next successful save.
    @Published private(set) var storageError: String?
    /// MCP servers set up on this Mac (reread when settings open and before each reply).
    @Published private(set) var mcpServers: [DirectLocalMCPServer]
    /// The tool lists last loaded from each server.
    @Published private(set) var toolCatalog: [String: DirectLocalToolCatalogEntry]
    @Published private(set) var loadingToolServers: Set<String> = []
    @Published private(set) var toolErrors: [String: String] = [:]
    /// The tool call waiting for you to allow or deny it.
    @Published private(set) var awaitingApproval: UUID?

    private let store: DirectLocalStore
    private let makeClient: () -> DirectLocalClient
    private let toolRunner: DirectLocalToolRunning
    private let loadServers: () -> [DirectLocalMCPServer]
    private var replyTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<DirectLocalApproval?, Never>?

    init(store: DirectLocalStore = DirectLocalStore(), makeClient: @escaping () -> DirectLocalClient = { DirectLocalClient() },
         toolRunner: DirectLocalToolRunning = DirectLocalMCPHub.shared,
         loadServers: @escaping () -> [DirectLocalMCPServer] = { DirectLocalMCPConfig.load() }) {
        self.store = store
        self.makeClient = makeClient
        self.toolRunner = toolRunner
        self.loadServers = loadServers
        configuration = store.loadConfiguration()
        messages = store.loadConversation()
        mcpServers = loadServers()
        toolCatalog = store.loadToolCatalog()
    }

    var isConfigured: Bool { (try? configuration.validate()) != nil }

    /// Loads the server's installed models for `draft` (the settings being edited).
    @discardableResult
    func loadModels(for draft: DirectLocalConfiguration) async -> [String] {
        loadingModels = true
        modelsError = nil
        defer { loadingModels = false }
        let client = makeClient()
        defer { client.close() }
        do {
            let models = try await client.models(draft)
            installedModels = models
            if models.isEmpty { modelsError = "The server has no local models installed." }
            return models
        } catch {
            installedModels = []
            modelsError = error.localizedDescription
            return []
        }
    }

    func save(_ draft: DirectLocalConfiguration) throws {
        try draft.validate()
        try store.saveConfiguration(draft)
        configuration = draft
    }

    // MARK: Tools

    func refreshMCPServers() {
        mcpServers = loadServers()
    }

    /// The cached tool list for `server`, unless its command changed since.
    func cachedTools(for server: DirectLocalMCPServer) -> [DirectLocalMCPTool]? {
        guard let entry = toolCatalog[server.name], entry.fingerprint == server.fingerprint else { return nil }
        return entry.tools
    }

    /// Starts `server` if needed and saves the tools it lists.
    @discardableResult
    func loadTools(for server: DirectLocalMCPServer) async -> Bool {
        loadingToolServers.insert(server.name)
        toolErrors[server.name] = nil
        defer { loadingToolServers.remove(server.name) }
        do {
            let tools = try await toolRunner.tools(for: server)
            toolCatalog[server.name] = DirectLocalToolCatalogEntry(fingerprint: server.fingerprint, tools: tools, loaded: Date())
            try? store.saveToolCatalog(toolCatalog)
            return true
        } catch {
            // Stop isn't the server's fault; don't show it as one.
            if !(error is CancellationError || Task.isCancelled) { toolErrors[server.name] = error.localizedDescription }
            return false
        }
    }

    func offeredTools(_ settings: DirectLocalToolSettings) -> [DirectLocalOfferedTool] {
        DirectLocalTools.offered(servers: mcpServers, catalog: toolCatalog, settings: settings)
    }

    /// Answers the tool call that's waiting (the transcript's Allow Once / Always Allow / Deny).
    func respond(to callID: UUID, with decision: DirectLocalApproval) {
        guard awaitingApproval == callID, let continuation = approvalContinuation else { return }
        approvalContinuation = nil
        awaitingApproval = nil
        continuation.resume(returning: decision)
    }

    // MARK: Sending

    /// Sends `text` and streams the reply. Returns false when nothing was sent.
    @discardableResult
    func send(_ text: String) -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isReplying else { return false }
        let configuration = configuration
        messages.append(DirectLocalMessage(role: .user, content: prompt))
        let replyID = UUID()
        messages.append(DirectLocalMessage(id: replyID, role: .assistant, content: "", model: configuration.model,
                                           streaming: true))
        persist()
        isReplying = true
        status = "Checking \(configuration.model.isEmpty ? "the model" : configuration.model)…"
        let client = makeClient()
        replyTask = Task { [weak self] in
            defer { client.close() }
            var failure: String?
            do {
                try configuration.validate()
                guard let self else { return }
                try await self.reply(replyID, configuration: configuration, client: client)
            } catch is CancellationError {
                failure = "Stopped."
            } catch {
                failure = Task.isCancelled ? "Stopped." : error.localizedDescription
            }
            // Deltas still queued for the main queue land before the reply is finished.
            await Self.drainMainQueue()
            self?.finish(replyID, error: failure)
        }
        return true
    }

    func stop() {
        replyTask?.cancel()
        if let continuation = approvalContinuation {
            approvalContinuation = nil
            awaitingApproval = nil
            continuation.resume(returning: nil)
        }
    }

    /// Deletes the conversation from this Mac.
    func clear() {
        guard !isReplying else { return }
        messages = []
        persist()
    }

    private func reply(_ replyID: UUID, configuration: DirectLocalConfiguration, client: DirectLocalClient) async throws {
        let offered = try await prepareTools(configuration)
        let definitions = offered.map(\.definition)
        let reserved = DirectLocalTools.characters(offered)
        for _ in 0..<DirectLocalTools.maxRounds {
            try Task.checkCancellation()
            let history = DirectLocalHistory.chatMessages(messages, configuration: configuration, reservedCharacters: reserved,
                                                          systemNote: offered.isEmpty ? nil : DirectLocalTools.systemNote)
            let requests = try await client.chat(configuration, messages: history, tools: definitions) { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(event, to: replyID) } }
            }
            await Self.drainMainQueue()
            guard !requests.isEmpty else { return }
            try await runTools(requests, replyID: replyID, offered: offered, configuration: configuration)
        }
        throw DirectLocalError("Stopped after \(DirectLocalTools.maxRounds) rounds of tool calls without a final answer.")
    }

    /// The tools to offer this reply, loading the lists of turned-on servers not loaded yet.
    private func prepareTools(_ configuration: DirectLocalConfiguration) async throws -> [DirectLocalOfferedTool] {
        guard !configuration.tools.enabledServers.isEmpty else { return [] }
        refreshMCPServers()
        for server in mcpServers where server.isAvailable && configuration.tools.isEnabled(server.name)
            && cachedTools(for: server) == nil {
            status = "Starting \(server.name)…"
            guard await loadTools(for: server) else {
                try Task.checkCancellation()
                throw DirectLocalError("Couldn't load the tools from \(server.name): \(toolErrors[server.name] ?? "unknown error") Fix it or turn it off in Local Model Settings.")
            }
            try Task.checkCancellation()
        }
        let offered = DirectLocalTools.offered(servers: mcpServers, catalog: toolCatalog, settings: configuration.tools)
        let tokens = DirectLocalTools.tokens(characters: DirectLocalTools.characters(offered) + configuration.systemPrompt.count)
        let limit = Int(Double(configuration.contextWindow) * DirectLocalTools.maxContextShare)
        guard tokens <= limit else {
            throw DirectLocalError("The turned-on tools' descriptions take about \(tokens) of the \(configuration.contextWindow) context tokens, leaving too little room for the conversation. Turn some tools off or raise the context window in Local Model Settings.")
        }
        status = "Checking \(configuration.model)…"
        return offered
    }

    /// Records one round of tool calls, then runs each (asking first unless it runs automatically).
    private func runTools(_ requests: [DirectLocalToolRequest], replyID: UUID, offered: [DirectLocalOfferedTool],
                          configuration: DirectLocalConfiguration) async throws {
        guard let index = messages.firstIndex(where: { $0.id == replyID }) else { throw CancellationError() }
        let calls = requests.enumerated().map { position, request -> DirectLocalToolCall in
            let offer = offered.first { $0.functionName == request.name }
            var call = DirectLocalToolCall(name: request.name, server: offer?.server.name, tool: offer?.tool.name,
                                           arguments: request.arguments, state: .waiting)
            if offer == nil {
                call.state = .failed
                call.result = "There is no tool named \(request.name). Use only the tools provided."
            } else if position >= DirectLocalTools.maxCallsPerRound {
                call.state = .denied
                call.result = "Not run: at most \(DirectLocalTools.maxCallsPerRound) tool calls at a time."
            }
            return call
        }
        messages[index].toolRounds = (messages[index].toolRounds ?? []) + [
            DirectLocalToolRound(content: messages[index].content, calls: calls),
        ]
        messages[index].content = ""
        persist()
        let limit = DirectLocalTools.resultLimit(contextWindow: configuration.contextWindow)
        for call in calls where call.state == .waiting {
            try Task.checkCancellation()
            guard let offer = offered.first(where: { $0.functionName == call.name }) else { continue }
            if !offer.automatic, !self.configuration.tools.isAutomatic(offer.server.name, offer.tool.name) {
                // The transcript's approval card asks; a status line would only repeat it.
                status = nil
                awaitingApproval = call.id
                let decision = await withCheckedContinuation { approvalContinuation = $0 }
                switch decision {
                case nil:
                    throw CancellationError()
                case .deny?:
                    update(call.id, in: replyID) {
                        $0.state = .denied
                        $0.result = "The user didn't allow this tool call. Don't try it again unless they ask."
                    }
                    persist()
                    continue
                case .always?:
                    allowAutomatically(offer)
                case .once?:
                    break
                }
            }
            update(call.id, in: replyID) { $0.state = .running }
            status = "Running \(offer.label)…"
            do {
                let output = try await toolRunner.call(offer.tool.name, arguments: DirectLocalTools.object(call.arguments),
                                                       on: offer.server)
                update(call.id, in: replyID) {
                    $0.state = output.isError ? .failed : .done
                    $0.result = DirectLocalTools.truncated(output.text, limit: limit)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                update(call.id, in: replyID) {
                    $0.state = .failed
                    $0.result = "The tool failed: \(error.localizedDescription)"
                }
            }
            persist()
        }
        status = "Reading the results…"
    }

    /// "Always Allow": this tool runs without asking from now on (Settings can turn it back).
    private func allowAutomatically(_ offer: DirectLocalOfferedTool) {
        var updated = configuration
        updated.tools.setAutomatic(offer.server.name, offer.tool.name, true)
        if (try? store.saveConfiguration(updated)) != nil { configuration = updated }
    }

    private func update(_ callID: UUID, in replyID: UUID, _ change: (inout DirectLocalToolCall) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == replyID }), var rounds = messages[index].toolRounds else { return }
        for round in rounds.indices {
            if let call = rounds[round].calls.firstIndex(where: { $0.id == callID }) {
                change(&rounds[round].calls[call])
                messages[index].toolRounds = rounds
                return
            }
        }
    }

    private func apply(_ event: DirectLocalStreamEvent, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].streaming else { return }
        switch event {
        case .content(let text):
            messages[index].content += text
            status = nil
        case .thinking(let text):
            messages[index].thinking = (messages[index].thinking ?? "") + text
            status = "Thinking…"
        case .toolCalls, .done, .failure:
            break
        }
    }

    private func finish(_ id: UUID, error: String?) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].streaming = false
            if let error { messages[index].error = error }
            if var rounds = messages[index].toolRounds {
                for round in rounds.indices {
                    for call in rounds[round].calls.indices where !rounds[round].calls[call].state.isFinished {
                        rounds[round].calls[call].state = .failed
                        rounds[round].calls[call].result = error ?? "Stopped."
                    }
                }
                messages[index].toolRounds = rounds
            }
        }
        isReplying = false
        status = nil
        awaitingApproval = nil
        replyTask = nil
        persist()
    }

    private func persist() {
        do {
            try store.saveConversation(messages)
            storageError = nil
        } catch {
            storageError = "Couldn't save this conversation on this Mac: \(error.localizedDescription)"
        }
    }

    private static func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
