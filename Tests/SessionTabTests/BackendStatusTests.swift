import Foundation

private final class StatusFakeBackend: Backend {
    var requests: [BackendRequest] = []
    var sink: ((BackendEvent) -> Void)?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        requests.append(request)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}
}

/// Answers for a monitor's checks, set per backend by the test.
private final class FakeProber {
    private let lock = NSLock()
    private var answers: [MonitoredBackend: [BackendProbe]] = [:]
    private(set) var calls: [MonitoredBackend] = []

    func answer(_ backend: MonitoredBackend, _ probes: BackendProbe...) {
        lock.withLock { answers[backend] = probes }
    }

    func count(_ backend: MonitoredBackend) -> Int { lock.withLock { calls.filter { $0 == backend }.count } }

    var prober: BackendStatusMonitor.Prober {
        { [self] backend, completion in
            let probe: BackendProbe = lock.withLock {
                calls.append(backend)
                var queue = answers[backend] ?? [BackendProbe(installed: false)]
                let next = queue.count > 1 ? queue.removeFirst() : queue[0]
                answers[backend] = queue
                return next
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { completion(probe) }
        }
    }
}

extension SessionTabTests {
    /// Nov 1: Cantrip checks every backend CLI is installed and signed in (no model calls), shows
    /// it in Settings on every client, alerts once when one goes signed out (and once when it's
    /// back), and routes around it meanwhile.
    @MainActor
    static func testBackendStatus() async throws {
        precondition(ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"] != nil,
                     "backend status tests write under HOME: run with a temporary one")
        try testBackendStatusParsers()
        try await testBackendStatusStubCLIs()
        try await testBackendStatusMonitor()
        try await testBackendStatusSignIn()
        try await testBackendStatusRouting()
        print("Backend status: CLI checks (signed in, signed out, slow, missing), one alert per outage, device sign-in, payload and routing passed")
    }

