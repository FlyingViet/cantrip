import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func names(_ matches: [BackendCommandFilter.Match]) -> [String] { matches.map(\.command.name) }

// Generic fixture shared with the clients' contract (no real skill names).
private let fixture: [BackendCommand] = [
    BackendCommand(name: "plan", description: "Create an implementation plan before coding", kind: .builtin,
                   source: "Copilot", inputHint: "prompt"),
    BackendCommand(name: "usage", description: "Display session usage metrics and statistics", kind: .builtin,
                   source: "Copilot"),
    BackendCommand(name: "model", description: "Select the AI model for this session", kind: .builtin,
                   source: "Copilot", inputHint: "model", availability: .cantrip,
                   note: BackendCommandPolicy.modelNote, action: "modelSettings"),
    BackendCommand(name: "allow-all", description: "Enable all permissions", kind: .builtin, source: "Copilot",
                   inputHint: "[on|off|show]", aliases: ["yolo"], availability: .unavailable,
                   note: BackendCommandPolicy.approvalsNote),
    BackendCommand(name: "fixture-skill", description: "Fixture project skill for tests", kind: .skill,
                   source: "Project", inputHint: "instructions for the skill"),
    BackendCommand(name: "review-helper", description: "Review the current diff", kind: .custom, source: "Personal"),
]

// MARK: When to suggest

do {
    expect(BackendCommandFilter.slashToken("/") == "", "a lone slash opens the full list")
    expect(BackendCommandFilter.slashToken("/PL") == "pl", "tokens are lowercased")
    expect(BackendCommandFilter.slashToken("/tmp/x") == nil, "a path is never a command")
    expect(BackendCommandFilter.slashToken("/Users") != nil, "a single word could still be a command")
    expect(BackendCommandFilter.slashToken("/plan x") == nil, "the list closes once arguments start")
    expect(BackendCommandFilter.slashToken(" /plan") == nil, "leading whitespace is not a command")
    expect(BackendCommandFilter.slashToken("/plan\n") == nil, "multi-line text is not a command")
    expect(BackendCommandFilter.slashToken("plan") == nil, "text without a slash is not a command")
}

// MARK: Matching and ranking (expected results from CONTRACT.md)

do {
    let all = BackendCommandFilter.matches(token: "", in: fixture)
    expect(names(all) == ["plan", "usage", "model", "fixture-skill", "review-helper", "allow-all"],
           "a lone slash lists everything in host order with unavailable rows last: \(names(all))")
    expect(BackendCommandFilter.defaultHighlight(token: "", matches: all) == nil, "nothing is preselected for a lone slash")

    let u = BackendCommandFilter.matches(token: "u", in: fixture)
    expect(names(u) == ["usage", "fixture-skill"], "/u: prefix first, then substring: \(names(u))")
    expect(BackendCommandFilter.defaultHighlight(token: "u", matches: u) == 0, "/u preselects usage")

    let pl = BackendCommandFilter.matches(token: "pl", in: fixture)
    expect(names(pl) == ["plan"], "/pl: \(names(pl))")

    let re = BackendCommandFilter.matches(token: "re", in: fixture)
    expect(names(re) == ["review-helper", "fixture-skill"], "/re: \(names(re))")
    expect(re.map(\.score) == [1, 3], "/re scores prefix 1 and substring 3")

    let yo = BackendCommandFilter.matches(token: "yo", in: fixture)
    expect(names(yo) == ["allow-all"] && yo.first?.score == 2, "/yo matches the alias")
    expect(BackendCommandFilter.defaultHighlight(token: "yo", matches: yo) == nil, "an unavailable row is never preselected")

    let exact = BackendCommandFilter.matches(token: "usage", in: fixture)
    expect(exact.first?.score == 0, "an exact name scores 0")
    let squashed = BackendCommandFilter.matches(token: "reviewhelper", in: fixture)
    expect(names(squashed) == ["review-helper"], "dashes are ignored for substring matches")
    let described = BackendCommandFilter.matches(token: "statis", in: fixture)
    expect(names(described) == ["usage"] && described.first?.score == 4, "description words match from 2 characters")
    expect(BackendCommandFilter.defaultHighlight(token: "statis", matches: described) == nil,
           "a description match is shown but Return still sends the text")
    expect(BackendCommandFilter.matches(token: "s", in: fixture).allSatisfy { $0.score != 4 },
           "single characters never match descriptions")
    expect(BackendCommandFilter.matches(token: "", in: fixture, limit: 2).count == 2, "the limit caps rows")
}

