import Foundation

extension SessionTabTests {
    /// Changing a setting between turns restarts agy; the old process's exit must not end the new turn.
    @MainActor
    static func testAntigravityRestartKeepsNextTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agy-restart-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("agy-restart-fixture")
        try Data(#"""
        #!/usr/bin/env python3
        import json, sys, time
        model = sys.argv[sys.argv.index('--model') + 1] if '--model' in sys.argv else 'none'
        for line in sys.stdin:
            if not line.strip():
                continue
            time.sleep(0.5)
            text = 'reply from ' + model
            print(json.dumps({'event': 'step_update', 'step_update': {'step_index': 1, 'state': 'DONE', 'step_type': 'agent_response', 'text_delta': text}}), flush=True)
            print(json.dumps({'event': 'result', 'conversation_id': 'conv-restart', 'result': {'status': 'SUCCESS', 'response': text, 'usage': {'input_tokens': 10, 'output_tokens': 5}}}), flush=True)
        """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        let settings = AppSettings.shared
        let saved = (settings.agyPath, settings.agyModel, settings.agyEffort, settings.agyPermissionMode, settings.allowActions)
        defer { (settings.agyPath, settings.agyModel, settings.agyEffort, settings.agyPermissionMode, settings.allowActions) = saved }
        settings.agyPath = script.path
        settings.agyModel = "model-a"
        settings.agyEffort = ""
        settings.agyPermissionMode = "default"
        settings.allowActions = true

        let backend = AntigravityBackend(persistKey: "test-agy-restart")
        backend.reset()
        defer { backend.cancel() }
        let first = try await antigravityTurn(backend, prompt: "one", workdir: directory.path)
        settings.agyModel = "model-b"
        let second = try await antigravityTurn(backend, prompt: "two", workdir: directory.path)
        precondition(first.text == "reply from model-a" && first.failure == nil,
                     "The first turn answers: \(first)")
        precondition(second.text == "reply from model-b" && second.failure == nil,
                     "After a restart the next turn waits for the new process's reply: \(second)")
    }

    /// Read-only sessions may only look, "Allow actions" off asks in Cantrip, and a tool that ran
    /// without the hook stops the session. The hook lives in agy's global hooks file, never in the
    /// folder the agent works in.
    @MainActor
    static func testAntigravityPermissionModes() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("agy-permissions-\(UUID())")
        let workdir = directory.appendingPathComponent("workspace")
        try fm.createDirectory(at: workdir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let sideEffects = directory.appendingPathComponent("executed.txt")
        let script = directory.appendingPathComponent("agy-permission-fixture")
        // Each prompt is a JSON list of [tool, args, hooked]; hooked=false runs a tool without asking.
        try Data(#"""
        #!/usr/bin/env python3
        import json, os, subprocess, sys

        def emit(obj):
            sys.stdout.write(json.dumps(obj) + '\n')
            sys.stdout.flush()

        with open(os.path.expanduser('~/.gemini/config/hooks.json'), 'r', encoding='utf-8') as f:
            entry = json.load(f).get('cantrip-guardrail', {})
        hook_cmd = entry['PreToolUse'][0]['hooks'][0]['command'] if entry.get('enabled') else None

        for line in sys.stdin:
            if not line.strip():
                continue
            calls = json.loads(json.loads(line)['message']['content'])
            decisions = []
            for idx, (tool, args, hooked) in enumerate(calls):
                if hooked:
                    proc = subprocess.run(hook_cmd, shell=True, text=True, capture_output=True,
                                          input=json.dumps({'toolCall': {'name': tool, 'args': args}, 'stepIdx': idx}))
                    decision = json.loads(proc.stdout.strip()).get('decision', 'none') if proc.stdout.strip() else 'error'
                else:
                    decision = 'unhooked'
                decisions.append(decision)
                if decision == 'deny':
                    continue
                with open(os.environ['AGY_TEST_SIDE_EFFECTS'], 'a', encoding='utf-8') as sf:
                    sf.write(tool + '\n')
                emit({'event': 'step_update', 'step_update': {
                    'step_index': idx + 1, 'state': 'DONE', 'step_type': 'tool', 'tool_name': tool,
                    'tool_info': {'name': tool, 'parameters': args, 'output': 'ok'}}})
            reply = ','.join(decisions)
            emit({'event': 'step_update', 'step_update': {'step_index': 99, 'state': 'DONE', 'step_type': 'agent_response', 'text_delta': reply}})
            emit({'event': 'result', 'conversation_id': 'conv-perm', 'result': {'status': 'SUCCESS', 'response': reply, 'usage': {'input_tokens': 1, 'output_tokens': 1}}})
        """#.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        setenv("AGY_TEST_SIDE_EFFECTS", sideEffects.path, 1)
        defer { unsetenv("AGY_TEST_SIDE_EFFECTS") }

        let settings = AppSettings.shared
        let saved = (settings.agyPath, settings.agyModel, settings.agyEffort, settings.agyPermissionMode, settings.allowActions)
        defer { (settings.agyPath, settings.agyModel, settings.agyEffort, settings.agyPermissionMode, settings.allowActions) = saved }
        settings.agyPath = script.path
        settings.agyModel = ""
        settings.agyEffort = ""
        settings.agyPermissionMode = "default"
        settings.allowActions = false

        precondition(AntigravityHook.isReadOnly(tool: "view_file", arguments: [:])
                     && AntigravityHook.isReadOnly(tool: "manage_task", arguments: ["Action": "status"])
                     && !AntigravityHook.isReadOnly(tool: "manage_task", arguments: ["Action": "send_input"])
                     && !AntigravityHook.isReadOnly(tool: "write_to_file", arguments: [:])
                     && !AntigravityHook.isReadOnly(tool: "run_command", arguments: [:]),
                     "Only Antigravity tools that look count as read-only")
        // Who decides, and the flags that follow from it.
        let readOnly = AntigravityBackend(persistKey: "test-agy-readonly", readOnly: true)
        let tab = AntigravityBackend(persistKey: "test-agy-ask")
        let skipFlag = "--dangerously-skip-permissions"
        precondition(readOnly.hookPolicy == .readOnly && tab.hookPolicy == .ask
                     && !readOnly.buildArguments(resumingSessionID: nil).contains(skipFlag)
                     && !tab.buildArguments(resumingSessionID: nil).contains(skipFlag),
                     "Read-only and Allow actions off go through Cantrip's hook")
        settings.allowActions = true
        precondition(readOnly.hookPolicy == .readOnly && tab.hookPolicy == nil
                     && tab.buildArguments(resumingSessionID: nil).contains(skipFlag)
                     && !readOnly.buildArguments(resumingSessionID: nil).contains(skipFlag),
                     "Act on my behalf skips agy's approvals, like Claude Code and Codex; read-only seats still only look")
        settings.allowActions = false
        settings.agyPermissionMode = "bypassPermissions"
        precondition(tab.hookPolicy == nil, "Antigravity's own Allow everything skips approvals too")
        settings.agyPermissionMode = "sandbox"
        precondition(tab.hookPolicy == .ask && tab.buildArguments(resumingSessionID: nil).contains("--sandbox"),
                     "Sandbox mode adds --sandbox and still asks")
        settings.agyPermissionMode = "default"
        tab.guardrail = .attended
        precondition(tab.hookPolicy == .guardrail(.attended), "A guardrail decides for child tabs and Home")
        tab.guardrail = nil

        // A user's own hooks survive Cantrip's entry being added.
        let config = AntigravityHook.configFile
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"user-linter": {"PostToolUse": [{"matcher": "run_command", "hooks": [{"command": "./lint.sh"}]}]}}"#.utf8)
            .write(to: config)

        func calls(_ list: [(String, [String: Any], Bool)]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: list.map { [$0.0, $0.1, $0.2] }), as: UTF8.self)
        }
        func executed() -> [String] {
            defer { try? fm.removeItem(at: sideEffects) }
            return ((try? String(contentsOf: sideEffects, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        let write: (String, [String: Any], Bool) = ("write_to_file", ["TargetFile": workdir.path + "/a.txt", "CodeContent": "x"], true)
        let command: (String, [String: Any], Bool) = ("run_command", ["CommandLine": "echo hi", "Cwd": workdir.path], true)
        let view: (String, [String: Any], Bool) = ("view_file", ["AbsolutePath": workdir.path + "/a.txt"], true)

        // Read-only: edits and commands are denied before they run; reads go to agy's own policy.
        let seat = try await antigravityTurn(readOnly, prompt: try calls([write, command, view]), workdir: workdir.path)
        readOnly.cancel()
        precondition(seat.text == "deny,deny,allow" && seat.prompts.isEmpty && executed() == ["view_file"],
                     "A read-only Antigravity seat can't edit files or run commands: \(seat)")

        // Allow actions off: Cantrip asks; the approved edit runs, the denied command doesn't.
        let asked = try await antigravityTurn(tab, prompt: try calls([write, command, view]), workdir: workdir.path,
                                              answers: [.approve, .deny])
        precondition(asked.text == "auto_approve,deny,allow" && executed() == ["write_to_file", "view_file"]
                     && asked.prompts == ["Allow Antigravity to run write_to_file?", "Allow Antigravity to run run_command?"],
                     "With Allow actions off, Antigravity asks in Cantrip before edits and commands: \(asked)")

        // A tool step the hook never saw means the hook isn't in effect (its entry removed or
        // disabled, say): the session stops.
        tab.cancel()
        let unhookedTab = AntigravityBackend(persistKey: "test-agy-unhooked")
        let unhooked = try await antigravityTurn(unhookedTab, prompt: try calls([("run_command", ["CommandLine": "echo hi"], false)]),
                                                 workdir: workdir.path)
        unhookedTab.cancel()
        precondition(unhooked.failure?.contains("without asking Cantrip") == true,
                     "Antigravity running a tool without the hook stops the session: \(unhooked)")
        _ = executed()

        let installed = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] ?? [:]
        let entry = installed[AntigravityHook.entryName] as? [String: Any]
        let hookCommand = ((entry?["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        precondition(installed["user-linter"] != nil && entry?["enabled"] as? Bool == true
                     && hookCommand == AntigravityHook.shellQuoted(AntigravityHook.helperFile.path)
                     && !fm.fileExists(atPath: workdir.appendingPathComponent(".agents").path),
                     "Cantrip's hook is one global entry beside the user's own, and nothing is written into the workspace: \(installed)")

        // Outside a Cantrip session the helper is a no-op; with a dead socket it denies.
        func runHelper(socket: String?) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [AntigravityHook.helperFile.path]
            var environment = ProcessInfo.processInfo.environment
            environment[AntigravityHook.socketVariable] = socket
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(#"{"toolCall":{"name":"run_command","args":{"CommandLine":"ls"}}}"#.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let outside = try runHelper(socket: nil)
        let deadSocket = try runHelper(socket: directory.appendingPathComponent("missing.sock").path)
        precondition(outside.contains(#""decision":"allow""#) && deadSocket.contains(#""decision":"deny""#),
                     "The global hook leaves other agy runs alone and fails closed for Cantrip's: \(outside) / \(deadSocket)")

        // A hooks file Cantrip can't read is left alone, and the session doesn't start unchecked.
        try Data("{ not json".utf8).write(to: config)
        let broken = try await antigravityTurn(tab, prompt: try calls([view]), workdir: workdir.path)
        tab.cancel()
        precondition(broken.failure?.contains("couldn't add its tool check") == true
                     && (try? String(contentsOf: config, encoding: .utf8)) == "{ not json"
                     && executed().isEmpty,
                     "An unreadable hooks file stops the session instead of being replaced: \(broken)")
        try? fm.removeItem(at: config)
    }

    /// Sends one prompt and collects the reply, any failure, and the approval prompts it raised
    /// (answered in order from `answers`, denying once they run out).
    @MainActor
    static func antigravityTurn(
        _ backend: AntigravityBackend, prompt: String, workdir: String,
        answers: [InputRequestAnswer.Decision] = []
    ) async throws -> (text: String, failure: String?, prompts: [String]) {
        var text = "", failure: String?, prompts: [String] = [], finished = false
        var remaining = answers
        backend.send(BackendRequest(prompt: prompt, userMessage: prompt, previousTurns: []), workdir: workdir) { event in
            DispatchQueue.main.async {
                switch event {
                case .textDelta(let delta): text += delta
                case .failure(let message): failure = message; finished = true
                case .done: finished = true
                case .inputRequired(let request):
                    prompts.append(request.snapshot.title)
                    let decision = remaining.isEmpty ? .deny : remaining.removeFirst()
                    try? request.respond(InputRequestAnswer(decision: decision))
                default: break
                }
            }
        }
        try await waitForJournalTest { finished }
        return (text, failure, prompts)
    }
}
