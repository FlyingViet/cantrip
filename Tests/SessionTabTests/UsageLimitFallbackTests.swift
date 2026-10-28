import Foundation

private final class LimitBackend: Backend {
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
    /// A backend at its plan's usage limit hands the run to the fallback backend, and new
    /// messages start there until the limit lifts. Nothing loops when the fallback is limited too.
    @MainActor
    static func testUsageLimitFallback() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        precondition(UsageLimit.isLimitError("Claude AI usage limit reached|1800003600"))
        precondition(UsageLimit.isLimitError("You've hit your limit · resets 3pm (America/Los_Angeles)"))
        precondition(UsageLimit.isLimitError("You have exceeded your premium request allowance."))
        precondition(UsageLimit.isLimitError("You've hit your usage limit. Upgrade to Pro, or try again in 4 days 2 hours."))
        precondition(UsageLimit.isLimitError("429 RESOURCE_EXHAUSTED: Quota exceeded for model"))
        precondition(!UsageLimit.isLimitError("Context limit reached · /compact or /clear to continue"))
        precondition(!UsageLimit.isLimitError("TypeError: fetch failed"))
        precondition(!UsageLimit.isLimitError("Model \"x\" is not available."))
        precondition(UsageLimit.resetDate(in: "Claude AI usage limit reached|1800003600", now: now)
            == Date(timeIntervalSince1970: 1_800_003_600))
        precondition(UsageLimit.resetDate(in: "try again in 2 hours and 5 minutes.", now: now)
            == now.addingTimeInterval(2 * 3_600 + 5 * 60))
        precondition(UsageLimit.resetDate(in: "You've hit your limit · resets 3pm", now: now) == nil)

        let tracker = BackendLimitTracker()
        tracker.markLimited(.codex, message: "usage limit", now: now)
        precondition(tracker.limitedUntil(.codex, now: now.addingTimeInterval(60)) != nil)
        precondition(BackendFallback.target(for: .copilot, configured: "", homeRun: false, tracker: tracker, now: now) == nil)
        precondition(BackendFallback.target(for: .copilot, configured: "Copilot", homeRun: false, tracker: tracker, now: now) == nil)
        precondition(BackendFallback.target(for: .claudeCode, configured: "Copilot", homeRun: false, tracker: tracker, now: now) == .copilot)
        precondition(BackendFallback.target(for: .claudeCode, configured: "Codex", homeRun: false, tracker: tracker, now: now) == nil,
                     "a limited fallback isn't used")
        precondition(BackendFallback.target(for: .claudeCode, configured: "Copilot Remote", homeRun: true, tracker: tracker, now: now) == nil,
                     "unattended Home runs stay on backends Cantrip checks per action")
        precondition(tracker.limitedUntil(.codex, now: now.addingTimeInterval(BackendLimitTracker.defaultCooldown + 1)) == nil)

        let settings = AppSettings.shared
        settings.memoryEnabled = false
        settings.voiceMode = false
        settings.backend = .copilot
        settings.limitFallbackBackend = BackendKind.claudeCode.rawValue
        BackendLimitTracker.shared.clear()
        defer {
            settings.limitFallbackBackend = ""
            BackendLimitTracker.shared.clear()
        }

        // The limit stops a run partway: the same run continues on the fallback.
        let copilot = LimitBackend()
        let claude = LimitBackend()
        let chat = ChatSession(copilotBackend: copilot, backendOverrides: [.claudeCode: claude])
        chat.submitRemote("first task", mode: .queue)
        try await waitForJournalTest { copilot.requests.count == 1 }
        copilot.sink?(.textDelta("partial work"))
        copilot.sink?(.failure("You have exceeded your premium request allowance. Try again in 2 hours."))
        try await waitForJournalTest { claude.requests.count == 1 }
        precondition(BackendLimitTracker.shared.limitedUntil(.copilot) != nil)
        precondition(claude.requests[0].prompt.contains("first task"), "the interrupted task continues on the fallback")
        precondition(chat.messages.contains { $0.role == .error && $0.text.contains("Continuing this task with Claude Code") })
        claude.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // New messages skip the limited backend.
        chat.submitRemote("second task", mode: .queue)
        try await waitForJournalTest { claude.requests.count == 2 }
        precondition(copilot.requests.count == 1, "the limited backend isn't tried again")
        precondition(chat.deliveryStatus?.contains("usage limit until") == true)

        // The fallback hits its limit too: the run fails instead of bouncing back.
        claude.sink?(.failure("Claude AI usage limit reached|\(Int(Date().timeIntervalSince1970) + 3_600)"))
        try await waitForJournalTest { !chat.isStreaming && !chat.autoResumePending }
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(copilot.requests.count == 1 && claude.requests.count == 2)

        // Off: a limit error ends the run as before.
        BackendLimitTracker.shared.clear()
        settings.limitFallbackBackend = ""
        chat.submitRemote("third task", mode: .queue)
        try await waitForJournalTest { copilot.requests.count == 2 }
        copilot.sink?(.failure("You have exceeded your premium request allowance."))
        try await waitForJournalTest { !chat.isStreaming && !chat.autoResumePending }
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(claude.requests.count == 2 && copilot.requests.count == 2)
    }
}
