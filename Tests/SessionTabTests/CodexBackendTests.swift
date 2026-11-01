import Foundation

extension SessionTabTests {
    /// Codex through `codex app-server`: the shapes Codex 0.166.0 sends (model list, rate limits,
    /// items, approvals, errors), and a fake app server that replays them, so permissions, Home's
    /// checks, usage limits, resume, steering and Stop are tested without an account.
    @MainActor
    static func testCodexBackend() async throws {
        testCodexModelList()
        try await testCodexUsageLimits()
        testCodexItems()
        try await testCodexAppServerTurns()
        print("Codex: models, limits, items, approvals, Home checks, resume, steering and Stop passed")
    }

    static func testCodexModelList() {
        func efforts(_ names: [String]) -> [[String: Any]] { names.map { ["reasoningEffort": $0, "description": "…"] } }
        let models = CodexModelFetcher.parse(["data": [
            ["id": "gpt-6-luna", "model": "gpt-6-luna", "displayName": "GPT-6-Luna", "hidden": false, "isDefault": true,
             "supportedReasoningEfforts": efforts(["low", "medium", "high", "xhigh", "max"]), "defaultReasoningEffort": "medium"],
            ["id": "gpt-5.6-terra", "model": "gpt-5.6-terra", "displayName": "GPT-5.6-Terra", "hidden": false, "isDefault": false,
             "supportedReasoningEfforts": efforts(["low", "medium", "high", "xhigh", "max", "ultra"]), "defaultReasoningEffort": "medium"],
            ["id": "internal", "model": "internal", "displayName": "Hidden", "hidden": true, "supportedReasoningEfforts": []],
        ], "nextCursor": NSNull()])
        precondition(models.map(\.id) == ["gpt-6-luna", "gpt-5.6-terra"]
                     && models[0].isDefault && !models[1].isDefault
                     && models[0].efforts == ["low", "medium", "high", "xhigh", "max"]
                     && models[1].efforts.last == "ultra" && models[0].defaultEffort == "medium"
                     && models[0].displayName == "GPT-6-Luna",
                     "model/list gives IDs, names, efforts and the default, without hidden models: \(models)")

        let settings = AppSettings.shared
        let saved = (settings.codexAvailableModels, settings.backend)
        defer { (settings.codexAvailableModels, settings.backend) = saved }
        settings.codexAvailableModels = models
        settings.backend = .codex
        let catalog = settings.tabModelCatalog(for: .codex)
        precondition(catalog.models.map(\.id) == ["gpt-6-luna", "gpt-5.6-terra"]
                     && catalog.info("gpt-5.6-terra")?.reasoningEfforts?.contains("ultra") == true,
                     "Per-tab settings and Remote offer Codex's models with their efforts")
        precondition(settings.codexModelLabel("gpt-6-luna") == "GPT-6-Luna" && settings.codexModelLabel("other") == "other")
        precondition(CantripHomeTaskModels.offered(settings) == ["gpt-6-luna", "gpt-5.6-terra"], "Home tasks pick Codex models")
        var metadata = SessionTabMetadata()
        metadata.setModelSettings(SessionModelSelection(model: "gpt-5.6-terra", effort: "ultra", contextTier: ""), for: .codex)
        precondition(metadata.modelSettings(for: .codex)?.effort == "ultra" && metadata.modelSettings(for: .copilot) == nil,
                     "Codex's per-tab model is kept apart from Copilot's")
    }

