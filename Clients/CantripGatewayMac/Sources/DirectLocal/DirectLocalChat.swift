import Foundation

/// The direct local conversation on this Mac: settings, the stored messages, and one reply at a time.
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

    private let store: DirectLocalStore
    private let makeClient: () -> DirectLocalClient
    private var replyTask: Task<Void, Never>?

    init(store: DirectLocalStore = DirectLocalStore(), makeClient: @escaping () -> DirectLocalClient = { DirectLocalClient() }) {
        self.store = store
        self.makeClient = makeClient
        configuration = store.loadConfiguration()
        messages = store.loadConversation()
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
        let history = DirectLocalHistory.chatMessages(Array(messages.dropLast()), configuration: configuration)
        let client = makeClient()
        // Deltas and the final state go through the main queue in order, so none lands after finish.
        replyTask = Task { [weak self] in
            defer { client.close() }
            var failure: String?
            do {
                try configuration.validate()
                try await client.chat(configuration, messages: history) { event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(event, to: replyID) } }
                }
            } catch is CancellationError {
                failure = "Stopped."
            } catch {
                failure = Task.isCancelled ? "Stopped." : error.localizedDescription
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(replyID, error: failure) } }
        }
        return true
    }

    func stop() {
        replyTask?.cancel()
    }

    /// Deletes the conversation from this Mac.
    func clear() {
        guard !isReplying else { return }
        messages = []
        persist()
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
        case .done, .failure:
            break
        }
    }

    private func finish(_ id: UUID, error: String?) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].streaming = false
            if let error { messages[index].error = error }
        }
        isReplying = false
        status = nil
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
}
