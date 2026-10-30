import Foundation

extension SessionTabTests {
    /// The inactivity watchdog cancels a run only when it is truly stuck: a run the backend says is
    /// waiting on background work (a watch-* build watcher, say) stays open, a long command's
    /// heartbeats keep it alive, and a silent run is still cancelled with the timeout error.
    @MainActor
    static func testRunWatchdog() async throws {
        let settings = AppSettings.shared
        let saved = settings.backend
        settings.backend = .copilot
        defer { settings.backend = saved }
        func timedOut(_ chat: ChatSession) -> Bool {
            chat.messages.contains { $0.role == .error && $0.text.contains("No response for") }
        }
        func start() async throws -> (ChatSession, CantripHomeBackendFixture) {
            let fixture = CantripHomeBackendFixture()
            let chat = ChatSession(copilotBackend: fixture)
            chat.inactivityLimit = 0.4
            chat.submit("Push the build and watch it")
            try await waitForJournalTest { fixture.sink != nil && chat.isStreaming }
            fixture.sink?(.textDelta("Started the build."))
            return (chat, fixture)
        }

        let (waiting, waitingBackend) = try await start()
        defer { waiting.cancel() }
        waitingBackend.sink?(.status(BackgroundWaitStatus.waiting(watchers: 0, parallel: 0, other: 1)))
        try await Task.sleep(for: .seconds(1.5))
        precondition(waiting.isStreaming && !timedOut(waiting),
                     "A run waiting on background work is idle on purpose, not stuck")
        waitingBackend.sink?(.status(BackgroundWaitStatus.resuming(parallel: false)))
        waitingBackend.sink?(.textDelta(" The build passed."))
        waitingBackend.sink?(.done)
        try await waitForJournalTest { !waiting.isStreaming }
        precondition(!timedOut(waiting), "It finishes normally when the work reports")

        let (busy, busyBackend) = try await start()
        defer { busy.cancel() }
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(200))
            busyBackend.sink?(.heartbeat)
        }
        precondition(busy.isStreaming && !timedOut(busy), "A long command's progress ticks keep the run alive")
        busyBackend.sink?(.done)
        try await waitForJournalTest { !busy.isStreaming }

        let (silent, _) = try await start()
        defer { silent.cancel() }
        try await waitForJournalTest { !silent.isStreaming }
        precondition(timedOut(silent), "A run with no events at all is still cancelled with the timeout error")
        print("Run watchdog: background waits and heartbeats keep runs open; silent runs still time out")
    }
}
