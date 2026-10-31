import Foundation

private final class PauseBackend: Backend {
    var prompts: [String] = []
    var sink: ((BackendEvent) -> Void)?
    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        prompts.append(request.prompt)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}
}

extension SessionTabTests {
    /// Stop ends the running turn and pauses the queue instead of discarding it: a new message runs
    /// right away, Resume runs the queue from its first message, and the pause survives a restart.
    @MainActor
    static func testStopPausesTheQueue() async throws {
        let settings = AppSettings.shared
        let saved = settings.backend
        settings.backend = .copilot
        defer { settings.backend = saved }
        let backend = PauseBackend()
        let id = UUID()
        let chat = ChatSession(id: id, copilotBackend: backend)
        defer { UserDefaults.standard.removeObject(forKey: TabDefaults.queuePaused(id)) }
        chat.submitRemote("first", mode: .queue)
        try await waitForJournalTest { backend.prompts.count == 1 }
        chat.submitRemote("second", mode: .queue)
        chat.submitRemote("third", mode: .queue)
        try await waitForJournalTest { chat.queued.count == 2 }

        chat.stop()
        try await waitForJournalTest { !chat.isStreaming }
        try await Task.sleep(for: .milliseconds(300))
        precondition(chat.queuePaused && chat.queued.map(\.text) == ["second", "third"] && backend.prompts.count == 1,
                     "Stop keeps the queue, paused: \(chat.queued.map(\.text)) \(backend.prompts)")
        precondition(chat.deliveryStatus == ChatSession.stoppedQueueStatus)
        precondition(UserDefaults.standard.bool(forKey: TabDefaults.queuePaused(id)), "The pause is saved")

        // A new message runs now instead of waiting behind the paused queue.
        chat.submitRemote("urgent", mode: .queue)
        try await waitForJournalTest { backend.prompts.count == 2 }
        precondition(backend.prompts[1].contains("urgent") && chat.queued.count == 2 && chat.queuePaused)
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
        try await Task.sleep(for: .milliseconds(300))
        precondition(backend.prompts.count == 2, "The paused queue doesn't start after it")

        chat.resumeQueue()
        try await waitForJournalTest { backend.prompts.count == 3 }
        precondition(backend.prompts[2].contains("second") && !chat.queuePaused, "Resume runs the queue from its first message")
        backend.sink?(.done)
        try await waitForJournalTest { backend.prompts.count == 4 }
        precondition(backend.prompts[3].contains("third"))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming && chat.queued.isEmpty }
        precondition(!UserDefaults.standard.bool(forKey: TabDefaults.queuePaused(id)), "An empty queue isn't paused")

        // Stop with nothing queued just stops; cancel() (closing a tab) still discards the queue.
        chat.submitRemote("alone", mode: .queue)
        try await waitForJournalTest { backend.prompts.count == 5 }
        chat.stop()
        try await waitForJournalTest { !chat.isStreaming }
        precondition(!chat.queuePaused)
        print("Queue pause: Stop keeps the queue paused, new messages run, Resume continues, the pause is saved")
    }
}
