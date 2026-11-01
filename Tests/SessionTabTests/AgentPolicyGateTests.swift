import Foundation

extension SessionTabTests {
    /// Saves a policy for the duration of `body`, then restores whatever file was there.
    static func withAgentPolicy<T>(enabled: Bool = true, rules: [AgentPolicyRule]? = nil, _ body: () throws -> T) rethrows -> T {
        let store = AgentPolicyGate.store
        let previous = try? Data(contentsOf: store.url)
        var document = AgentPolicyDocument.starter
        document.enabled = enabled
        if let rules { document.rules = rules }
        try! store.save(document, basedOn: nil)
        defer {
            if let previous { try? previous.write(to: store.url) } else { try? FileManager.default.removeItem(at: store.url) }
            _ = store.current()
        }
        return try body()
    }

    /// Turns the agent policy off until the returned closure runs (fixtures that answer no hooks).
    static func suspendAgentPolicy() -> () -> Void {
        let store = AgentPolicyGate.store
        let previous = try? Data(contentsOf: store.url)
        var document = AgentPolicyDocument.starter
        document.enabled = false
        try! store.save(document, basedOn: nil)
        return {
            if let previous { try? previous.write(to: store.url) } else { try? FileManager.default.removeItem(at: store.url) }
            _ = store.current()
        }
    }

    @MainActor
    static func withAgentPolicy<T>(enabled: Bool = true, rules: [AgentPolicyRule]? = nil,
                                   _ body: () async throws -> T) async rethrows -> T {
        let store = AgentPolicyGate.store
        let previous = try? Data(contentsOf: store.url)
        var document = AgentPolicyDocument.starter
        document.enabled = enabled
        if let rules { document.rules = rules }
        try! store.save(document, basedOn: nil)
        defer {
            if let previous { try? previous.write(to: store.url) } else { try? FileManager.default.removeItem(at: store.url) }
            _ = store.current()
        }
        return try await body()
    }

