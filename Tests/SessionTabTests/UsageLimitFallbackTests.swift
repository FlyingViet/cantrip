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

        // Copilot's session.error category decides, not its wording.
        let monthly = "You have exceeded your monthly quota (Request ID: DE85:240A65:64CE8F:76CB05:6AE2A78D)"
        let quota = UsageLimit.copilotReport(errorType: "quota", errorCode: "quota_exceeded", message: monthly, now: now)
        precondition(quota?.code == "quota/quota_exceeded")
        precondition(quota?.resetsAt == UsageLimit.startOfNextMonthUTC(after: now),
                     "the monthly allowance is skipped until it resets, not retried hourly")
        precondition(UsageLimit.startOfNextMonthUTC(after: now) == ISO8601DateFormatter().date(from: "2027-02-01T00:00:00Z"))
        precondition(UsageLimit.copilotReport(errorType: "rate_limit", errorCode: "user_weekly_rate_limited",
                                              message: "Try again in 3 hours.", now: now)?.resetsAt
            == now.addingTimeInterval(3 * 3_600))
        precondition(UsageLimit.copilotReport(errorType: "rate_limit", errorCode: nil, message: "", now: now)?.resetsAt == nil)
        precondition(UsageLimit.copilotReport(errorType: "authentication", errorCode: nil, message: "quota", now: now) == nil)
        precondition(UsageLimit.copilotReport(errorType: "context_limit", errorCode: nil, message: "", now: now) == nil)
        let reported = BackendLimitTracker()
        reported.markLimited(.copilot, message: monthly, report: quota, now: now)
        precondition(reported.limitedUntil(.copilot, now: now.addingTimeInterval(BackendLimitTracker.defaultCooldown + 1)) != nil,
                     "a reported reset outlasts the default cooldown")

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

        // The limit stops a run partway: the same run continues on the fallback. Copilot's own
        // report decides; this message's wording matches none of the phrases.
        let copilot = LimitBackend()
        let claude = LimitBackend()
        let chat = ChatSession(copilotBackend: copilot, backendOverrides: [.claudeCode: claude])
        chat.submitRemote("first task", mode: .queue)
        try await waitForJournalTest { copilot.requests.count == 1 }
        copilot.sink?(.textDelta("partial work"))
        precondition(!UsageLimit.isLimitError(monthly))
        copilot.sink?(.usageLimit(UsageLimit.copilotReport(errorType: "quota", errorCode: "quota_exceeded", message: monthly)!))
        copilot.sink?(.failure(monthly))
        try await waitForJournalTest { claude.requests.count == 1 }
        precondition(BackendLimitTracker.shared.limitedUntil(.copilot) == UsageLimit.startOfNextMonthUTC(after: Date()),
                     "Copilot is skipped until its monthly allowance resets")
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
        try await testUsageFallbackAPI()
    }

    /// Paired clients read and set the fallback, and clear limits, through /api/v1/usage-fallback.
    @MainActor
    private static func testUsageFallbackAPI() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.limitFallbackBackend)
        defer { (settings.backend, settings.limitFallbackBackend) = saved; BackendLimitTracker.shared.clear() }
        settings.backend = .claudeCode
        settings.limitFallbackBackend = ""
        BackendLimitTracker.shared.clear()
        BackendLimitTracker.shared.markLimited(.claudeCode, message: "Claude AI usage limit reached|\(Int(Date().timeIntervalSince1970) + 3_600)")

        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager)
        defer { withExtendedLifetime(manager) {} }
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ method: String = "GET", _ body: [String: Any]? = nil, authorized: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/usage-fallback")!)
            request.httpMethod = method
            if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
        }

        let loaded = try await call()
        let choices = (loaded.1["choices"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let limited = loaded.1["limited"] as? [[String: Any]] ?? []
        precondition(loaded.0 == 200 && loaded.1["backend"] as? String == "" && loaded.1["primary"] as? String == "Claude Code"
                     && !choices.contains("Claude Code") && choices.contains("Copilot")
                     && limited.first?["backend"] as? String == "Claude Code",
                     "GET lists the choices without the Mac's own backend, and who is limited: \(loaded)")
        let revision = loaded.1["revision"] as? String ?? ""
        let anonymous = try await call(authorized: false)
        let itself = try await call("POST", ["revision": revision, "backend": "Claude Code"])
        let stale = try await call("POST", ["revision": "stale", "backend": "Copilot"])
        precondition(anonymous.0 == 401, "Pairing is required")
        precondition(itself.0 == 400, "A backend can't fall back on itself")
        precondition(stale.0 == 409, "A stale revision is refused")
        let set = try await call("POST", ["revision": revision, "backend": "Copilot"])
        precondition(set.0 == 200 && set.1["backend"] as? String == "Copilot" && settings.limitFallbackBackend == "Copilot",
                     "POST saves the fallback: \(set)")
        let cleared = try await call("POST", ["revision": set.1["revision"] as? String ?? "", "resetLimits": true])
        precondition(cleared.0 == 200 && (cleared.1["limited"] as? [Any])?.isEmpty == true
                     && BackendLimitTracker.shared.limitedUntil(.claudeCode) == nil,
                     "resetLimits lets every backend be tried again: \(cleared)")
        let off = try await call("POST", ["revision": cleared.1["revision"] as? String ?? "", "backend": ""])
        precondition(off.0 == 200 && settings.limitFallbackBackend == "", "\"\" turns it off")
        let ready = try await call()
        precondition(ready.1["backend"] as? String == "", "Reads back the saved value")
    }
}