// MARK: Choosing

do {
    let usage = fixture[1], plan = fixture[0], model = fixture[2], allowAll = fixture[3]
    expect(BackendCommandFilter.choose(usage) == .insert(text: "/usage ", send: true), "a command without input runs")
    expect(BackendCommandFilter.choose(usage, viaTab: true) == .insert(text: "/usage ", send: false), "Tab only inserts")
    expect(BackendCommandFilter.choose(plan) == .insert(text: "/plan ", send: false), "a command with an input hint inserts")
    var required = usage
    required.requiresInput = true
    expect(BackendCommandFilter.choose(required) == .insert(text: "/usage ", send: false), "required input inserts")
    expect(BackendCommandFilter.choose(allowAll) == .none, "unavailable rows can't be chosen")
    expect(BackendCommandFilter.choose(model, canOpenModelSettings: true) == .openModelSettings,
           "/model opens the model settings when the client can")
    expect(BackendCommandFilter.choose(model) == .insert(text: "/model ", send: false),
           "/model inserts when the client has no model settings")
    let codexSkill = BackendCommandParsers.codex(["data": [["cwd": "/tmp/p", "skills": [
        ["name": "imagegen", "description": "Generate images", "scope": "system", "enabled": true, "path": "/x"],
    ]]]]).first
    expect(codexSkill.map { BackendCommandFilter.choose($0) } == .insert(text: "$imagegen ", send: false),
           "a Codex skill inserts its $mention and waits for instructions")
}

// MARK: Parsing sent prompts

do {
    let plan = SlashInvocation("/plan add a README")
    expect(plan?.name == "plan" && plan?.input == "add a README", "name and input split at the first space")
    expect(SlashInvocation("  /usage  ")?.name == "usage" && SlashInvocation("  /usage  ")?.input == "",
           "surrounding whitespace is ignored")
    expect(SlashInvocation("/model\ngpt-x")?.input == "gpt-x", "a newline also ends the name")
    expect(SlashInvocation("/Users/me/file.txt is broken") == nil, "a path is never a command")
    expect(SlashInvocation("/") == nil && SlashInvocation("plan") == nil, "no name, no command")
    let hidden = SlashInvocation("/allow-all\u{FEFF}on")
    expect(hidden?.name == "allow-all" && hidden?.input == "on", "a zero-width character can't hide a name")
    expect(SlashInvocation("\u{FEFF}/permissions")?.name == "permissions", "leading invisible characters are ignored")
    expect(SlashInvocation("/plugin:cmd x")?.name == "plugin:cmd", "plugin-style names keep their colon")
    expect(SlashInvocation("/allow-all!")?.name == "allow-all", "punctuation after a name doesn't hide it")

    // Aliases reach the same rule as the command they name.
    expect(BackendCommandPolicy.rule(family: .copilot, name: "cd", discovered: nil)?.availability == .unavailable,
           "/cd is /cwd")
    expect(BackendCommandPolicy.rule(family: .copilot, name: "loop", discovered: nil)?.availability == .unavailable,
           "Copilot's /loop is /every")
    expect(BackendCommandPolicy.rule(family: .copilot, name: "models", discovered: nil)?.action == "modelSettings",
           "/models is /model")
    expect(BackendCommandPolicy.rule(family: .claudeCode, name: "new", discovered: nil)?.action == "startFresh"
           && BackendCommandPolicy.rule(family: .claudeCode, name: "reset", discovered: nil)?.action == "startFresh",
           "Claude's /new and /reset are /clear")
    expect(BackendCommandPolicy.rule(family: .claudeCode, name: "loop", discovered: nil) == nil, "Claude's own /loop runs")
    let aliased = BackendCommand(name: "sandbox", description: "", kind: .builtin, source: "Copilot", aliases: ["sbx"])
    expect(BackendCommandPolicy.rule(family: .copilot, name: "sbx", discovered: aliased)?.availability == .unavailable,
           "a discovered alias resolves to its blocked command")
    let automatic = BackendCommand(name: "auto-skill", description: "", kind: .skill, source: "Copilot",
                                   availability: .unavailable, note: BackendCommandPolicy.automaticSkillNote)
    expect(BackendCommandPolicy.rule(family: .copilot, name: "auto-skill", discovered: automatic)?.note
           == BackendCommandPolicy.automaticSkillNote, "a discovered unavailable command is refused with its note")
    let plain = BackendCommand(name: "plan", description: "", kind: .builtin, source: "Copilot")
    expect(BackendCommandPolicy.rule(family: .copilot, name: "plan", discovered: plain) == nil, "ordinary commands run")
    let blocked = BackendCommandPolicy.blockedNames(family: .copilot)
    expect(["allow-all", "yolo", "permissions", "cd", "cwd", "loop", "every", "model", "models"].allSatisfy { blocked[$0] != nil }
           && blocked["plan"] == nil && blocked["clear"] == nil, "the bridge refuses blocked names and their aliases")
}