    private static func testBackendStatusParsers() throws {
        let claudeIn = BackendProbes.parseClaudeStatus("""
        {"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "email": "person@example.com",
         "orgName": "Example", "subscriptionType": "max"}
        """)
        precondition(claudeIn == .init(signedIn: true, account: "person@example.com", method: "Claude account", plan: "Max"), "\(claudeIn)")
        precondition(BackendProbes.parseClaudeStatus(#"{"loggedIn": false}"#).signedIn == false)
        precondition(BackendProbes.parseClaudeStatus(#"{"loggedIn": true, "apiProvider": "bedrock"}"#).method == "Amazon Bedrock")
        precondition(BackendProbes.parseClaudeStatus("Not logged in. Run claude auth login.").signedIn == false)
        precondition(BackendProbes.parseClaudeStatus("TypeError: fetch failed").signedIn == nil,
                     "a CLI error isn't a sign-out")

        let codexIn = BackendProbes.parseCodexAccount(["account": ["type": "chatgpt", "email": "person@example.com", "planType": "plus"],
                                                       "requiresOpenaiAuth": true])
        precondition(codexIn == .init(signedIn: true, account: "person@example.com", method: "ChatGPT", plan: "Plus"), "\(codexIn)")
        precondition(BackendProbes.parseCodexAccount(["account": NSNull(), "requiresOpenaiAuth": true]).signedIn == false)
        precondition(BackendProbes.parseCodexAccount(["account": ["type": "apiKey"]]).method == "API key")
        precondition(BackendProbes.parseCodexLoginStatus("Logged in using ChatGPT") == .init(signedIn: true, method: "ChatGPT"))
        precondition(BackendProbes.parseCodexLoginStatus("Not logged in").signedIn == false)
        precondition(BackendProbes.parseCodexLoginStatus("error: config.toml is invalid").signedIn == nil)

        precondition(BackendProbes.parseAntigravityUsage(#"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage"}}"#).signedIn == true)
        precondition(BackendProbes.parseAntigravityUsage(#"{"status":"ERROR","error":"You are not logged into Antigravity."}"#).signedIn == false)
        precondition(BackendProbes.parseAntigravityUsage(#"{"status":"ERROR","error":"deadline exceeded"}"#).signedIn == nil)

        precondition(BackendProbes.parseVersion("2.1.312 (Claude Code)") == "2.1.312")
        precondition(BackendProbes.parseVersion("codex-cli 0.166.0") == "0.166.0")

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("backend-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let config = home.appendingPathComponent(".copilot/config.json")
        try """
        // User settings belong in settings.json.
        // This file is managed automatically.
        {"lastLoggedInUser": {"host": "https://github.com", "login": "octocat"},
         "loggedInUsers": [{"host": "https://github.com", "kind": "oauth", "login": "octocat"}]}
        """.write(to: config, atomically: true, encoding: .utf8)
        let user = BackendProbes.copilotConfigUser(home: home.path)
        precondition(user?.signedIn == true && user?.login == "octocat", "\(String(describing: user))")
        let viaConfig = BackendProbes.copilotStatus(.failure(CopilotQuotaError.timeout), home: home.path)
        precondition(viaConfig.signedIn == true && viaConfig.account == "octocat", "\(viaConfig)")
        precondition(BackendProbes.copilotStatus(.failure(CopilotQuotaError.authentication), home: home.path).signedIn == false,
                     "GitHub refusing the token wins over the config's list")
        try "// c\n{\"loggedInUsers\": []}".write(to: config, atomically: true, encoding: .utf8)
        precondition(BackendProbes.copilotStatus(.failure(CopilotQuotaError.timeout), home: home.path).signedIn == false)

        let copilotCode = BackendStatusMonitor.deviceCode(in: """
        \u{1B}[1mTo authenticate, visit https://github.com/login/device and enter code ABCD-1234.\u{1B}[0m
        """)
        precondition(copilotCode.url == "https://github.com/login/device" && copilotCode.code == "ABCD-1234", "\(copilotCode)")
        let codexCode = BackendStatusMonitor.deviceCode(in: "Open https://auth.openai.com/codex/device\nEnter this one-time code: WXYZ-98765")
        precondition(codexCode.url == "https://auth.openai.com/codex/device" && codexCode.code == "WXYZ-98765", "\(codexCode)")
    }

    /// The real checks against stub CLIs: signed in, signed out, too slow, and missing.
    @MainActor
    private static func testBackendStatusStubCLIs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("backend-stubs-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        let saved = (settings.claudePath, settings.codexPath, settings.agyPath)
        let savedTimeout = BackendProbes.authTimeout
        defer {
            (settings.claudePath, settings.codexPath, settings.agyPath) = saved
            BackendProbes.authTimeout = savedTimeout
            try? FileManager.default.removeItem(at: folder)
        }
        func stub(_ name: String, _ body: String) throws -> String {
            let path = folder.appendingPathComponent(name).path
            try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return path
        }
        func probe(_ backend: MonitoredBackend) async -> BackendProbe {
            await withCheckedContinuation { continuation in
                BackendProbes.probe(backend, settings: settings, copilotAccount: { $0(.failure(CopilotQuotaError.authentication)) }) {
                    continuation.resume(returning: $0)
                }
            }
        }
        BackendProbes.authTimeout = 2

        settings.claudePath = try stub("claude-in", """
        case "$1" in
          --version) echo "9.9.9 (Claude Code)";;
          auth) echo '{"loggedIn": true, "authMethod": "claude.ai", "email": "person@example.com", "subscriptionType": "pro"}';;
        esac
        """)
        let claudeIn = await probe(.claude)
        precondition(claudeIn.installed && claudeIn.version == "9.9.9" && claudeIn.signedIn == true
                     && claudeIn.account == "person@example.com" && claudeIn.plan == "Pro", "\(claudeIn)")

        settings.claudePath = try stub("claude-out", """
        case "$1" in --version) echo "9.9.9 (Claude Code)";; auth) echo '{"loggedIn": false}'; exit 1;; esac
        """)
        let claudeOut = await probe(.claude)
        precondition(claudeOut.signedIn == false, "\(claudeOut)")

        settings.claudePath = try stub("claude-slow", """
        case "$1" in --version) echo "9.9.9 (Claude Code)";; auth) exec sleep 30;; esac
        """)
        let started = Date()
        let slow = await probe(.claude)
        precondition(slow.installed && slow.signedIn == nil && slow.problem?.contains("didn't answer") == true, "\(slow)")
        precondition(Date().timeIntervalSince(started) < 15, "a slow CLI is cut off at its time limit")

        settings.claudePath = folder.appendingPathComponent("not-here/claude").path
        let missing = await probe(.claude)
        precondition(missing == BackendProbe(installed: false), "a missing CLI is reported as not installed: \(missing)")

        // Codex: the app server isn't there (a stub), so `codex login status` answers.
        settings.codexPath = try stub("codex", """
        case "$1" in --version) echo "codex-cli 9.1.0";; login) echo "Logged in using ChatGPT";; *) exit 3;; esac
        """)
        let codex = await probe(.codex)
        precondition(codex.version == "9.1.0" && codex.signedIn == true && codex.authMethod == "ChatGPT", "\(codex)")

        settings.agyPath = try stub("agy", """
        case "$1" in --version) echo "1.4.99";; -p) echo '{"status":"ERROR","error":"You are not logged into Antigravity."}';; esac
        """)
        let agy = await probe(.antigravity)
        precondition(agy.version == "1.4.99" && agy.signedIn == false, "\(agy)")
    }

    @MainActor
    private static func testBackendStatusMonitor() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("backend-status-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let savedDelay = BackendStatusMonitor.confirmDelay
        BackendStatusMonitor.confirmDelay = 0.05
        defer { BackendStatusMonitor.confirmDelay = savedDelay }
        let fake = FakeProber()
        let tracker = BackendLimitTracker()
        let signedIn = BackendProbe(installed: true, path: "/stub/claude", version: "9.9.9", signedIn: true,
                                    account: "person@example.com", authMethod: "Claude account")
        let signedOut = BackendProbe(installed: true, path: "/stub/claude", version: "9.9.9", signedIn: false,
                                     problem: "Claude Code isn't signed in.")
        fake.answer(.claude, signedIn)
        fake.answer(.codex, BackendProbe(installed: true, path: "/stub/codex", signedIn: nil, problem: "Codex didn't answer within 45 s."))
        fake.answer(.copilot, BackendProbe(installed: true, path: "/stub/copilot", signedIn: true, account: "octocat"))
        fake.answer(.antigravity, BackendProbe(installed: false))
        let monitor = BackendStatusMonitor(store: store, prober: fake.prober, tracker: tracker)
        func settle() async throws {
            for _ in 0..<200 {
                if !monitor.statuses.contains(where: \.checking) { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        precondition(monitor.statuses.map(\.id) == ["copilot", "claude", "antigravity", "codex"])
        precondition(monitor.statuses.allSatisfy { $0.state == .unknown && $0.summary == "Not checked yet" })

        monitor.check()
        precondition(monitor.statuses.allSatisfy(\.checking), "Check now shows every row checking at once")
        try await settle()
        precondition(monitor.status(.claude)?.state == .ready && monitor.status(.claude)?.account == "person@example.com")
        precondition(monitor.status(.codex)?.state == .unknown && monitor.status(.codex)?.unavailable == false,
                     "a check that couldn't tell never takes a backend out of routing")
        precondition(monitor.status(.antigravity)?.state == .notInstalled && monitor.status(.antigravity)?.unavailable == false)
        precondition(monitor.alerts.isEmpty)

        // One stray "signed out" is checked again before anything changes.
        fake.answer(.claude, signedOut, signedIn)
        monitor.check([.claude])
        try await settle()
        precondition(monitor.status(.claude)?.state == .ready && fake.count(.claude) == 3 && monitor.alerts.isEmpty,
                     "the confirming check found it signed in")

        // Signed out for real: skipped by routing, and one alert.
        fake.answer(.claude, signedOut)
        monitor.check([.claude])
        try await settle()
        let out = monitor.status(.claude)!
        precondition(out.state == .signedOut && out.unavailable && tracker.limitedUntil(.claudeCode) == .distantFuture, "\(out)")
        precondition(tracker.usageLimitedUntil(.claudeCode) == nil, "being signed out isn't a usage limit")
        precondition(monitor.alerts.map(\.title) == ["Claude Code is signed out"], "\(monitor.alerts)")
        monitor.check([.claude])
        try await settle()
        monitor.runFailed(.claudeCode, message: "Failed to authenticate. API Error: 401 OAuth token has expired.")
        try await settle()
        precondition(monitor.alerts.count == 1, "no repeat while it stays down")
        precondition(monitor.status(.claude)?.lastAuthError?.message.contains("OAuth token has expired") == true)

        // The state survives a relaunch, so the alert isn't sent again.
        let relaunched = BackendStatusMonitor(store: store, prober: fake.prober, tracker: tracker)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(relaunched.status(.claude)?.state == .signedOut && relaunched.alerts.isEmpty)

        // Back: one more alert, and routing uses it again.
        fake.answer(.claude, signedIn)
        monitor.check([.claude])
        try await settle()
        precondition(monitor.status(.claude)?.state == .ready && tracker.limitedUntil(.claudeCode) == nil)
        precondition(monitor.alerts.map(\.title) == ["Claude Code is signed out", "Claude Code is back"], "\(monitor.alerts)")

        // A failed run with a sign-in error checks again right away; other failures don't.
        let before = fake.count(.copilot)
        monitor.runFailed(.copilot, message: "TypeError: fetch failed")
        try await settle()
        precondition(fake.count(.copilot) == before, "a network error isn't a sign-in problem")
        monitor.runFailed(.copilot, message: "Error: Not logged in. Run copilot login.")
        try await settle()
        precondition(fake.count(.copilot) == before + 1, "an auth error is checked at once")
        monitor.runSucceeded(.copilot)
        precondition(monitor.status(.copilot)?.lastSuccessAt != nil)

        // Out of quota: an account-wide limit, alerted once, with its reset time.
        tracker.markLimited(.copilot, message: "quota", report: UsageLimitReport(code: "quota/quota_exceeded",
                                                                                   resetsAt: Date().addingTimeInterval(7_200)))
        monitor.check([.copilot])
        try await settle()
        precondition(monitor.status(.copilot)?.state == .outOfQuota && monitor.status(.copilot)?.limitedUntil != nil
                     && monitor.status(.copilot)?.unavailable == false)
        precondition(monitor.alerts.last?.title == "Copilot CLI is out of quota")

        // What clients get: no tokens, every row, the sign-in plan.
        let payload = monitor.remotePayload()
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)
        precondition(!text.lowercased().contains("token\":") && text.contains("\"checkInterval\":1800"), text)
        let decoded = try JSONDecoder().decode([BackendStatus].self,
                                               from: JSONSerialization.data(withJSONObject: payload["backends"] as Any))
        precondition(decoded.count == 4 && decoded.first { $0.id == "claude" }?.signIn.mode == "terminal"
                     && decoded.first { $0.id == "codex" }?.signIn.command == "codex login --device-auth")
        let lines = BackendStatusText.lines(decoded.first { $0.id == "claude" }!).map(\.text)
        precondition(lines.contains { $0.hasPrefix("Installed: /stub/claude · 9.9.9") }
                     && lines.contains { $0.hasPrefix("Account: person@example.com · Claude account") }
                     && lines.contains { $0.hasPrefix("Last sign-in error: Failed to authenticate") }, "\(lines)")
    }

    /// Copilot's device sign-in: its link and code reach every client; Cancel stops it.
    @MainActor
    private static func testBackendStatusSignIn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("backend-signin-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copilot = folder.appendingPathComponent("copilot").path
        try """
        #!/bin/sh
        [ "$1 $2" = "login --device-code" ] || exit 2
        echo "To authenticate, visit https://github.com/login/device and enter code QRST-4321."
        /bin/sleep 30 &
        echo $! > '\(folder.path)/child.pid'
        wait
        """.write(toFile: copilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copilot)
        let fake = FakeProber()
        fake.answer(.copilot, BackendProbe(installed: true, path: copilot, signedIn: false))
        let monitor = BackendStatusMonitor(store: folder.appendingPathComponent("status.json"), prober: fake.prober,
                                           tracker: BackendLimitTracker())
        let savedDelay = BackendStatusMonitor.confirmDelay
        BackendStatusMonitor.confirmDelay = 0.05
        defer { BackendStatusMonitor.confirmDelay = savedDelay }
        monitor.check([.copilot])
        for _ in 0..<250 where monitor.status(.copilot)?.path != copilot { try await Task.sleep(nanoseconds: 20_000_000) }
        // Sign in runs the checked CLI: only ever the stub here.
        precondition(monitor.status(.copilot)?.path == copilot && monitor.status(.copilot)?.checking == false)
        precondition(monitor.signIn(.copilot).hasPrefix("Starting"))
        for _ in 0..<150 where monitor.status(.copilot)?.signIn.code == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        let pending = monitor.status(.copilot)!.signIn
        precondition(pending.code == "QRST-4321" && pending.url == "https://github.com/login/device" && pending.startedAt != nil,
                     "\(pending)")
        precondition(monitor.signIn(.copilot).contains("already waiting"))
        monitor.cancelSignIn(.copilot)
        let cancelled = monitor.status(.copilot)!.signIn
        precondition(cancelled.code == nil && cancelled.message == "Sign-in cancelled.", "\(cancelled)")
        // Cancel stops what the CLI started too (npm's loader runs the real CLI as a child).
        let child = pid_t(try String(contentsOfFile: folder.appendingPathComponent("child.pid").path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        for _ in 0..<100 where child > 0 && kill(child, 0) == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(child > 0 && kill(child, 0) != 0, "the sign-in's child process is stopped")
        monitor.check([.copilot])
        for _ in 0..<150 where monitor.status(.copilot)?.checking != false { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(monitor.status(.copilot)?.signIn.message == nil, "the next check clears an ended attempt's note")
    }

    /// A signed-out backend is passed over like a used-up one: new messages and Home runs start
    /// on the backup, and the note says why.
    @MainActor
    private static func testBackendStatusRouting() async throws {
        let tracker = BackendLimitTracker()
        tracker.setUnavailable(.claudeCode, reason: "Claude Code isn't signed in on the Mac")
        precondition(BackendFallback.target(for: .copilot, chain: ["Claude Code", "Codex"], homeRun: true, tracker: tracker) == .codex,
                     "backups skip a signed-out backend")
        precondition(BackendFallback.untilLabel(.distantFuture) == "you sign in again")
        tracker.setUnavailable(.claudeCode, reason: nil)
        precondition(BackendFallback.target(for: .copilot, chain: ["Claude Code", "Codex"], homeRun: true, tracker: tracker) == .claudeCode)

        let settings = AppSettings.shared
        let saved = (settings.backend, settings.limitFallbackBackends, settings.memoryEnabled)
        settings.memoryEnabled = false
        settings.backend = .copilot
        settings.limitFallbackBackends = [BackendKind.claudeCode.rawValue]
        BackendLimitTracker.shared.clear()
        defer {
            (settings.backend, settings.limitFallbackBackends, settings.memoryEnabled) = saved
            BackendLimitTracker.shared.setUnavailable(.copilot, reason: nil)
            BackendLimitTracker.shared.clear()
        }
        BackendLimitTracker.shared.setUnavailable(.copilot, reason: "Copilot CLI isn't signed in on the Mac")
        let copilot = StatusFakeBackend()
        let claude = StatusFakeBackend()
        let chat = ChatSession(copilotBackend: copilot, backendOverrides: [.claudeCode: claude])
        chat.submitRemote("check the build", mode: .queue)
        try await waitForJournalTest { claude.requests.count == 1 }
        precondition(copilot.requests.isEmpty, "the signed-out backend isn't tried")
        precondition(chat.deliveryStatus?.contains("isn't signed in on the Mac") == true, "\(chat.deliveryStatus ?? "")")
        claude.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }

        BackendLimitTracker.shared.setUnavailable(.copilot, reason: nil)
        chat.submitRemote("and the tests", mode: .queue)
        try await waitForJournalTest { copilot.requests.count == 1 }
        copilot.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
    }
}