    /// Paired clients read the policy and the browser Remote edits it through /api/v1/policy.
    @MainActor
    static func testAgentPolicyRemote() async throws {
        let store = AgentPolicyGate.store
        let previous = try? Data(contentsOf: store.url)
        defer {
            if let previous { try? previous.write(to: store.url) } else { try? FileManager.default.removeItem(at: store.url) }
            _ = store.current()
        }
        try? FileManager.default.removeItem(at: store.url)
        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager)
        defer { withExtendedLifetime(manager) {} }
        let port = Int.random(in: 20_000...45_000), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ method: String = "GET", _ body: [String: Any]? = nil, authorized: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/policy")!)
            request.httpMethod = method
            if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
        }
        func policy(_ response: (Int, [String: Any])) -> [String: Any] { response.1["policy"] as? [String: Any] ?? [:] }
        func ruleIDs(_ response: (Int, [String: Any])) -> [String] {
            (policy(response)["rules"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }

        let anonymous = try await call(authorized: false)
        precondition(anonymous.0 == 401, "Pairing is required")
        let loaded = try await call()
        precondition(loaded.0 == 200 && ruleIDs(loaded) == AgentPolicyRule.starter.map(\.id)
                     && (loaded.1["summaries"] as? [String: String])?["deletes-outside-workspace"]?.contains("deletes outside") == true
                     && (loaded.1["namedCommands"] as? [String]) == ["@cantrip-restart"],
                     "GET returns the starter rules before anything is saved: \(loaded)")
        let added = try await call("POST", ["revision": 0, "rule": [
            "id": "no-fly-deploy", "effect": "deny", "reason": "Deploys go through CI.", "commands": ["fly deploy"]]])
        let revision = policy(added)["revision"] as? Int ?? -1
        precondition(added.0 == 200 && ruleIDs(added).last == "no-fly-deploy" && revision >= 1, "Adding a rule saves it: \(added)")
        precondition(store.current().evaluate(.shell("fly deploy"), context: .current(workdir: NSTemporaryDirectory())).ruleID == "no-fly-deploy",
                     "The saved rule applies at once")
        let stale = try await call("POST", ["revision": 0, "enabled": false])
        precondition(stale.0 == 409, "A stale revision is refused")
        let invalid = try await call("POST", ["revision": revision, "rule": ["id": "empty", "effect": "deny", "reason": "r"]])
        precondition(invalid.0 == 400 && (invalid.1["error"] as? String ?? "").contains("matches nothing"), "An invalid rule is refused: \(invalid)")
        let toggled = try await call("POST", ["revision": revision, "setRuleEnabled": ["id": "no-fly-deploy", "enabled": false]])
        let toggledRule = (policy(toggled)["rules"] as? [[String: Any]] ?? []).first { $0["id"] as? String == "no-fly-deploy" }
        precondition(toggled.0 == 200 && toggledRule?["enabled"] as? Bool == false, "A rule turns off")
        let removed = try await call("POST", ["revision": policy(toggled)["revision"] as? Int ?? 0, "removeRule": "no-fly-deploy"])
        precondition(removed.0 == 200 && !ruleIDs(removed).contains("no-fly-deploy"), "A rule is removed")
        let missing = try await call("POST", ["revision": policy(removed)["revision"] as? Int ?? 0, "removeRule": "nothing"])
        precondition(missing.0 == 404, "Removing an unknown rule says so")
        var replacement = policy(removed)
        replacement["enabled"] = false
        replacement["privateTerms"] = ["Fixture Person"]
        let replaced = try await call("POST", ["revision": policy(removed)["revision"] as? Int ?? 0, "policy": replacement])
        precondition(replaced.0 == 200 && policy(replaced)["enabled"] as? Bool == false
                     && policy(replaced)["privateTerms"] as? [String] == ["Fixture Person"] && !AgentPolicyGate.enforcesEverywhere,
                     "The whole policy can be replaced: \(replaced)")
        print("Agent policy Remote API: read, add, turn off, remove, replace, conflicts and pairing passed")
    }

    /// One policy for every backend: the gate's decisions, Home's stricter layer, the push
    /// privacy scan, and a Claude tab that acts on the user's behalf still checking every call.
    @MainActor
    static func testAgentPolicyGate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("policy-gate-\(UUID())").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        var context = AgentPolicyContext.current(workdir: folder)
        context.repository = { _ in nil }
        var policy = AgentPolicyDocument.starter
        policy.rules.append(.init(id: "allow-make", effect: .allow, reason: "Imported.", commands: ["make"]))
        func gate(_ request: CantripHomeActionRequest, _ approval: CantripHomeApproval = .automatic,
                  guardrail: CantripHomeGuardrail? = nil, document: AgentPolicyDocument? = nil) -> AgentPolicyOutcome {
            AgentPolicyGate.decide(request, guardrail: guardrail, approval: approval, label: "Notes tab", workdir: folder,
                                   policy: document ?? policy, context: context)
        }

        precondition(gate(.shell("ls")) == .allow(by: "Act on my behalf"), "Act on my behalf runs what no rule covers")
        precondition(gate(.shell("ls"), .ask) == .prompt, "With Act on my behalf off, an uncovered command asks as before")
        precondition(gate(.init(kind: .read, paths: [folder + "/a"]), .ask) == .allow(by: "Read-only"), "Reads don't ask")
        precondition(gate(.shell("make test"), .ask).explicitlyAllowed, "An allow rule runs without the backend's prompt")
        guard case .deny(let reason, let by) = gate(.shell("rm -rf /opt/policy-fixture/x")) else {
            preconditionFailure("A delete outside the tab's folder is refused under Act on my behalf")
        }
        precondition(by == "Cantrip policy (deletes-outside-workspace)" && reason.contains("Don't try another way"),
                     "The refusal names the rule: \(by)")
        guard case .ask(let title, let detail, let scope, let source, _) = gate(.shell("gh release create v1")) else {
            preconditionFailure("An ask rule asks even under Act on my behalf")
        }
        precondition(title == "Notes tab wants to run `gh release create v1`" && detail.contains("rule publishing")
                     && scope.hasPrefix("policy:publishing|") && source == "Cantrip policy", "The card explains the rule: \(title) \(detail)")
        var off = policy
        off.enabled = false
        precondition(gate(.shell("rm -rf /opt/policy-fixture/x"), document: off) == .allow(by: "Act on my behalf"),
                     "A policy turned off checks nothing in regular tabs")

        // Home's rules are the stricter layer, whatever the policy allows.
        var allowAll = policy
        allowAll.rules.append(.init(id: "allow-all", effect: .allow, reason: "Imported.", commands: ["*"]))
        precondition(gate(.shell("killall Cantrip"), guardrail: .attended, document: allowAll)
                     == .deny(reason: CantripHomeActionPolicy.evaluate(.shell("killall Cantrip"), mode: .attended).reason,
                              by: "Cantrip Home policy"), "Home and child tabs keep Home's refusals")
        precondition(gate(.shell("killall Cantrip"), document: allowAll).explicitlyAllowed,
                     "Regular tabs follow the policy (the restart window is a user rule)")
        guard case .ask(_, _, _, let homeSource, _) = gate(.shell("git push origin main"), .ask, guardrail: .unattended) else {
            preconditionFailure("Unattended Home still pauses before a push")
        }
        precondition(homeSource == "Cantrip Home", "Home's own asks keep their source")
        guard case .deny(_, let denied) = gate(.shell("sudo ls"), guardrail: .attended, document: off) else {
            preconditionFailure("Home refuses sudo even with the policy off")
        }
        precondition(denied == "Cantrip Home policy", "Home's layer doesn't depend on the policy file")

        let activity = AgentPolicyGate.denialActivity(.shell("rm x"), reason: reason, by: by)
        precondition(activity.state == .failed && activity.title == "Blocked by \(by)"
                     && activity.output?.contains("Don't try another way") == false && activity.input == "rm x",
                     "The tab shows a failed step with the reason")

        // Privacy scan of outgoing commits.
        let log = "\u{0}abcdef1234567\u{1}Example Bot <bot@users.noreply.github.com>\n"
            + "+let host = \"10.1.2.3\" // ok\n+contact: someone@example.org\n+url: box.tail1234ab.ts.net\n"
            + "+fine: bot@users.noreply.github.com and test@example.com\n+says Fixture Person\n"
        let scan = AgentPolicyPrivacyScan.scan(log: log, privateTerms: ["Fixture Person"])
        precondition(scan.commits == 1 && scan.findings.count == 4
                     && scan.summary.contains("private network address: 10.1.2.3")
                     && scan.summary.contains("email address: someone@example.org")
                     && scan.summary.contains("tailnet name") && scan.summary.contains("private term: \"Fixture Person\"")
                     && !scan.summary.contains("noreply"), "The scan finds private details: \(scan.summary)")
        precondition(AgentPolicyPrivacyScan.scan(log: "\u{0}abc\u{1}Bot <b@example.com>\n+clean line\n", privateTerms: [])
                        .summary.contains("nothing private found"), "A clean push says so")

        try await testAgentPolicyClaudeTab(folder)
        print("Agent policy gate: decisions, Home layer, privacy scan and a Claude tab on Act on my behalf passed")
    }

    /// A regular Claude tab with Act on my behalf still launches bypassPermissions, but registers
    /// Cantrip's PreToolUse hook: a delete outside its folder is refused with a visible step, an
    /// ordinary command passes without a prompt, and an ask rule shows Cantrip's card.
    @MainActor
    private static func testAgentPolicyClaudeTab(_ folder: String) async throws {
        let settings = AppSettings.shared
        let saved = (settings.claudePath, settings.allowActions, settings.claudePermissionMode)
        defer { (settings.claudePath, settings.allowActions, settings.claudePermissionMode) = saved }
        let script = URL(fileURLWithPath: folder).appendingPathComponent("claude-policy-fixture")
        try Data(#"""
        #!/usr/bin/env node
        const readline=require('readline');const results=[];let hooked=null;
        const emit=x=>process.stdout.write(JSON.stringify(x)+'\n');
        const args=process.argv.slice(2).join(' ');
        const mode=(args.match(/--permission-mode (\S+)/)||[])[1]||'none';
        const calls=[['Bash',{command:'rm -rf /opt/policy-fixture/x'}],['Bash',{command:'ls -la'}],
          ['Bash',{command:'gh release create v1'}],['Bash',{command:'make test'}]];
        const next=()=>{const call=calls[results.length];
          if(!call){emit({type:'stream_event',event:{type:'content_block_delta',delta:{type:'text_delta',text:mode+':'+results.join(',')}}});emit({type:'result',is_error:false});return;}
          emit({type:'control_request',request_id:'hook-'+results.length,request:{subtype:'hook_callback',callback_id:hooked,
            input:{hook_event_name:'PreToolUse',tool_name:call[0],tool_input:call[1]},tool_use_id:'tool-'+results.length}});};
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const value=JSON.parse(line);
          if(value.type==='control_request'&&value.request.subtype==='initialize'){
            hooked=value.request.hooks.PreToolUse[0].hookCallbackIds[0];
          } else if(value.type==='user'){ if(!hooked){emit({type:'stream_event',event:{type:'content_block_delta',delta:{type:'text_delta',text:'unhooked'}}});emit({type:'result',is_error:false});return;} next(); }
          else if(value.type==='control_response'){
            const out=value.response.response;
            results.push(out.hookSpecificOutput?out.hookSpecificOutput.permissionDecision:(out.continue?'continue':'?'));
            next();
          }
        });
        """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        settings.claudePath = script.path
        settings.claudePermissionMode = "default"

        func run(allowActions: Bool) async throws -> (text: String, prompts: [String], blocked: [ToolActivity]) {
            settings.allowActions = allowActions
            let backend = ClaudeCodeBackend(persistKey: "test-policy-claude-\(UUID())")
            backend.guardrailLabel = "Notes tab"
            defer { backend.reset() }
            final class Box { var text = "", done = false, prompts: [String] = [], blocked: [ToolActivity] = [] }
            let box = Box()
            backend.send(BackendRequest(prompt: "go", userMessage: "go", previousTurns: []), workdir: folder) { event in
                DispatchQueue.main.async {
                    switch event {
                    case .textDelta(let text): box.text += text
                    case .activity(let activity) where activity.toolName == "Cantrip policy": box.blocked.append(activity)
                    case .inputRequired(let request):
                        box.prompts.append(request.snapshot.title)
                        try? request.respond(.init(decision: .approve))
                    case .done, .failure: box.done = true
                    default: break
                    }
                }
            }
            try await waitForJournalTest { box.done }
            return (box.text, box.prompts, box.blocked)
        }

        try await withAgentPolicy(rules: AgentPolicyRule.starter + [
            .init(id: "allow-make", effect: .allow, reason: "Imported.", commands: ["make"]),
        ]) {
            let automatic = try await run(allowActions: true)
            precondition(automatic.text == "bypassPermissions:deny,continue,allow,allow",
                         "Act on my behalf: bypass mode, yet the hook refuses the delete and asks before publishing: \(automatic.text)")
            precondition(automatic.prompts == ["Notes tab wants to run `gh release create v1`"], "One card: \(automatic.prompts)")
            precondition(automatic.blocked.count == 1 && automatic.blocked[0].title == "Blocked by Cantrip policy (deletes-outside-workspace)",
                         "The refusal shows in the tab")
            let asking = try await run(allowActions: false)
            precondition(asking.text == "none:deny,continue,allow,allow",
                         "Act on my behalf off: uncovered commands follow Claude's own flow; the allow rule skips it: \(asking.text)")
        }
        try await withAgentPolicy(enabled: false) {
            let unchecked = try await run(allowActions: true)
            precondition(unchecked.text == "unhooked", "With the policy off, regular tabs launch without the hook")
        }
    }
}