// MARK: Copilot

do {
    let commands: [[String: Any]] = [
        ["name": "plan", "description": "Create a plan", "kind": "builtin", "input": ["hint": "prompt"],
         "allowDuringAgentExecution": true],
        ["name": "allow-all", "description": "Enable all permissions", "kind": "builtin",
         "aliases": ["yolo"], "allowDuringAgentExecution": true],
        ["name": "model", "description": "Select the AI model", "kind": "builtin", "input": ["hint": "model"]],
        ["name": "every", "description": "Schedule a recurring prompt", "kind": "builtin",
         "input": ["hint": "<interval> <prompt>", "required": true]],
        ["name": "fixture-skill", "description": "Fixture skill\nsecond line", "kind": "skill",
         "input": ["hint": "instructions for the skill"]],
        ["name": "fixture-cmd", "description": "Fixture command", "kind": "skill"],
        ["name": "client-only", "description": "Registered by an SDK client", "kind": "client"],
    ]
    let skills: [[String: Any]] = [
        ["name": "fixture-skill", "source": "project", "userInvocable": true, "enabled": true,
         "path": "/tmp/p/.github/skills/fixture-skill/SKILL.md"],
        ["name": "fixture-cmd", "source": "personal-agents", "userInvocable": true, "enabled": true,
         "path": "/tmp/home/.claude/commands/fixture-cmd.md"],
        ["name": "auto-skill", "description": "Used by the model on its own", "source": "builtin",
         "userInvocable": false, "enabled": true],
        ["name": "off-skill", "source": "builtin", "userInvocable": false, "enabled": false],
    ]
    let parsed = BackendCommandParsers.copilot(commands: commands, skills: skills)
    let byName = Dictionary(uniqueKeysWithValues: parsed.map { ($0.name, $0) })
    expect(byName["client-only"] == nil, "SDK client commands are not listed")
    expect(byName["plan"]?.availability == .runs && byName["plan"]?.inputHint == "prompt", "built-ins run with their hint")
    expect(byName["allow-all"]?.availability == .unavailable && byName["allow-all"]?.aliases == ["yolo"],
           "approval switches are unavailable")
    expect(byName["every"]?.availability == .unavailable && byName["every"]?.requiresInput == true,
           "scheduling dies with the idle runtime")
    expect(byName["model"]?.availability == .cantrip && byName["model"]?.action == "modelSettings",
           "/model maps to the tab's model settings")
    expect(byName["fixture-skill"]?.kind == .skill && byName["fixture-skill"]?.source == "Project",
           "project skills are labeled")
    expect(byName["fixture-skill"]?.description == "Fixture skill second line", "descriptions are one line")
    expect(byName["fixture-cmd"]?.kind == .custom && byName["fixture-cmd"]?.source == "Personal",
           "a command file is a custom command")
    expect(byName["auto-skill"]?.availability == .unavailable
           && byName["auto-skill"]?.note == BackendCommandPolicy.automaticSkillNote,
           "model-only skills are listed as automatic")
    expect(byName["off-skill"] == nil, "disabled automatic skills are not listed")

    let acp = BackendCommandParsers.acp([
        ["name": "context", "description": "Show context usage"],
        ["name": "allow-all", "description": "Enable all permissions", "input": ["hint": "[on|off]"]],
        ["name": "every", "description": "Schedule"],
        ["name": "fixture-skill", "description": "Fixture", "input": ["hint": "instructions for the skill"]],
    ])
    expect(acp.first { $0.name == "allow-all" }?.note == BackendCommandPolicy.acpApprovalsNote,
           "Copilot Remote approvals stay with Cantrip")
    expect(acp.first { $0.name == "every" }?.availability == .runs, "a long-lived ACP server can schedule")
    expect(acp.first { $0.name == "fixture-skill" }?.kind == .skill, "ACP skills are labeled")
}

