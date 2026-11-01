import Foundation

private final class FakeOneShotRunner: OneShotRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [OneShotTarget] = []
    private var prompts: [OneShotPrompt] = []
    var behavior: @Sendable (OneShotTarget) async throws -> OneShotResult

    init(_ behavior: @escaping @Sendable (OneShotTarget) async throws -> OneShotResult) {
        self.behavior = behavior
    }

    var calls: [OneShotTarget] { lock.withLock { recorded } }
    var lastPrompt: OneShotPrompt? { lock.withLock { prompts.last } }

    func run(_ prompt: OneShotPrompt, on target: OneShotTarget, timeout: TimeInterval) async throws -> OneShotResult {
        lock.withLock {
            recorded.append(target)
            prompts.append(prompt)
        }
        return try await behavior(target)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

extension SessionTabTests {
    /// Cantrip's OpenAI-compatible endpoint: requests become stateless, tool-free calls that go
    /// through the Mac's backend and its usage-limit backup chain, and are counted per consumer.
    @MainActor
    static func testOpenAIEndpoint() async throws {
        try testOpenAIEndpointRequests()
        try testOneShotParsers()
        testEndpointLedger()
        try await testOpenAIEndpointRouting()
        try await testOpenAIEndpointTiers()
        try await testOpenAIEndpointHTTP()
        print("OpenAI endpoint: requests, model names, backup chain, limits, parsers, per-consumer usage and HTTP passed")
    }

    private static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

    // MARK: - Requests and model names

    private static func testOpenAIEndpointRequests() throws {
        precondition(OpenAIEndpointModel.parse(nil) == .auto)
        precondition(OpenAIEndpointModel.parse("auto") == .auto)
        precondition(OpenAIEndpointModel.parse("my-old-shim") == .auto, "an older server's model name keeps working")
        precondition(OpenAIEndpointModel.parse("gpt-4o") == .auto, "a name that isn't a backend uses the chain")
        precondition(OpenAIEndpointModel.parse("copilot") == .backend(.copilot, model: ""))
        precondition(OpenAIEndpointModel.parse("claude:sonnet") == .backend(.claudeCode, model: "sonnet"))
        precondition(OpenAIEndpointModel.parse("antigravity:gemini-3.8-flash-medium") == .backend(.antigravity, model: "gemini-3.8-flash-medium"))
        precondition(OpenAIEndpointModel.name(.claudeCode, model: "claude-opus-5-5") == "claude:claude-opus-5-5")

        // A lone user message goes as it is; with a system message every turn is labelled.
        let simple = try OpenAIEndpointRequest.parse(json(["messages": [["role": "user", "content": "Classify this."]]]))
        precondition(simple.model == .auto && !simple.stream && simple.prompt.conversationText == "Classify this.")
        precondition(simple.prompt.combinedText == "Classify this.")
        let classify = try OpenAIEndpointRequest.parse(json([
            "model": "my-old-shim", "temperature": 0, "stream": false, "max_tokens": 900, "reasoning_effort": "High",
            "messages": [["role": "system", "content": "You classify events."], ["role": "user", "content": "Item 1"]],
        ]))
        precondition(classify.prompt.system == "You classify events." && classify.prompt.maxTokens == 900)
        precondition(classify.effort == "high")
        precondition(classify.prompt.combinedText == "[system]\nYou classify events.\n\n[user]\nItem 1")
        let conversation = try OpenAIEndpointRequest.parse(json(["messages": [
            ["role": "user", "content": "Hi"], ["role": "assistant", "content": "Hello"], ["role": "user", "content": "Again"],
        ]]))
        precondition(conversation.prompt.conversationText == "[user]\nHi\n\n[assistant]\nHello\n\n[user]\nAgain")

        // Vision: text plus a base64 image in one user message.
        let vision = try OpenAIEndpointRequest.parse(json(["max_tokens": 12000, "messages": [
            ["role": "system", "content": "Extract rows."],
            ["role": "user", "content": [
                ["type": "text", "text": "Read job-1."],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString(), "detail": "high"]],
            ]],
        ]]))
        precondition(vision.prompt.images.count == 1 && vision.prompt.images[0].mediaType == "image/png")
        precondition(vision.prompt.conversationText == "Read job-1.")

        func rejects(_ body: [String: Any], _ fragment: String) {
            do {
                _ = try OpenAIEndpointRequest.parse(json(body))
                preconditionFailure("expected a rejection containing \(fragment)")
            } catch let invalid as OpenAIEndpointRequest.Invalid {
                precondition(invalid.message.contains(fragment), invalid.message)
            } catch { preconditionFailure("\(error)") }
        }
        rejects(["messages": []], "messages")
        rejects(["messages": [["role": "system", "content": "only system"]]], "user message")
        rejects(["messages": [["role": "user", "content": "x"]], "tools": [["type": "function"]]], "tool-free")
        rejects(["messages": [["role": "tool", "content": "x"]]], "tool-free")
        rejects(["messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": "https://example.com/a.png"]]]]]],
                "base64 data URLs")
        rejects(["messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]]]]],
                "PNG, JPEG")
        rejects(["messages": [["role": "user", "content": "x"]], "n": 2], "n = 1")

        precondition(OpenAIEndpoint.split(path: "/consumer/Nightly Ingest/v1/chat/completions", headers: [:])
            == ("nightly-ingest", "/v1/chat/completions"))
        precondition(OpenAIEndpoint.split(path: "/v1/models/", headers: ["x-cantrip-consumer": "reader-app"]) == ("reader-app", "/v1/models"))
        precondition(OpenAIEndpoint.split(path: "/v1/chat/completions", headers: [:]).consumer == "unlabeled")

        // Loopback callers need no key (OpenAI clients send a placeholder); proxied requests do.
        precondition(OpenAIEndpoint.authorize(["authorization": "Bearer sk-placeholder"], key: nil) == nil)
        precondition(OpenAIEndpoint.authorize(["authorization": "Bearer sk-placeholder"], key: "secret") == nil)
        precondition(OpenAIEndpoint.authorize(["x-forwarded-for": "100.64.0.2"], key: nil)?.status == 403)
        precondition(OpenAIEndpoint.authorize(["tailscale-user-login": "someone@example.com"], key: "secret")?.status == 401)
        precondition(OpenAIEndpoint.authorize(["tailscale-user-login": "someone@example.com", "authorization": "Bearer secret"],
                                              key: "secret") == nil)
        precondition(OpenAIEndpoint.authorize(["forwarded": "for=1.2.3.4", "authorization": "Bearer secreT"], key: "secret")?.status == 401)
    }

    // MARK: - CLI output, from real runs

    private static func testOneShotParsers() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-31T19:41:49Z")!
        let copilot = OneShotTarget(backend: .copilot, model: "gpt-5.6-sol", effort: "low")

        let arguments = OneShotCompletion.copilotArguments(
            OneShotPrompt(system: "Be brief.", turns: [.init(role: "user", text: "Hi")]), target: copilot, attachments: ["/tmp/x/image-1.png"])
        precondition(arguments.contains(MessageRouter.copilotNoTools) && !arguments.contains("--allow-all-tools"))
        precondition(arguments.contains("--disable-builtin-mcps") && arguments.contains("--sync-session=off"))
        precondition(arguments[arguments.firstIndex(of: "--attachment")! + 1] == "/tmp/x/image-1.png")
        precondition(arguments[arguments.firstIndex(of: "--reasoning-effort")! + 1] == "low")
        precondition(arguments[1] == "[system]\nBe brief.\n\n[user]\nHi")

        // copilot 1.0.105 `-p --output-format json`, trimmed.
        let answered = Data("""
        {"type":"session.tools_updated","data":{"model":"gpt-5.6-sol"},"ephemeral":true}
        {"type":"assistant.turn_start","data":{"turnId":"0"}}
        {"type":"assistant.message_delta","data":{"messageId":"m1","deltaContent":"pong"},"ephemeral":true}
        {"type":"assistant.message","data":{"messageId":"m1","model":"gpt-5.6-sol","content":"pong","toolRequests":[]}}
        {"type":"session.usage_checkpoint","data":{"totalNanoAiu":5320000000,"totalPremiumRequests":1}}
        {"type":"result","sessionId":"s","exitCode":0,"usage":{"premiumRequests":1,"totalApiDurationMs":1883}}
        """.utf8)
        let result = try OneShotCompletion.copilotResult(answered, status: 0, errorText: "", target: copilot, now: now)
        precondition(result.text == "pong" && result.model == "gpt-5.6-sol" && result.premiumRequests == 1)

        // A real monthly-quota error: limited until the 1st, from its errorType, not its words.
        let quota = Data("""
        {"type":"session.error","data":{"errorType":"quota","message":"You have exceeded your monthly quota (Request ID: X)","statusCode":402,"errorCode":"quota_exceeded"}}
        """.utf8)
        do {
            _ = try OneShotCompletion.copilotResult(quota, status: 1, errorText: "", target: copilot, now: now)
            preconditionFailure("a quota error is a usage limit")
        } catch OneShotError.usageLimit(let report, _) {
            precondition(report.code == "quota/quota_exceeded")
            precondition(report.resetsAt == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        }
        do {
            _ = try OneShotCompletion.copilotResult(Data(), status: 1,
                                                    errorText: "Error: Model \"x\" from --model flag is not available.",
                                                    target: copilot, now: now)
            preconditionFailure("a bad model fails")
        } catch OneShotError.failed(let message) { precondition(message.contains("not available")) }
        let tooled = Data(#"{"type":"tool.execution_start","data":{"toolCallId":"t","toolName":"bash"}}"# .utf8)
            + Data("\n".utf8) + answered
        do {
            _ = try OneShotCompletion.copilotResult(tooled, status: 0, errorText: "", target: copilot, now: now)
            preconditionFailure("a tool call fails the request")
        } catch OneShotError.failed {}

        let claude = OneShotTarget(backend: .claudeCode, model: "opus", effort: "high")
        let claudeArguments = OneShotCompletion.claudeArguments(OneShotPrompt(system: "", turns: [.init(role: "user", text: "x")]),
                                                                target: claude)
        precondition(claudeArguments[claudeArguments.firstIndex(of: "--tools")! + 1] == "")
        precondition(claudeArguments.contains("--strict-mcp-config") && claudeArguments.contains("--no-session-persistence"))
        precondition(claudeArguments[claudeArguments.firstIndex(of: "--system-prompt")! + 1] == OneShotCompletion.defaultSystemPrompt)
        precondition(claudeArguments[claudeArguments.firstIndex(of: "--effort")! + 1] == "high")
        let input = try OneShotCompletion.claudeInput(OneShotPrompt(system: "", turns: [.init(role: "user", text: "Colour?")],
                                                                    images: [OneShotPrompt.Image(data: png)!]))
        let message = (try JSONSerialization.jsonObject(with: input) as? [String: Any])?["message"] as? [String: Any]
        let blocks = message?["content"] as? [[String: Any]] ?? []
        precondition(blocks.count == 2 && blocks[0]["text"] as? String == "Colour?")
        precondition((blocks[1]["source"] as? [String: Any])?["media_type"] as? String == "image/png")

        // claude 2.1.312 stream-json, trimmed.
        let tracker = UsageTracker(quotaLoader: { _ in }, claudeLoader: nil, antigravityLoader: { nil }, codexLoader: { nil })
        let claudeAnswer = Data("""
        {"type":"system","subtype":"init","model":"claude-haiku-5-5","tools":[],"mcp_servers":[]}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Red"}]},"parent_tool_use_id":null}
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1793498400,"rateLimitType":"five_hour","utilization":0.91}}
        {"type":"result","subtype":"success","is_error":false,"result":"Red","total_cost_usd":0.000122,"usage":{"input_tokens":2,"cache_creation_input_tokens":599,"cache_read_input_tokens":0,"output_tokens":4},"modelUsage":{"claude-haiku-5-5":{"contextWindow":1000000}}}
        """.utf8)
        let claudeResult = try OneShotCompletion.claudeResult(claudeAnswer, status: 0, errorText: "", target: claude, tracker: tracker)
        precondition(claudeResult.text == "Red" && claudeResult.model == "claude-haiku-5-5")
        precondition(claudeResult.inputTokens == 601 && claudeResult.outputTokens == 4 && claudeResult.costUSD == 0.000122)
        let rejected = Data("""
        {"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1793498400,"rateLimitType":"five_hour"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"You've hit your limit · resets 3pm"}]},"error":"rate_limit","parent_tool_use_id":null}
        {"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit · resets 3pm"}
        """.utf8)
        do {
            _ = try OneShotCompletion.claudeResult(rejected, status: 1, errorText: "", target: claude, tracker: tracker)
            preconditionFailure("a rejected window is a usage limit")
        } catch OneShotError.usageLimit(let report, let text) {
            precondition(report.code == "rate_limit/five_hour" && report.resetsAt == Date(timeIntervalSince1970: 1793498400))
            precondition(text.contains("hit your limit"))
        }
        do {
            _ = try OneShotCompletion.claudeResult(Data(#"{"type":"result","is_error":true,"result":"Overloaded"}"#.utf8),
                                                   status: 1, errorText: "", target: claude, tracker: tracker)
            preconditionFailure("an ordinary error isn't a limit")
        } catch OneShotError.failed(let message) { precondition(message.contains("Overloaded")) }

        let agy = OneShotTarget(backend: .antigravity, model: "gemini-3.8-flash-medium")
        let agyArguments = OneShotCompletion.antigravityArguments(OneShotPrompt(system: "", turns: [.init(role: "user", text: "x")]),
                                                                  target: agy, timeout: 120)
        precondition(agyArguments.contains("json") && agyArguments.contains("120s") && agyArguments.contains("--disable-slash-commands"))
        let agyAnswer = Data(#"{"conversation_id":"c","status":"SUCCESS","response":"pong\n","usage":{"input_tokens":6798,"output_tokens":27,"cache_read_tokens":0}}"#.utf8)
        let agyResult = try OneShotCompletion.antigravityResult(agyAnswer, status: 0, errorText: "", target: agy)
        precondition(agyResult.text == "pong" && agyResult.inputTokens == 6798)
        do {
            _ = try OneShotCompletion.antigravityResult(Data(#"{"status":"ERROR","error":"boom"}"#.utf8), status: 1, errorText: "", target: agy)
            preconditionFailure("agy errors fail")
        } catch OneShotError.failed(let message) { precondition(message.contains("boom")) }

        do {
            _ = try OneShotCompletion.localResult(json(["error": ["message": "Quota", "code": "insufficient_quota"]]), status: 429, model: "m")
            preconditionFailure("insufficient_quota is a limit")
        } catch OneShotError.usageLimit(let report, _) { precondition(report.code == "insufficient_quota") }
        let local = try OneShotCompletion.localResult(json([
            "model": "hermes", "choices": [["message": ["role": "assistant", "content": "ok"]]],
            "usage": ["prompt_tokens": 3, "completion_tokens": 1],
        ]), status: 200, model: "m")
        precondition(local.text == "ok" && local.model == "hermes" && local.inputTokens == 3)

        precondition(OneShotCompletion.unsupportedReason(.codex) != nil && OneShotCompletion.unsupportedReason(.copilotRemote) != nil)
        precondition(OneShotCompletion.unsupportedReason(.claudeCode) == nil)
    }

    // MARK: - Accounting

    private static func testEndpointLedger() {
        let suite = "cantrip-endpoint-ledger-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = EndpointUsageLedger(defaults: defaults, tracker: nil)
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        ledger.record(consumer: "ingest-worker", backend: .copilot, outcome: .answered,
                      result: OneShotResult(text: "x", model: "gpt-5.6-sol", premiumRequests: 1), at: now)
        ledger.record(consumer: "ingest-worker", backend: .claudeCode, outcome: .answered,
                      result: OneShotResult(text: "x", model: "opus", inputTokens: 1_000, outputTokens: 200, costUSD: 0.02), at: yesterday)
        ledger.record(consumer: "ingest-worker", backend: nil, outcome: .limited, result: nil, at: now)
        ledger.record(consumer: "reader-app", backend: .copilot, outcome: .answered,
                      result: OneShotResult(text: "x", model: "gpt-5.6-sol", premiumRequests: 0.33), at: now)
        let consumers = ledger.consumers(now: now)
        precondition(consumers.map(\.name) == ["ingest-worker", "reader-app"], "\(consumers.map(\.name))")
        let ingest = consumers[0]
        precondition(ingest.today.calls == 1 && ingest.today.limited == 1 && ingest.week.calls == 2)
        precondition(ingest.week.backends == ["Copilot": 1, "Claude Code": 1] && ingest.week.premiumRequests == 1)
        precondition(ingest.week.detail.contains("1 premium request") && ingest.week.detail.contains("1.2k tokens"))
        precondition(ingest.week.detail.contains("1 at usage limits"))
        let snapshot = ledger.snapshot(enabled: true, listening: 11439, now: now)
        let decoded = try! JSONDecoder().decode(EndpointUsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        precondition(decoded == snapshot && decoded.listening && decoded.port == 11439)
        precondition(ledger.totals(days: 1, now: now)["reader-app"]?.premiumRequests == 0.33)
    }

    // MARK: - Model tiers

    /// `deep` runs the chain at the deep tier and `copilot:deep` one backend's deep models: a model
    /// at its own limit moves to the tier's next, a whole-backend limit skips the backend.
    @MainActor
    private static func testOpenAIEndpointTiers() async throws {
        precondition(OpenAIEndpointModel.parse("deep") == .tier(.deep) && OpenAIEndpointModel.parse(" Fast ") == .tier(.fast))
        precondition(OpenAIEndpointModel.parse("copilot:Deep") == .backend(.copilot, model: "deep"))
        let settings = AppSettings.shared
        let saved = (settings.dotfileValues, settings.copilotModelCatalog, settings.claudeModelCatalog, settings.agyAvailableModels)
        defer {
            settings.applySettings(saved.0)
            settings.copilotModelCatalog = saved.1
            settings.claudeModelCatalog = saved.2
            settings.agyAvailableModels = saved.3
        }
        let efforts = ["low", "medium", "high", "xhigh", "max"]
        settings.copilotModelCatalog = ["claude-opus-5.5", "gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-sol", "claude-haiku-5.5"]
            .map { CopilotModelInfo(id: $0, reasoningEfforts: efforts) }
        settings.claudeModelCatalog = ["opus", "sonnet", "haiku"].map { CopilotModelInfo(id: $0, reasoningEfforts: efforts) }
        settings.agyAvailableModels = AppSettings.agyDefaultModels
        settings.applySettings(["backend": "Copilot", "openAIEndpointModel": "", "openAIEndpointEffort": "",
                                "limitFallbackEntries": [["backend": "Claude Code", "model": "", "effort": ""],
                                                         ["backend": "Antigravity", "model": "gemini-3.8-flash-medium", "effort": ""]]])
        settings.modelTiers = ModelTierMap()
        let tracker = BackendLimitTracker()
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        func request(_ model: String) throws -> OpenAIEndpointRequest {
            try OpenAIEndpointRequest.parse(json(["model": model, "messages": [["role": "user", "content": "Hi"]]]))
        }
        let deep = OpenAIEndpointPlanner.plan(try request("deep"), settings: settings, tracker: tracker, now: clock)
        precondition(deep.targets.prefix(4).map { "\($0.backend.rawValue)/\($0.model)/\($0.effort)" } == [
            "Copilot/claude-opus-5.5/xhigh", "Copilot/gpt-6.1-sol/xhigh", "Copilot/gpt-6-astra/xhigh", "Claude Code/opus/xhigh",
        ] && deep.targets.count == 5 && deep.targets[4].model == "gemini-3.8-flash-medium",
                     "the chain at deep keeps a backup's exact model: \(deep.targets)")
        precondition(deep.targets.prefix(4).allSatisfy { $0.tier == .deep } && deep.targets[4].tier == nil)
        let fast = OpenAIEndpointPlanner.plan(try request("antigravity:fast"), settings: settings, tracker: tracker, now: clock)
        precondition(fast.targets.map(\.model) == ["gemini-3.8-flash-medium", "gemini-3.8-flash-low"])

        // Argon's group used up: Antigravity's deep starts on Opus.
        tracker.markLimited(.antigravity, model: "gemini-4-argon-high", message: "Argon",
                            report: UsageLimitReport(code: "usage/argon", resetsAt: clock.addingTimeInterval(600), scope: "argon"), now: clock)
        let agyDeep = OpenAIEndpointPlanner.plan(try request("antigravity:deep"), settings: settings, tracker: tracker, now: clock)
        precondition(agyDeep.targets.map(\.model) == ["claude-opus-5-5-high"] && agyDeep.skipped.count == 1)

        // Copilot's shared quota: its first deep model's limit skips its others, and Claude's deep answers.
        let runner = FakeOneShotRunner { target in
            if target.backend == .copilot {
                throw OneShotError.usageLimit(UsageLimitReport(code: "quota/quota_exceeded", resetsAt: clock.addingTimeInterval(3_600)), "quota")
            }
            return OneShotResult(text: "From \(target.backend.rawValue)", model: target.model)
        }
        let suite = "cantrip-endpoint-tiers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = OpenAIEndpointService(runner: { _ in runner }, tracker: tracker,
                                            ledger: EndpointUsageLedger(defaults: defaults, tracker: nil), now: { clock })
        guard case .answered(_, let target, let fellBack) = await service.complete(try request("deep"), consumer: "tiers",
                                                                                  settings: settings) else {
            preconditionFailure("Claude's deep answers")
        }
        precondition(target == OneShotTarget(backend: .claudeCode, model: "opus", effort: "xhigh", tier: .deep) && fellBack == [.copilot])
        precondition(runner.calls.map(\.backend) == [.copilot, .claudeCode], "\(runner.calls)")
        guard case .failed(429, "usage_limit", _, _) = await service.complete(try request("copilot:deep"), consumer: "tiers",
                                                                             settings: settings) else {
            preconditionFailure("a limited pinned backend at a tier is a 429")
        }
        let models = service.models(settings: settings).compactMap { $0["id"] as? String }
        precondition(["fast", "standard", "deep", "copilot:deep", "claude:fast", "antigravity:standard"].allSatisfy(models.contains), "\(models)")
    }

    // MARK: - Routing through the backup chain

    @MainActor
    private static func testOpenAIEndpointRouting() async throws {
        let settings = AppSettings.shared
        let saved = settings.dotfileValues
        defer { settings.applySettings(saved) }
        settings.applySettings([
            "backend": BackendKind.copilot.rawValue, "limitFallbackBackends": ["Claude Code", "Codex", "Antigravity"],
            "openAIEndpointModel": "copilot:gpt-5.6-sol", "openAIEndpointEffort": "xhigh",
            "openAIEndpointContextTier": "long_context", "claudeModel": "opus", "claudeEffort": "high",
        ])
        precondition(settings.applySettings(["openAIEndpointModel": "nonsense:x"]).isEmpty, "only backend names are accepted")
        let suite = "cantrip-endpoint-routing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = EndpointUsageLedger(defaults: defaults, tracker: nil)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let tracker = BackendLimitTracker()

        let request = try OpenAIEndpointRequest.parse(json(["model": "my-old-shim", "messages": [["role": "user", "content": "Hi"]]]))
        let plan = OpenAIEndpointPlanner.plan(request, settings: settings, tracker: tracker, now: clock)
        precondition(plan.targets.map(\.backend) == [.copilot, .claudeCode, .antigravity], "\(plan.targets)")
        precondition(plan.targets[0] == OneShotTarget(backend: .copilot, model: "gpt-5.6-sol", effort: "xhigh", contextTier: "long_context"))
        precondition(plan.targets[1].model == "opus" && plan.targets[1].effort == "high")
        precondition(plan.skipped.map(\.backend) == [.codex], "Codex has no tool-free mode")

        // A forced limit on the primary: its structured error marks it limited (for tabs too) and
        // the backup answers; the next request goes straight to the backup.
        let monthEnd = ISO8601DateFormatter().date(from: "2027-02-01T00:00:00Z")!
        let runner = FakeOneShotRunner { target in
            switch target.backend {
            case .copilot:
                throw OneShotError.usageLimit(UsageLimitReport(code: "quota/quota_exceeded", resetsAt: monthEnd),
                                              "You have exceeded your monthly quota")
            case .claudeCode:
                return OneShotResult(text: "From Claude", model: "claude-opus-5-5", inputTokens: 10, outputTokens: 2, costUSD: 0.01)
            default:
                return OneShotResult(text: "From \(target.backend.rawValue)", model: target.model)
            }
        }
        let service = OpenAIEndpointService(runner: { _ in runner }, tracker: tracker, ledger: ledger, now: { clock })
        guard case .answered(let result, let target, let fellBack) = await service.complete(request, consumer: "admin-worker",
                                                                                          settings: settings) else {
            preconditionFailure("the backup answers")
        }
        precondition(result.text == "From Claude" && target.backend == .claudeCode && fellBack == [.copilot])
        precondition(tracker.limitedUntil(.copilot, now: clock) == monthEnd)
        precondition(runner.calls.map(\.backend) == [.copilot, .claudeCode])
        _ = await service.complete(request, consumer: "admin-worker", settings: settings)
        precondition(runner.calls.map(\.backend) == [.copilot, .claudeCode, .claudeCode], "a limited primary isn't tried again")
        precondition(ledger.totals(days: 1, now: clock)["admin-worker"]?.backends == ["Claude Code": 2])

        // A named backend runs only there, as picked: limited means 429 with when to retry.
        let pinned = try OpenAIEndpointRequest.parse(json(["model": "copilot", "messages": [["role": "user", "content": "Hi"]]]))
        guard case .failed(429, "usage_limit", _, let retry) = await service.complete(pinned, consumer: "x", settings: settings) else {
            preconditionFailure("a limited pinned backend is a 429")
        }
        precondition(retry == monthEnd)
        let pinnedModel = try OpenAIEndpointRequest.parse(json(["model": "claude:sonnet", "reasoning_effort": "low",
                                                                "messages": [["role": "user", "content": "Hi"]]]))
        _ = await service.complete(pinnedModel, consumer: "x", settings: settings)
        precondition(runner.calls.last == OneShotTarget(backend: .claudeCode, model: "sonnet", effort: "low"))

        // Claude fails for another reason: Antigravity answers next.
        runner.behavior = { target in
            if target.backend == .claudeCode { throw OneShotError.failed("Claude: Overloaded") }
            if target.backend == .copilot { preconditionFailure("still limited") }
            return OneShotResult(text: "From agy", model: target.model)
        }
        guard case .answered(_, let agyTarget, let agyFallback) = await service.complete(request, consumer: "reader-app", settings: settings) else {
            preconditionFailure("agy answers")
        }
        precondition(agyTarget.backend == .antigravity && agyFallback == [.claudeCode])
        precondition(tracker.limitedUntil(.claudeCode, now: clock) == nil, "an ordinary failure isn't a limit")

        // Every backend limited: 429 at the soonest reset, and nothing runs.
        tracker.markLimited(.claudeCode, message: "limit", report: UsageLimitReport(code: "rate_limit/five_hour",
                                                                                   resetsAt: clock.addingTimeInterval(3_600)), now: clock)
        tracker.markLimited(.antigravity, message: "limit", report: UsageLimitReport(code: "usage/weekly",
                                                                                    resetsAt: clock.addingTimeInterval(7_200)), now: clock)
        let before = runner.calls.count
        guard case .failed(429, _, _, let soonest) = await service.complete(request, consumer: "reader-app", settings: settings) else {
            preconditionFailure("all limited is a 429")
        }
        precondition(soonest == clock.addingTimeInterval(3_600) && runner.calls.count == before)
        precondition(ledger.totals(days: 1, now: clock)["reader-app"]?.limited == 1)
        let health = service.health(settings: settings)
        precondition(health["status"] as? String == "limited" && health["copilot_limited_until"] is String)

        // The limits lift: the primary is tried first again.
        clock = monthEnd.addingTimeInterval(1)
        runner.behavior = { target in OneShotResult(text: "ok", model: target.model) }
        guard case .answered(_, let back, _) = await service.complete(request, consumer: "reader-app", settings: settings) else {
            preconditionFailure("the primary answers again")
        }
        precondition(back.backend == .copilot)

        // Antigravity can't read an image without its file tools: the call moves on instead of failing.
        let vision = OneShotPrompt(system: "", turns: [.init(role: "user", text: "Colour?")], images: [OneShotPrompt.Image(data: png)!])
        do {
            _ = try await OneShotCompletion(configuration: OneShotConfiguration()).run(vision, on: OneShotTarget(backend: .antigravity), timeout: 1)
            preconditionFailure("agy takes no images")
        } catch OneShotError.unavailable {}
        do {
            _ = try await OneShotCompletion(configuration: OneShotConfiguration()).run(vision, on: OneShotTarget(backend: .codex), timeout: 1)
            preconditionFailure("Codex has no tool-free mode")
        } catch OneShotError.unavailable(let reason) { precondition(reason.contains("shell")) }

        let models = service.models(settings: settings).compactMap { $0["id"] as? String }
        precondition(models.first == "auto" && models.contains("copilot") && models.contains("claude") && !models.contains("codex"))
    }

    // MARK: - HTTP

    @MainActor
    private static func testOpenAIEndpointHTTP() async throws {
        let settings = AppSettings.shared
        let saved = settings.dotfileValues
        defer { settings.applySettings(saved) }
        settings.applySettings(["backend": BackendKind.claudeCode.rawValue, "limitFallbackBackends": [String](),
                                "claudeModel": "opus", "openAIEndpointModel": ""])
        let suite = "cantrip-endpoint-http-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = EndpointUsageLedger(defaults: defaults, tracker: nil)
        let cancelled = Flag()
        let runner = FakeOneShotRunner { target in
            OneShotResult(text: "Answer from \(target.backend.rawValue)", model: "claude-opus-5-5", inputTokens: 7, outputTokens: 3)
        }
        let endpoint = OpenAIEndpoint()
        endpoint.service = OpenAIEndpointService(runner: { _ in runner }, tracker: BackendLimitTracker(), ledger: ledger)
        var port = 0
        for _ in 0..<5 {
            let candidate = Int.random(in: 41_000...48_000)
            let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                var resumed = false
                endpoint.onStatus = { listening, error in
                    guard !resumed, listening != nil || error != nil else { return }
                    resumed = true
                    continuation.resume(returning: listening == candidate)
                }
                endpoint.start(port: candidate, key: "secret-key")
            }
            if ready { port = candidate; break }
            endpoint.stop()
        }
        precondition(port != 0, "the endpoint listens on loopback")
        defer { endpoint.stop() }

        let session = URLSession(configuration: .ephemeral)
        func call(_ path: String, body: [String: Any]? = nil, headers: [String: String] = [:],
                  timeout: TimeInterval = 10) async throws -> (Int, Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: timeout)
            if let body {
                request.httpMethod = "POST"
                request.httpBody = json(body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await session.data(for: request)
            let http = response as! HTTPURLResponse
            return (http.statusCode, data, http)
        }
        let chat: [String: Any] = ["model": "auto", "messages": [["role": "user", "content": "Hi"]]]
        let (status, data, response) = try await call("/consumer/test-app/v1/chat/completions", body: chat,
                                                      headers: ["Authorization": "Bearer sk-placeholder"])
        precondition(status == 200, String(decoding: data, as: UTF8.self))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(object["object"] as? String == "chat.completion" && object["model"] as? String == "claude:claude-opus-5-5")
        let choice = (object["choices"] as! [[String: Any]])[0]
        precondition((choice["message"] as? [String: Any])?["content"] as? String == "Answer from Claude Code")
        precondition(choice["finish_reason"] as? String == "stop")
        precondition((object["usage"] as? [String: Any])?["total_tokens"] as? Int == 10)
        precondition(response.value(forHTTPHeaderField: "X-Cantrip-Backend") == "Claude Code")
        precondition(ledger.totals(days: 1)["test-app"]?.calls == 1, "calls are counted per consumer")

        let (modelsStatus, modelsData, _) = try await call("/v1/models")
        precondition(modelsStatus == 200 && String(decoding: modelsData, as: UTF8.self).contains(#""id":"auto""#))
        let (healthStatus, healthData, _) = try await call("/health", headers: ["X-Forwarded-For": "100.64.0.9"])
        precondition(healthStatus == 200 && String(decoding: healthData, as: UTF8.self).contains("cantrip-openai"))

        let (proxied, _, _) = try await call("/v1/chat/completions", body: chat, headers: ["Tailscale-User-Login": "a@example.com"])
        precondition(proxied == 401, "a proxied request needs the key")
        let (keyed, _, _) = try await call("/v1/chat/completions", body: chat,
                                           headers: ["Tailscale-User-Login": "a@example.com", "Authorization": "Bearer secret-key"])
        precondition(keyed == 200)
        let (bad, badData, _) = try await call("/v1/chat/completions", body: ["messages": [["role": "tool", "content": "x"]]])
        precondition(bad == 400 && String(decoding: badData, as: UTF8.self).contains("invalid_request_error"))
        let (missing, _, _) = try await call("/v1/embeddings", body: ["input": "x"])
        precondition(missing == 404)

        let (streamStatus, streamData, streamResponse) = try await call(
            "/v1/chat/completions", body: chat.merging(["stream": true, "stream_options": ["include_usage": true]]) { _, new in new })
        let stream = String(decoding: streamData, as: UTF8.self)
        precondition(streamStatus == 200 && streamResponse.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
        precondition(stream.contains(#""object":"chat.completion.chunk""#) && stream.contains("Answer from Claude Code"))
        precondition(stream.contains(#""finish_reason":"stop""#) && stream.contains(#""total_tokens":10"#)
                     && stream.hasSuffix("data: [DONE]\n\n"))

        // A caller that gives up stops its model call.
        runner.behavior = { _ in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { cancelled.set(); throw OneShotError.cancelled }
            return OneShotResult(text: "late", model: "m")
        }
        _ = try? await call("/v1/chat/completions", body: chat, timeout: 1)
        for _ in 0..<50 where !cancelled.isSet { try await Task.sleep(nanoseconds: 100_000_000) }
        precondition(cancelled.isSet, "closing the connection cancels the call")
    }

    /// `CANTRIP_OPENAI_LIVE_TEST=1`: one tiny call through each real CLI, tool-free (spends a little quota).
    static func testOpenAIEndpointLive() async throws {
        let configuration = await OneShotConfiguration.current()
        let runner = OneShotCompletion(configuration: configuration)
        let image = try OpenAIEndpointRequest.parse(json(["messages": [["role": "user", "content": [
            ["type": "text", "text": "What single colour fills this image? Answer with one word."],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64," + redSquare().base64EncodedString()]],
        ]]]]))
        let text = try OpenAIEndpointRequest.parse(json(["messages": [
            ["role": "system", "content": "Answer with exactly one word."],
            ["role": "user", "content": "Reply with the word pong."],
        ]]))
        let targets = [
            (OneShotTarget(backend: .copilot, model: "gpt-5.6-sol", effort: "low"), image),
            (OneShotTarget(backend: .claudeCode, model: "haiku"), image),
            (OneShotTarget(backend: .antigravity, model: "gemini-3.8-flash-medium"), text),
        ]
        for (target, request) in targets {
            let started = Date()
            let result = try await runner.run(request.prompt, on: target, timeout: 180)
            print("live \(target.label): \"\(result.text.prefix(40))\" model=\(result.model) in=\(result.inputTokens) "
                + "premium=\(result.premiumRequests.map { String($0) } ?? "-") \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            precondition(!result.text.isEmpty)
            if request.prompt.images.isEmpty == false { precondition(result.text.lowercased().contains("red"), result.text) }
        }
        do {
            _ = try await runner.run(image.prompt, on: OneShotTarget(backend: .antigravity), timeout: 30)
            preconditionFailure("agy can't take images tool-free")
        } catch OneShotError.unavailable {}
        try await testOpenAIEndpointLiveFallback(configuration: configuration, request: text)
        print("OpenAI endpoint live checks passed")
    }

    /// A forced limit on the primary: a stand-in `copilot` prints Copilot's real quota event, and the
    /// call moves to the real Claude Code CLI next in the chain.
    @MainActor
    private static func testOpenAIEndpointLiveFallback(configuration: OneShotConfiguration,
                                                       request: OpenAIEndpointRequest) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-live-quota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = folder.appendingPathComponent("copilot")
        try """
        #!/bin/sh
        echo '{"type":"session.error","data":{"errorType":"quota","message":"You have exceeded your monthly quota","statusCode":402,"errorCode":"quota_exceeded"}}'
        exit 1
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let settings = AppSettings.shared
        let saved = settings.dotfileValues
        defer { settings.applySettings(saved) }
        settings.applySettings(["backend": BackendKind.copilot.rawValue, "limitFallbackBackends": ["Claude Code"],
                                "claudeModel": "haiku", "claudeEffort": "", "openAIEndpointModel": ""])
        let forced = { var value = configuration; value.copilotPath = fake.path; return value }()
        let suite = "cantrip-live-ledger-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = BackendLimitTracker()
        let service = OpenAIEndpointService(runner: { _ in OneShotCompletion(configuration: forced) }, tracker: tracker,
                                            ledger: EndpointUsageLedger(defaults: defaults, tracker: nil))
        guard case .answered(let result, let target, let fellBack) = await service.complete(request, consumer: "live-check",
                                                                                          settings: settings) else {
            preconditionFailure("Claude answers when Copilot is at its limit")
        }
        precondition(target.backend == .claudeCode && fellBack == [.copilot] && !result.text.isEmpty)
        precondition(tracker.limitedUntil(.copilot) == UsageLimit.startOfNextMonthUTC(after: Date()))
        print("live fallback: Copilot quota -> \(target.label) answered \"\(result.text.prefix(20))\"; Copilot limited until "
            + ISODate.string(from: tracker.limitedUntil(.copilot)!))
    }

    private static func redSquare() -> Data {
        var crcTable = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            crcTable[n] = c
        }
        func crc(_ bytes: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFFFFFF
            for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            return c ^ 0xFFFFFFFF
        }
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            let body = Array(type.utf8) + data
            return be(UInt32(data.count)) + body + be(crc(body))
        }
        let size = 32
        var raw: [UInt8] = []
        for _ in 0..<size { raw.append(0); for _ in 0..<size { raw += [255, 0, 0] } }
        // Stored (uncompressed) deflate blocks inside a zlib stream.
        var deflate: [UInt8] = [0x78, 0x01]
        var offset = 0
        while offset < raw.count {
            let block = Array(raw[offset..<min(offset + 65_535, raw.count)])
            offset += block.count
            let length = UInt16(block.count)
            deflate += [offset >= raw.count ? 1 : 0, UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)]
            deflate += block
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        deflate += be(b << 16 | a)
        let header = be(UInt32(size)) + be(UInt32(size)) + [8, 2, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", header) + chunk("IDAT", deflate) + chunk("IEND", []))
    }
}
