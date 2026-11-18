import Foundation

extension SessionTabTests {
    /// Private Local's read-only tools (PrivateLocalTools): the filter, the catalog through a real
    /// MCP relay with stub servers, on-demand tools, refusals, the context budget, settings and
    /// the transcript. Synthetic data only.
    @MainActor
    static func testPrivateLocalTools() async throws {
        // The read-only rule: no write word, not marked as changing anything, and a read word or a
        // server that declares every tool read-only.
        func tool(_ name: String, _ readOnly: Bool? = nil, destructive: Bool? = nil) -> [String: Any] {
            var annotations: [String: Any] = [:]
            if let readOnly { annotations["readOnlyHint"] = readOnly }
            if let destructive { annotations["destructiveHint"] = destructive }
            return ["name": name, "description": "Synthetic \(name)", "annotations": annotations,
                    "inputSchema": ["type": "object", "properties": [String: Any]()]]
        }
        let mixed = PrivateLocalTools.split(server: "service", tools: [
            tool("search_issues", true), tool("get_issue"), tool("list-projects", true), tool("issue_details"),
            tool("create_issue", true), tool("update_issue"), tool("execute_sql", true), tool("send_message"),
            tool("get_report", false), tool("find_events", nil, destructive: true), tool("calendar_events", true),
            tool("API-post-search", true), tool("renderChart", true), tool("bad name!"),
        ])
        precondition(mixed.allowed.map(\.name) == ["search_issues", "get_issue", "list-projects", "issue_details"],
                     "Only tools whose name reads, and that aren't marked as writing: \(mixed.allowed.map(\.name))")
        precondition(mixed.excluded == ["create_issue", "update_issue", "execute_sql", "send_message", "get_report",
                                        "find_events", "calendar_events", "API-post-search", "renderChart", "bad name!"],
                     "Everything else is left out: \(mixed.excluded)")
        let declared = PrivateLocalTools.split(server: "notes", tools: [tool("calendar_events", true), tool("chats", true)])
        precondition(declared.allowed.count == 2 && declared.excluded.isEmpty,
                     "A server that declares every tool read-only may name tools as nouns")
        let undeclared = PrivateLocalTools.split(server: "notes", tools: [tool("calendar_events", true), tool("chats")])
        precondition(undeclared.allowed.isEmpty, "Without that declaration, nouns are unclear and left out")
        for name in ["bitwarden", "agent_chrome", "forms", "xcode", "rea", "my-password-store", "browser-use", "Shell"] {
            precondition(PrivateLocalTools.isBlocked(server: name), name)
        }
        precondition(!PrivateLocalTools.isBlocked(server: "notes") && !PrivateLocalTools.isBlocked(server: "area"))

        // Settings: off by default, kept when older clients save, and checked.
        let configuration = PrivateLocalConfiguration()
        precondition(configuration.tools == PrivateLocalToolSettings(), "Tools start off")
        let legacy = try JSONDecoder().decode(PrivateLocalConfiguration.self, from: Data(
            #"{"baseURL":"https://llm.example.com/v1","model":"m","contextWindow":4096,"systemPrompt":"","api":"openai"}"#.utf8))
        precondition(!legacy.tools.enabled && legacy.tools.servers == nil, "Saved settings without tools keep them off")
        let saved = PrivateLocalToolSettings(enabled: true, servers: ["notes"])
        let fields: [String: Any] = ["baseURL": "https://llm.example.com/v1", "model": "m", "contextWindow": 4096,
                                     "systemPrompt": "", "api": "openai"]
        let kept = try PrivateLocalConfiguration.remote(fields, savedAPI: .openAI, savedTools: saved)
        precondition(kept.tools == saved, "A client that predates tools keeps the saved ones")
        var withTools = fields
        withTools["tools"] = ["enabled": true]
        let chosen = try PrivateLocalConfiguration.remote(withTools, savedAPI: .openAI, savedTools: saved)
        precondition(chosen.tools == PrivateLocalToolSettings(enabled: true, servers: nil), "A client can choose every server")
        for bad: Any in [["enabled": "yes"], ["enabled": true, "servers": "notes"], ["enabled": true, "extra": 1], 1] {
            var invalid = fields
            invalid["tools"] = bad
            do { _ = try PrivateLocalConfiguration.remote(invalid, savedAPI: .openAI); preconditionFailure("Invalid tools \(bad)") }
            catch let error as SessionModelSettingsError { precondition(error.status == 400) }
        }
        var tooMany = legacy
        tooMany.tools.servers = (0...100).map { "s\($0)" }
        do { try tooMany.validate(); preconditionFailure("At most 100 servers") }
        catch let error as SessionModelSettingsError { precondition(error.status == 400) }

        // Stub MCP servers behind a real relay.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("stub.py")
        try #"""
        import json, sys
        kind = sys.argv[1]
        def tools():
            if kind == "notes":
                return [{"name": n, "description": "Synthetic notes " + n, "annotations": {"readOnlyHint": True},
                         "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}}}
                        for n in ["notes_search", "notes_read", "notes_count"]] + [
                        {"name": "notes_delete", "annotations": {"readOnlyHint": False}, "inputSchema": {"type": "object"}}]
            pad = "Synthetic tracker tool for a demo project. " * 40
            return [{"name": "get_issue_%d" % i if i else "get_issue", "description": pad,
                     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}}} for i in range(20)] + [
                    {"name": "create_issue", "description": "Create", "inputSchema": {"type": "object"}}]
        for line in sys.stdin:
            m = json.loads(line)
            if "id" not in m: continue
            if m["method"] == "initialize": r = {"protocolVersion": "2025-03-26", "capabilities": {}, "serverInfo": {"name": kind}}
            elif m["method"] == "tools/list": r = {"tools": tools()}
            else:
                name = m["params"]["name"]; args = m["params"].get("arguments") or {}
                if name == "notes_read": text = "Example Co note. " + "lorem ipsum " * 4000
                elif name == "notes_search": text = "Found 2 notes about " + str(args.get("query", ""))
                elif name == "get_issue": text = "Issue DEMO-1: sample bug, status open"
                else: text = name + " called"
                r = {"content": [{"type": "text", "text": text}]}
            print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let servers = [
            MCPServer(name: "notes", command: "/usr/bin/python3", args: [script.path, "notes"]),
            MCPServer(name: "tracker", command: "/usr/bin/python3", args: [script.path, "tracker"]),
            MCPServer(name: "bitwarden", command: "/usr/bin/python3", args: [script.path, "notes"]),
            MCPServer(name: "offline", command: "/nonexistent/server"),
        ]
        let socketPath = "/tmp/cantrip-plt-\(getpid()).sock"
        final class Sessions: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func add() { lock.withLock { count += 1 } }
            var value: Int { lock.withLock { count } }
        }
        let sessions = Sessions()
        let relay = MCPRelay(environment: MCPRelay.Environment(server: { name in
            sessions.add()
            return servers.first { $0.name == name }
        }), path: socketPath)
        relay.start()
        defer { relay.stop(); try? FileManager.default.removeItem(atPath: socketPath) }
        try await Task.sleep(for: .milliseconds(300))
        let tools = PrivateLocalTools()
        tools.registry = { servers }
        tools.socketPath = { socketPath }

        // Lookups that arrive together while nothing is cached share one listing: one relay
        // session per server that isn't blocked (notes, tracker, offline), not one per caller.
        async let first = tools.catalog(), second = tools.catalog(), third = tools.catalog(), fourth = tools.catalog()
        let together = await [first, second, third, fourth]
        precondition(sessions.value == 3 && Set(together.map { $0.map(\.name) }).count == 1,
                     "Concurrent lookups share one listing: \(sessions.value) sessions")
        let catalog = await tools.catalog()
        precondition(sessions.value == 3, "A fresh listing is cached")
        let summary = Dictionary(uniqueKeysWithValues: tools.summary(catalog).map { ($0.name, $0) })
        precondition(summary["notes"]?.tools == ["notes_search", "notes_read", "notes_count"]
                     && summary["notes"]?.excluded == ["notes_delete"] && summary["notes"]?.onDemand == false,
                     "A small server is offered up front, without its delete tool: \(String(describing: summary["notes"]))")
        precondition(summary["tracker"]?.tools.count == 20 && summary["tracker"]?.excluded == ["create_issue"]
                     && summary["tracker"]?.onDemand == true, "A large server loads on demand")
        let sized = { (name: String, characters: Int) in
            PrivateLocalTools.Server(name: name, tools: [PrivateLocalTools.Tool(server: name, name: "\(name)_read",
                description: "", schema: ["type": "object", "description": String(repeating: "x", count: characters)])])
        }
        let direct = PrivateLocalTools.directServers([sized("mail", 9_000), sized("home", 7_500), sized("db", 5_000), sized("big", 14_000)])
        precondition(direct == ["mail", "home", "db"],
                     "Mail- and home-sized servers stay direct together; a bigger one loads on demand: \(direct)")
        precondition(summary["bitwarden"]?.blocked == true && summary["bitwarden"]?.tools.isEmpty == true,
                     "Blocked servers are listed but never started")
        precondition(summary["offline"]?.problem != nil && summary["offline"]?.tools.isEmpty == true,
                     "A server that doesn't answer shows why")

        // One reply's tools: the small server's and a search; the rest by name or topic.
        let session = await tools.session(PrivateLocalToolSettings(enabled: true))
        defer { session.close() }
        func offered() -> [String] { session.openAITools().compactMap { ($0["function"] as? [String: Any])?["name"] as? String } }
        precondition(offered() == ["mcp__notes__notes_search", "mcp__notes__notes_read", "mcp__notes__notes_count",
                                   PrivateLocalToolSession.searchName], "Offered: \(offered())")
        // 2026-11-18 02:00 UTC is still the 17th in Los Angeles.
        let instructions = session.instructions(now: Date(timeIntervalSince1970: 1_794_967_200), zone: TimeZone(identifier: "America/Los_Angeles")!)
        precondition(instructions.contains("Servers attached now: notes (3 tools).")
                     && instructions.contains("load on demand with search_tools (by name or topic):\n- tracker: get_issue, get_issue_1")
                     && instructions.contains("can't send, create, change, delete")
                     && instructions.hasSuffix("Today is Tuesday, November 17, 2026 (time zone America/Los_Angeles)."),
                     "The model is told which servers are attached, which tools load on demand, and the local date: \(instructions)")
        let before = await session.call("mcp__tracker__get_issue", arguments: ["id": "DEMO-1"])
        precondition(before.allowed && before.success && before.output.contains("DEMO-1"),
                     "An on-demand tool can be called by its name")
        let search = await session.call(PrivateLocalToolSession.searchName, arguments: ["query": "tracker get_issue"])
        precondition(search.success && search.output.contains("mcp__tracker__get_issue") && offered().contains("mcp__tracker__get_issue"),
                     "A search loads matching tools: \(search.output)")
        for name in ["mcp__tracker__create_issue", "mcp__notes__notes_delete", "run_shell", "mcp__bitwarden__get"] {
            let refused = await session.call(name, arguments: [:])
            precondition(!refused.allowed && !refused.success && refused.output.hasPrefix("Refused:")
                         && refused.output.contains("nothing was sent, created, changed or deleted"), name)
        }
        precondition(session.refused.values.reduce(0, +) == 4 && session.calls["mcp__tracker__get_issue"] == 1)

        // Code mode: one program chains the session's own read-only tools; a write tool isn't in it.
        precondition(!offered().contains(CodeMode.runTool), "Code mode is off by default")
        session.codeMode = true
        session.shapes = CodeModeShapes(file: folder.appendingPathComponent("shapes.json"))
        precondition(offered().contains(CodeMode.runTool), "Code mode offers run_tool_script")
        let program = await session.call(CodeMode.runTool, arguments: ["script": """
            const [found, issue] = await Promise.all([notes.notes_search({ query: "Example Co" }), tracker.get_issue({ id: "DEMO-1" })]);
            let write = "not tried";
            try { await new Promise((ok, no) => __call("tracker", "create_issue", "{}", ok, no)); write = "ran"; } catch (e) { write = "refused"; }
            return { found, issue, write, hasCreate: typeof tracker.create_issue };
            """])
        precondition(program.success && program.output.contains("Found 2 notes about Example Co") && program.output.contains("DEMO-1")
                     && program.output.contains(#""write":"refused""#) && program.output.contains(#""hasCreate":"undefined""#)
                     && program.output.contains("(2 tool calls, 1 refused"),
                     "A program's calls are the session's own read-only calls: \(program.output)")
        precondition(session.programs == 1 && session.programCalls == 2 && session.calls["mcp__notes__notes_search"] == 1)
        session.codeMode = false
        let onlyNotes = await tools.session(PrivateLocalToolSettings(enabled: true, servers: ["notes"]))
        precondition(onlyNotes.servers.map(\.name) == ["notes"]
                     && !onlyNotes.openAITools().contains { ($0["function"] as? [String: Any])?["name"] as? String == PrivateLocalToolSession.searchName },
                     "Only the chosen servers")
        onlyNotes.close()

        // A whole reply on a loopback model: tools run, a write is refused, long output fits.
        let fixture = try PrivateOllamaFixture()
        defer { fixture.stop() }
        var local = PrivateLocalConfiguration()
        local.api = .openAI
        local.baseURL = try await fixture.start() + "/v1"
        local.model = "Fixture-8B-4bit"
        local.contextWindow = 20_000
        local.tools = PrivateLocalToolSettings(enabled: true)
        fixture.mode = "openai"
        func sse(_ deltas: [String], finish: String) -> String {
            deltas.map { #"data: {"choices":[{"index":0,"delta":\#($0),"finish_reason":null}]}"# + "\n\n" }.joined()
                + #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"\#(finish)"}]}"# + "\n\ndata: [DONE]\n"
        }
        func call(_ name: String, _ arguments: String) -> String {
            let args = String(decoding: try! JSONSerialization.data(withJSONObject: arguments, options: .fragmentsAllowed), as: UTF8.self)
            return #"{"tool_calls":[{"index":0,"id":"c\#(UUID().uuidString.prefix(6))","type":"function","function":{"name":"\#(name)","arguments":\#(args)}}]}"#
        }
        let steps = [
            call("mcp__notes__notes_read", #"{"query":"Example Co"}"#),
            call("mcp__notes__notes_read", #"{"query":"Example Co again"}"#),
            call("mcp__notes__notes_read", #"{"query":"Example Co once more"}"#),
            call(PrivateLocalToolSession.searchName, #"{"query":"tracker issue"}"#),
            call("mcp__tracker__get_issue", #"{"id":"DEMO-1"}"#),
            call("mcp__tracker__create_issue", #"{"title":"x"}"#),
        ]
        var bodies: [[String: Any]] = []
        fixture.chatResponder = { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            bodies.append(body)
            let step = ((body["messages"] as? [[String: Any]]) ?? []).filter { $0["role"] as? String == "tool" }.count
            if step < steps.count { return sse([#"{"content":"Checking. "}"#, steps[step]], finish: "tool_calls") }
            return sse([#"{"content":"Example Co has notes; DEMO-1 is open. I can't create issues here."}"#], finish: "stop")
        }
        let backend = PrivateLocalBackend()
        backend.configuration = local
        backend.tools = tools
        var events: [BackendEvent] = []
        var finished = false
        backend.send(BackendRequest(prompt: "What do my notes say about Example Co, and file a bug?", userMessage: "q", previousTurns: []),
                     workdir: NSTemporaryDirectory()) { event in
            DispatchQueue.main.async {
                events.append(event)
                if case .done = event { finished = true }
                if case .failure = event { finished = true }
            }
        }
        try await waitForJournalTest(timeout: 30) { finished }
        if case .failure(let message) = events.last { preconditionFailure("The reply failed: \(message)") }
        let activities = events.compactMap { event -> ToolActivity? in if case .activity(let a) = event { return a }; return nil }
        let completed = activities.filter { $0.state != .running }
        precondition(completed.count == steps.count && completed.filter { $0.state == .failed }.count == 1,
                     "Every tool step shows, and only the write fails: \(completed.map { "\($0.toolName) \($0.state)" })")
        let text = events.compactMap { event -> String? in if case .textDelta(let t) = event { return t }; return nil }.joined()
        precondition(text.hasSuffix("I can't create issues here."), "The answer streams after the tool steps")
        precondition(bodies.count == steps.count + 1, "One request per step: \(bodies.count)")
        let system = ((bodies[0]["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        precondition(system.hasPrefix("You are a helpful private assistant.\n\nTools:") && !system.contains("You have no tools or internet access"),
                     "The old no-tools default prompt is replaced while tools are on")
        let toolMessages = (bodies.last?["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "tool" }
        let contents = toolMessages.compactMap { $0["content"] as? String }
        precondition(contents.contains(OpenAICompatibleBackend.leftOut),
                     "Older long tool output is left out to fit the 20,000-token window")
        precondition(contents.contains { $0.contains("more characters left out") } && contents.allSatisfy { $0.count < 16_200 },
                     "Each tool result is cut to \(PrivateLocalTools.resultCharacters) characters")
        precondition(contents.last?.hasPrefix("Refused:") == true, "The write tool was refused, not run")
        let sizes = bodies.map { HomeLocalProfile.estimate(String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self)) }
        precondition(sizes.allSatisfy { $0 <= local.contextWindow }, "Every request fits the window: \(sizes)")
        let lastTools = (bodies[bodies.count - 1]["tools"] as? [[String: Any]] ?? [])
            .compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        precondition(lastTools.contains("mcp__tracker__get_issue") && !lastTools.contains("mcp__tracker__create_issue"),
                     "Loaded tools stay offered for the rest of the reply; write tools never are")

        // With tools off, a tool call from the model still fails closed.
        var off = local
        off.tools.enabled = false
        let quiet = PrivateLocalBackend()
        quiet.configuration = off
        quiet.tools = tools
        fixture.chatResponder = { _ in sse([call("mcp__notes__notes_search", "{}")], finish: "tool_calls") }
        var failure: String?
        quiet.send(BackendRequest(prompt: "q", userMessage: "q", previousTurns: []), workdir: NSTemporaryDirectory()) { event in
            if case .failure(let message) = event { DispatchQueue.main.async { failure = message } }
        }
        try await waitForJournalTest(timeout: 10) { failure != nil }
        precondition(failure?.contains("Tools are disabled in Private Local") == true, "Tools off: \(failure ?? "")")

        // The step limit: after it, the model must answer without tools.
        var calls = 0
        fixture.chatResponder = { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            guard body["tools"] != nil else { return sse([#"{"content":"Done with what I found."}"#], finish: "stop") }
            calls += 1
            return sse([call("mcp__notes__notes_count", "{}")], finish: "tool_calls")
        }
        var limited = false
        var limitText = ""
        backend.send(BackendRequest(prompt: "Count forever", userMessage: "q", previousTurns: []), workdir: NSTemporaryDirectory()) { event in
            DispatchQueue.main.async {
                if case .textDelta(let t) = event { limitText += t }
                if case .done = event { limited = true }
            }
        }
        try await waitForJournalTest(timeout: 60) { limited }
        precondition(calls == PrivateLocalTools.maxSteps && limitText == "Done with what I found.",
                     "At most \(PrivateLocalTools.maxSteps) tool steps, then an answer: \(calls)")
        // Through the Private Local tab: the tool step shows in its saved transcript; no cloud backend runs.
        let originalConfig = UserDefaults.standard.data(forKey: "privateLocalConfiguration")
        let shared = PrivateLocalTools.shared
        let (sharedRegistry, sharedSocket) = (shared.registry, shared.socketPath)
        let memory = AppSettings.shared.memoryEnabled
        defer {
            UserDefaults.standard.set(originalConfig, forKey: "privateLocalConfiguration")
            shared.registry = sharedRegistry
            shared.socketPath = sharedSocket
            AppSettings.shared.memoryEnabled = memory
        }
        AppSettings.shared.memoryEnabled = false
        shared.registry = { servers }
        shared.socketPath = { socketPath }
        _ = await shared.catalog(refresh: true)
        var toolsOff = local
        toolsOff.tools.enabled = false
        UserDefaults.standard.set(try JSONEncoder().encode(toolsOff), forKey: "privateLocalConfiguration")
        fixture.chatResponder = { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let answered = ((body["messages"] as? [[String: Any]]) ?? []).contains { $0["role"] as? String == "tool" }
            return answered ? sse([#"{"content":"You have 2 notes about Example Co."}"#], finish: "stop")
                : sse([call("mcp__notes__notes_search", #"{"query":"Example Co"}"#)], finish: "tool_calls")
        }
        final class CloudTrap: Backend {
            var requests = 0
            func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
                requests += 1
                onEvent(.failure("A Private Local request reached a cloud backend"))
            }
            func cancel() {}
            func reset() {}
        }
        let trap = CloudTrap()
        let chat = ChatSession(id: ChatSession.privateLocalID, copilotBackend: trap)
        chat.messages = [ChatMessage(role: .user, text: "Check my notes"),
                         ChatMessage(role: .assistant, text: "I do not have access to your notes.")]
        // Switching tools on starts fresh, so the earlier no-access reply never reaches the model.
        try chat.updatePrivateLocalSettings(local, revision: chat.privateLocalRevision)
        precondition(chat.messages.last?.role == .freshStart, "Turning tools on starts the tab fresh")
        let divider = chat.messages.count
        try chat.updatePrivateLocalSettings(local, revision: chat.privateLocalRevision)
        precondition(chat.messages.count == divider, "Saving again with tools on adds no second divider")
        var sentHistory = ""
        let previous = fixture.chatResponder
        fixture.chatResponder = { request in
            sentHistory += String(decoding: request.body, as: UTF8.self)
            return previous?(request) ?? ""
        }
        chat.submitRemote("What do my notes say about Example Co?")
        try await waitForJournalTest(timeout: 30) { !chat.isStreaming && chat.messages.last?.text.isEmpty == false }
        let answer = try requireHome(chat.messages.last)
        precondition(answer.text.contains("2 notes about Example Co") && trap.requests == 0,
                     "The tab answers from the tool result, locally: \(answer.text)")
        precondition(answer.activities.map(\.toolName).count == 1 && answer.activities.first?.state == .succeeded,
                     "The tool step shows in the transcript: \(answer.activities)")
        precondition(!sentHistory.contains("I do not have access to your notes"), "Turns above the divider aren't sent")
        let savedTranscript = try JSONDecoder().decode([ChatMessage].self, from: Data(contentsOf: SessionManager.chatsDir.appendingPathComponent("\(chat.id.uuidString).json")))
        precondition(savedTranscript.last?.toolMarks.count == 1 && savedTranscript.last?.text == answer.text
                     && savedTranscript.last?.toolCalls.map(\.name) == ["mcp__notes__notes_search"]
                     && savedTranscript.last?.toolCalls.first?.arguments.contains("Example Co") == true,
                     "The saved reply keeps where its tool step was and what it called (activities are live-only in every tab)")

        // A follow-up replays the earlier call with its answer, so the model looks things up again.
        var followUp: [[String: Any]] = []
        fixture.chatResponder = { request in
            followUp = ((try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            return sse([#"{"content":"Still 2 notes."}"#], finish: "stop")
        }
        chat.submitRemote("Any new notes about Example Co?")
        try await waitForJournalTest(timeout: 30) { !chat.isStreaming && chat.messages.last?.text == "Still 2 notes." }
        let replayedCalls = followUp.compactMap { $0["tool_calls"] as? [[String: Any]] }.flatMap { $0 }
            .compactMap { $0["function"] as? [String: Any] }
        precondition(followUp.suffix(5).map { $0["role"] as? String ?? "" } == ["user", "assistant", "tool", "assistant", "user"]
                     && replayedCalls.map { $0["name"] as? String } == ["mcp__notes__notes_search"]
                     && (replayedCalls.first?["arguments"] as? String) == #"{"query":"Example Co"}"#
                     && followUp.suffix(3).first?["content"] as? String == PrivateLocalClient.earlierResult
                     && followUp.suffix(2).first?["content"] as? String == answer.text,
                     "The earlier answer is replayed after its tool call: \(followUp.map { $0["role"] ?? "" })")

        // Trimming the oldest turns never leaves a tool result without its call.
        let answerText = "Two notes.", prompt = "And now?"
        var history = PrivateLocalClient.replayed([
            ConversationContextMessage(role: "user", content: String(repeating: "Example Co notes? ", count: 200)),
            ConversationContextMessage(role: "assistant", content: answerText,
                                       toolCalls: [ConversationToolCall(name: "mcp__notes__notes_search", arguments: "{}")]),
        ]) + [["role": "user", "content": prompt]]
        var replayedCount = history.count - 1
        let fitsWithOrphan = [PrivateLocalClient.earlierResult, answerText, prompt].reduce(0) { $0 + HomeLocalProfile.estimate($1) + 4 }
        precondition(OpenAICompatibleBackend.fit(&history, budget: fitsWithOrphan, replayed: &replayedCount)
                     && history.map { $0["role"] as? String ?? "" } == ["assistant", "user"],
                     "The orphaned tool result goes with its call: \(history.map { $0["role"] ?? "" })")

        print("Private Local tools: read-only filter, relay catalog, on-demand tools, refusals, budget, step limit and settings passed")
    }
}
