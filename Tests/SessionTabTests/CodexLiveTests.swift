import Foundation

extension SessionTabTests {
    /// BACKEND-ONBOARDING section 7 against the installed, signed-in Codex CLI
    /// (`CANTRIP_CODEX_LIVE_TEST=1`). Spends a few small turns; deletes its threads afterwards.
    @MainActor
    static func testCodexLive() async throws {
        let fm = FileManager.default
        guard let executable = ToolLocator.shared.codex(configured: "") else { preconditionFailure("codex isn't installed") }
        let root = URL(fileURLWithPath: "/private/tmp/codex-live-\(UUID().uuidString.prefix(8))")
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for folder in [first, second] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try "contents: lighthouse\n".write(to: first.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)
        let echo = root.appendingPathComponent("echo_mcp.py")
        try #"""
        import json, sys
        for line in sys.stdin:
            m = json.loads(line)
            if "id" not in m: continue
            method = m.get("method")
            if method == "initialize": r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "echo", "version": "1"}}
            elif method == "tools/list": r = {"tools": [{"name": "shout", "description": "Echoes text in capitals", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}]}
            elif method == "tools/call": r = {"content": [{"type": "text", "text": "ECHO " + m["params"]["arguments"].get("text", "").upper()}]}
            else: r = {}
            print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
        """#.write(to: echo, atomically: true, encoding: .utf8)

        let settings = AppSettings.shared
        let saved = (settings.allowActions, settings.codexPermissionMode, settings.codexModel, settings.codexEffort, settings.codexPath)
        defer {
            (settings.allowActions, settings.codexPermissionMode, settings.codexModel, settings.codexEffort, settings.codexPath) = saved
        }
        settings.allowActions = false
        settings.codexPermissionMode = "default"
        settings.codexPath = ""
        settings.codexEffort = "low"
        var keys: [String] = []
        let version = Process()
        version.executableURL = URL(fileURLWithPath: executable)
        version.arguments = ["--version"]
        let pipe = Pipe()
        version.standardOutput = pipe
        try version.run()
        version.waitUntilExit()
        func note(_ line: String) { print(line); fflush(stdout) }
        note(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))

        // Models and limits: read without a model call.
        let models = try await withCheckedThrowingContinuation { CodexModelFetcher.fetch(executable: executable, completion: $0.resume(with:)) }
        precondition(!models.isEmpty && models.contains(where: \.isDefault) && models.allSatisfy { !$0.efforts.isEmpty })
        settings.codexModel = models.first(where: \.isDefault)!.id
        note("models: " + models.map { "\($0.id) [\($0.efforts.joined(separator: ","))]" }.joined(separator: "; "))
        let usage = try await withCheckedThrowingContinuation { CodexUsage.fetch(executable: executable, completion: $0.resume(with:)) }
        precondition(!usage.windows.isEmpty)
        note("limits: " + usage.windows.map { "\($0.title) \(Int($0.usedPercent))% resets \($0.resetsAt ?? "?")" }.joined(separator: "; "))

        func backend(_ name: String, readOnly: Bool = false, extraArguments: [String] = []) -> CodexBackend {
            let key = "codex-live-\(name)-\(UUID().uuidString)"
            keys.append(key)
            let backend = CodexBackend(persistKey: key, readOnly: readOnly)
            if !extraArguments.isEmpty {
                backend.makeServer = { arguments, environment, workdir in
                    CodexAppServer(executable: executable, arguments: arguments + extraArguments, environment: environment,
                                   directory: URL(fileURLWithPath: workdir))
                }
            }
            return backend
        }
        func turn(_ backend: CodexBackend, _ prompt: String, in folder: URL = first, previous: [ConversationTurn] = [],
                  answers: [InputRequestAnswer.Decision] = [], stopAfter: TimeInterval? = nil) async throws -> CodexTurn {
            let box = CodexTurnBox()
            var remaining = answers
            let started = Date()
            backend.send(BackendRequest(prompt: prompt, userMessage: prompt, previousTurns: previous), workdir: folder.path) { event in
                DispatchQueue.main.async {
                    switch event {
                    case .textDelta(let delta): box.value.text += delta
                    case .failure(let message): box.value.failure = message; box.value.finished = true
                    case .done: box.value.finished = true
                    case .activity(let activity): box.value.activities[activity.id] = activity
                    case .approval(let approval): box.value.approvals.append(approval)
                    case .usageLimit(let limit): box.value.limits.append(limit)
                    case .usage(let usage): box.value.usage = usage
                    case .inputRequired(let request):
                        box.value.prompts.append(request.snapshot.title)
                        let decision = remaining.isEmpty ? .deny : remaining.removeFirst()
                        try? request.respond(InputRequestAnswer(decision: decision))
                    default: break
                    }
                }
            }
            let deadline = Date().addingTimeInterval(240)
            while !box.value.finished, Date() < deadline {
                if let stopAfter, Date().timeIntervalSince(started) > stopAfter,
                   box.value.activities.values.contains(where: { $0.state == .running }) {
                    precondition(backend.interruptTurn())
                    box.value.finished = true
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            precondition(box.value.finished, "Codex didn't finish: \(prompt)")
            let steps = box.value.activities.values.map { "\($0.title) [\($0.state)]" }.sorted().joined(separator: ", ")
            note("» \(prompt.prefix(60)) → \(box.value.failure.map { "FAILED \($0)" } ?? box.value.text.prefix(80).description)"
                          + (steps.isEmpty ? "" : " | steps: \(steps)") + (box.value.prompts.isEmpty ? "" : " | asked: \(box.value.prompts)"))
            return box.value
        }

        // 1. Three turns that remember, then a restart and a Stop.
        var tab: CodexBackend? = backend("tab")
        _ = try await turn(tab!, "Remember the code word PELICAN. Reply only: OK")
        let read = try await turn(tab!, "Run `cat existing.txt` and reply with the word after 'contents:' only.")
        precondition(read.text.lowercased().contains("lighthouse"), "A read runs")
        // 3. Actions off: Cantrip asks; approved runs, denied fails.
        let made = try await turn(tab!, "Use a shell command to create made.txt containing hi. Then reply: done", answers: [.approve, .approve])
        precondition(!made.prompts.isEmpty && fm.fileExists(atPath: first.appendingPathComponent("made.txt").path), "Approved edits run")
        let denied = try await turn(tab!, "Run exactly this shell command: touch denied.txt. Don't try anything else. Then reply: tried")
        precondition(!denied.prompts.isEmpty && !fm.fileExists(atPath: first.appendingPathComponent("denied.txt").path), "Denied edits don't")
        // Cantrip quits: its Codex process ends, and a new one resumes the thread.
        tab = nil
        try await Task.sleep(for: .seconds(2))
        let restarted = CodexBackend(persistKey: keys[0])
        let recalled = try await turn(restarted, "What was the code word? Reply with it only.")
        precondition(recalled.text.uppercased().contains("PELICAN"), "The thread survives a restart")
        _ = try await turn(restarted, "Run `sleep 30` in the shell, then reply: slept", answers: [.approve], stopAfter: 3)
        let after = try await turn(restarted, "What was the code word? Reply with it only.")
        precondition(after.failure == nil && after.text.uppercased().contains("PELICAN"), "Stop keeps the conversation")

        // 2. A tab that ran on another backend carries its turns over.
        let switched = backend("switched")
        let carried = try await turn(switched, "What's my favorite color? One word.",
                                     previous: [ConversationTurn(user: "My favorite color is teal.", assistant: "Noted: teal.")])
        precondition(carried.text.lowercased().contains("teal"), "Earlier turns reach a new Codex thread")
        // 5. A folder change starts a thread in the new folder.
        let moved = try await turn(switched, "Run pwd and reply with its output only.", in: second)
        precondition(moved.text.contains(second.lastPathComponent), "The new folder: \(moved.text)")

        // 4. A read-only council seat that tries to edit, even with Act on my behalf.
        settings.allowActions = true
        let seat = backend("seat", readOnly: true)
        _ = try await turn(seat, "Create a file named seat.txt containing x, using any tool. Then reply: done")
        precondition(!fm.fileExists(atPath: first.appendingPathComponent("seat.txt").path), "A read-only seat can't edit")
        // Act on my behalf: full access, no prompts.
        let open = backend("open")
        let acted = try await turn(open, "Use a shell command to create acted.txt containing hi. Then reply: done")
        precondition(acted.prompts.isEmpty && fm.fileExists(atPath: first.appendingPathComponent("acted.txt").path))
        settings.allowActions = false

        // 7. A per-tab model.
        if let other = models.first(where: { !$0.isDefault }) {
            let pinned = backend("pinned")
            pinned.modelOverride = other.id
            pinned.effortOverride = other.efforts.first
            let reply = try await turn(pinned, "Reply only: ok")
            precondition(reply.failure == nil, "The tab's own model runs: \(other.id)")
        }

        // 10. Cantrip Home: the policy decides; sudo is blocked without asking.
        let home = backend("home")
        home.guardrail = .unattended
        let blocked = try await turn(home, "Run exactly: sudo -n true. Then reply with what happened in five words.")
        precondition(blocked.prompts.isEmpty && blocked.approvals.contains { $0.decision == "denied" },
                     "Home blocks sudo: \(blocked.approvals)")

        // Shared MCP servers: Cantrip's `-c` overrides reach the real CLI, and the tool asks first.
        let snapshot = MCPRegistry.Snapshot(servers: MCPRegistry.importConfigs(copilot: ["mcpServers": [
            "echo": ["type": "local", "command": "/usr/bin/python3", "args": [echo.path], "tools": ["*"]],
        ]], claude: nil).servers)
        let mcp = backend("mcp", extraArguments: MCPBackendConfig.codexArgs(snapshot))
        let called = try await turn(mcp, "Call the shout tool on the echo MCP server with text hi, then reply with its result only.",
                                    answers: [.approve])
        precondition(called.text.contains("ECHO HI") && !called.prompts.isEmpty, "The shared server's tool ran after approval")

        // Clean up: delete every thread this test made.
        let threads = keys.compactMap { UserDefaults.standard.string(forKey: $0) }
        for backend in [restarted, switched, seat, open, home, mcp] { backend.reset() }
        try await CodexAppServer.withServer(executable: executable) { server in
            for thread in Set(threads) { _ = try? await server.request("thread/delete", ["threadId": thread], timeout: 20) }
        }
        try? fm.removeItem(at: root)
        note("deleted \(Set(threads).count) threads")
    }
}