// MARK: Claude Code

do {
    let response: [String: Any] = [
        "commands": [
            ["name": "compact", "description": "Free up context", "argumentHint": "<instructions>"],
            ["name": "clear", "description": "Start a new session", "argumentHint": "[name]"],
            ["name": "color", "description": "Set the prompt bar color", "argumentHint": "[red|blue]"],
            ["name": "fast", "description": "Toggle fast mode", "argumentHint": "[on|off]"],
            ["name": "loop", "description": "Run on an interval", "argumentHint": "[interval] [prompt]",
             "aliases": ["proactive"]],
            ["name": "__internal", "description": "Internal"],
            ["name": "agents", "description": "(removed) Ask Claude to manage subagents"],
            ["name": "proj-skill", "description": "Project skill. (project)", "argumentHint": ""],
            ["name": "proj-cmd", "description": "Project command (project)", "argumentHint": "topic"],
            ["name": "my-skill", "description": "Personal skill", "argumentHint": ""],
            ["name": "my-cmd", "description": "Personal command", "argumentHint": ""],
            ["name": "marked-skill", "description": "Marked personal skill. (user)", "argumentHint": ""],
        ],
        "account": ["tokenSource": "none"],
        "fast_mode_disabled_reason": "sdk_opt_in_required",
    ]
    let parsed = BackendCommandParsers.claude(response, personalSkills: ["my-skill"], personalCommands: ["my-cmd"],
                                              projectSkills: ["proj-skill"])
    let byName = Dictionary(uniqueKeysWithValues: parsed.commands.map { ($0.name, $0) })
    expect(parsed.signedIn == false, "a missing token means signed out")
    expect(byName["__internal"] == nil && byName["agents"] == nil, "internal and removed commands are hidden")
    expect(byName["compact"]?.availability == .runs && byName["compact"]?.kind == .builtin, "built-ins run")
    expect(byName["clear"]?.action == "startFresh", "/clear maps to Start Fresh")
    expect(byName["color"]?.availability == .unavailable, "/color has nothing to color")
    expect(byName["fast"]?.availability == .unavailable && byName["fast"]?.note?.contains("SDK") == true,
           "fast mode reports Claude's own reason")
    expect(byName["loop"]?.aliases == ["proactive"], "aliases are kept")
    expect(byName["proj-skill"]?.kind == .skill && byName["proj-skill"]?.source == "Project"
           && byName["proj-skill"]?.description == "Project skill.", "project skills drop the (project) suffix")
    expect(byName["proj-cmd"]?.kind == .custom && byName["proj-cmd"]?.inputHint == "topic", "project commands are custom")
    expect(byName["proj-skill"]?.inputHint == nil, "an empty argument hint means none")
    expect(byName["my-skill"]?.kind == .skill && byName["my-skill"]?.source == "Personal", "personal skills are labeled")
    expect(byName["my-cmd"]?.kind == .custom && byName["my-cmd"]?.source == "Personal", "personal commands are labeled")
    expect(byName["marked-skill"]?.source == "Personal" && byName["marked-skill"]?.kind == .skill
           && byName["marked-skill"]?.description == "Marked personal skill.", "a (user) suffix marks a personal skill")
    let signedIn = BackendCommandParsers.claude(["commands": [], "account": ["tokenSource": "claude.ai"]])
    expect(signedIn.signedIn == true, "a token source means signed in")
}