    @MainActor
    static func testCodexUsageLimits() async throws {
        // `account/rateLimits/read` on a free plan: one 30-day window, nulls for what isn't there.
        let free = try requireHome(CodexUsage.parse([
            "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 0, "windowDurationMins": 43200, "resetsAt": 1796079750],
                           "secondary": NSNull(), "planType": "free"],
            "rateLimitsByLimitId": ["codex": ["limitId": "codex", "limitName": NSNull(),
                                              "primary": ["usedPercent": 0, "windowDurationMins": 43200, "resetsAt": 1796079750],
                                              "secondary": NSNull(), "planType": "free"]],
        ]))
        precondition(free.plan == "free" && free.windows.map(\.id) == ["codex/primary"]
                     && free.windows[0].title == "Monthly limit" && free.windows[0].resetsAt == "2026-11-30T23:02:30Z",
                     "The free plan's 30-day window: \(free)")
        // A paid plan: 5-hour and weekly windows, plus a model's own limit.
        let paid = try requireHome(CodexUsage.parse(["rateLimitsByLimitId": [
            "codex": ["limitId": "codex", "planType": "plus",
                      "primary": ["usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1793491200],
                      "secondary": ["usedPercent": 41.5, "windowDurationMins": 10080, "resetsAt": 1793836800]],
            "codex_terra": ["limitId": "codex_terra", "limitName": "GPT-5.6-Terra",
                            "primary": ["usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1793491200]],
        ]]))
        precondition(paid.windows.map(\.title) == ["5-hour limit", "Weekly limit", "GPT-5.6-Terra 5-hour limit"]
                     && paid.primary?.id == "codex/primary" && paid.windows[0].isExhausted && !paid.windows[1].isExhausted,
                     "Every limit's windows, the main one unnamed: \(paid.windows)")
        precondition(CodexUsage.limitedUntil(["primary": ["usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1793491200]])
                     == Date(timeIntervalSince1970: 1793491200)
                     && CodexUsage.limitedUntil(["primary": ["usedPercent": 99, "resetsAt": 1793491200]]) == nil,
                     "A full window says when it lifts")
        precondition(CodexUsage.parse(["ordinaryUsageAllowed": true]) == nil, "No windows is no answer")

        // Structured errors: only the usage and rate limits move a run to the fallback.
        let full: [String: Any] = ["primary": ["usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1793491200]]
        precondition(CodexBackend.usageLimit(from: ["message": "You've hit your usage limit.", "codexErrorInfo": "usageLimitExceeded"],
                                             rateLimits: full)
                     == UsageLimitReport(code: "codex/usageLimitExceeded", resetsAt: Date(timeIntervalSince1970: 1793491200))
                     && CodexBackend.usageLimit(from: ["codexErrorInfo": "rateLimitExceeded"], rateLimits: nil)?.resetsAt == nil
                     && CodexBackend.usageLimit(from: ["message": "The 'x' model is not supported", "codexErrorInfo": "modelNotFound"],
                                                rateLimits: full) == nil
                     && CodexBackend.usageLimit(from: ["message": "usage limit"], rateLimits: full) == nil,
                     "Codex's error codes, not its wording, decide")

        // The usage screen reads the limits with each refresh; a full window marks Codex limited.
        let now = Date(timeIntervalSince1970: 1793480000)
        var completion: ((Result<CodexAccountUsage, Error>) -> Void)?
        let tracker = UsageTracker(quotaLoader: { $0(.failure(CopilotQuotaError.timeout)) }, claudeLoader: nil,
                                   antigravityLoader: { nil }, codexLoader: { { completion = $0 } }, quotaClock: { now })
        BackendLimitTracker.shared.clear()
        defer { BackendLimitTracker.shared.clear() }
        tracker.refreshQuotas()
        precondition(completion != nil, "One refresh reads Codex too")
        completion?(.success(free))
        try await Task.sleep(for: .milliseconds(20))
        precondition(tracker.copilotUsage.codex?.account == free && tracker.copilotUsage.codex?.isStale(at: now) == false
                     && BackendLimitTracker.shared.limitedUntil(.codex, now: now) == nil)
        tracker.applyCodex(.success(paid))
        precondition(BackendLimitTracker.shared.limitedUntil(.codex, now: now) == Date(timeIntervalSince1970: 1793491200),
                     "A full window sends Codex's messages to the fallback until it resets")
        // A tab's update carries only the main limit; the model's own window stays.
        tracker.applyCodex(.success(CodexAccountUsage(plan: nil, windows: [paid.windows[1]])), merging: true)
        precondition(tracker.copilotUsage.codex?.account?.windows.count == 3 && tracker.copilotUsage.codex?.account?.plan == "plus")
        tracker.applyCodex(.failure(CodexUsageError.response))
        precondition(tracker.copilotUsage.codex?.error != nil && tracker.copilotUsage.codex?.account != nil,
                     "A failed read keeps the last limits, marked with the error")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tracker.copilotUsage)) as? [String: Any]
        let windows = ((encoded?["codex"] as? [String: Any])?["account"] as? [String: Any])?["windows"] as? [[String: Any]]
        precondition(windows?.contains { $0["id"] as? String == "codex/primary" && $0["usedPercent"] as? Double == 100
                         && $0["windowMinutes"] as? Int == 300 } == true,
                     "Remote clients get Codex's windows under `codex`: \(String(describing: windows))")
    }

    static func testCodexItems() {
        precondition(CodexBackend.displayCommand("/bin/zsh -lc 'cat existing.txt && echo probe > made-by-shell.txt'")
                     == "cat existing.txt && echo probe > made-by-shell.txt"
                     && CodexBackend.displayCommand("/bin/zsh -lc 'echo '\\''hi'\\'''") == "echo 'hi'"
                     && CodexBackend.displayCommand(#"/bin/zsh -lc "printf 'hi' > made.txt""#) == "printf 'hi' > made.txt"
                     && CodexBackend.displayCommand(#"/bin/zsh -lc "echo \"a\"""#) == #"echo "a""#
                     && CodexBackend.displayCommand("ls -la") == "ls -la")
        precondition(CodexBackend.isKnownRead("cat README.md") && CodexBackend.isKnownRead("rg -n TODO Sources")
                     && !CodexBackend.isKnownRead("cat a > b") && !CodexBackend.isKnownRead("sed -i '' s/a/b/ f")
                     && !CodexBackend.isKnownRead("find . -delete") && !CodexBackend.isKnownRead("node build.js"),
                     "Only plain reads may run unchecked under Home")
        precondition(CodexBackend.quotedTool(in: "Allow the echo MCP server to run tool \"shout\"?") == "shout"
                     && CodexBackend.quotedTool(in: "Allow it?") == nil)

        let command = CodexBackend.activity(for: [
            "type": "commandExecution", "id": "exec-1", "command": "/bin/zsh -lc 'cat existing.txt'",
            "status": "completed", "aggregatedOutput": "hello\n", "exitCode": 0,
        ], running: false)
        precondition(command?.state == .succeeded && command?.output == "hello\n" && command?.id == "exec-1"
                     && command?.title == "cat existing.txt", "A command step is named by its command")
        let edit = CodexBackend.activity(for: [
            "type": "fileChange", "id": "exec-2", "status": "declined",
            "changes": [["path": "/tmp/codex-probe/made-by-patch.txt", "kind": ["type": "add"], "diff": "hi\n"]],
        ], running: false)
        precondition(edit?.state == .failed && edit?.title == "Edit made-by-patch.txt" && edit?.fileChanges.count == 1
                     && edit?.output?.contains("Declined") == true, "A declined edit shows as failed, with its diff")
        let tool = CodexBackend.activity(for: [
            "type": "mcpToolCall", "id": "exec-3", "server": "echo", "tool": "shout", "status": "failed",
            "arguments": ["text": "hi"], "result": NSNull(), "error": ["message": "user rejected MCP tool call"],
        ], running: false)
        precondition(tool?.state == .failed && tool?.title == "echo: shout" && tool?.output == "user rejected MCP tool call")
        let agent = CodexBackend.activity(for: ["type": "collabAgentToolCall", "id": "agent-1", "prompt": "Survey the tests",
                                                "model": "gpt-6-luna"], running: true)
        precondition(agent?.subagent?.status == .running && agent?.subagent?.canCancel == false
                     && agent?.subagent?.model == "gpt-6-luna", "Codex's subagents show, without a Stop they can't honor")
        precondition(CodexBackend.activity(for: ["type": "reasoning", "id": "r"], running: true) == nil
                     && CodexBackend.activity(for: ["type": "agentMessage", "id": "m"], running: false) == nil)
    }

    // MARK: - Fake app server

    /// Answers the handshake, threads and turns like Codex 0.166.0 and logs every message it gets.
    /// The prompt picks the turn: `ask` (a command and an MCP tool, both asking), `limit`, `slow`
    /// (runs until interrupted), `home` (a blocked command, then one that ran unasked) and `read`.
    static let fakeCodexServer = #"""
    #!/usr/bin/env python3
    import json, os, sys
    log = open(os.environ["FAKE_CODEX_LOG"], "a")
    interrupted = [False]
    current = ["turn-0"]
    late = []
    def send(message):
        sys.stdout.write(json.dumps(message) + "\n"); sys.stdout.flush()
    def read():
        line = sys.stdin.readline()
        if not line: sys.exit(0)
        message = json.loads(line); log.write(line); log.flush()
        return message
    def note(params):
        send({"method": params[0], "params": params[1]})
    def item(kind, state, body):
        note(("item/" + state, {"threadId": "thread-1", "turnId": current[0], "item": dict(body, type=kind)}))
    def ask(request_id, method, params):
        send({"id": request_id, "method": method, "params": dict(params, threadId="thread-1", turnId=current[0])})
        while True:
            message = read()
            if message.get("id") == request_id and "method" not in message: return message.get("result", {})
            handle(message)
    def wait_for_interrupt():
        while not interrupted[0]: handle(read())
    def done(status="completed", error=None, turn_id=None):
        note(("turn/completed", {"threadId": "thread-1", "turn": {"id": turn_id or current[0], "status": status, "error": error}}))
    def turn(text):
        interrupted[0] = False
        if text.startswith("ask"):
            shell = "/bin/zsh -lc 'touch made.txt'"
            item("commandExecution", "started", {"id": "exec-1", "command": shell, "status": "inProgress"})
            answer = ask(100, "item/commandExecution/requestApproval", {"itemId": "exec-1", "command": shell, "cwd": "/tmp"})
            ran = answer.get("decision") == "accept"
            item("commandExecution", "completed", {"id": "exec-1", "command": shell, "status": "completed" if ran else "declined",
                                                   "aggregatedOutput": "", "exitCode": 0 if ran else None})
            answer = ask(101, "mcpServer/elicitation/request", {
                "serverName": "echo", "mode": "form", "requestedSchema": {"type": "object", "properties": {}},
                "_meta": {"codex_approval_kind": "mcp_tool_call", "tool_params": {"text": "hi"}},
                "message": "Allow the echo MCP server to run tool \"shout\"?"})
            used = answer.get("action") == "accept"
            item("mcpToolCall", "completed", {"id": "mcp-1", "server": "echo", "tool": "shout", "arguments": {"text": "hi"},
                                              "status": "completed" if used else "failed",
                                              "result": {"content": [{"type": "text", "text": "HI"}]} if used else None,
                                              "error": None if used else {"message": "user rejected MCP tool call"}})
            note(("item/agentMessage/delta", {"itemId": "msg-1", "delta": "Done."}))
            item("agentMessage", "completed", {"id": "msg-1", "text": "Done."})
            note(("thread/tokenUsage/updated", {"tokenUsage": {"last": {"inputTokens": 100, "cachedInputTokens": 40,
                                                                        "outputTokens": 20}, "modelContextWindow": 258400}}))
            done()
        elif text.startswith("limit"):
            note(("account/rateLimits/updated", {"rateLimits": {"limitId": "codex", "planType": "plus",
                "primary": {"usedPercent": 100, "windowDurationMins": 300, "resetsAt": 4102444800},
                "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 4102531200}}}))
            error = {"message": "You've hit your usage limit.", "codexErrorInfo": "usageLimitExceeded"}
            note(("error", {"error": error, "willRetry": False}))
            done("failed", error)
        elif text.startswith("slow"):
            item("commandExecution", "started", {"id": "exec-9", "command": "sleep 30", "status": "inProgress"})
            wait_for_interrupt()
        elif text.startswith("home"):
            blocked = "/bin/zsh -lc 'sudo rm -rf /var/db/x'"
            answer = ask(200, "item/commandExecution/requestApproval", {"itemId": "exec-h1", "command": blocked, "cwd": "/tmp"})
            item("commandExecution", "completed", {"id": "exec-h1", "command": blocked,
                                                   "status": "declined" if answer.get("decision") != "accept" else "completed"})
            item("commandExecution", "completed", {"id": "exec-h2", "command": "/bin/zsh -lc 'node build.js'",
                                                   "status": "completed", "aggregatedOutput": "built"})
            wait_for_interrupt()
        else:
            ask(300, "item/commandExecution/requestApproval", {"itemId": "exec-r", "command": "/bin/zsh -lc 'cat README.md'"})
            item("commandExecution", "completed", {"id": "exec-r", "command": "/bin/zsh -lc 'cat README.md'",
                                                   "status": "completed", "aggregatedOutput": "readme"})
            note(("item/agentMessage/delta", {"itemId": "msg-2", "delta": "Read it."}))
            done()
    def handle(message):
        method, request_id = message.get("method"), message.get("id")
        if method == "initialize": send({"id": request_id, "result": {"userAgent": "fake/0.166.0"}})
        elif method == "thread/start": send({"id": request_id, "result": {"thread": {"id": "thread-1"}}})
        elif method == "thread/resume": send({"id": request_id, "result": {"thread": {"id": message["params"]["threadId"]}}})
        elif method == "turn/steer": send({"id": request_id, "result": {"turnId": current[0]}})
        elif method == "turn/interrupt":
            # Like Codex, the stopped turn's completion can come after the next turn starts.
            send({"id": request_id, "result": {}}); interrupted[0] = True; late.append(message["params"]["turnId"])
        elif method == "turn/start":
            current[0] = "turn-%d" % (int(current[0].split("-")[1]) + 1)
            send({"id": request_id, "result": {"turn": {"id": current[0], "status": "inProgress"}}})
            while late: done("interrupted", turn_id=late.pop())
            turn(message["params"]["input"][0]["text"])
    while True: handle(read())
    """#

    struct CodexTurn {
        var text = "", failure: String?, prompts: [String] = [], approvals: [BackendApproval] = []
        var activities: [String: ToolActivity] = [:], limits: [UsageLimitReport] = [], usage: BackendUsage?
        var finished = false
    }

    @MainActor
    static func testCodexAppServerTurns() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codex-fake-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let script = root.appendingPathComponent("codex")
        try fakeCodexServer.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let logURL = root.appendingPathComponent("received.jsonl")
        let workdir = root.appendingPathComponent("work").path
        try fm.createDirectory(atPath: workdir, withIntermediateDirectories: true)

        let settings = AppSettings.shared
        let saved = (settings.allowActions, settings.codexPermissionMode, settings.codexModel, settings.codexEffort)
        defer {
            (settings.allowActions, settings.codexPermissionMode, settings.codexModel, settings.codexEffort) = saved
            BackendLimitTracker.shared.clear()
        }
        settings.allowActions = false
        settings.codexPermissionMode = "default"
        settings.codexModel = ""
        settings.codexEffort = ""

        func received() -> [[String: Any]] {
            ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
        func sent(_ method: String) -> [[String: Any]] {
            received().filter { $0["method"] as? String == method }.map { $0["params"] as? [String: Any] ?? [:] }
        }
        func answers() -> [Int: [String: Any]] {
            Dictionary(received().compactMap { message -> (Int, [String: Any])? in
                guard message["method"] == nil, let id = message["id"] as? Int, let result = message["result"] as? [String: Any] else {
                    return nil
                }
                return (id, result)
            }, uniquingKeysWith: { $1 })
        }
        func backend(_ key: String, readOnly: Bool = false) -> CodexBackend {
            let backend = CodexBackend(persistKey: key, readOnly: readOnly)
            backend.makeServer = { arguments, environment, workdir in
                var environment = environment
                environment["FAKE_CODEX_LOG"] = logURL.path
                return CodexAppServer(executable: script.path, arguments: arguments, environment: environment,
                                      directory: URL(fileURLWithPath: workdir))
            }
            return backend
        }
        func turn(_ backend: CodexBackend, _ prompt: String, answers decisions: [InputRequestAnswer.Decision] = [],
                  wait: Bool = true, collect: CodexTurnBox) async throws {
            var remaining = decisions
            backend.send(BackendRequest(prompt: prompt, userMessage: prompt, previousTurns: []), workdir: workdir) { event in
                DispatchQueue.main.async {
                    switch event {
                    case .textDelta(let delta): collect.value.text += delta
                    case .failure(let message): collect.value.failure = message; collect.value.finished = true
                    case .done: collect.value.finished = true
                    case .activity(let activity): collect.value.activities[activity.id] = activity
                    case .approval(let approval): collect.value.approvals.append(approval)
                    case .usageLimit(let report): collect.value.limits.append(report)
                    case .usage(let usage): collect.value.usage = usage
                    case .inputRequired(let request):
                        collect.value.prompts.append(request.snapshot.title)
                        let decision = remaining.isEmpty ? .deny : remaining.removeFirst()
                        try? request.respond(InputRequestAnswer(decision: decision))
                    default: break
                    }
                }
            }
            if wait { try await waitForJournalTest { collect.value.finished } }
        }
        let key = "test-codex-\(UUID().uuidString)"
        defer {
            for suffix in ["", ".folder", ".seenTurns"] { UserDefaults.standard.removeObject(forKey: key + suffix) }
        }

        // Ask mode: each command and MCP tool asks the user; the answers go back to Codex.
        let tab = backend(key)
        let ask = CodexTurnBox()
        try await turn(tab, "ask first", answers: [.approve, .deny], collect: ask)
        let start = try requireHome(sent("thread/start").first)
        precondition(start["sandbox"] as? String == "workspace-write" && start["approvalPolicy"] as? String == "untrusted"
                     && start["cwd"] as? String == workdir
                     && (start["developerInstructions"] as? String)?.contains(ReplyVisibility.guidance) == true,
                     "A tab runs in the workspace sandbox and asks before acting: \(start)")
        precondition(ask.value.prompts == ["Allow Codex to run touch made.txt?", "Allow Codex to use echo (shout)?"]
                     && answers()[100]?["decision"] as? String == "accept" && answers()[101]?["action"] as? String == "decline",
                     "The command was allowed and the MCP tool declined, as answered: \(ask.value.prompts) \(answers())")
        precondition(ask.value.text == "Done." && ask.value.failure == nil
                     && ask.value.activities["exec-1"]?.state == .succeeded && ask.value.activities["mcp-1"]?.state == .failed
                     && ask.value.usage?.inputTokens == 100 && ask.value.usage?.cachedInputTokens == 40,
                     "Streams the reply once, the steps and the token use: \(ask.value.text) \(ask.value.activities.keys)")

        // A usage limit: reported once, with the full window's reset, and the turn fails.
        let limit = CodexTurnBox()
        try await turn(tab, "limit", collect: limit)
        precondition(limit.value.limits == [UsageLimitReport(code: "codex/usageLimitExceeded",
                                                              resetsAt: Date(timeIntervalSince1970: 4102444800))]
                     && limit.value.failure == "You've hit your usage limit.",
                     "A Codex limit goes to the fallback with its reset time: \(limit.value.limits)")
        try await waitForJournalTest { BackendLimitTracker.shared.limitedUntil(.codex) != nil }
        precondition(UsageTracker.shared.copilotUsage.codex?.account?.plan == "plus", "The tab's update reaches the usage screen")
        BackendLimitTracker.shared.clear()
        precondition(sent("thread/start").count == 1 && sent("turn/start").count == 2, "One thread, one server for the tab")

        // Steering and Stop: a message during the turn steers it; Stop interrupts it in-band.
        let slow = CodexTurnBox()
        try await turn(tab, "slow", wait: false, collect: slow)
        try await waitForJournalTest { slow.value.activities["exec-9"] != nil }
        var steered: MidTurnDelivery?
        tab.injectMidTurn("also check the tests") { delivery in steered = delivery }
        try await waitForJournalTest { steered != nil }
        if case .accepted = steered {} else { preconditionFailure("Steering is accepted: \(String(describing: steered))") }
        let steer = try requireHome(sent("turn/steer").first)
        precondition(steer["expectedTurnId"] as? String == "turn-3"
                     && ((steer["input"] as? [[String: Any]])?.first?["text"] as? String) == "also check the tests")
        precondition(tab.interruptTurn(), "Stop interrupts the running turn")
        try await waitForJournalTest { slow.value.activities["exec-9"]?.state == .cancelled }
        try await waitForJournalTest { !sent("turn/interrupt").isEmpty }
        precondition(!tab.interruptTurn(), "Nothing is left to interrupt")
        let afterStop = CodexTurnBox()
        try await turn(tab, "read after stop", collect: afterStop)
        precondition(afterStop.value.text == "Read it." && afterStop.value.failure == nil,
                     "The stopped turn's late completion doesn't end the next turn: \(afterStop.value)")
        precondition(slow.value.activities["exec-9"]?.state == .cancelled && slow.value.failure == nil,
                     "The open step ends as stopped and the turn ends quietly")

        // A new backend for the same tab (Cantrip restarted) resumes the saved thread.
        tab.cancel()
        let restarted = backend(key)
        let resumed = CodexTurnBox()
        try await turn(restarted, "read", collect: resumed)
        let resume = try requireHome(sent("thread/resume").first)
        precondition(resume["threadId"] as? String == "thread-1" && resume["excludeTurns"] as? Bool == true
                     && sent("thread/start").count == 1 && resumed.value.text == "Read it.",
                     "The saved thread resumes instead of starting over: \(resume)")
        precondition(resumed.value.prompts.isEmpty && answers()[300]?["decision"] as? String == "accept",
                     "Codex asks even for `cat`; Cantrip allows plain reads without a prompt")
        restarted.reset()
        precondition(UserDefaults.standard.string(forKey: key) == nil, "Start fresh forgets the thread")

        // Council seats: Codex's read-only sandbox even with Act on my behalf, and nothing but reads.
        settings.allowActions = true
        let seatKey = key + "-seat"
        defer { UserDefaults.standard.removeObject(forKey: seatKey); UserDefaults.standard.removeObject(forKey: seatKey + ".folder") }
        let seat = backend(seatKey, readOnly: true)
        precondition(seat.access == .readOnly && CodexBackend.threadPolicy(seat.access) == ("read-only", "untrusted"))
        let seatTurn = CodexTurnBox()
        try await turn(seat, "ask seat", collect: seatTurn)
        precondition(sent("thread/start").last?["sandbox"] as? String == "read-only" && seatTurn.value.prompts.isEmpty
                     && answers()[100]?["decision"] as? String == "decline" && answers()[101]?["action"] as? String == "decline",
                     "A read-only seat never bypasses the sandbox and declines every action")
        seat.reset()

        // Full access only with Act on my behalf or the explicit setting.
        let open = CodexBackend(persistKey: key + "-open")
        precondition(open.access == .full && CodexBackend.threadPolicy(open.access) == ("danger-full-access", "never"))
        settings.allowActions = false
        precondition(open.access == .ask)
        settings.codexPermissionMode = "bypassPermissions"
        precondition(open.access == .full, "Full access is the explicit setting")
        settings.codexPermissionMode = "default"

        // Cantrip Home: the action policy answers; a command that ran unasked stops the run.
        let homeKey = key + "-home"
        defer { for suffix in ["", ".folder", ".seenTurns"] { UserDefaults.standard.removeObject(forKey: homeKey + suffix) } }
        let home = backend(homeKey)
        home.guardrail = .unattended
        let blocked = CodexTurnBox()
        try await turn(home, "home", collect: blocked)
        precondition(answers()[200]?["decision"] as? String == "decline" && blocked.value.prompts.isEmpty
                     && blocked.value.approvals.contains { $0.decision == "denied" && $0.decidedBy == "Cantrip Home policy" },
                     "Home's policy blocks sudo without asking anyone")
        precondition(blocked.value.failure?.contains("Codex ran a command Cantrip didn't check (node build.js)") == true,
                     "A command that skipped the check stops the run: \(String(describing: blocked.value.failure))")
        let reads = CodexTurnBox()
        try await turn(home, "read", collect: reads)
        precondition(reads.value.failure == nil && reads.value.text == "Read it.", "Plain reads Codex runs on its own are fine")
        home.reset()

        // A child tab waits for its turn at shared resources before the policy sees the command.
        let childKey = key + "-child"
        defer { for suffix in ["", ".folder", ".seenTurns"] { UserDefaults.standard.removeObject(forKey: childKey + suffix) } }
        let child = backend(childKey)
        child.guardrail = .attended
        var checked: [String] = []
        child.childPolicy = { request, decide, status in
            checked.append(request.command)
            status("Waiting for the Simulator")
            decide(.deny("The parent tab holds the Simulator."))
        }
        let waited = CodexTurnBox()
        try await turn(child, "ask child", collect: waited)
        precondition(checked == ["touch made.txt"] && answers()[100]?["decision"] as? String == "decline"
                     && waited.value.approvals.contains { $0.decidedBy == "Child tab rules" },
                     "The child tab's resource rules decline the command: \(checked)")
        child.reset()
    }

    @MainActor
    final class CodexTurnBox {
        var value = CodexTurn()
    }
}
