import Foundation

/// Where each CLI keeps the rules Cantrip imports, and where Cantrip writes its deny rules back.
struct AgentPolicyFiles {
    var home: String

    static var current: Self { Self(home: FileManager.default.homeDirectoryForCurrentUser.path) }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: home).appendingPathComponent(path) }
    var claudeSettings: URL { url(".claude/settings.json") }
    var copilotFolder: URL { url(".copilot") }
    var copilotPermissions: URL { url(".copilot/permissions-config.json") }
    var copilotHooks: URL { url(".copilot/hooks/cantrip-policy.json") }
    var codexFolder: URL { url(".codex") }
    var codexRules: URL { url(".codex/rules/cantrip.rules") }
    var antigravitySettings: URL { url(".gemini/antigravity-cli/settings.json") }
    var backups: URL { url("Library/Application Support/Cantrip/policy-backups") }
    var hookHelper: URL { url(".cache/Cantrip/policy-hook") }
}

// MARK: - Importing each CLI's rules

/// Turns each CLI's own allow, ask and deny rules into policy rules, once per CLI, after backing
/// up the CLI's file, so nothing that runs without a prompt today starts asking.
enum AgentPolicyImport {
    struct Source {
        var key: String
        var name: String
        var file: URL
    }

    static func sources(_ files: AgentPolicyFiles) -> [Source] {
        [
            Source(key: "claude", name: "Claude Code", file: files.claudeSettings),
            Source(key: "copilot", name: "Copilot", file: files.copilotPermissions),
            Source(key: "codex", name: "Codex", file: files.codexFolder.appendingPathComponent("rules")),
            Source(key: "antigravity", name: "Antigravity", file: files.antigravitySettings),
        ]
    }

    /// Imports every CLI not imported yet. Returns what happened, for the log.
    @discardableResult
    static func importMissing(into document: inout AgentPolicyDocument, files: AgentPolicyFiles,
                              now: Date = Date()) -> [String] {
        var notes: [String] = []
        let done = Set(document.imports.map(\.source))
        for source in sources(files) where !done.contains(source.key) {
            var ids = Set((document.rules + document.projects.flatMap(\.rules)).map(\.id))
            var rules: [AgentPolicyRule] = []
            var projects: [AgentPolicyProject] = []
            var backup: String?
            let display = source.file.path.replacingOccurrences(of: files.home, with: "~")
            if FileManager.default.fileExists(atPath: source.file.path) {
                backup = try? self.backup(source.file, key: source.key, to: files.backups, now: now)
                switch source.key {
                case "claude", "antigravity":
                    if let object = json(source.file) {
                        rules = permissionRules(object["permissions"] as? [String: Any] ?? [:], prefix: source.key,
                                                cli: source.name, file: display, ids: &ids)
                    }
                case "copilot":
                    if let object = json(source.file) {
                        (rules, projects) = copilotRules(object, home: files.home, file: display, ids: &ids)
                    }
                case "codex":
                    let ruleFiles = (try? FileManager.default.contentsOfDirectory(at: source.file, includingPropertiesForKeys: nil)) ?? []
                    for file in ruleFiles.sorted(by: { $0.path < $1.path })
                    where file.pathExtension == "rules" && file.lastPathComponent != "cantrip.rules" {
                        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                        rules += codexRules(text, file: file.path.replacingOccurrences(of: files.home, with: "~"), ids: &ids)
                    }
                default:
                    break
                }
            }
            document.rules += rules
            for project in projects {
                if let index = document.projects.firstIndex(where: { $0.path == project.path }) {
                    document.projects[index].rules += project.rules
                } else {
                    document.projects.append(project)
                }
            }
            let count = rules.count + projects.reduce(0) { $0 + $1.rules.count }
            document.imports.append(AgentPolicyImportRecord(source: source.key, file: display, backup: backup,
                                                            importedAt: now, rules: count))
            notes.append("policy: imported \(count) rule(s) from \(source.name) (\(display))"
                         + (backup.map { ", backup \($0)" } ?? ""))
        }
        return notes
    }