// MARK: Codex

do {
    let parsed = BackendCommandParsers.codex(["data": [["cwd": "/tmp/p", "errors": [], "skills": [
        ["name": "repo-skill", "description": "Long", "shortDescription": "Short", "scope": "repo", "enabled": true],
        ["name": "user-skill", "description": "User", "interface": ["shortDescription": "Interface"],
         "scope": "user", "enabled": true],
        ["name": "sys-skill", "description": "System", "scope": "system", "enabled": true],
        ["name": "off-skill", "description": "Off", "scope": "user", "enabled": false],
        ["name": "repo-skill", "description": "Duplicate", "scope": "user", "enabled": true],
    ]]]])
    let byName = Dictionary(uniqueKeysWithValues: parsed.map { ($0.name, $0) })
    expect(parsed.count == 4, "duplicates across folders appear once")
    expect(byName["repo-skill"]?.source == "Project" && byName["repo-skill"]?.description == "Short", "repo skill")
    expect(byName["user-skill"]?.source == "Personal" && byName["user-skill"]?.description == "Interface",
           "the interface description wins")
    expect(byName["sys-skill"]?.source == "Codex" && byName["sys-skill"]?.insert == "$sys-skill ", "system skill")
    expect(byName["sys-skill"]?.title == "$sys-skill" && fixture[0].title == "/plan", "rows show the inserted token")
    expect(byName["off-skill"]?.availability == .unavailable, "disabled skills are marked")
}

// MARK: Order, scripts, encoding

do {
    let ordered = BackendCommandPolicy.ordered([
        BackendCommand(name: "b-builtin", description: "", kind: .builtin, source: "Copilot"),
        BackendCommand(name: "a-skill", description: "", kind: .skill, source: "Project"),
        BackendCommand(name: "c-custom", description: "", kind: .custom, source: "Personal"),
        BackendCommand(name: "Dup", description: "", kind: .skill, source: "Project"),
        BackendCommand(name: "dup", description: "", kind: .builtin, source: "Copilot"),
    ] + BackendCommandParsers.cantripScripts([(name: "hello", description: "Example\nscript")]))
    expect(ordered.map(\.name) == ["c-custom", "a-skill", "Dup", "b-builtin", "hello"],
           "your commands, skills, built-ins, then Cantrip scripts, without duplicates: \(ordered.map(\.name))")
    expect(ordered.last?.kind == .cantrip && ordered.last?.source == "Cantrip"
           && ordered.last?.description == "Example script", "Cantrip scripts are labeled")

    let list = BackendCommandList(backend: "Copilot", workdir: "/tmp/p", status: nil, commands: fixture)
    let data = try! JSONEncoder().encode(list)
    let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    let first = (object["commands"] as! [[String: Any]])[1]
    expect(object.keys.contains("status") && object["status"] is NSNull, "status is always present")
    expect(first["inputHint"] is NSNull && first["note"] is NSNull && first["action"] is NSNull,
           "optional fields are explicit nulls")
    expect(first["insert"] as? String == "/usage " && first["availability"] as? String == "runs", "insert and availability")
    let decoded = try! JSONDecoder().decode(BackendCommandList.self, from: data)
    expect(decoded == list, "the list round-trips")
    let changed = BackendCommandList(backend: "Copilot", workdir: "/tmp/p", status: "x", commands: fixture)
    expect(changed.revision != list.revision, "the revision follows the content")
    expect(BackendCommandList(backend: "Copilot", workdir: "/other", status: nil, commands: fixture).revision
           == list.revision, "the revision ignores where it came from")
    expect(list.command(named: "YOLO")?.name == "allow-all", "lookup by alias, any case")
}

// MARK: Discovery against fake CLIs

