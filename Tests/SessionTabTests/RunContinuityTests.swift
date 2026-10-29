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
    /// Queued work and an unfinished run survive network drops and relaunches. A run that fails in
    /// a conversation pauses on its error until the user taps Continue there, and the queue waits
    /// behind it; unattended handoff tabs wait for the network and continue by themselves.
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

        // A conversation: the failed run waits for Continue on its message, never retrying by
        // itself, and nothing queued jumps ahead of it — not even after the network is back.
        let backend = ContinuityBackend()
        let chat = ChatSession(copilotBackend: backend)
        chat.submitRemote("first task", mode: .queue)
        try await waitForJournalTest { backend.requests.count == 1 }
        backend.sink?(.textDelta("partial work"))
        chat.submitRemote("second task", mode: .queue)
        precondition(chat.queued.map(\.text) == ["second task"])
        NetworkMonitor.shared.setOnlineForTesting(false)
        backend.sink?(.failure("TypeError: fetch failed"))
        try await waitForJournalTest { !chat.isStreaming && chat.canResume }
        precondition(!chat.autoResumePending && chat.deliveryStatus == ChatSession.pausedQueueStatus)
        guard let failed = chat.messages.last(where: { $0.role == .error }) else { preconditionFailure() }
        precondition(chat.continuableMessageIDs == [failed.id], "the failed message offers Continue")
        precondition(chat.continueFailedRun(from: failed.id, includesAmbientContext: false)?.contains("offline") == true)
        NetworkMonitor.shared.setOnlineForTesting(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(backend.requests.count == 1, "no automatic retry once the network is back")
        precondition(chat.queued.map(\.text) == ["second task"], "the queue waits for the failed run")
        // A message sent meanwhile waits behind the failed run instead of starting the queue.
        chat.submitRemote("third task")
        precondition(chat.queued.map(\.text) == ["second task", "third task"] && backend.requests.count == 1)
        chat.removeQueued(at: 1) // one queued message runs alone (grouping would call the router CLI)
        precondition(chat.continueFailedRun(from: failed.id, includesAmbientContext: false) == nil)
        try await waitForJournalTest { backend.requests.count == 2 }
        precondition(backend.requests[1].prompt.contains("first task")
                     && backend.requests[1].prompt.contains("interrupted mid-run"),
                     "the same run resumes: \(backend.requests[1].prompt.prefix(200))")
        precondition(chat.continuableMessageIDs.isEmpty)
        backend.sink?(.done)
        try await waitForJournalTest { backend.requests.count == 3 }
        precondition(backend.requests[2].prompt.contains("second task"), "the queue runs after the continued task")
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming && chat.queued.isEmpty }

        // Send now skips the failed run; Continue on its message later picks it up as a new run
        // that keeps the original request, even when that one fails too.
        chat.submitRemote("flaky task", mode: .queue)
        try await waitForJournalTest { backend.requests.count == 4 }
        var step = ToolActivityFactory.start(id: "step-one", toolName: "edit", arguments: ["path": "step-one.swift"])
        step.state = .succeeded
        backend.sink?(.activity(step))
        chat.submitRemote("next task", mode: .queue)
        backend.sink?(.failure("getaddrinfo ENOTFOUND api.githubcopilot.com"))
        try await waitForJournalTest { !chat.isStreaming && chat.canResume }
        guard let flaky = chat.messages.last(where: { $0.role == .error }), let next = chat.queued.first,
              let flakyRun = flaky.runID else { preconditionFailure() }
        precondition(chat.sendQueuedNow(id: next.id) == nil)
        try await waitForJournalTest { backend.requests.count == 5 }
        precondition(backend.requests[4].prompt.contains("next task"))
        precondition(chat.continuableMessageIDs.isEmpty, "no Continue while a run works")
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
        precondition(chat.continuableMessageIDs == [flaky.id], "an earlier failed run still offers Continue")
        precondition(chat.continueFailedRun(from: flaky.id, includesAmbientContext: false) == nil)
        try await waitForJournalTest { backend.requests.count == 6 }
        precondition(backend.requests[5].prompt.contains("flaky task")
                     && backend.requests[5].prompt.contains("interrupted mid-run"))
        let continuation = chat.messages.last { $0.role == .user }
        precondition(continuation?.text == ChatSession.resumePrompt && continuation?.continuesRunID == flakyRun)
        backend.sink?(.failure("Request timed out."))
        try await waitForJournalTest { !chat.isStreaming && chat.canResume }
        guard let again = chat.messages.last(where: { $0.role == .error }) else { preconditionFailure() }
        precondition(chat.continuableMessageIDs == [again.id], "only the latest attempt offers Continue")
        precondition(chat.continueFailedRun(from: again.id, includesAmbientContext: false) == nil)
        try await waitForJournalTest { backend.requests.count == 7 }
        precondition(backend.requests[6].prompt.contains("flaky task") && backend.requests[6].prompt.contains("step-one.swift"),
                     "the original request and its steps carry through: \(backend.requests[6].prompt.prefix(300))")
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // A Home handoff's tab has nobody to tap Continue: offline, it waits for the network and
        // continues the same run before the queue behind it.
        let handoff = ContinuityBackend()
        let worker = ChatSession(copilotBackend: handoff)
        worker.submitRemote("(Handed off by Cantrip Home.)\n\nfirst job", mode: .queue)
        try await waitForJournalTest { handoff.requests.count == 1 }
        handoff.sink?(.textDelta("partial work"))
        worker.submitRemote("second job", mode: .queue)
        NetworkMonitor.shared.setOnlineForTesting(false)
        handoff.sink?(.failure("TypeError: fetch failed"))
        try await waitForJournalTest { !worker.isStreaming && worker.deliveryStatus?.hasPrefix("Offline") == true }
        precondition(worker.autoResumePending && !worker.canResume && worker.continuableMessageIDs.isEmpty)
        worker.submitRemote("third job")
        precondition(worker.queued.map(\.text) == ["second job", "third job"] && handoff.requests.count == 1)
        precondition(worker.deliveryStatus?.contains("interrupted task first") == true)
        worker.removeQueued(at: 1)
        NetworkMonitor.shared.setOnlineForTesting(true)
        try await waitForJournalTest { handoff.requests.count == 2 }
        precondition(handoff.requests[1].prompt.contains("first job"))
        handoff.sink?(.done)
        try await waitForJournalTest { handoff.requests.count == 3 }
        precondition(handoff.requests[2].prompt.contains("second job"))
        handoff.sink?(.done)
        try await waitForJournalTest { !worker.isStreaming && worker.queued.isEmpty }

        // Online but the connection fails: retried after a delay, a bounded number of times.
        ChatSession.networkRetryDelays = [0.05]
        worker.submitRemote("(Handed off by Cantrip Home.)\n\nflaky job", mode: .queue)
        try await waitForJournalTest { handoff.requests.count == 4 }
        handoff.sink?(.failure("getaddrinfo ENOTFOUND api.githubcopilot.com"))
        try await waitForJournalTest { handoff.requests.count == 5 }
        handoff.sink?(.failure("getaddrinfo ENOTFOUND api.githubcopilot.com"))
        try await waitForJournalTest { !worker.isStreaming && !worker.autoResumePending }
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(handoff.requests.count == 5, "network retries are bounded")
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

        // Crashing again mid-resume resumes once more; after the limit it waits for Continue.
        let second = ContinuityBackend()
        let again2 = ChatSession(id: tab.id, copilotBackend: second)
        again2.continueAfterLaunch()
        try await waitForJournalTest { second.requests.count == 1 }
        try await again2.flushJournal()
        let third = ContinuityBackend()
        let looping = ChatSession(id: tab.id, copilotBackend: third)
        looping.continueAfterLaunch()
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(third.requests.isEmpty && looping.canResume && !looping.autoResumePending,
                     "a run that keeps interrupting relaunches waits for the user")
        guard let quit = looping.messages.last(where: { $0.role == .error }) else { preconditionFailure() }
        precondition(looping.continuableMessageIDs == [quit.id], "the interruption notice offers Continue")
        precondition(looping.continueFailedRun(from: quit.id, includesAmbientContext: false) == nil)
        try await waitForJournalTest { third.requests.count == 1 }
        third.sink?(.done)
        try await waitForJournalTest { third.requests.count == 2 }
        precondition(third.requests[1].prompt.contains("follow-up"))
        third.sink?(.done)
        try await waitForJournalTest { !looping.isStreaming && looping.queued.isEmpty }

        // Relaunching while a failed run waits for Continue doesn't retry it.
        let pausedBackend = ContinuityBackend()
        let paused = ChatSession(copilotBackend: pausedBackend)
        paused.submitRemote("paused task", mode: .queue)
        try await waitForJournalTest { pausedBackend.requests.count == 1 }
        pausedBackend.sink?(.failure("Request timed out."))
        try await waitForJournalTest { paused.canResume }
        try await paused.flushJournal()
        let reopenedBackend = ContinuityBackend()
        let reopened = ChatSession(id: paused.id, copilotBackend: reopenedBackend)
        reopened.continueAfterLaunch()
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(reopenedBackend.requests.isEmpty && !reopened.autoResumePending
                     && reopened.continuableMessageIDs.count == 1, "a failed run stays paused after a relaunch")
        precondition(reopened.continueFailedRun(from: reopened.continuableMessageIDs.first!, includesAmbientContext: false) == nil)
        try await waitForJournalTest { reopenedBackend.requests.count == 1 }
        precondition(reopenedBackend.requests[0].prompt.contains("paused task"))
        reopenedBackend.sink?(.done)
        try await waitForJournalTest { !reopened.isStreaming }

        // Clearing the conversation abandons the failed run; the next message sends at once.
        let clearing = ContinuityBackend()
        let cleared = ChatSession(copilotBackend: clearing)
        cleared.submitRemote("abandoned task", mode: .queue)
        try await waitForJournalTest { clearing.requests.count == 1 }
        clearing.sink?(.failure("TypeError: fetch failed"))
        try await waitForJournalTest { !cleared.isStreaming && !cleared.continuableMessageIDs.isEmpty }
        cleared.newConversation()
        precondition(!cleared.canResume && cleared.continuableMessageIDs.isEmpty)
        cleared.submitRemote("fresh task")
        try await waitForJournalTest { clearing.requests.count == 2 }
        precondition(clearing.requests[1].prompt.contains("fresh task")
                     && !clearing.requests[1].prompt.contains("interrupted mid-run"))
        clearing.sink?(.done)
        try await waitForJournalTest { !cleared.isStreaming }
        print("Run continuity: failed runs wait for Continue on their message; queues and relaunches keep their order")
    }
}
