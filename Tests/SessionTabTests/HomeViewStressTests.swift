import Foundation

extension SessionTabTests {
    /// A view whose tool sources all refresh at once, through the real relay, catalog and
    /// `HomeViews.relayCall`, against stub servers shaped like a real setup: blocked servers, local
    /// servers that start slowly, one that never lists its tools, remote servers over HTTP, tools
    /// that are slow or never answer, and a cold catalog every round. Run it optimized
    /// (`make test-views-stress`): the Swift 6.4 miscompile it guards against only shows with -O.
    @MainActor
    static func testHomeViewParallelToolSources(rounds: Int = 50) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vstress-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("stub.py")
        try #"""
        import json, sys, time, random
        kind = sys.argv[1]
        time.sleep(random.uniform(0.05, 0.4))
        def tools():
            names = ["briefing", "status", "search_items"] if kind == "lab" else ["status", "search_items"]
            return [{"name": n, "description": "Synthetic " + n, "annotations": {"readOnlyHint": True},
                     "inputSchema": {"type": "object", "properties": {"sections": {"type": "string"}}}} for n in names]
        for line in sys.stdin:
            m = json.loads(line)
            if "id" not in m: continue
            if m["method"] == "initialize": r = {"protocolVersion": "2025-03-26", "capabilities": {}, "serverInfo": {"name": kind}}
            elif m["method"] == "tools/list":
                if kind == "stuck": continue
                r = {"tools": tools()}
            else:
                args = m["params"].get("arguments") or {}
                if args.get("hang"): continue
                time.sleep(args.get("delay", 0.2) * random.uniform(0.5, 1.5))
                r = {"content": [{"type": "text", "text": json.dumps({"section": args.get("sections"),
                                                                      "rows": [{"name": "Row %d" % i} for i in range(3)]})}]}
            print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        func local(_ name: String, _ kind: String) -> MCPServer {
            MCPServer(name: name, command: "/usr/bin/python3", args: [script.path, kind])
        }
        func remote(_ name: String) -> MCPServer { MCPServer(name: name, url: "https://\(name).example.com/mcp") }
        let servers = [local("lab", "lab"), local("notes", "notes"), local("mail", "notes"), local("stuck", "stuck"),
                       local("bitwarden", "notes"), local("agent_chrome", "notes"), local("forms", "notes"),
                       local("xcode", "notes"), local("rea", "notes"),
                       remote("flights"), remote("designs"), remote("flows"), remote("billing"),
                       remote("awards"), remote("errors"), remote("database")]
        // Remote servers answer after a short wait, like a real service.
        let transport: MCPOAuth.Transport = { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            try await Task.sleep(for: .milliseconds(Int.random(in: 20...400)))
            let url = request.url!
            guard let id = body["id"] else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)!)
            }
            let result: [String: Any] = body["method"] as? String == "tools/list"
                ? ["tools": [["name": "search_items", "annotations": ["readOnlyHint": true], "inputSchema": ["type": "object"]]]]
                : ["protocolVersion": "2025-03-26", "capabilities": [String: Any]()]
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                          headerFields: ["Content-Type": "application/json", "Mcp-Session-Id": UUID().uuidString])!)
        }
        let socketPath = "/tmp/cantrip-vstress-\(getpid()).sock"
        let relay = MCPRelay(environment: MCPRelay.Environment(
            server: { name in servers.first { $0.name == name } },
            // The host's relay asks the main actor before each session, as MCPHost does.
            refusal: { _, _ in DispatchQueue.main.sync { MainActor.assumeIsolated { nil } } },
            transport: transport), path: socketPath)
        relay.start()
        defer { relay.stop(); try? FileManager.default.removeItem(atPath: socketPath) }
        setenv("CANTRIP_MCP_SOCKET", socketPath, 1)
        defer { unsetenv("CANTRIP_MCP_SOCKET") }
        try await Task.sleep(for: .milliseconds(300))

        let tools = PrivateLocalTools.shared
        let savedTools = (tools.registry, tools.socketPath, tools.cacheLifetime, tools.listTimeout)
        let savedTimeouts = HomeViews.toolTimeouts
        tools.registry = { servers }
        tools.socketPath = { socketPath }
        tools.cacheLifetime = 0
        tools.listTimeout = 2
        HomeViews.toolTimeouts = (open: 5, call: 3)
        let views = HomeViews.shared
        let saved = (views.tasks, views.servers, views.callTool, views.policy, views.privateServers)
        defer {
            (tools.registry, tools.socketPath, tools.cacheLifetime, tools.listTimeout) = savedTools
            HomeViews.toolTimeouts = savedTimeouts
            (views.tasks, views.servers, views.callTool, views.policy, views.privateServers) = saved
            views.reset()
        }
        let tasks = viewTestTasks()
        views.reset(loading: true)
        views.tasks = { tasks }
        views.servers = { servers }
        views.policy = { _, _ in nil }
        views.privateServers = { [] }
        views.callTool = { try await HomeViews.relayCall($0) }

        func source(_ section: String, _ extra: String) -> String {
            #"{"tool":{"server":"lab","name":"briefing","arguments":{"sections":"\#(section)",\#(extra)}},"path":"rows"}"#
        }
        let json = """
        {"name":"Briefing","icon":"music.note.list",
         "data":{"summary":\(source("summary", #""delay":0.3"#)),"shows":\(source("shows", #""delay":0.8"#)),
                 "artists":\(source("artists", #""delay":0.1"#)),"readiness":\(source("readiness", #""hang":true"#)),
                 "jobs":{"records":"\(interviewsID)"}},
         "blocks":[{"type":"stat","label":"Rows","value":{"from":"summary","count":true}},
                   {"type":"table","from":"shows","columns":[{"title":"Name","field":"name"}]},
                   {"type":"table","from":"artists","columns":[{"title":"Name","field":"name"}]},
                   {"type":"table","from":"readiness","columns":[{"title":"Name","field":"name"}]},
                   {"type":"list","title":"Jobs","from":"jobs","titleField":"company"}]}
        """
        let applied = try views.apply(viewProposal(json), activities: [])
        let view = try requireHome(applied.view)
        let started = Date()
        var problems: [String] = []
        for round in 1...rounds {
            await views.refresh(view.id)
            let fetched = try requireHome(views.find(view.id)).fetched
            for name in ["summary", "shows", "artists"] where fetched[name]?.error != nil || fetched[name]?.fetchedAt == nil {
                problems.append("round \(round): \(name) didn't answer (\(fetched[name]?.error ?? "nothing saved"))")
            }
            if fetched["readiness"]?.error?.contains("didn't answer within") != true {
                problems.append("round \(round): the stuck tool should time out (\(fetched["readiness"]?.error ?? "no error"))")
            }
        }
        // Let anything a refresh left running finish: a child task that outlived its group crashes here.
        try await Task.sleep(for: .seconds(2))
        guard problems.isEmpty else {
            print("Views stress: \(problems.count) problem(s)\n" + problems.prefix(5).joined(separator: "\n"))
            exit(1)
        }
        print("Views: \(rounds) refreshes of 4 parallel tool sources (slow, stuck, cold catalog) through the relay passed in \(Int(Date().timeIntervalSince(started))) s")
    }

    /// Swift 6.4 with -O miscompiles a task body (`Task {}`, `addTask {}`) that returns a tuple built
    /// around `try await` from both `do` and `catch`: the tuple comes back wrong, and a task group
    /// ends before its children, which crash the process when they finish. No task body may have it.
    static func testNoTaskBodyReturnsTuplesFromDoCatch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folders = ["Sources", "Clients/CantripIOS/Sources", "Clients/CantripIOS/Shared", "Clients/CantripGatewayMac/Sources"]
        let opener = try NSRegularExpression(pattern: #"(\bTask(\.detached)?\s*(\([^()]*(\([^()]*\))?[^()]*\))?\s*\{|addTask(UnlessCancelled)?\s*(\([^()]*\))?\s*\{)"#)
        let doBlock = try NSRegularExpression(pattern: #"\bdo\s*\{"#)
        let tupleAroundAwait = try NSRegularExpression(pattern: #"return\s*\([^()]*,\s*(\.\w+\()?try\??\s+await"#)
        var scanned = 0, found: [String] = []
        for folder in folders {
            guard let files = FileManager.default.enumerator(atPath: root.appendingPathComponent(folder).path) else { continue }
            for case let file as String in files where file.hasSuffix(".swift") {
                let path = root.appendingPathComponent(folder).appendingPathComponent(file).path
                let text = try String(contentsOfFile: path, encoding: .utf8) as NSString
                for match in opener.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                    var index = match.range.location + match.range.length, depth = 1
                    while depth > 0, index < text.length {
                        let character = text.character(at: index)
                        if character == 0x7B { depth += 1 } else if character == 0x7D { depth -= 1 }
                        index += 1
                    }
                    let start = match.range.location + match.range.length
                    let body = text.substring(with: NSRange(location: start, length: max(0, index - 1 - start)))
                    let range = NSRange(location: 0, length: (body as NSString).length)
                    scanned += 1
                    if doBlock.firstMatch(in: body, range: range) != nil, body.contains("catch"),
                       tupleAroundAwait.firstMatch(in: body, range: range) != nil {
                        found.append("\(folder)/\(file)")
                    }
                }
            }
        }
        precondition(scanned > 100, "the scan found the sources (\(scanned) task bodies under \(root.path))")
        precondition(found.isEmpty, "Task bodies that return a tuple around try await from do/catch: \(found)")
    }
}