let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cantrip-commands-\(UUID().uuidString)")
let home = root.appendingPathComponent("home")
let project = root.appendingPathComponent("project")
let bin = root.appendingPathComponent("bin")
defer { try? FileManager.default.removeItem(at: root) }
for directory in [home, project, bin, home.appendingPathComponent(".claude/skills/my-skill"),
                  project.appendingPathComponent(".claude/skills/proj-skill")] {
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

func script(_ name: String, _ body: String) -> String {
    let url = bin.appendingPathComponent(name)
    try! ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

var environment = ProcessInfo.processInfo.environment
environment["HOME"] = home.path

// Answers the initialize request with the request_id it was sent, after an unrelated line.
let fakeClaude = script("claude", #"""
read line
id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\1/')
echo '{"type":"system","subtype":"other"}'
printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"commands":[{"name":"my-skill","description":"Mine","argumentHint":""},{"name":"proj-skill","description":"P (project)","argumentHint":""},{"name":"compact","description":"Compact","argumentHint":""}],"account":{"tokenSource":"none"}}}}\n' "$id"
sleep 30
"""#)
do {
    let started = Date()
    let result = await BackendCommandDiscovery.claude(path: fakeClaude, workdir: project.path,
                                                      environment: environment, home: home.path)
    expect(result.commands.map(\.name) == ["my-skill", "proj-skill", "compact"], "Claude's initialize answer is read: \(result)")
    expect(result.commands.first?.source == "Personal" && result.commands.count > 1 && result.commands[1].kind == .skill,
           "folder names label personal and project skills")
    expect(result.status?.contains("isn't signed in") == true, "signed out is reported")
    expect(Date().timeIntervalSince(started) < 10, "discovery doesn't wait for the CLI to exit")
    let missing = await BackendCommandDiscovery.claude(path: nil, workdir: project.path,
                                                       environment: environment, home: home.path)
    expect(missing.commands.isEmpty && missing.status == "Claude Code isn't installed on this Mac.", "no Claude")
}

let fakeCodex = script("codex", #"""
[ "$1" = "app-server" ] || exit 3
while read line; do
  case "$line" in
    *'"skills/list"'*) echo '{"id":2,"result":{"data":[{"cwd":"x","errors":[],"skills":[{"name":"fake-skill","description":"Fake","scope":"repo","enabled":true,"path":"/p"}]}]}}' ;;
    *'"initialize"'*) echo '{"id":1,"result":{"userAgent":"fake"}}' ;;
  esac
