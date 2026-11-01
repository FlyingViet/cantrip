import Foundation

// Importing each CLI's rules, the overlap report, deny rules written back into each CLI, and the
// Terminal hook helper. A temporary folder stands in for the home folder.
func testImportAndBackstops() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("agent-policy-import-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let home = root.path
    let files = AgentPolicyFiles(home: home)
    func write(_ path: String, _ text: String) {
        let url = root.appendingPathComponent(path)
        try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }
    write(".claude/settings.json", #"""
    {"model": "opus", "permissions": {"allow": ["Bash(*)", "Bash(curl:*)", "Write(*)", "Edit(*)", "mcp__tracker__*",
     "WebSearch", "WebFetch", "Workflow", "Read(//etc/hosts)", "Read(/relative-to-settings)"],
     "deny": ["Bash(shutdown:*)"]}}
    """#)
    write(".copilot/permissions-config.json", #"""
    {"locations": {"\#(home)": {"tool_approvals": [
      {"kind": "commands", "commandIdentifiers": ["git -C", "printf"]}, {"kind": "write"},
      {"kind": "commands", "commandIdentifiers": ["kill", "sleep"]}, {"kind": "commands", "commandIdentifiers": ["git push"]},
      {"kind": "url", "url": "https://example.com"}]},
     "\#(home)/Coding/app": {"tool_approvals": [{"kind": "commands", "commandIdentifiers": ["make"]}]}}}
    """#)
    write(".codex/config.toml", "model = \"x\"\n")
    write(".codex/rules/default.rules", #"prefix_rule(pattern = ["git", "status"], decision = "allow")"# + "\n")
    write(".gemini/antigravity-cli/settings.json", #"{"trustedWorkspaces": ["/tmp"]}"#)

    var document = AgentPolicyDocument.starter
    document.rules += [
        .init(id: "no-store-cli", effect: .deny, reason: "Install apps another way.", commands: ["mas"]),
        .init(id: "public-push", effect: .ask, reason: "Check first.", commands: ["git push"], repos: ["app"]),
        .init(id: "late-restart", effect: .deny, reason: "Tasks run now.", commands: ["@cantrip-restart"], hours: ["21:45-22:50"]),
        .init(id: "notes-server", effect: .deny, reason: "Off limits.", mcp: ["notes"]),
    ]
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let notes = AgentPolicyImport.importMissing(into: &document, files: files, now: now)
    check(notes.count == 4 && document.imports.map(\.source) == ["claude", "copilot", "codex", "antigravity"], "four imports: \(notes)")
    let ids = Set(document.rules.map(\.id))
    for id in ["claude-bash", "claude-bash-curl", "claude-write", "claude-edit", "claude-mcp-tracker", "claude-websearch",
               "claude-workflow", "claude-read-etc-hosts", "claude-deny-bash-shutdown", "copilot-git-c-printf", "copilot-write",
               "copilot-kill-sleep", "copilot-git-push", "codex-git-status"] {
        check(ids.contains(id), "imported \(id): \(ids.sorted())")
    }
    check(!ids.contains(where: { $0.contains("relative") }), "paths relative to Claude's settings file are skipped")
    check(document.projects.first?.path == home + "/Coding/app" && document.projects.first?.rules.first?.commands == ["make"],
          "folder approvals become that folder's override")
    check(document.rules.first { $0.id == "claude-bash" }?.commands == ["*"], "Bash(*) allows every command")
    check(document.rules.first { $0.id == "claude-deny-bash-shutdown" }?.effect == .deny, "the CLI's own deny rules stay denies")
    check(document.rules.first { $0.id == "claude-bash" }?.source?.contains("~/.claude/settings.json: Bash(*)") == true,
          "each rule names where it came from")
    for record in document.imports where record.source != "codex" {
        check(record.backup.map { fm.fileExists(atPath: $0) } == true, "\(record.source) was backed up first")
    }
    check(document.imports.first { $0.source == "antigravity" }?.rules == 0, "Antigravity had nothing to import")
    check(AgentPolicyImport.importMissing(into: &document, files: files, now: now).isEmpty, "each CLI imports once")
    check(document.validationErrors().isEmpty, "imported rules are valid: \(document.validationErrors())")

    // Nothing that ran without a prompt starts asking; the stricter rules still win.
    var context = AgentPolicyContext(home: home, worktree: home + "/Coding/app", project: home + "/Coding/app",
                                     temporaryRoots: ["/tmp"])
    context.repository = { $0.hasPrefix(home + "/Coding/app") ? AgentPolicyRepository(root: home + "/Coding/app", remote: nil) : nil }
    func verdict(_ command: String) -> String {
        let decision = document.evaluate(.shell(command), context: context)
        return "\(decision.verdict.rawValue):\(decision.ruleID)"
    }
    check(verdict("swift build") == "allow:claude-bash", "ordinary commands stay allowed: \(verdict("swift build"))")
    check(verdict("mas list") == "deny:no-store-cli" && verdict("sudo ls") == "deny:admin-commands", "denies win over Bash(*)")
    check(verdict("git push") == "ask:public-push", "the public-repo push still asks")
    check(document.evaluate(.write(home + "/Coding/app/a.swift"), context: context).ruleID == "claude-write", "writes stay allowed")

    let conflicts = AgentPolicyImport.conflicts(document)
    func conflict(_ imported: String, _ stricter: String) -> Bool {
        conflicts.contains { $0.imported == imported && $0.stricter == stricter }
    }
    check(conflict("claude-bash", "no-store-cli") && conflict("claude-bash", "admin-commands")
          && conflict("claude-bash", "deletes-outside-workspace") && conflict("copilot-kill-sleep", "home-stop-cantrip (built in)")
          && conflict("copilot-git-push", "public-push") && conflict("claude-mcp-tracker", "outbound-messages")
          && !conflict("claude-mcp-tracker", "notes-server") && !conflict("copilot-git-c-printf", "no-store-cli"),
          "overlaps are reported: \(conflicts.map { "\($0.imported)>\($0.stricter)" })")

    // Deny rules go back into each CLI's own configuration.
    write(".claude/settings.json", #"{"model": "opus", "permissions": {"allow": ["Bash(*)"], "deny": ["Bash(shutdown:*)"]}}"#)
    try! fm.createDirectory(at: files.copilotFolder, withIntermediateDirectories: true)
    AgentPolicyBackstop.apply(&document, files: files, executable: "/Applications/Example.app/Contents/MacOS/Example", now: now)
    let claude = AgentPolicyImport.json(files.claudeSettings)!
    let deny = (claude["permissions"] as! [String: Any])["deny"] as! [String]
    for entry in ["Bash(shutdown:*)", "Bash(mas)", "Bash(mas *)", "Bash(sudo)", "Bash(sudo *)", "Bash(simctl create *)",
                  "Bash(xcrun simctl create *)", "mcp__notes"] {
        check(deny.contains(entry), "Claude deny list has \(entry): \(deny)")
    }
    check(!deny.contains(where: { $0.contains("@cantrip") || $0.contains("re:") }), "rules Claude can't express stay host-only")
    check(claude["model"] as? String == "opus" && (claude["permissions"] as! [String: Any])["allow"] as? [String] == ["Bash(*)"],
          "the rest of Claude's settings is untouched")
    check(try! fm.contentsOfDirectory(atPath: files.backups.path).contains { $0.hasPrefix("claude-before-deny") }, "backed up before writing")
    let codex = try! String(contentsOf: files.codexRules, encoding: .utf8)
    check(codex.hasPrefix("# \(AgentPolicyBackstop.marker)") && codex.contains(#"prefix_rule(pattern = ["mas"], decision = "forbidden""#)
          && codex.contains(#"["xcrun", "simctl", "erase"]"#) && !codex.contains("cantrip-restart"), "Codex rules file: \(codex)")
    let hook = AgentPolicyImport.json(files.copilotHooks)!
    let entry = ((hook["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]])[0]
    check(hook["version"] as? Int == 1 && (entry["bash"] as! String).hasSuffix("policy-hook' copilot"), "Copilot hook file: \(hook)")
    let helper = try! String(contentsOf: files.hookHelper, encoding: .utf8)
    check(helper.contains("CANTRIP_POLICY_HOST") && helper.contains("--cantrip-policy-hook"), "helper script")

    // A rule turned off disappears from the CLIs; the user's own entries stay.
    document.rules = document.rules.map { var rule = $0; if rule.id == "no-store-cli" { rule.enabled = false }; return rule }
    AgentPolicyBackstop.apply(&document, files: files, executable: "/Applications/Example.app/Contents/MacOS/Example", now: now)
    let after = ((AgentPolicyImport.json(files.claudeSettings)!["permissions"] as! [String: Any])["deny"] as! [String])
    check(!after.contains("Bash(mas)") && after.contains("Bash(shutdown:*)") && after.contains("Bash(sudo)"), "stale entries go: \(after)")
    check(!(try! String(contentsOf: files.codexRules, encoding: .utf8)).contains(#"["mas"]"#), "Codex rules follow")
    write(".codex/rules/cantrip.rules", "# my own rules\n")
    check(AgentPolicyBackstop.apply(&document, files: files, executable: nil, now: now).contains { $0.contains("left") }
          && (try! String(contentsOf: files.codexRules, encoding: .utf8)) == "# my own rules\n", "a rules file Cantrip didn't write is left alone")

    // The Terminal hook: deny rules only, in each CLI's answer format.
    let store = AgentPolicyStore(url: root.appendingPathComponent("policy.json"))
    try! store.save(document, basedOn: nil)
    func ask(_ client: String, _ json: String) -> String {
        AgentPolicyBackstop.runHelper(client: client, input: Data(json.utf8), store: store)
    }
    let denied = ask("copilot", #"{"tool_name":"Bash","tool_input":{"command":"sudo ls"},"cwd":"/tmp"}"#)
    check(denied.contains(#""permissionDecision":"deny""#) && denied.contains("hookSpecificOutput") && denied.contains("admin-commands"),
          "a denied Copilot call: \(denied)")
    check(ask("copilot", #"{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp"}"#) == "{}", "other calls are left to the CLI")
    check(ask("copilot", #"{"toolName":"bash","toolArgs":"{\"command\":\"sudo ls\"}","cwd":"/tmp"}"#).contains("deny"), "camelCase payloads too")
    check(ask("copilot", #"{"tool_name":"Bash","tool_input":{"command":"npm publish"}}"#) == "{}", "asks aren't enforced in Terminal")
    check(ask("antigravity", #"{"toolCall":{"name":"run_command","args":{"CommandLine":"sudo ls","Cwd":"/tmp"}}}"#)
            .contains(#""decision":"deny""#), "Antigravity's format")
    check(ask("antigravity", #"{"toolCall":{"name":"view_file","args":{"AbsolutePath":"/tmp/a"}}}"#) == #"{"decision":"allow"}"#, "agy allow")
    check(ask("copilot", "not json") == "{}", "unreadable input never blocks a CLI")
    print("Agent policy import: CLI rules, backups, overlaps, native deny rules and the Terminal hook passed")
}
