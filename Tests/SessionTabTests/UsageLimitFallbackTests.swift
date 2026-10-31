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
    /// A backend at its plan's usage limit hands the run to the next backup in the chain, and new
    /// messages start there until the limit lifts. Nothing loops when every backup is limited too.
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
        precondition(BackendFallback.target(for: .copilot, chain: [], homeRun: false, tracker: tracker, now: now) == nil)
        precondition(BackendFallback.target(for: .copilot, chain: ["Copilot"], homeRun: false, tracker: tracker, now: now) == nil)
        precondition(BackendFallback.target(for: .claudeCode, chain: ["Copilot"], homeRun: false, tracker: tracker, now: now) == .copilot)
        precondition(BackendFallback.target(for: .claudeCode, chain: ["Codex"], homeRun: false, tracker: tracker, now: now) == nil,
                     "a limited fallback isn't used")
        precondition(BackendFallback.target(for: .claudeCode, chain: ["Codex", "Claude Code", "Antigravity", "Copilot"],
                                            homeRun: false, tracker: tracker, now: now) == .antigravity,
                     "the chain skips the limited backend and the one being left, in order")
        precondition(BackendFallback.target(for: .claudeCode, chain: ["Copilot Remote"], homeRun: true, tracker: tracker, now: now) == nil,
                     "unattended Home runs stay on backends Cantrip checks per action")
        precondition(BackendFallback.target(for: .claudeCode, chain: ["Copilot Remote", "Local Model"], homeRun: true, tracker: tracker, now: now) == .localModel,
                     "...and move on to the next backup instead")
        precondition(AppSettings.fallbackChain(["Codex", "Nope", "Copilot", "Codex"]) == ["Codex", "Copilot"],
                     "the saved chain keeps known backends once, in order")
        precondition(tracker.limitedUntil(.codex, now: now.addingTimeInterval(BackendLimitTracker.defaultCooldown + 1)) == nil)

        let settings = AppSettings.shared
        settings.memoryEnabled = false
        settings.voiceMode = false
        settings.backend = .copilot
        settings.limitFallbackBackends = [BackendKind.claudeCode.rawValue, BackendKind.codex.rawValue]
        // The Claude backup is pinned to a model and effort Claude Code offers.
        let savedCatalog = settings.claudeModelCatalog
        settings.claudeModelCatalog = [
            CopilotModelInfo(id: "claude-opus-5-5", reasoningEfforts: ["low", "medium", "high"]),
            CopilotModelInfo(id: "claude-sonnet-5-5", reasoningEfforts: ["low", "high"]),
        ]
        settings.limitFallbackModels = ["Claude Code": SessionModelSelection(model: "claude-opus-5-5", effort: "high", contextTier: "")]
        BackendLimitTracker.shared.clear()
        defer {
            settings.limitFallbackBackends = []
            settings.limitFallbackModels = [:]
            settings.claudeModelCatalog = savedCatalog
            BackendLimitTracker.shared.clear()
        }
        let pinned = settings.fallbackRun(for: .claudeCode)
        precondition(pinned.selection?.model == "claude-opus-5-5" && pinned.selection?.effort == "high"
                     && pinned.label == "Claude Code · claude-opus-5-5 · high", "\(pinned)")
        settings.limitFallbackModels["Claude Code"] = SessionModelSelection(model: "claude-gone-4", effort: "high", contextTier: "")
        let gone = settings.fallbackRun(for: .claudeCode)
        precondition(gone.selection?.model == settings.claudeModel && gone.label.contains("claude-gone-4 isn't available now"),
                     "A model that's no longer offered runs the default, and the note says so: \(gone)")
        settings.limitFallbackModels["Claude Code"] = SessionModelSelection(model: "claude-opus-5-5", effort: "high", contextTier: "")
        precondition(settings.fallbackRun(for: .codex).selection == nil, "A backup with no choice runs as it would on its own")

        // The limit stops a run partway: the same run continues on the fallback. Copilot's own
        // report decides; this message's wording matches none of the phrases.
        let copilot = LimitBackend()
        let claude = LimitBackend()
        let codex = LimitBackend()
        let chat = ChatSession(copilotBackend: copilot, backendOverrides: [.claudeCode: claude, .codex: codex])
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
        precondition(chat.messages.contains { $0.role == .error && $0.text.contains("Continuing this task with Claude Code · claude-opus-5-5 · high") },
                     "The note names the backup's model and effort")
        precondition(chat.fallbackModel == pinned, "The run on the backup uses its chosen model and effort")
        claude.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // New messages skip the limited backend.
        chat.submitRemote("second task", mode: .queue)
        try await waitForJournalTest { claude.requests.count == 2 }
        precondition(copilot.requests.count == 1, "the limited backend isn't tried again")
        precondition(chat.deliveryStatus?.contains("usage limit until") == true)

        // The first backup hits its limit too: the run moves down the chain to the second.
        claude.sink?(.textDelta("more work"))
        claude.sink?(.failure("Claude AI usage limit reached|\(Int(Date().timeIntervalSince1970) + 3_600)"))
        try await waitForJournalTest { codex.requests.count == 1 }
        precondition(codex.requests[0].prompt.contains("second task"), "the task continues on the next backup")
        precondition(chat.messages.contains { $0.role == .error && $0.text.contains("Continuing this task with Codex") })
        precondition(copilot.requests.count == 1 && claude.requests.count == 2, "limited backends aren't tried again")
        codex.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // The last backup runs out as well: the run fails instead of bouncing back.
        chat.submitRemote("third task", mode: .queue)
        try await waitForJournalTest { codex.requests.count == 2 }
        codex.sink?(.failure("You've hit your usage limit. Try again in 3 hours."))
        try await waitForJournalTest { !chat.isStreaming && !chat.autoResumePending }
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(copilot.requests.count == 1 && claude.requests.count == 2 && codex.requests.count == 2)

        // Back on the Mac's own backend, the backup's model no longer applies.
        BackendLimitTracker.shared.clear()
        settings.limitFallbackBackends = [BackendKind.claudeCode.rawValue]
        chat.submitRemote("own backend task", mode: .queue)
        try await waitForJournalTest { copilot.requests.count == 2 }
        precondition(chat.fallbackModel == nil, "The tab's own model returns with its own backend")
        copilot.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        // Off: a limit error ends the run as before.
        BackendLimitTracker.shared.clear()
        settings.limitFallbackBackends = []
        chat.submitRemote("fourth task", mode: .queue)
        try await waitForJournalTest { copilot.requests.count == 3 }
        copilot.sink?(.failure("You have exceeded your premium request allowance."))
        try await waitForJournalTest { !chat.isStreaming && !chat.autoResumePending }
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(claude.requests.count == 2 && copilot.requests.count == 3 && codex.requests.count == 2)
        try await testUsageFallbackAPI()
    }

    /// Paired clients read and set the fallbacks, and clear limits, through /api/v1/usage-fallback.
    @MainActor
    private static func testUsageFallbackAPI() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.limitFallbackBackends)
        defer { (settings.backend, settings.limitFallbackBackends) = saved; BackendLimitTracker.shared.clear() }
        settings.backend = .claudeCode
        settings.limitFallbackBackends = []
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
        precondition(loaded.0 == 200 && loaded.1["backend"] as? String == "" && (loaded.1["backends"] as? [String])?.isEmpty == true
                     && loaded.1["primary"] as? String == "Claude Code"
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
        let unknown = try await call("POST", ["revision": revision, "backends": ["Copilot", "Nope"]])
        let twice = try await call("POST", ["revision": revision, "backends": ["Copilot", "Copilot"]])
        precondition(unknown.0 == 400 && twice.0 == 400, "The chain names known backends, each once")
        let chain = try await call("POST", ["revision": revision, "backends": ["Codex", "Copilot"]])
        precondition(chain.0 == 200 && chain.1["backends"] as? [String] == ["Codex", "Copilot"]
                     && chain.1["backend"] as? String == "Codex" && settings.limitFallbackBackends == ["Codex", "Copilot"],
                     "POST saves the chain in order: \(chain)")
        // An older client sends one backend: it replaces the first backup and keeps the rest.
        let set = try await call("POST", ["revision": chain.1["revision"] as? String ?? "", "backend": "Copilot"])
        precondition(set.0 == 200 && set.1["backend"] as? String == "Copilot" && settings.limitFallbackBackends == ["Copilot"],
                     "An older client's pick replaces the first backup and isn't listed twice: \(set)")
        let two = try await call("POST", ["revision": set.1["revision"] as? String ?? "", "backends": ["Copilot", "Codex"]])
        let antigravity = try await call("POST", ["revision": two.1["revision"] as? String ?? "", "backend": "Antigravity"])
        precondition(antigravity.0 == 200 && settings.limitFallbackBackends == ["Antigravity", "Codex"],
                     "An older client's pick replaces only the first backup: \(antigravity)")
        let cleared = try await call("POST", ["revision": antigravity.1["revision"] as? String ?? "", "resetLimits": true])
        precondition(cleared.0 == 200 && (cleared.1["limited"] as? [Any])?.isEmpty == true
                     && BackendLimitTracker.shared.limitedUntil(.claudeCode) == nil,
                     "resetLimits lets every backend be tried again: \(cleared)")
        // Each backup's model and effort, from the backend's real lists.
        let savedCatalog = settings.claudeModelCatalog
        let savedModels = settings.limitFallbackModels
        defer { settings.claudeModelCatalog = savedCatalog; settings.limitFallbackModels = savedModels }
        settings.backend = .copilot
        settings.claudeModelCatalog = [CopilotModelInfo(id: "claude-opus-5-5", reasoningEfforts: ["low", "high"])]
        let offered = try await call()
        let claudeChoice = (offered.1["choices"] as? [[String: Any]] ?? []).first { $0["id"] as? String == "Claude Code" }
        let codexChoice = (offered.1["choices"] as? [[String: Any]] ?? []).first { $0["id"] as? String == "Codex" }
        let claudeModels = claudeChoice?["models"] as? [[String: Any]]
        precondition(claudeModels?.first?["id"] as? String == "claude-opus-5-5"
                     && claudeModels?.first?["efforts"] as? [String] == ["low", "high"] && codexChoice?["models"] == nil,
                     "Choices list each backend's real models and efforts, none for a backend without a picker: \(offered.1)")
        var rev = offered.1["revision"] as? String ?? ""
        let fake = try await call("POST", ["revision": rev, "entries": [["backend": "Claude Code", "model": "claude-fake-9"]]])
        let badEffort = try await call("POST", ["revision": rev, "entries": [["backend": "Claude Code", "model": "claude-opus-5-5", "effort": "medium"]]])
        let codexModel = try await call("POST", ["revision": rev, "entries": [["backend": "Codex", "model": "gpt-5"]]])
        precondition(fake.0 == 400 && badEffort.0 == 400 && codexModel.0 == 400,
                     "Only models and efforts the backend offers are accepted")
        let entries = try await call("POST", ["revision": rev, "entries": [
            ["backend": "Claude Code", "model": "claude-opus-5-5", "effort": "high"], ["backend": "Codex"]]])
        let savedEntries = entries.1["entries"] as? [[String: Any]]
        precondition(entries.0 == 200 && settings.limitFallbackBackends == ["Claude Code", "Codex"]
                     && settings.limitFallbackModels["Claude Code"] == SessionModelSelection(model: "claude-opus-5-5", effort: "high", contextTier: "")
                     && savedEntries?.first?["model"] as? String == "claude-opus-5-5"
                     && savedEntries?.first?["effort"] as? String == "high" && savedEntries?.last?["model"] as? String == "",
                     "POST entries saves the chain with each backup's model and effort: \(entries)")
        // A client that only edits the order keeps the chosen models.
        rev = entries.1["revision"] as? String ?? ""
        let reordered = try await call("POST", ["revision": rev, "backends": ["Codex", "Claude Code"]])
        let kept = (reordered.1["entries"] as? [[String: Any]])?.last
        precondition(reordered.0 == 200 && kept?["backend"] as? String == "Claude Code" && kept?["model"] as? String == "claude-opus-5-5",
                     "Reordering through backends keeps each backup's model: \(reordered)")
        rev = reordered.1["revision"] as? String ?? ""
        let older = try await call("POST", ["revision": rev, "backend": "Claude Code"])
        precondition(older.0 == 200 && settings.limitFallbackModels["Claude Code"]?.model == "claude-opus-5-5",
                     "An older client's single pick keeps the model too")
        // `cantrip config`: name:model:effort sets a backup's model and effort; a bare name keeps it.
        let host = HostControl(manager: manager)
        let configured = host.handle(["command": "config", "set": ["limitFallbackBackends": "claude:claude-opus-5-5:low, codex"]])
        precondition(configured["error"] == nil && settings.limitFallbackBackends == ["Claude Code", "Codex"]
                     && settings.limitFallbackModels["Claude Code"] == SessionModelSelection(model: "claude-opus-5-5", effort: "low", contextTier: ""),
                     "cantrip config sets the chain with a backup's model and effort: \(configured)")
        let listed = (configured["settings"] as? [String: Any])?["limitFallbackModels"] as? [String: [String: String]]
        precondition(listed?["Claude Code"]?["effort"] == "low", "config lists the chosen models")
        _ = host.handle(["command": "config", "set": ["limitFallbackBackends": "codex, claude"]])
        precondition(settings.limitFallbackModels["Claude Code"]?.model == "claude-opus-5-5", "A bare name keeps the saved model")
        let wrong = host.handle(["command": "config", "set": ["limitFallbackBackends": "claude:claude-fake-1"]])
        precondition((wrong["error"] as? String)?.contains("doesn't offer claude-fake-1") == true,
                     "config refuses a model the backend doesn't offer: \(wrong)")
        settings.backend = .claudeCode
        let current = try await call()

        let off = try await call("POST", ["revision": current.1["revision"] as? String ?? "", "backend": ""])
        precondition(off.0 == 200 && settings.limitFallbackBackends.isEmpty, "\"\" turns every backup off")
        let ready = try await call()
        precondition(ready.1["backend"] as? String == "" && (ready.1["backends"] as? [String])?.isEmpty == true,
                     "Reads back the saved value")
    }
}