done
"""#)
do {
    let result = await BackendCommandDiscovery.codex(command: fakeCodex, workdir: project.path, environment: environment)
    expect(result.commands.map(\.insert) == ["$fake-skill "], "Codex skills come from app-server: \(result)")
    let missing = await BackendCommandDiscovery.codex(command: bin.appendingPathComponent("nope").path,
                                                      workdir: project.path, environment: environment)
    expect(missing.status == "Codex isn't installed on this Mac.", "a missing Codex is reported: \(missing)")
}

do {
    let agySkillDir = project.appendingPathComponent(".agents/skills/agy-project-skill")
    try! FileManager.default.createDirectory(at: agySkillDir, withIntermediateDirectories: true)
    try! "---\nname: agy-project-skill\ndescription: Antigravity project skill fixture.\n---\n"
        .write(to: agySkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let result = await BackendCommandDiscovery.antigravity(command: "agy", workdir: project.path,
                                                           home: home.path, environment: environment)
    expect(result.commands.contains { $0.name == "plan" && $0.kind == .builtin && $0.source == "Antigravity" },
           "Antigravity built-in /plan command is listed: \(result)")
    expect(result.commands.contains { $0.name == "agy-project-skill" && $0.kind == .skill && $0.source == "Project" },
           "Antigravity discovers .agents/skills project skills: \(result)")
    expect(result.commands.first { $0.name == "clear" }?.availability == .cantrip,
           "Antigravity /clear routes to Cantrip Start Fresh: \(result)")
}

do {
    let fakeCopilot = script("copilot", "echo 'not copilot'\n")
    let result = await BackendCommandDiscovery.copilot(command: fakeCopilot, workdir: project.path,
                                                       environment: environment)
    expect(result.commands.isEmpty && result.status?.hasPrefix("Couldn't list Copilot's commands") == true,
           "a CLI that isn't Copilot is reported, not guessed: \(result)")
}

do {
    let silent = script("silent", "sleep 30\n")
    let started = Date()
    let outcome = await JSONLineProcess.run(silent, [], environment: environment, directory: project.path,
                                            input: [["x": 1]], timeout: 1) { _ in true }
    expect(outcome.timedOut && outcome.object == nil, "a silent CLI times out")
    expect(Date().timeIntervalSince(started) < 5, "the timeout is honored")
    let crash = script("crash", "echo 'boom: failed to start' >&2\nexit 4\n")
    let crashed = await JSONLineProcess.run(crash, [], environment: environment, directory: project.path,
                                            input: [], timeout: 5) { _ in true }
    expect(crashed.exitStatus == 4 && crashed.failureText == "boom: failed to start", "stderr explains a crash: \(crashed.failureText)")
}

// MARK: Fingerprint

do {
    let before = BackendCommandFingerprint.compute(workdir: project.path, home: home.path, environment: environment)
    expect(before == BackendCommandFingerprint.compute(workdir: project.path, home: home.path, environment: environment),
           "the fingerprint is stable")
    try? await Task.sleep(nanoseconds: 1_100_000_000)
    try! FileManager.default.createDirectory(at: project.appendingPathComponent(".claude/skills/new-skill"),
                                             withIntermediateDirectories: true)
    let added = BackendCommandFingerprint.compute(workdir: project.path, home: home.path, environment: environment)
    expect(added != before, "adding a project skill changes the fingerprint")
    try? await Task.sleep(nanoseconds: 1_100_000_000)
    try! FileManager.default.createDirectory(at: home.appendingPathComponent(".agents/skills/personal"),
                                             withIntermediateDirectories: true)
    expect(BackendCommandFingerprint.compute(workdir: project.path, home: home.path, environment: environment) != added,
           "adding a personal skill changes the fingerprint")
}

// MARK: Live CLIs (opt-in: CANTRIP_COMMANDS_LIVE_TEST=1; uses the real home, a temp project)

if ProcessInfo.processInfo.environment["CANTRIP_COMMANDS_LIVE_TEST"] == "1" {
    let live = root.appendingPathComponent("live")
    let skill = live.appendingPathComponent(".github/skills/live-fixture")
    try! FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try! "---\nname: live-fixture\ndescription: Live fixture skill.\n---\nSay LIVE-FIXTURE-OK.\n"
        .write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let real = ProcessInfo.processInfo.environment
    let started = Date()
    let copilot = await BackendCommandDiscovery.copilot(command: "", workdir: live.path, environment: real)
    print(String(format: "live copilot: %d commands in %.1f s, status %@", copilot.commands.count,
                 Date().timeIntervalSince(started), copilot.status ?? "none"))
    expect(copilot.commands.contains { $0.name == "plan" && $0.availability == .runs }, "live Copilot lists /plan")
    expect(copilot.commands.contains { $0.name == "live-fixture" && $0.source == "Project" }, "live Copilot lists the project skill")
    expect(copilot.commands.first { $0.name == "allow-all" }?.availability == .unavailable, "live /allow-all is blocked")
    let claudePath = ["\(NSHomeDirectory())/.local/bin/claude", "/opt/homebrew/bin/claude"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    if let claudePath {
        let claude = await BackendCommandDiscovery.claude(path: claudePath, workdir: live.path, environment: real,
                                                          home: NSHomeDirectory())
        print("live claude: \(claude.commands.count) commands, status \(claude.status ?? "none")")
        expect(claude.commands.contains { $0.name == "compact" }, "live Claude lists /compact")
    }
    if let codex = ProcessInfo.processInfo.environment["CANTRIP_COMMANDS_LIVE_CODEX"] {
        let result = await BackendCommandDiscovery.codex(command: codex, workdir: live.path, environment: real)
        print("live codex: \(result.commands.map(\.name)), status \(result.status ?? "none")")
        expect(result.commands.contains { $0.insert.hasPrefix("$") }, "live Codex lists skills as $mentions")
    }
}

if failures > 0 {
    fputs("\(failures) backend command test(s) failed\n", stderr)
    exit(1)
}
print("Backend command tests passed")