    static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Copies `url` into the backups folder; returns the copy's path.
    static func backup(_ url: URL, key: String, to folder: URL, now: Date) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        let name = "\(key)-\(url.lastPathComponent)-\(formatter.string(from: now))"
        let target = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: url, to: target)
        return target.path
    }

    /// Claude Code's (and Antigravity's) `permissions` lists: "Bash(git push:*)", "Write(*)",
    /// "mcp__server__tool", "WebFetch".
    static func permissionRules(_ permissions: [String: Any], prefix: String, cli: String, file: String,
                                ids: inout Set<String>) -> [AgentPolicyRule] {
        var rules: [AgentPolicyRule] = []
        for (key, effect) in [("deny", AgentPolicyRule.Effect.deny), ("ask", .ask), ("allow", .allow)] {
            for entry in permissions[key] as? [String] ?? [] {
                guard var rule = claudeRule(entry, effect: effect) else { continue }
                rule.id = uniqueID("\(prefix)-\(effect == .allow ? "" : effect.rawValue + "-")\(slug(entry))", &ids)
                rule.source = "\(cli) \(file): \(entry)"
                let verb = effect == .allow ? "Allowed" : effect == .ask ? "Asked about" : "Denied"
                rule.reason = "\(verb) by \(cli)'s own settings (\(entry)) before Cantrip's policy."
                rules.append(rule)
            }
        }
        return rules
    }

    static func claudeRule(_ entry: String, effect: AgentPolicyRule.Effect) -> AgentPolicyRule? {
        var name = entry.trimmingCharacters(in: .whitespaces)
        var spec: String?
        if let open = name.firstIndex(of: "("), name.hasSuffix(")") {
            spec = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
            name = String(name[..<open])
        }
        var rule = AgentPolicyRule(id: "", effect: effect, reason: "")
        let any = spec == nil || spec == "*" || spec == "**" || spec == ""
        switch name {
        case "Bash":
            guard let command = any ? "*" : commandPattern(spec!) else { return nil }
            rule.commands = [command]
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            if any { rule.kinds = ["write"] } else if let path = claudePath(spec!) { (rule.paths, rule.access) = ([path], .write) } else { return nil }
        case "Read":
            if any { rule.kinds = ["read"] } else if let path = claudePath(spec!) { (rule.paths, rule.access) = ([path], .read) } else { return nil }
        case let tool where tool.hasPrefix("mcp__"):
            let parts = tool.components(separatedBy: "__").dropFirst()
            guard let server = parts.first, !server.isEmpty else { return nil }
            let rest = parts.dropFirst().joined(separator: "__")
            rule.mcp = ["\(server)/\(rest.isEmpty ? "*" : rest)"]
        case "":
            return nil
        default:
            rule.tools = [name]
        }
        return rule
    }

    /// "git push:*" → "git push"; "npm run *" → "npm run"; "ls" → "ls".
    static func commandPattern(_ spec: String) -> String? {
        var value = spec.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix(":*") { value.removeLast(2) }
        while value.hasSuffix(" *") || value.hasSuffix("*") { value.removeLast(value.hasSuffix(" *") ? 2 : 1) }
        value = value.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "*" : value
    }

    /// Claude's path syntax: `//abs`, `~/home`, `./relative` (to the folder), `/x` (to the
    /// settings file, which Cantrip can't place, so skipped). A trailing `/**` covers the folder.
    static func claudePath(_ spec: String) -> String? {
        var path = spec.trimmingCharacters(in: .whitespaces)
        if path.hasSuffix("/**") { path.removeLast(3) }
        if path.hasPrefix("//") { return String(path.dropFirst()) }
        if path.hasPrefix("~/") || path == "~" { return path }
        if path.hasPrefix("./") { return "$WORKTREE/" + path.dropFirst(2) }
        if path.hasPrefix("/") { return nil }
        return "$WORKTREE/" + path
    }

    /// Copilot's remembered approvals, per folder: approvals for the home folder apply
    /// everywhere; others become that folder's overrides.
    static func copilotRules(_ object: [String: Any], home: String, file: String,
                             ids: inout Set<String>) -> (rules: [AgentPolicyRule], projects: [AgentPolicyProject]) {
        var global: [AgentPolicyRule] = []
        var projects: [AgentPolicyProject] = []
        let locations = object["locations"] as? [String: Any] ?? [:]
        for folder in locations.keys.sorted() {
            let approvals = (locations[folder] as? [String: Any])?["tool_approvals"] as? [[String: Any]] ?? []
            var rules: [AgentPolicyRule] = []
            for approval in approvals {
                var rule = AgentPolicyRule(id: "", effect: .allow, reason: "")
                let kind = approval["kind"] as? String ?? ""
                var label = kind
                switch kind {
                case "commands":
                    let commands = (approval["commandIdentifiers"] as? [String] ?? []).filter { !$0.isEmpty }
                    guard !commands.isEmpty else { continue }
                    rule.commands = commands
                    label = commands.joined(separator: ", ")
                case "write", "read":
                    rule.kinds = [kind]
                case "mcp":
                    guard let server = approval["serverName"] as? String else { continue }
                    let tool = approval["toolName"] as? String
                    rule.mcp = ["\(server)/\(tool ?? "*")"]
                    label = "\(server) \(tool ?? "tools")"
                default:
                    continue
                }
                rule.id = uniqueID("copilot-\(slug(label))", &ids)
                rule.source = "Copilot \(file): \(folder) · \(label)"
                rule.reason = "Approved for good in Copilot (\(label)) before Cantrip's policy."
                rules.append(rule)
            }
            guard !rules.isEmpty else { continue }
            if folder == home || folder == home + "/" || folder == "/" { global += rules }
            else { projects.append(AgentPolicyProject(path: folder, rules: rules)) }
        }
        return (global, projects)
    }

    /// `prefix_rule(pattern = ["git", "push"], decision = "allow")` lines from Codex's own rules.
    static func codexRules(_ text: String, file: String, ids: inout Set<String>) -> [AgentPolicyRule] {
        let regex = try! NSRegularExpression(pattern: #"prefix_rule\(\s*pattern\s*=\s*\[([^\]]*)\]\s*,\s*decision\s*=\s*"(\w+)""#)
        var rules: [AgentPolicyRule] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let tokensRange = Range(match.range(at: 1), in: text),
                  let decisionRange = Range(match.range(at: 2), in: text) else { continue }
            let tokens = text[tokensRange].split(separator: ",").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\t"))
            }.filter { !$0.isEmpty }
            let effect: AgentPolicyRule.Effect
            switch text[decisionRange] {
            case "allow": effect = .allow
            case "prompt": effect = .ask
            case "forbidden": effect = .deny
            default: continue
            }
            guard !tokens.isEmpty else { continue }
            let command = tokens.joined(separator: " ")
            rules.append(AgentPolicyRule(id: uniqueID("codex-\(slug(command))", &ids), effect: effect,
                                         reason: "From Codex's own rules (\(command)) before Cantrip's policy.",
                                         source: "Codex \(file): \(command)", commands: [command]))
        }
        return rules
    }

    // MARK: Overlaps

    /// Imported allow rules that a deny or ask rule overrides for some of the same calls, plus
    /// Home's built-in refusal to stop Cantrip.
    static func conflicts(_ document: AgentPolicyDocument) -> [AgentPolicyConflict] {
        let all = document.rules + document.projects.flatMap(\.rules)
        let imported = all.filter { $0.effect == .allow && isImported($0) }
        let stricter = all.filter { $0.effect != .allow && !isImported($0) && $0.enabled }
        var conflicts: [AgentPolicyConflict] = []
        for allow in imported {
            for rule in stricter where overlaps(allow, rule) {
                conflicts.append(AgentPolicyConflict(
                    imported: allow.id, source: allow.source ?? "", stricter: rule.id, effect: rule.effect,
                    note: "\(rule.effect == .deny ? "Still denied" : "Still asks") where \(rule.id) applies: "
                        + "\(rule.effect.rawValue) beats allow. Narrow or turn off \(rule.id) to let the imported rule win."))
            }
            let stops = (allow.commands ?? []).contains { $0 == "*" || ["kill", "pkill", "killall"].contains(firstWord($0)) }
            if stops {
                conflicts.append(AgentPolicyConflict(
                    imported: allow.id, source: allow.source ?? "", stricter: "home-stop-cantrip (built in)", effect: .deny,
                    note: "Cantrip Home and child tabs still can't stop Cantrip; other tabs follow the policy."))
            }
        }
        return conflicts
    }

    static func isImported(_ rule: AgentPolicyRule) -> Bool {
        ["claude-", "copilot-", "codex-", "antigravity-"].contains { rule.id.hasPrefix($0) }
    }

    static func overlaps(_ allow: AgentPolicyRule, _ rule: AgentPolicyRule) -> Bool {
        let allowCommands = allow.commands ?? []
        if !allowCommands.isEmpty {
            if allowCommands.contains("*"), !(rule.commands ?? []).isEmpty || !(rule.deletesOutside ?? []).isEmpty { return true }
            for pattern in allowCommands where pattern != "*" {
                for other in rule.commands ?? [] {
                    if other.hasPrefix("re:") || other.hasPrefix("@") {
                        if AgentPolicyMatcher.commandMatches(other, line: pattern.lowercased()) { return true }
                    } else if firstWord(other) == firstWord(pattern) {
                        return true
                    }
                }
                if !(rule.deletesOutside ?? []).isEmpty, ["rm", "find", "rsync", "trash", "unlink"].contains(firstWord(pattern)) { return true }
            }
        }
        if allow.kinds?.contains("write") == true, !(rule.paths ?? []).isEmpty, rule.access != .read { return true }
        if allow.kinds?.contains("read") == true, !(rule.paths ?? []).isEmpty, rule.access == .read || rule.access == .any { return true }
        for pattern in allow.mcp ?? [] {
            let server = pattern.split(separator: "/").first.map(String.init) ?? "*"
            if (rule.mcp ?? []).contains(where: { other in
                let otherServer = other.split(separator: "/").first.map(String.init) ?? "*"
                return server == "*" || otherServer == "*" || AgentPolicyMatcher.glob(otherServer.lowercased(), server.lowercased())
            }) { return true }
        }
        return false
    }

    static func firstWord(_ pattern: String) -> String {
        pattern.split(separator: " ").first.map { String($0).lowercased() } ?? ""
    }

    static func slug(_ text: String) -> String {
        var slug = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber { slug.append(character) }
            else if slug.last != "-" { slug.append("-") }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "all" : String(trimmed.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func uniqueID(_ base: String, _ ids: inout Set<String>) -> String {
        var id = base
        var number = 2
        while ids.contains(id) { id = "\(base)-\(number)"; number += 1 }
        ids.insert(id)
        return id
    }
}

// MARK: - Deny rules in each CLI's own configuration

/// The policy's deny rules written into each CLI's own configuration, so they hold when the CLI
/// runs in Terminal too: Claude Code's `permissions.deny`, Codex's rules file, and a PreToolUse
/// hook for Copilot and Antigravity that asks Cantrip's binary. Only rules a CLI can express
/// natively (plain commands without hours or repositories) go into Claude and Codex.
enum AgentPolicyBackstop {
    static let hookArgument = "--cantrip-policy-hook"
    /// Set for CLIs Cantrip starts: the host checks those itself, so the Terminal hook steps aside.
    static let hostVariable = "CANTRIP_POLICY_HOST"
    static let marker = "Generated by Cantrip from its agent policy"

    /// Deny rules a CLI can match by command prefix: enabled, Mac-wide, no hours, repositories or
    /// author conditions.
    static func nativeRules(_ document: AgentPolicyDocument) -> [AgentPolicyRule] {
        guard document.enabled else { return [] }
        return document.rules.filter {
            $0.enabled && $0.effect == .deny && ($0.hours ?? []).isEmpty && ($0.repos ?? []).isEmpty && $0.unlessGitAuthor == nil
        }
    }

    /// Plain command patterns (no globs, expressions or named groups), as words.
    static func plainCommands(_ rule: AgentPolicyRule) -> [[String]] {
        (rule.commands ?? []).compactMap { pattern -> [String]? in
            guard !pattern.hasPrefix("re:"), !pattern.hasPrefix("@"), !pattern.contains(where: { "*?[]".contains($0) }) else { return nil }
            let words = pattern.split(separator: " ").map(String.init)
            return words.isEmpty ? nil : words
        }.flatMap { words -> [[String]] in
            // `xcrun simctl …` runs the same tool.
            ["simctl", "altool", "notarytool"].contains(words[0]) ? [words, ["xcrun"] + words] : [words]
        }
    }

    static func claudeEntries(_ document: AgentPolicyDocument) -> [String] {
        var entries: [String] = []
        for rule in nativeRules(document) {
            for words in plainCommands(rule) {
                let command = words.joined(separator: " ")
                entries += ["Bash(\(command))", "Bash(\(command) *)"]
            }
            for pattern in rule.mcp ?? [] where rule.verbs == nil {
                // Claude names a whole server or one exact tool.
                let parts = pattern.split(separator: "/", maxSplits: 1).map(String.init)
                guard let server = parts.first, !server.contains(where: { "*?[".contains($0) }) else { continue }
                if parts.count < 2 || parts[1] == "*" { entries.append("mcp__\(server)") }
                else if !parts[1].contains(where: { "*?[".contains($0) }) { entries.append("mcp__\(server)__\(parts[1])") }
            }
            for path in rule.paths ?? [] where !path.contains("$") {
                let claudePath = path.hasPrefix("/") ? "/" + path : path
                let access = rule.access ?? .write
                if access == .read || access == .any { entries += ["Read(\(claudePath))", "Read(\(claudePath)/**)"] }
                if access != .read { entries += ["Edit(\(claudePath))", "Edit(\(claudePath)/**)"] }
            }
        }
        var seen: Set<String> = []
        return entries.filter { seen.insert($0).inserted }
    }

    static func codexRules(_ document: AgentPolicyDocument) -> String? {
        var lines: [String] = []
        for rule in nativeRules(document) {
            for words in plainCommands(rule) {
                let pattern = words.map { "\"\(escape($0))\"" }.joined(separator: ", ")
                lines.append("prefix_rule(pattern = [\(pattern)], decision = \"forbidden\", "
                             + "justification = \"\(escape("Blocked by Cantrip's agent policy (rule \(rule.id)): \(rule.reason)"))\")")
            }
        }
        guard !lines.isEmpty else { return nil }
        return "# \(marker). Cantrip replaces this file; edit the policy in Cantrip instead.\n" + lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Brings every CLI's configuration in line with the policy. Files are backed up before
    /// Cantrip first changes them; CLIs that aren't installed are left alone.
    @discardableResult
    static func apply(_ document: inout AgentPolicyDocument, files: AgentPolicyFiles, executable: String?,
                      now: Date = Date()) -> [String] {
        var notes: [String] = []
        let fm = FileManager.default
        // Claude Code: its own deny list, keeping the user's entries.
        if fm.fileExists(atPath: files.claudeSettings.deletingLastPathComponent().path) {
            let previous = document.backstops["claude"] ?? []
            let wanted = claudeEntries(document)
            var settings = AgentPolicyImport.json(files.claudeSettings) ?? [:]
            if fm.fileExists(atPath: files.claudeSettings.path), AgentPolicyImport.json(files.claudeSettings) == nil {
                notes.append("policy: left \(files.claudeSettings.path) alone (it isn't JSON Cantrip can read)")
            } else {
                var permissions = settings["permissions"] as? [String: Any] ?? [:]
                let existing = permissions["deny"] as? [String] ?? []
                let kept = existing.filter { !previous.contains($0) }
                let deny = kept + wanted.filter { !kept.contains($0) }
                if deny != existing {
                    if fm.fileExists(atPath: files.claudeSettings.path) {
                        _ = try? AgentPolicyImport.backup(files.claudeSettings, key: "claude-before-deny", to: files.backups, now: now)
                    }
                    permissions["deny"] = deny
                    settings["permissions"] = permissions
                    if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                        try? data.write(to: files.claudeSettings, options: .atomic)
                        notes.append("policy: wrote \(wanted.count) deny rule(s) into Claude Code's settings")
                    }
                }
                document.backstops["claude"] = wanted
            }
        }
        // Codex: a rules file of its own.
        if fm.fileExists(atPath: files.codexFolder.path) {
            let text = codexRules(document)
            let current = try? String(contentsOf: files.codexRules, encoding: .utf8)
            if let current, !current.contains(marker) {
                notes.append("policy: left \(files.codexRules.path) alone (Cantrip didn't write it)")
            } else if text != current {
                if let text {
                    try? fm.createDirectory(at: files.codexRules.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? text.write(to: files.codexRules, atomically: true, encoding: .utf8)
                } else {
                    try? fm.removeItem(at: files.codexRules)
                }
                notes.append("policy: updated Codex's rules file")
            }
            document.backstops["codex"] = text.map { [$0] } ?? []
        }
        // Copilot (and Antigravity's hook): a helper that asks Cantrip's binary.
        if let executable {
            let script = helperScript(executable: executable)
            if (try? String(contentsOf: files.hookHelper, encoding: .utf8)) != script {
                try? fm.createDirectory(at: files.hookHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? script.write(to: files.hookHelper, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.hookHelper.path)
            }
            if fm.fileExists(atPath: files.copilotFolder.path) {
                let hook: [String: Any] = ["version": 1, "hooks": ["PreToolUse": [[
                    "type": "command", "bash": shellQuoted(files.hookHelper.path) + " copilot", "timeoutSec": 15,
                ] as [String: Any]]]]
                let data = try? JSONSerialization.data(withJSONObject: hook, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                if let data, (try? Data(contentsOf: files.copilotHooks)) != data {
                    try? fm.createDirectory(at: files.copilotHooks.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: files.copilotHooks, options: .atomic)
                    notes.append("policy: added Cantrip's PreToolUse hook for Copilot in Terminal")
                }
                document.backstops["copilot"] = [files.copilotHooks.path]
            }
        }
        return notes
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The hook command. It never blocks a CLI by failing: anything unexpected allows the call
    /// (Copilot treats a failing hook as a denial).
    static func helperScript(executable: String) -> String {
        """
        #!/bin/sh
        # \(marker): checks Copilot and Antigravity tool calls made outside Cantrip against the
        # policy's deny rules. Calls Cantrip starts are checked by Cantrip itself.
        if [ -n "$\(hostVariable)" ] || [ ! -x \(shellQuoted(executable)) ]; then
          cat >/dev/null
          case "$1" in antigravity) echo '{"decision":"allow"}' ;; *) echo '{}' ;; esac
          exit 0
        fi
        exec \(shellQuoted(executable)) \(hookArgument) "$1"

        """
    }

    /// `--cantrip-policy-hook <client>`: reads one PreToolUse request and prints a decision. Only
    /// deny rules apply here; everything else is left to the CLI.
    static func runHelper(client: String, input: Data, store: AgentPolicyStore = .shared) -> String {
        let allow = client == "antigravity" ? #"{"decision":"allow"}"# : "{}"
        let document = store.current()
        guard document.enabled, let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return allow }
        let request: CantripHomeActionRequest
        var folder = object["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        if client == "antigravity" {
            let call = object["toolCall"] as? [String: Any] ?? [:]
            let args = call["args"] as? [String: Any] ?? [:]
            request = CantripHomeActionRequest(antigravityTool: call["name"] as? String ?? "", input: args)
            if let cwd = request.cwd { folder = cwd }
        } else {
            let raw = object["tool_name"] as? String ?? object["toolName"] as? String ?? ""
            // Copilot's camelCase payloads use its own tool names.
            let names = ["bash": "Bash", "powershell": "Bash", "view": "Read", "create": "Write", "edit": "Edit",
                         "str_replace_editor": "Edit", "apply_patch": "Edit", "grep": "Grep", "glob": "Glob",
                         "web_fetch": "WebFetch"]
            let tool = names[raw] ?? raw
            var input = object["tool_input"] as? [String: Any] ?? [:]
            if input.isEmpty, let text = object["toolArgs"] as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                input = parsed
            }
            request = CantripHomeActionRequest(claudeTool: tool, input: input)
        }
        let decision = document.evaluate(request, context: .current(workdir: folder))
        guard decision.verdict == .deny else { return allow }
        let reason = decision.denial
        let body: [String: Any] = client == "antigravity" ? ["decision": "deny", "reason": reason] : [
            "permissionDecision": "deny", "permissionDecisionReason": reason,
            "hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)).map { String(decoding: $0, as: UTF8.self) } ?? allow
    }
}
