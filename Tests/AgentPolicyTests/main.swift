import Foundation

// Agent policy: rule matching, precedence, project overrides and storage. Fixture paths only.

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    if !condition {
        print("FAILED (line \(line)): \(message())")
        exit(1)
    }
}

let home = "/Users/fixture"
let app = home + "/Coding/app"
let other = home + "/Coding/other"
var author = "Someone Else <someone@example.com>"
var context = AgentPolicyContext(
    home: home, worktree: app, project: app,
    temporaryRoots: ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", "/var/folders/xy/T"]
)
context.repository = { folder in
    if folder == app || folder.hasPrefix(app + "/") {
        return AgentPolicyRepository(root: app, remote: "git@github.com:example/app.git")
    }
    if folder == other || folder.hasPrefix(other + "/") {
        return AgentPolicyRepository(root: other, remote: "https://github.com/example/other.git")
    }
    return nil
}
context.gitAuthor = { _ in author }
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "UTC")!
context.calendar = calendar
func at(_ hour: Int, _ minute: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: hour, minute: minute))!
}
context.now = at(12, 0)

let personal: [AgentPolicyRule] = [
    .init(id: "no-store-cli", effect: .deny, reason: "Install apps another way.", commands: ["mas"]),
    .init(id: "keychain-lock", effect: .deny, reason: "Keep the keychain unlocked for builds.",
          commands: [#"re:^security set-keychain-settings\b.*\s-[a-z]*[lu]"#]),
    .init(id: "restart-window", effect: .deny, reason: "Scheduled tasks are running.",
          commands: ["@cantrip-restart"], hours: ["21:45-22:50", "23:30-00:30"]),
    .init(id: "notes-read-only", effect: .deny, reason: "The notes server is read-only.",
          mcp: ["notes/*"], verbs: AgentPolicyRule.mutatingVerbs),
    .init(id: "secrets", effect: .deny, reason: "Ask for secrets by name.", paths: ["~/.secrets"], access: .any),
    .init(id: "public-author", effect: .deny, reason: "Commit as the bot.", commands: ["git commit"],
          repos: ["example/app"], unlessGitAuthor: "Example Bot"),
    .init(id: "public-push", effect: .ask, reason: "Check outgoing commits first.", commands: ["git push"],
          repos: ["app"], privacyScan: true),
    .init(id: "imported-shell", effect: .allow, reason: "Imported.", source: "imported", commands: ["*"]),
    .init(id: "imported-web", effect: .allow, reason: "Imported.", tools: ["WebFetch", "WebSearch"]),
    .init(id: "imported-writes", effect: .allow, reason: "Imported.", kinds: ["write"]),
]
var policy = AgentPolicyDocument(rules: AgentPolicyRule.starter + personal)

func decide(_ request: CantripHomeActionRequest, _ document: AgentPolicyDocument? = nil,
            in ctx: AgentPolicyContext? = nil) -> AgentPolicyDecision {
    (document ?? policy).evaluate(request, context: ctx ?? context)
}
func shell(_ command: String, cwd: String? = nil) -> AgentPolicyDecision {
    var request = CantripHomeActionRequest.shell(command)
    request.cwd = cwd
    return decide(request)
}
func expect(_ command: String, _ verdict: AgentPolicyDecision.Verdict, _ rule: String? = nil, line: Int = #line) {
    let decision = shell(command)
    check(decision.verdict == verdict && (rule == nil || decision.ruleID == rule),
          "\(command) → \(decision.verdict) \(decision.ruleID), wanted \(verdict) \(rule ?? "")", line: line)
}

// Precedence: deny beats ask beats allow; imported `*` allows the rest.
expect("ls -la", .allow, "imported-shell")
expect("sudo ls", .deny, "admin-commands")
expect("env FOO=1 sudo ls", .deny, "admin-commands")
expect("bash -c 'sudo rm x'", .deny, "admin-commands")
expect(#"osascript -e 'do shell script "id" with administrator privileges'"#, .deny, "admin-commands")
expect("mas install 123", .deny, "no-store-cli")
expect("nohup mas list", .deny, "no-store-cli")
expect("timeout 30 mas list", .deny, "no-store-cli")
expect("brew install mas", .allow)
expect("massage --help", .allow)
expect("cd /tmp && mas list", .deny, "no-store-cli")
expect("echo $(mas list)", .deny, "no-store-cli")

// Deletes stay inside the tab's folder, its project and temporary folders.
expect("rm -rf build", .allow)
expect("rm -rf ./build/*", .allow)
expect("rm /Users/fixture/Desktop/a.txt", .deny, "deletes-outside-workspace")
expect("rm ~/Desktop/a.txt", .deny, "deletes-outside-workspace")
expect("cd /Users/fixture/Desktop && rm a.txt", .deny, "deletes-outside-workspace")
expect("cd build && rm -rf ../../other", .deny, "deletes-outside-workspace")
expect("rm -rf /Users/fixture/Coding/app", .deny, "deletes-outside-workspace")
expect("rm -rf /tmp/scratch /private/var/folders/xy/T/x", .allow)
expect("rm -rf \"$TMPDIR/x\"", .allow)
expect("rm -rf $OUT/x", .allow)
expect("find . -name '*.o' -delete", .allow)
expect("find /Users/fixture/Desktop -name '*.log' -delete", .deny, "deletes-outside-workspace")
expect("find ~/Library/Logs -name x -exec rm {} +", .deny, "deletes-outside-workspace")
expect("bash -c \"rm -rf /Users/fixture/Desktop/x\"", .deny, "deletes-outside-workspace")
expect("bash <<'EOF'\nrm -rf /Users/fixture/Desktop/x\nEOF", .deny, "deletes-outside-workspace")
expect("cat <<'EOF' > notes.txt\nrm -rf /Users/fixture/Desktop/x\nEOF", .allow)
expect("mv ~/Downloads/a.zip vendor/", .allow)
expect("rsync -a --delete dist/ /Users/fixture/Sites/app/", .deny, "deletes-outside-workspace")
check(shell("rm /Users/fixture/Desktop/a.txt").denial.contains("deletes-outside-workspace"), "denial names the rule")
var childContext = context
childContext.worktree = home + "/.cache/Cantrip/worktrees/ABC"
childContext.project = childContext.worktree
check(decide(.shell("rm -rf /Users/fixture/Coding/app/build"), in: childContext).verdict == .deny,
      "a child tab can't delete in the parent's checkout")
check(decide(.shell("rm -rf build"), in: childContext).verdict == .allow, "a child tab deletes in its own checkout")

// Wrappers and the shared Simulator.
expect("xcrun simctl create Test com.apple.CoreSimulator.SimDeviceType.iPhone-17", .deny, "simulator-lifecycle")
expect("sudo -u root timeout 5 xcrun simctl delete all", .deny, "admin-commands")
expect("timeout 5 xcrun --sdk iphoneos simctl erase all", .deny, "simulator-lifecycle")
expect("xcrun simctl list devices", .allow)

// Asks: publishing, production data, outbound messages.
expect("gh release create v1.0 dist/app.zip", .ask, "publishing")
expect("npx eas submit -p ios", .ask, "publishing")
expect("xcrun altool --upload-app -f app.ipa", .ask, "publishing")
expect("gh release view v1.0", .allow)
expect("supabase db push", .ask, "production-data")
expect("psql \"$PROD_URL\" -c 'select 1'", .ask, "production-data")
expect("messages-send --detect someone@example.com", .allow)
expect("messages-send someone@example.com 'hi'", .ask, "outbound-messages")
expect(#"osascript -e 'tell application "Messages" to send "hi" to buddy "x"'"#, .ask, "outbound-messages")
check(decide(.init(kind: .mcp, server: "chat", tool: "send_message")).ruleID == "outbound-messages", "MCP send asks")
check(decide(.init(kind: .mcp, server: "chat", tool: "sendMessage")).ruleID == "outbound-messages", "camelCase send asks")
check(decide(.init(kind: .mcp, server: "notes", tool: "notes_search")).verdict == .none, "a read tool needs no rule")
check(decide(.init(kind: .mcp, server: "notes", tool: "create_note")).ruleID == "notes-read-only", "read-only server")
check(decide(.init(kind: .mcp, server: "agent_chrome", tool: "click")).verdict == .none, "other servers are unaffected")

// Keychain settings and time windows.
expect("security set-keychain-settings -lut 7200 login.keychain", .deny, "keychain-lock")
expect("security set-keychain-settings -t 3600 login.keychain", .allow)
context.now = at(22, 0)
expect("killall Cantrip", .deny, "restart-window")
expect(#"osascript -e 'tell application "Cantrip" to quit'"#, .deny, "restart-window")
expect("make -C ~/Coding/Cantrip run", .deny, "restart-window")
expect("killall Cantrip Gateway", .allow)
context.now = at(0, 10)
expect("killall Cantrip", .deny, "restart-window")
context.now = at(23, 0)
expect("killall Cantrip", .allow)
context.now = at(12, 0)

// Paths, tools and kinds.
expect("cat ~/.secrets/token", .deny, "secrets")
check(decide(CantripHomeActionRequest(claudeTool: "Read", input: ["file_path": home + "/.secrets/token"])).ruleID == "secrets",
      "reading a secret file with a read tool")
check(decide(.write(home + "/.secrets/token")).ruleID == "secrets", "writing a secret file")
check(decide(.write(app + "/README.md")).ruleID == "imported-writes", "imported write allow")
check(decide(CantripHomeActionRequest(claudeTool: "WebFetch", input: ["url": "https://example.com"])).ruleID == "imported-web",
      "imported tool allow")
check(decide(CantripHomeActionRequest(claudeTool: "Read", input: ["file_path": app + "/a.swift"])).verdict == .none,
      "an ordinary read has no rule")

// Repositories and commit authors.
expect("git commit -m 'Fix'", .deny, "public-author")
expect("git -C /Users/fixture/Coding/other commit -m 'Fix'", .allow)
expect("git commit --author='Example Bot <bot@example.com>' -m x", .allow)
expect("GIT_AUTHOR_NAME='Example Bot' git commit -m x", .allow)
author = "Example Bot <bot@example.com>"
expect("git commit -m 'Fix'", .allow)
expect("cd ../other && git push", .allow)
let push = shell("git push origin main")
check(push.verdict == .ask && push.rule?.privacyScan == true && push.directory == app, "public push asks with a scan")
expect("git -C /Users/fixture/Coding/app push", .ask, "public-push")
check(shell("git push", cwd: other).verdict == .allow, "a tool call's own folder decides the repository")

// Project overrides: in the folder they cover, rules can be turned off or added.
policy.projects = [
    AgentPolicyProject(path: "~/Coding/app", rules: [
        .init(id: "app-no-deploy", effect: .deny, reason: "Deploys go through CI.", commands: ["fly deploy"]),
    ], disabled: ["no-store-cli"]),
]
expect("mas list", .allow)
expect("fly deploy", .deny, "app-no-deploy")
var elsewhere = context
elsewhere.worktree = other
elsewhere.project = other
check(decide(.shell("mas list"), in: elsewhere).ruleID == "no-store-cli", "other folders keep the Mac-wide rule")
check(decide(.shell("fly deploy"), in: elsewhere).verdict == .allow, "project rules stay in their project")
policy.projects = []

var disabled = policy
disabled.rules = disabled.rules.map { var rule = $0; if rule.id == "no-store-cli" { rule.enabled = false }; return rule }
check(decide(.shell("mas list"), disabled).ruleID == "imported-shell", "a disabled rule doesn't apply")

// Validation.
var broken = AgentPolicyDocument(rules: [
    .init(id: "a", effect: .deny, reason: "", commands: ["x"]),
    .init(id: "a", effect: .deny, reason: "r"),
    .init(id: "b", effect: .deny, reason: "r", commands: ["re:("], hours: ["7:45"]),
    .init(id: "c", effect: .deny, reason: "r", commands: ["@nothing"]),
])
broken.projects = [AgentPolicyProject(path: "relative")]
let errors = broken.validationErrors().joined(separator: "\n")
for fragment in ["a has no reason", "share the ID a", "matches nothing", "regular expression", "hours must", "named command group", "full folder path"] {
    check(errors.contains(fragment), "validation mentions \(fragment): \(errors)")
}
check(AgentPolicyDocument.starter.validationErrors().isEmpty, "starter rules are valid")
check(policy.validationErrors().isEmpty, "fixture rules are valid: \(policy.validationErrors())")

// Decoding fills defaults; storage keeps revisions and the last good copy.
let minimal = #"{"rules":[{"id":"x","effect":"deny","reason":"r","commands":["mas"]}]}"#
let decoded = try! AgentPolicyStore.decoder.decode(AgentPolicyDocument.self, from: Data(minimal.utf8))
check(decoded.enabled && decoded.rules[0].enabled && decoded.version == 1 && decoded.projects.isEmpty, "defaults fill in")

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-policy-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: folder) }
let store = AgentPolicyStore(url: folder.appendingPathComponent("policy.json"))
check(!store.exists && store.current() == .starter, "a missing file means the starter rules")
let first = try! store.update { $0.rules.append(personal[0]) }
check(first.revision == 1 && store.current().rules.contains { $0.id == "no-store-cli" }, "first save")
let second = try! store.save(first, basedOn: 1)
check(second.revision == 2, "second save bumps the revision")
do {
    try store.save(first, basedOn: 1)
    check(false, "a stale revision must fail")
} catch let error as AgentPolicyStore.SaveError {
    check(error.status == 409, "stale revision is a conflict")
}
do {
    try store.save(broken, basedOn: nil)
    check(false, "an invalid policy must not save")
} catch let error as AgentPolicyStore.SaveError {
    check(error.status == 400, "invalid policy is a bad request")
}
check(FileManager.default.fileExists(atPath: store.url.path + ".previous"), "the previous file is kept")
let permissions = (try! FileManager.default.attributesOfItem(atPath: store.url.path))[.posixPermissions] as! Int
check(permissions == 0o600, "the policy file is private")
Thread.sleep(forTimeInterval: 1.1)
try! Data("{ not json".utf8).write(to: store.url)
check(store.current().revision == 2 && store.loadError != nil, "a broken file keeps the last good policy")

// Speed: every tool call is checked, so evaluation must stay cheap.
let started = Date()
for index in 0..<2_000 {
    _ = shell("cd build && make -j8 && rm -rf out\(index) && git status && echo done | tee log.txt")
}
let perCall = Date().timeIntervalSince(started) / 2_000 * 1_000
check(perCall < 2, "evaluation takes \(perCall) ms per call")
print("Agent policy: matching, precedence, overrides, validation and storage passed (\(String(format: "%.3f", perCall)) ms per call)")
