import Foundation

extension SessionTabTests {
    /// Code mode: the sandbox, typed API, recipes, and that every call a program makes gets the
    /// caller's own checks (Privacy Gate, agent policy, relay), end to end through a real relay.
    static func testCodeMode() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("code-mode-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let shapes = CodeModeShapes(file: home.appendingPathComponent("shapes.json"))

        // A stub server in memory: search returns two notes, read returns one.
        let search = CodeModeTool(server: "notes", name: "notes_search", description: "Find notes",
                                  inputSchema: ["type": "object", "properties": ["query": ["type": "string"], "limit": ["type": "integer"]],
                                                "required": ["query"]])
        let read = CodeModeTool(server: "notes", name: "notes_read", description: "Read a note",
                                inputSchema: ["type": "object", "properties": ["id": ["type": "integer"]], "required": ["id"]])
        let tools = [search, read]
        func stub(_ delay: Duration = .zero) -> CodeModeRunner.Perform {
            { tool, arguments in
                if delay > .zero { try? await Task.sleep(for: delay) }
                switch tool.name {
                case "notes_search": return .output(#"{"count":2,"results":[{"id":1,"title":"Example A"},{"id":2,"title":"Example B"}]}"#, isError: false)
                case "notes_read":
                    let id = arguments["id"] as? Int ?? 0
                    return id == 2 ? .output("not found", isError: true) : .output(#"{"id":\#(id),"text":"Hello from note \#(id)"}"#, isError: false)
                default: return .refused("no such tool")
                }
            }
        }
        func run(_ script: String, limits: CodeMode.Limits = .init(), perform: CodeModeRunner.Perform? = nil,
                 recipes: [CodeModeRecipe] = []) async -> CodeModeRunner.Result {
            await CodeModeRunner(tools: tools, recipes: recipes, limits: limits, shapes: shapes, perform: perform ?? stub()).run(script)
        }

        // Nothing but the tool functions.
        let globals = await run(#"return [typeof fetch, typeof require, typeof setTimeout, typeof XMLHttpRequest, typeof process, typeof WebAssembly, typeof console].join(",")"#)
        precondition(globals.value == #""undefined,undefined,undefined,undefined,undefined,undefined,undefined""#, "Sandbox globals: \(globals)")

        // A chain: search, then read each match in parallel; a failed read is caught.
        let chain = await run("""
        const found = await notes.notes_search({ query: "example" });
        const read = await Promise.all(found.results.map(r => notes.notes_read({ id: r.id }).catch(e => ({ id: r.id, error: e.message }))));
        log("read", read.length);
        return read;
        """)
        precondition(chain.error == nil && chain.toolCalls == 3 && chain.calls == ["notes/notes_search": 1, "notes/notes_read": 2]
                     && chain.value?.contains("Hello from note 1") == true && chain.value?.contains("notes.notes_read failed: not found") == true
                     && chain.log == ["read 2"] && chain.reply.contains("(3 tool calls"),
                     "Chained calls stay in the sandbox; only the result returns: \(chain)")

        // Anything outside the API is refused, not run.
        let outside = await run("""
        try { await new Promise((ok, no) => __call("notes", "notes_delete", "{}", ok, no)); return "ran"; }
        catch (e) { return String((e && e.message) || e); }
        """)
        precondition(outside.value?.contains("isn't available here") == true && outside.refused == 1 && outside.toolCalls == 0,
                     "A tool not in the API is refused: \(outside)")

        // Limits and errors come back as messages.
        var quick = CodeMode.Limits()
        quick.cpuSeconds = 1
        let started = Date()
        let loop = await run("while (true) {}", limits: quick)
        precondition(loop.error?.contains("compute") == true && Date().timeIntervalSince(started) < 10, "A runaway loop is stopped: \(loop)")
        var few = CodeMode.Limits()
        few.toolCalls = 2
        let capped = await run("for (let i = 0; i < 5; i++) await notes.notes_search({ query: 'x' }); return 'done';", limits: few)
        precondition(capped.error?.contains("limit of 2 tool calls") == true && capped.toolCalls == 2, "Tool calls are capped: \(capped)")
        var small = CodeMode.Limits()
        small.outputCharacters = 100
        let long = await run("return 'x'.repeat(500);", limits: small)
        precondition(long.value?.contains("more characters left out") == true && (long.value?.count ?? 0) < 200, "Results are capped: \(long)")
        let syntax = await run("return (")
        precondition(syntax.error?.contains("SyntaxError") == true, "Syntax errors are reported: \(syntax)")
        let thrown = await run("throw new Error('boom')")
        precondition(thrown.error == "boom", "Thrown errors are reported: \(thrown)")
        var brief = CodeMode.Limits()
        brief.seconds = 1
        let slow = await run("return await notes.notes_search({ query: 'x' });", limits: brief, perform: stub(.seconds(3)))
        precondition(slow.error?.contains("Stopped after 1 s") == true, "Programs have a time limit: \(slow)")
        var tiny = CodeMode.Limits()
        tiny.scriptCharacters = 10
        let tooLong = await run("return 'a long program';", limits: tiny)
        precondition(tooLong.error?.contains("limit is 10") == true, "Programs have a size limit: \(tooLong)")

        // Typed API: inputs from the schema, outputs from shapes seen (key names and types only).
        precondition(CodeModeAPI.identifier("search-flight") == "search_flight" && CodeModeAPI.identifier("delete") == "delete_"
                     && CodeModeAPI.identifier("2fa") == "_2fa", "Identifiers")
        precondition(CodeModeAPI.typescript(search.inputSchema) == "{ limit?: number; query: string }", CodeModeAPI.typescript(search.inputSchema))
        precondition(CodeModeAPI.typescript(["type": "array", "items": ["enum": ["a", "b"]]]) == "Array<\"a\" | \"b\">")
        shapes.observe("notes/notes_read", text: #"{"id":7,"text":"Private words","from":"someone@example.com","tags":["x"],"note":"untrusted"}"#)
        shapes.observe("notes/notes_read", text: #"{"id":8,"text":"More","extra":null,"by":{"someone@example.com":1}}"#)
        let stored = try String(contentsOf: shapes.file, encoding: .utf8)
        precondition(!stored.contains("Private words") && !stored.contains("someone@example.com") && !stored.contains("untrusted"),
                     "Shapes keep key names and types, never values: \(stored)")
        let declared = CodeModeAPI.declarations(tools, recipes: [], shapes: shapes)
        precondition(declared.contains("notes_search(args: { limit?: number; query: string }): Promise<{ count: number; results: { id: number; title: string }[] }>")
                     && declared.contains("by?: Record<string, number>") && declared.contains("id: number")
                     && declared.contains("text: string") && !declared.contains(" note: ") && !declared.contains(" note?: "),
                     "Declarations: \(declared)")

        // Recipes: a saved chain, offered only when its tools are.
        let recipe = CodeModeRecipe(name: "note_digest", description: "Search, then read each", params: "{ query: string }",
                                    returns: "unknown", tools: ["notes.notes_search", "notes.notes_read"], script: """
            const found = await notes.notes_search({ query: args.query });
            return Promise.all(found.results.slice(0, 1).map(r => notes.notes_read({ id: r.id })));
            """)
        let viaRecipe = await run("return await recipes.note_digest({ query: 'x' });", recipes: [recipe])
        precondition(viaRecipe.value?.contains("Hello from note 1") == true && viaRecipe.toolCalls == 2, "Recipes run: \(viaRecipe)")
        precondition(!recipe.available(with: [search]) && recipe.available(with: tools))
        let builtIns = CodeModeRecipes.builtIn.map(\.name)
        precondition(builtIns.contains("mail_digest") && builtIns.contains("message_threads"), "Built-in recipes: \(builtIns)")
        let folder = home.appendingPathComponent("recipes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"name":"saved_one","description":"d","tools":["notes.notes_search"],"script":"return 1;"}"#
            .write(to: folder.appendingPathComponent("saved_one.json"), atomically: true, encoding: .utf8)
        precondition(CodeModeRecipes.all(folder: folder).contains { $0.name == "saved_one" }, "Recipes load from the folder")

        // Every call a program makes gets the caller's checks.
        let connections = CodeModeConnections(hello: .init(server: CodeMode.serverName), path: "/nonexistent")
        defer { connections.close() }
        let personal = CodeModeTool(server: "personal", name: "mail_search", description: "", inputSchema: [:])
        var cloud = CodeModeHost.Caller(hello: .init(server: CodeMode.serverName, backend: "Copilot"))
        cloud.policy.privacy = PrivacyCloudRestriction(PrivacyCloudRuns())
        guard case .refused(let byGate) = await CodeModeHost.perform(personal, arguments: [:], caller: cloud, connections: connections),
              byGate.contains("Privacy Gate") else { preconditionFailure("A cloud-restricted run can't reach personal from a program") }
        cloud.excludedServers = ["personal"]
        guard case .refused(let excluded) = await CodeModeHost.perform(personal, arguments: [:], caller: cloud, connections: connections),
              excluded.contains("Privacy Gate") else { preconditionFailure("Excluded servers are refused") }
        let savedStore = AgentPolicyGate.store
        AgentPolicyGate.store = AgentPolicyStore(url: home.appendingPathComponent("policy.json"))
        defer { AgentPolicyGate.store = savedStore }
        var policy = AgentPolicyDocument.starter
        policy.rules.append(.init(id: "no-notes-read", effect: .deny, reason: "Notes stay closed.", mcp: ["notes/notes_read"]))
        policy.rules.append(.init(id: "ask-notes-search", effect: .ask, reason: "Ask first.", mcp: ["notes/notes_search"]))
        try AgentPolicyGate.store.save(policy, basedOn: nil)
        let local = CodeModeHost.Caller(hello: .init(server: CodeMode.serverName, backend: "Private Local"))
        guard case .refused(let denied) = await CodeModeHost.perform(read, arguments: ["id": 1], caller: local, connections: connections),
              denied.contains("no-notes-read") else { preconditionFailure("A policy deny rule refuses a program's call") }
        guard case .refused(let asked) = await CodeModeHost.perform(search, arguments: [:], caller: local, connections: connections),
              asked.contains("asks before") else { preconditionFailure("A policy ask rule refuses a program's call") }
        AgentPolicyGate.store = savedStore

        // End to end through a real relay: cantrip_code lists the API and runs a program whose calls
        // go back through the relay to stub servers; a restricted caller sees and reaches none of notes.
        let script = home.appendingPathComponent("stub.py")
        try #"""
        import json, sys
        def tools():
            return [{"name": n, "description": "Synthetic " + n, "annotations": {"readOnlyHint": True},
                     "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}, "query": {"type": "string"}}}}
                    for n in ["notes_search", "notes_read"]] + [{"name": "notes_delete", "inputSchema": {"type": "object"}}]
        for line in sys.stdin:
            m = json.loads(line)
            if "id" not in m: continue
            if m["method"] == "initialize": r = {"protocolVersion": "2025-03-26", "capabilities": {}, "serverInfo": {"name": "notes"}}
            elif m["method"] == "tools/list": r = {"tools": tools()}
            else:
                name = m["params"]["name"]; args = m["params"].get("arguments") or {}
                if name == "notes_search": text = json.dumps({"count": 2, "results": [{"id": 1}, {"id": 3}]})
                elif name == "notes_read": text = json.dumps({"id": args.get("id"), "text": "note %s" % args.get("id")})
                else: text = name + " called"
                r = {"content": [{"type": "text", "text": text}]}
            print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let servers = [MCPServer(name: "notes", command: "/usr/bin/python3", args: [script.path]),
                       MCPServer(name: "bitwarden", command: "/usr/bin/python3", args: [script.path])]
        let socketPath = "/tmp/cantrip-cm-\(getpid()).sock"
        let catalogTools = PrivateLocalTools()
        catalogTools.registry = { servers }
        catalogTools.socketPath = { socketPath }
        let host = CodeModeHost()
        host.catalog = { await catalogTools.catalog(refresh: true) }
        host.socketPath = { socketPath }
        host.recipes = { [recipe] }
        host.shapes = shapes
        nonisolated(unsafe) var restricted = false
        host.resolveCaller = { hello in
            var caller = CodeModeHost.Caller(hello: hello)
            if restricted { caller.excludedServers = ["notes"] }
            return caller
        }
        let relay = MCPRelay(environment: MCPRelay.Environment(
            server: { name in name == CodeMode.serverName ? CodeMode.virtualServer : servers.first { $0.name == name } },
            builtIn: { hello, deliver in hello.server == CodeMode.serverName ? CodeModeUpstream(hello: hello, host: host, deliver: deliver) : nil }
        ), path: socketPath)
        relay.start()
        defer { relay.stop(); try? FileManager.default.removeItem(atPath: socketPath) }
        try await Task.sleep(for: .milliseconds(300))
        let client = MCPRelayClient(server: CodeMode.serverName, tab: nil, backend: "Copilot", path: socketPath)
        defer { client.close() }
        try await client.open()
        let listed = try await client.listTools()
        let description = listed.first { $0["name"] as? String == CodeMode.runTool }?["description"] as? String ?? ""
        precondition(listed.compactMap { $0["name"] as? String } == [CodeMode.runTool, CodeMode.apiTool]
                     && description.contains("declare const notes") && description.contains("notes_read(")
                     && !description.contains("notes_delete") && !description.contains("bitwarden")
                     && description.contains("note_digest("),
                     "The API lists read-only tools only, never blocked servers: \(description)")
        let (reply, failed) = try await client.callTool(CodeMode.runTool, arguments: ["script": """
            const found = await notes.notes_search({ query: "x" });
            const read = await Promise.all(found.results.map(r => notes.notes_read({ id: r.id })));
            return read.map(n => n.text);
            """])
        precondition(!failed && reply.hasPrefix(#"["note 1","note 3"]"#) && reply.contains("(3 tool calls"), "A program over the relay: \(reply)")
        let (api, _) = try await client.callTool(CodeMode.apiTool, arguments: ["servers": ["notes"]])
        precondition(api.contains("Promise<{ count: number; results: { id: number; title?: string }[] }>"),
                     "Shapes seen through the relay merge with earlier ones (a key one result lacks becomes optional): \(api)")
        restricted = true
        let (blockedReply, blockedFailed) = try await client.callTool(CodeMode.runTool, arguments: ["script": """
            try { return await notes.notes_search({ query: "x" }); } catch (e) { return "refused: " + e.message; }
            """])
        precondition(blockedReply.contains("refused") || blockedReply.contains("notes is not defined") || blockedFailed,
                     "A restricted caller can't reach the excluded server from a program: \(blockedReply)")
        let relisted = try await client.listTools()
        let restrictedDescription = relisted.first { $0["name"] as? String == CodeMode.runTool }?["description"] as? String ?? ""
        precondition(!restrictedDescription.contains("declare const notes"), "Nor see its declarations")

        // Backend configs: cantrip_code only while code mode is on; Claude's per-tab config names the tab.
        let snapshot = MCPRegistry.Snapshot(servers: servers)
        let wasOn = UserDefaults.standard.bool(forKey: CodeMode.settingKey)
        defer { UserDefaults.standard.set(wasOn, forKey: CodeMode.settingKey) }
        UserDefaults.standard.set(false, forKey: CodeMode.settingKey)
        precondition((MCPBackendConfig.copilot(snapshot)["mcpServers"] as? [String: Any])?[CodeMode.serverName] == nil,
                     "Off: no cantrip_code")
        UserDefaults.standard.set(true, forKey: CodeMode.settingKey)
        let tabID = UUID()
        let claudeEntry = (MCPBackendConfig.claude(snapshot, tab: tabID, relay: "/r")["mcpServers"] as? [String: Any])?[CodeMode.serverName] as? [String: Any]
        let copilotEntry = (MCPBackendConfig.copilot(snapshot, relay: "/r")["mcpServers"] as? [String: Any])?[CodeMode.serverName] as? [String: Any]
        precondition(claudeEntry?["args"] as? [String] == [CodeMode.serverName, "--backend", BackendKind.claudeCode.rawValue, "--tab", tabID.uuidString]
                     && copilotEntry?["args"] as? [String] == [CodeMode.serverName, "--backend", BackendKind.copilot.rawValue]
                     && claudeEntry?["command"] as? String == "/r",
                     "On: every backend gets the relayed cantrip_code: \(String(describing: claudeEntry)) \(String(describing: copilotEntry))")
        precondition(!MCPBackendConfig.codexArgs(snapshot, excluded: [CodeMode.serverName], relay: "/r").joined().contains(CodeMode.serverName),
                     "A tab can switch it off like any server")

        print("Code mode: sandbox, limits, typed API, shapes without values, recipes, policy and Privacy Gate checks and relay passed")
    }
}
