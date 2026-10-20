import Foundation

private final class ContinuityBackend: Backend {
    var requests: [BackendRequest] = []
    var sink: ((BackendEvent) -> Void)?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        requests.append(request)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}
}

extension SessionTabTests {
    /// Queued work and an unfinished run survive network drops and relaunches: nothing fails or
    /// runs while offline, and the interrupted run continues before the queue behind it.
    @MainActor
    static func testRunContinuity() async throws {
        AppSettings.shared.memoryEnabled = false
        AppSettings.shared.voiceMode = false
        AppSettings.shared.backend = .copilot
        let savedDelays = ChatSession.networkRetryDelays
        NetworkMonitor.settleDelay = 0.05
        NetworkMonitor.shared.setOnlineForTesting(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        defer {
            ChatSession.networkRetryDelays = savedDelays
            NetworkMonitor.shared.setOnlineForTesting(true)
        }

        precondition(ChatSession.isNetworkError("TypeError: fetch failed"))
        precondition(ChatSession.isNetworkError("getaddrinfo ENOTFOUND api.githubcopilot.com"))
        precondition(ChatSession.isNetworkError("The Internet connection appears to be offline."))
        precondition(!ChatSession.isNetworkError("Model \"x\" is not available."))
        precondition(!ChatSession.isNetworkError(CopilotBackend.lostMidReply))

        // Offline mid-run: the run waits instead of failing, and the queue doesn't start.
        let backend = ContinuityBackend()
        let chat = ChatSession(copilotBackend: backend)
        chat.submitRemote("first task", mode: .queue)
        try await waitForJournalTest { backend.requests.count == 1 }
        backend.sink?(.textDelta("partial work"))
        chat.submitRemote("second task", mode: .queue)
        precondition(chat.queued.map(\.text) == ["second task"])
        NetworkMonitor.shared.setOnlineForTesting(false)
        backend.sink?(.failure("TypeError: fetch failed"))
        try await waitForJournalTest { !chat.isStreaming && chat.deliveryStatus?.hasPrefix("Offline") == true }
        precondition(chat.autoResumePending && !chat.canResume)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(backend.requests.count == 1, "nothing is sent while offline")
        precondition(chat.queued.map(\.text) == ["second task"], "the queue waits for the interrupted run")
        // A message sent meanwhile waits behind the interrupted run instead of replacing it.
        chat.submitRemote("third task")
        precondition(chat.queued.map(\.text) == ["second task", "third task"] && backend.requests.count == 1)
        precondition(chat.deliveryStatus?.contains("interrupted task first") == true)
        chat.removeQueued(at: 1) // one queued message runs alone (grouping would call the router CLI)
        NetworkMonitor.shared.setOnlineForTesting(true)
        try await waitForJournalTest { backend.requests.count == 2 }
        precondition(backend.requests[1].prompt.contains("first task"), "the same run resumes: \(backend.requests[1].prompt.prefix(200))")
        backend.sink?(.done)
        try await waitForJournalTest { backend.requests.count == 3 }
        precondition(backend.requests[2].prompt.contains("second task"), "the queue runs after the resumed task")
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming && chat.queued.isEmpty }

        // Online but the connection fails: retried after a delay, a bounded number of times.
        ChatSession.networkRetryDelays = [0.05]
        chat.submitRemote("flaky task", mode: .queue)
        try await waitForJournalTest { backend.requests.count == 4 }
        backend.sink?(.failure("getaddrinfo ENOTFOUND api.githubcopilot.com"))
        try await waitForJournalTest { backend.requests.count == 5 }
        backend.sink?(.failure("getaddrinfo ENOTFOUND api.githubcopilot.com"))
        try await waitForJournalTest { !chat.isStreaming && !chat.autoResumePending }
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(backend.requests.count == 5, "network retries are bounded")
        ChatSession.networkRetryDelays = savedDelays

        // Relaunch mid-run: the restored run continues by itself, then its queue.
        let original = ContinuityBackend()
        let tab = ChatSession(copilotBackend: original)
        tab.submitRemote("long task", mode: .queue)
        try await waitForJournalTest { original.requests.count == 1 }
        original.sink?(.textDelta("step one done"))
        tab.submitRemote("follow-up", mode: .queue)
        try await tab.flushJournal()

        NetworkMonitor.shared.setOnlineForTesting(false)
        let relaunched = ContinuityBackend()
        let restored = ChatSession(id: tab.id, copilotBackend: relaunched)
        precondition(restored.canResume && restored.queued.map(\.text) == ["follow-up"] && restored.hasRestoredWork)
        restored.continueAfterLaunch()
        precondition(restored.autoResumePending && !restored.canResume)
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(relaunched.requests.isEmpty, "a relaunch while offline waits for the network")
        NetworkMonitor.shared.setOnlineForTesting(true)
        try await waitForJournalTest { relaunched.requests.count == 1 }
        precondition(relaunched.requests[0].prompt.contains("long task"))
        try await restored.flushJournal()

        // Crashing again mid-resume resumes once more; after the limit it waits for Resume.
        let second = ContinuityBackend()
        let again = ChatSession(id: tab.id, copilotBackend: second)
        again.continueAfterLaunch()
        try await waitForJournalTest { second.requests.count == 1 }
        try await again.flushJournal()
        let third = ContinuityBackend()
        let looping = ChatSession(id: tab.id, copilotBackend: third)
        looping.continueAfterLaunch()
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(third.requests.isEmpty && looping.canResume && !looping.autoResumePending,
                     "a run that keeps interrupting relaunches waits for the user")
        looping.resumeInterrupted()
        try await waitForJournalTest { third.requests.count == 1 }
        third.sink?(.done)
        try await waitForJournalTest { third.requests.count == 2 }
        precondition(third.requests[1].prompt.contains("follow-up"))
        third.sink?(.done)
        try await waitForJournalTest { !looping.isStreaming && looping.queued.isEmpty }

        // Clearing the conversation abandons a pending resume; the next message sends at once.
        let clearing = ContinuityBackend()
        let cleared = ChatSession(copilotBackend: clearing)
        cleared.submitRemote("abandoned task", mode: .queue)
        try await waitForJournalTest { clearing.requests.count == 1 }
        NetworkMonitor.shared.setOnlineForTesting(false)
        clearing.sink?(.failure("TypeError: fetch failed"))
        try await waitForJournalTest { cleared.autoResumePending }
        cleared.newConversation()
        precondition(!cleared.autoResumePending)
        NetworkMonitor.shared.setOnlineForTesting(true)
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(clearing.requests.count == 1, "a cleared conversation never resumes")
        cleared.submitRemote("fresh task")
        try await waitForJournalTest { clearing.requests.count == 2 }
        precondition(clearing.requests[1].prompt.contains("fresh task")
                     && !clearing.requests[1].prompt.contains("interrupted mid-run"))
        clearing.sink?(.done)
        try await waitForJournalTest { !cleared.isStreaming }
        print("Run continuity: network drops and relaunches keep the interrupted run and its queue")
    }
}
