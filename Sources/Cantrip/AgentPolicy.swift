import Foundation

// MARK: - Policy file

/// Cantrip's one policy for what agents may do, the same for every tab, child tab and Home run on
/// every backend. Rules allow, ask or deny; deny beats ask and ask beats allow. Anything no rule
/// covers follows "Act on my behalf" (runs when it's on, asks when it's off). Saved as
/// `~/Library/Application Support/Cantrip/policy.json`, never inside a project.
struct AgentPolicyDocument: Codable, Equatable {
    var version = 1
    /// Bumped on every save, so two clients editing at once can't overwrite each other.
    var revision = 0
    /// Off: regular tabs run as they did before the policy. Home and child tabs keep Home's rules.
    var enabled = true
    var rules: [AgentPolicyRule] = []
    /// Per-folder overrides, kept here so nothing is written into the repositories themselves.
    var projects: [AgentPolicyProject] = []
    /// Words the public-repo privacy scan looks for in outgoing commits. Stays on this Mac.
    var privateTerms: [String] = []
    /// Each CLI's rules Cantrip imported, with the backup it kept of the CLI's file.
    var imports: [AgentPolicyImportRecord] = []
    /// Imported allow rules that overlap a stricter rule; the stricter rule wins unless changed.
    var conflicts: [AgentPolicyConflict] = []
    /// Deny rules Cantrip wrote into each CLI's own configuration, so it can replace them later.
    var backstops: [String: [String]] = [:]

    init(rules: [AgentPolicyRule] = [], projects: [AgentPolicyProject] = []) {
        self.rules = rules
        self.projects = projects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        rules = try c.decodeIfPresent([AgentPolicyRule].self, forKey: .rules) ?? []
        projects = try c.decodeIfPresent([AgentPolicyProject].self, forKey: .projects) ?? []
        privateTerms = try c.decodeIfPresent([String].self, forKey: .privateTerms) ?? []
        imports = try c.decodeIfPresent([AgentPolicyImportRecord].self, forKey: .imports) ?? []
        conflicts = try c.decodeIfPresent([AgentPolicyConflict].self, forKey: .conflicts) ?? []
        backstops = try c.decodeIfPresent([String: [String]].self, forKey: .backstops) ?? [:]
    }

    /// The rules a new Mac starts with. Personal rules belong in the user's own file.
    static var starter: Self { Self(rules: AgentPolicyRule.starter) }

    /// Rules with problems a save would refuse: missing IDs, duplicates, unknown variables, bad
    /// hours or patterns.
    func validationErrors() -> [String] {
        var errors: [String] = []
        var seen: Set<String> = []
        let all = rules + projects.flatMap(\.rules)
        for rule in all {
            if rule.id.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("A rule has no ID.") }
            else if !seen.insert(rule.id).inserted { errors.append("Two rules share the ID \(rule.id).") }
            if rule.reason.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("\(rule.id) has no reason.") }
            if !rule.hasTarget { errors.append("\(rule.id) matches nothing: add commands, paths, tools, MCP tools or deletesOutside.") }
            for range in rule.hours ?? [] where AgentPolicyRule.minutes(range) == nil {
                errors.append("\(rule.id): hours must look like 07:45-08:50 (\(range)).")
            }
            for pattern in rule.commands ?? [] where pattern.hasPrefix("re:") {
                if (try? NSRegularExpression(pattern: String(pattern.dropFirst(3)))) == nil {
                    errors.append("\(rule.id): \(pattern) isn't a valid regular expression.")
                }
            }
            for pattern in rule.commands ?? [] where pattern.hasPrefix("@") && AgentPolicyRule.namedCommands[pattern] == nil {
                errors.append("\(rule.id): \(pattern) isn't a named command group (\(AgentPolicyRule.namedCommands.keys.sorted().joined(separator: ", "))).")
            }
        }
        for project in projects where !project.path.hasPrefix("/") && !project.path.hasPrefix("~") {
            errors.append("Project overrides need a full folder path (\(project.path)).")
        }
        return errors
    }
}

struct AgentPolicyProject: Codable, Equatable {
    /// The folder the override covers: tabs working in it or below it.
    var path: String
    var rules: [AgentPolicyRule] = []
    /// IDs of Mac-wide rules that don't apply in this folder.
    var disabled: [String] = []

    init(path: String, rules: [AgentPolicyRule] = [], disabled: [String] = []) {
        self.path = path
        self.rules = rules
        self.disabled = disabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        rules = try c.decodeIfPresent([AgentPolicyRule].self, forKey: .rules) ?? []
        disabled = try c.decodeIfPresent([String].self, forKey: .disabled) ?? []
    }
}

struct AgentPolicyImportRecord: Codable, Equatable {
    var source: String
    var file: String
    var backup: String?
    var importedAt: Date
    var rules: Int
}

struct AgentPolicyConflict: Codable, Equatable {
    var imported: String
    var source: String
    var stricter: String
    var effect: AgentPolicyRule.Effect
    var note: String
}

/// One rule. A rule applies when any of its targets (commands, paths, deletesOutside, MCP tools,
/// tools, kinds) matches and all of its conditions (hours, repos, unlessGitAuthor) hold.
struct AgentPolicyRule: Codable, Equatable, Identifiable {
    enum Effect: String, Codable, CaseIterable { case allow, ask, deny }
    enum Access: String, Codable, CaseIterable { case read, write, delete, any }

    var id: String
    var effect: Effect
    /// Shown to the agent and in the tab when the rule denies, and on the approval card when it asks.
    var reason: String
    var enabled = true
    /// Where the rule came from: "default", "user", or the CLI file it was imported from.
    var source: String?

    /// Shell commands by their words: "git push" matches `git push origin main` (globs allowed in
    /// any word, `*` alone matches every command); `re:` starts a regular expression over the
    /// command; `@cantrip-restart` names a built-in group.
    var commands: [String]?
    /// Files the rule covers. `$WORKTREE`, `$PROJECT`, `$TMP`, `$HOME` and `~` expand; a folder
    /// covers everything below it.
    var paths: [String]?
    /// What happens to `paths`: write (the default; includes deletes), delete, read or any.
    var access: Access?
    /// Deletes whose targets fall outside every one of these folders.
    var deletesOutside: [String]?
    /// MCP tools as `server/tool` globs ("notes/*", "*/send_*"); a bare name covers the server.
    var mcp: [String]?
    /// With `mcp`: only tools whose names contain one of these words ("send", "delete").
    var verbs: [String]?
    /// Backend tools by name, such as "WebFetch".
    var tools: [String]?
    /// Kinds of tool call: shell, write, read, url, mcp, other.
    var kinds: [String]?

    /// Local times the rule is in effect, such as "07:45-08:50" (may wrap past midnight).
    var hours: [String]?
    /// Only in these git repositories (folder name, origin repository name, or owner/name).
    var repos: [String]?
    /// With `git commit`: applies unless the commit's author name or email contains this.
    var unlessGitAuthor: String?
    /// With `git push`: the approval card shows a scan of the outgoing commits for private details.
    var privacyScan: Bool?

    init(id: String, effect: Effect, reason: String, enabled: Bool = true, source: String? = nil,
         commands: [String]? = nil, paths: [String]? = nil, access: Access? = nil,
         deletesOutside: [String]? = nil, mcp: [String]? = nil, verbs: [String]? = nil,
         tools: [String]? = nil, kinds: [String]? = nil, hours: [String]? = nil, repos: [String]? = nil,
         unlessGitAuthor: String? = nil, privacyScan: Bool? = nil) {
        self.id = id
        self.effect = effect
        self.reason = reason
        self.enabled = enabled
        self.source = source
        self.commands = commands
        self.paths = paths
        self.access = access
        self.deletesOutside = deletesOutside
        self.mcp = mcp
        self.verbs = verbs
        self.tools = tools
        self.kinds = kinds
        self.hours = hours
        self.repos = repos
        self.unlessGitAuthor = unlessGitAuthor
        self.privacyScan = privacyScan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        effect = try c.decode(Effect.self, forKey: .effect)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        source = try c.decodeIfPresent(String.self, forKey: .source)
        commands = try c.decodeIfPresent([String].self, forKey: .commands)
        paths = try c.decodeIfPresent([String].self, forKey: .paths)
        access = try c.decodeIfPresent(Access.self, forKey: .access)
        deletesOutside = try c.decodeIfPresent([String].self, forKey: .deletesOutside)
        mcp = try c.decodeIfPresent([String].self, forKey: .mcp)
        verbs = try c.decodeIfPresent([String].self, forKey: .verbs)
        tools = try c.decodeIfPresent([String].self, forKey: .tools)
        kinds = try c.decodeIfPresent([String].self, forKey: .kinds)
        hours = try c.decodeIfPresent([String].self, forKey: .hours)
        repos = try c.decodeIfPresent([String].self, forKey: .repos)
        unlessGitAuthor = try c.decodeIfPresent(String.self, forKey: .unlessGitAuthor)
        privacyScan = try c.decodeIfPresent(Bool.self, forKey: .privacyScan)
    }

    var hasTarget: Bool {
        [commands, paths, deletesOutside, mcp, tools, kinds].contains { !($0 ?? []).isEmpty }
    }

    /// One line for lists: what the rule matches.
    var summary: String {
        var parts: [String] = []
        if let commands, !commands.isEmpty { parts.append("commands: " + commands.joined(separator: ", ")) }
        if let paths, !paths.isEmpty { parts.append("\((access ?? .write).rawValue) paths: " + paths.joined(separator: ", ")) }
        if let deletesOutside, !deletesOutside.isEmpty { parts.append("deletes outside " + deletesOutside.joined(separator: ", ")) }
        if let mcp, !mcp.isEmpty {
            parts.append("MCP: " + mcp.joined(separator: ", ") + (verbs.map { " (" + $0.joined(separator: "/") + ")" } ?? ""))
        }
        if let tools, !tools.isEmpty { parts.append("tools: " + tools.joined(separator: ", ")) }
        if let kinds, !kinds.isEmpty { parts.append("kinds: " + kinds.joined(separator: ", ")) }
        if let hours, !hours.isEmpty { parts.append("during " + hours.joined(separator: ", ")) }
        if let repos, !repos.isEmpty { parts.append("in " + repos.joined(separator: ", ")) }
        if let unlessGitAuthor { parts.append("unless authored by \(unlessGitAuthor)") }
        return parts.joined(separator: "; ")
    }

    static let mutatingVerbs = [
        "send", "post", "create", "update", "delete", "remove", "merge", "push", "publish", "write", "edit",
        "close", "comment", "reply", "transfer", "pay", "purchase", "order", "archive", "move", "set", "add",
    ]

    /// Built-in command groups a rule can name instead of listing patterns.
    static let namedCommands: [String: [String]] = [
        "@cantrip-restart": [
            #"deploy-when-idle"#, #"\bmake\b[^;&|]*cantrip[^;&|]*\brun\b"#, #"\bmake\b[^;&|]*\brun\b[^;&|]*cantrip"#,
            #"\bcantrip\s+daemon\s+(start|stop|restart)\b"#, #"cantrip_install_now"#, #"cantrip/install\.sh"#,
            #"\bopen\s+(-[a-z]+\s+)*[^;&|]*cantrip\.app\b"#, #"(quit|kill)[^;&|]*(application|app)\s+\\?"?cantrip\b"#,
            #"\b(application|app)\s+\\?"?cantrip\b(?!\s+gateway)[^;&|]*\b(quit|kill)\b"#,
            #"\b(killall|pkill)\b[^;&|]*\b(cantrip|agentspotlight)\b(?![\w.-]|\s+gateway)"#,
            #"\blaunchctl\b[^;&|]*\b(kickstart|bootout|unload|kill|stop|restart)\b[^;&|]*(agentspotlight|cantrip)"#,
        ],
    ]

    /// The rules every Mac starts with. Generic: personal rules go in the user's own file.
    static let starter: [AgentPolicyRule] = [
        .init(id: "admin-commands", effect: .deny,
              reason: "Agents don't run commands as an administrator.", source: "default",
              commands: ["sudo", "doas", "su", #"re:\bwith\s+administrator\s+privileges\b"#]),
        .init(id: "deletes-outside-workspace", effect: .deny,
              reason: "Agents delete files only inside the tab's folder, its project and temporary folders.",
              source: "default", deletesOutside: ["$WORKTREE", "$PROJECT", "$TMP"]),
        .init(id: "simulator-lifecycle", effect: .deny,
              reason: "Simulators are shared. Lease one with `cantrip sim acquire` and release it instead of creating, cloning, erasing or deleting simulators.",
              source: "default",
              commands: ["simctl create", "simctl clone", "simctl erase", "simctl delete"]),
        .init(id: "publishing", effect: .ask,
              reason: "Publishing reaches other people or devices.", source: "default",
              commands: ["gh release create", "gh release upload", "gh release edit", "gh release delete",
                         "eas submit", "eas update", "fastlane pilot", "fastlane deliver", "fastlane beta",
                         "npm publish", "pnpm publish", "yarn publish", "altool *--upload*"]),
        .init(id: "production-data", effect: .ask,
              reason: "Changes to production data can't be undone.", source: "default",
              commands: ["supabase db push", "supabase db reset", "supabase migration up",
                         #"re:^(psql|mysql|mongosh)\b.*\bprod"#]),
        .init(id: "outbound-messages", effect: .ask,
              reason: "Messages, emails and posts can't be unsent.", source: "default",
              commands: [#"re:^messages-send\b(?!.*--detect)"#, "sendmail", "msmtp",
                         #"re:^osascript\b.*application \\?"?(messages|mail)\\?"?.*\bsend\b"#],
              mcp: ["*"], verbs: ["send", "post", "reply", "comment", "publish", "tweet"]),
    ]

    /// Minutes since midnight for "HH:MM-HH:MM".
    static func minutes(_ range: String) -> (start: Int, end: Int)? {
        let parts = range.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        func value(_ text: String) -> Int? {
            let pieces = text.split(separator: ":")
            guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]),
                  (0...24).contains(hour), (0..<60).contains(minute) else { return nil }
            return hour * 60 + minute
        }
        guard let start = value(parts[0]), let end = value(parts[1]) else { return nil }
        return (start, end)
    }
}

// MARK: - Evaluating

/// Where a tool call runs: the folders `$WORKTREE`, `$PROJECT` and `$TMP` stand for, the time,
/// and how to learn about git repositories (replaced in tests).
struct AgentPolicyContext {
    var home: String
    /// The tab's folder (a child tab's own checkout).
    var worktree: String
    /// The git repository the tab's folder is in, if any.
    var project: String?
    var temporaryRoots: [String]
    var now = Date()
    var calendar = Calendar.current
    var repository: (String) -> AgentPolicyRepository? = AgentPolicyGit.repository(at:)
    var gitAuthor: (String) -> String? = AgentPolicyGit.author(at:)

    static func current(workdir: String) -> Self {
        let home = AgentPolicyMatcher.canonical(FileManager.default.homeDirectoryForCurrentUser.path)
        let folder = workdir.isEmpty ? home : AgentPolicyMatcher.canonical(workdir)
        let temporary = AgentPolicyMatcher.canonical(NSTemporaryDirectory())
        return Self(home: home, worktree: folder,
                    project: AgentPolicyGit.repository(at: folder).map { AgentPolicyMatcher.canonical($0.root) },
                    temporaryRoots: ["/tmp", "/var/folders", temporary])
    }
}

struct AgentPolicyRepository: Equatable {
    var root: String
    var remote: String?

    /// Whether `name` ("app", "owner/app") names this repository.
    func matches(_ name: String) -> Bool {
        let wanted = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !wanted.isEmpty else { return false }
        if (root as NSString).lastPathComponent.lowercased() == wanted { return true }
        guard var remote = remote?.lowercased() else { return false }
        if remote.hasSuffix(".git") { remote.removeLast(4) }
        remote = remote.replacingOccurrences(of: ":", with: "/")
        return remote.hasSuffix("/" + wanted)
    }
}

struct AgentPolicyDecision: Equatable {
    enum Verdict: String { case none, allow, ask, deny }
    var verdict: Verdict = .none
    var rule: AgentPolicyRule?
    /// What matched: a command, a path or an MCP tool.
    var matched = ""
    /// What the action does, for approval titles ("run `git push`").
    var action = ""
    /// Where the matched command runs, for the privacy scan.
    var directory: String?

    var ruleID: String { rule?.id ?? "" }
    var reason: String { rule?.reason ?? "" }
    /// Approving lets the identical action repeat in the same turn without asking again.
    var scope: String { "policy:\(ruleID)|\(matched)" }

    /// What the agent hears when the rule denies.
    var denial: String {
        "Blocked by Cantrip's agent policy (rule \(ruleID)): \(reason) Don't try another way to do this; "
            + "tell the user it was blocked if it matters."
    }
}

extension AgentPolicyDocument {
    /// The rules in effect in `context`'s folder: Mac-wide rules a project override doesn't turn
    /// off, then the overrides' own rules.
    func effectiveRules(_ context: AgentPolicyContext) -> [AgentPolicyRule] {
        let folder = context.worktree
        let overrides = projects.filter { project in
            let path = AgentPolicyMatcher.expandHome(project.path, home: context.home)
            return folder == path || folder.hasPrefix(path.hasSuffix("/") ? path : path + "/")
                || context.project.map { $0 == path || $0.hasPrefix(path + "/") } == true
        }
        let disabled = Set(overrides.flatMap(\.disabled))
        return (rules.filter { !disabled.contains($0.id) } + overrides.flatMap(\.rules)).filter(\.enabled)
    }

    /// The rule that decides `request`: the first deny that matches, else the first ask, else the
    /// first allow; `.none` when no rule matches.
    func evaluate(_ request: CantripHomeActionRequest, context: AgentPolicyContext) -> AgentPolicyDecision {
        let matcher = AgentPolicyMatcher(request: request, context: context)
        var found: [AgentPolicyRule.Effect: AgentPolicyDecision] = [:]
        for rule in effectiveRules(context) where found[rule.effect] == nil {
            guard let hit = matcher.match(rule) else { continue }
            found[rule.effect] = AgentPolicyDecision(
                verdict: AgentPolicyDecision.Verdict(rawValue: rule.effect.rawValue) ?? .none,
                rule: rule, matched: hit.matched, action: hit.action, directory: hit.directory)
            if rule.effect == .deny { break }
        }
        return found[.deny] ?? found[.ask] ?? found[.allow] ?? AgentPolicyDecision()
    }
}

/// Matches one request against rules. Shell commands are read the way Cantrip Home's guardrails
/// read them: every simple command in the line, inside `bash -c`, `eval` and heredocs fed to a
/// shell, in the folder it runs in after `cd`.
struct AgentPolicyMatcher {
    struct Hit {
        var matched: String
        var action: String
        var directory: String?
    }

    /// One command a shell line runs.
    struct Run {
        var words: [String]
        var segment: String
        var directory: String?
    }

    struct PathUse {
        var path: String
        var access: AgentPolicyRule.Access
        var directory: String?
    }

    let request: CantripHomeActionRequest
    let context: AgentPolicyContext
    let runs: [Run]
    let paths: [PathUse]

    init(request: CantripHomeActionRequest, context: AgentPolicyContext) {
        self.request = request
        self.context = context
        let cwd = request.cwd.flatMap { Self.resolve($0, cwd: context.worktree, context: context) } ?? context.worktree
        switch request.kind {
        case .shell:
            runs = Self.runs(in: request.command, cwd: cwd, context: context, depth: 0)
            paths = Self.pathUses(runs, context: context)
        case .write:
            runs = []
            paths = request.paths.compactMap { Self.resolve($0, cwd: cwd, context: context) }
                .map { PathUse(path: $0, access: .write, directory: cwd) }
        case .read:
            runs = []
            paths = request.paths.compactMap { Self.resolve($0, cwd: cwd, context: context) }
                .map { PathUse(path: $0, access: .read, directory: cwd) }
        default:
            runs = []
            paths = []
        }
    }

    func match(_ rule: AgentPolicyRule) -> Hit? {
        if let hours = rule.hours, !hours.isEmpty, !Self.inHours(hours, now: context.now, calendar: context.calendar) {
            return nil
        }
        for hit in targetHits(rule) where conditionsHold(rule, hit) { return hit }
        return nil
    }

    private func targetHits(_ rule: AgentPolicyRule) -> [Hit] {
        var hits: [Hit] = []
        if let kinds = rule.kinds, kinds.map({ $0.lowercased() }).contains(request.kind.rawValue) {
            hits.append(Hit(matched: describe(), action: actionText(), directory: context.worktree))
        }
        if let patterns = rule.commands, !patterns.isEmpty, request.kind == .shell {
            for run in runs {
                for variant in Self.variants(run.words) {
                    let line = variant.joined(separator: " ")
                    if patterns.contains(where: { Self.commandMatches($0, line: line.lowercased()) }) {
                        hits.append(Hit(matched: line, action: "run `\(line.prefix(80))`",
                                        directory: Self.gitDirectory(run.words, base: run.directory, context: context)))
                        break
                    }
                }
            }
            // Named groups and expressions also see the whole line (`osascript -e '…' -e '…'`).
            let whole = request.command.lowercased()
            if hits.isEmpty, patterns.contains(where: { pattern in
                (pattern.hasPrefix("@") || pattern.hasPrefix("re:")) && Self.commandMatches(pattern, line: whole)
            }) {
                hits.append(Hit(matched: request.command, action: "run `\(request.command.prefix(80))`",
                                directory: request.cwd ?? context.worktree))
            }
        }
        if let patterns = rule.paths, !patterns.isEmpty {
            let wanted = rule.access ?? .write
            let roots = patterns.flatMap { Self.expand($0, context: context) }
            for use in paths where Self.access(use.access, satisfies: wanted)
                && roots.contains(where: { Self.path(use.path, matches: $0) }) {
                hits.append(Hit(matched: use.path, action: "\(Self.verb(use.access)) \(use.path)", directory: use.directory))
            }
        }
        if let folders = rule.deletesOutside, !folders.isEmpty {
            let roots = folders.flatMap { Self.expand($0, context: context) }
            for use in paths where use.access == .delete
                && !roots.contains(where: { use.path != $0 && Self.path(use.path, matches: $0) }) {
                hits.append(Hit(matched: use.path, action: "delete \(use.path)", directory: use.directory))
            }
        }
        if let patterns = rule.mcp, !patterns.isEmpty, request.kind == .mcp {
            let server = (request.server ?? "").lowercased()
            let tool = (request.tool ?? "").lowercased()
            let verbs = (rule.verbs ?? []).map { $0.lowercased() }
            if patterns.contains(where: { Self.mcp($0, server: server, tool: tool) }),
               verbs.isEmpty || Self.toolWords(request.tool ?? "").contains(where: verbs.contains) {
                hits.append(Hit(matched: "\(server)/\(tool)", action: "use \(request.server ?? "an MCP server") \(request.tool ?? "tool")",
                                directory: context.worktree))
            }
        }
        if let tools = rule.tools, !tools.isEmpty, let name = request.tool, request.kind != .mcp,
           tools.contains(where: { Self.glob($0.lowercased(), name.lowercased()) }) {
            hits.append(Hit(matched: name, action: "use \(name)", directory: context.worktree))
        }
        return hits
    }

    private func conditionsHold(_ rule: AgentPolicyRule, _ hit: Hit) -> Bool {
        if let repos = rule.repos, !repos.isEmpty {
            guard let directory = hit.directory, let repository = context.repository(directory),
                  repos.contains(where: repository.matches) else { return false }
        }
        if let wanted = rule.unlessGitAuthor?.lowercased(), !wanted.isEmpty {
            let author = runs.first { Self.variants($0.words).contains { $0.joined(separator: " ") == hit.matched } }
                .flatMap { authorOverride($0) }
                ?? hit.directory.flatMap(context.gitAuthor)
            if author?.lowercased().contains(wanted) == true { return false }
        }
        return true
    }

    /// The author a `git commit` names itself: `--author`, `-c user.name=…` or `GIT_AUTHOR_NAME=…`.
    private func authorOverride(_ run: Run) -> String? {
        if let index = run.words.firstIndex(where: { $0.hasPrefix("--author") }) {
            let word = run.words[index]
            if let equals = word.firstIndex(of: "=") { return String(word[word.index(after: equals)...]) }
            if index + 1 < run.words.count { return run.words[index + 1] }
        }
        for (index, word) in run.words.enumerated() where word == "-c" && index + 1 < run.words.count {
            let setting = run.words[index + 1].lowercased()
            if setting.hasPrefix("user.name=") || setting.hasPrefix("user.email=") {
                return String(run.words[index + 1].split(separator: "=", maxSplits: 1).last ?? "")
            }
        }
        let regex = try! NSRegularExpression(pattern: #"\bGIT_AUTHOR_(?:NAME|EMAIL)=("[^"]*"|'[^']*'|\S+)"#)
        let range = NSRange(run.segment.startIndex..., in: run.segment)
        if let match = regex.firstMatch(in: run.segment, range: range), let value = Range(match.range(at: 1), in: run.segment) {
            return run.segment[value].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private func describe() -> String {
        switch request.kind {
        case .shell: return request.command
        case .mcp: return "\(request.server ?? "")/\(request.tool ?? "")"
        case .url: return request.url ?? request.tool ?? "url"
        default: return (request.paths + [request.tool].compactMap { $0 }).joined(separator: " ")
        }
    }

    private func actionText() -> String {
        switch request.kind {
        case .shell: return "run `\(request.command.prefix(80))`"
        case .write: return "edit \(request.paths.first ?? "files")"
        case .read: return "read \(request.paths.first ?? "files")"
        case .url: return "open \(request.url ?? "a web page")"
        case .mcp: return "use \(request.server ?? "an MCP server") \(request.tool ?? "tool")"
        case .other: return "use \(request.tool ?? "a tool")"
        }
    }

    // MARK: Commands

    static func runs(in command: String, cwd: String?, context: AgentPolicyContext, depth: Int) -> [Run] {
        guard depth < 4 else { return [] }
        let text = ShellCommandText.splitHeredocs(command)
        let segments = ShellCommandText.scopedSegments(of: text.code)
        let words = segments.map { ShellCommandText.commandWords($0.text) }
        let names = words.map { $0.first.map(ShellCommandText.baseName) ?? "" }
        var directories: [String?] = [cwd]
        var runs: [Run] = []
        for (index, segment) in segments.enumerated() {
            while directories.count > segment.depth + 1 { directories.removeLast() }
            while directories.count < segment.depth + 1 { directories.append(directories.last ?? nil) }
            let here = directories[segment.depth]
            guard !words[index].isEmpty else { continue }
            runs.append(Run(words: words[index], segment: segment.text, directory: here))
            let args = Array(words[index].dropFirst())
            if ["cd", "pushd"].contains(names[index]), !["|", "&"].contains(segment.separator) {
                let target = args.first { !$0.hasPrefix("-") }
                if let target {
                    directories[segment.depth] = here.flatMap { resolve(target, cwd: $0, context: context) }
                } else {
                    directories[segment.depth] = context.home
                }
            }
            let inner = innerCommand(words[index])
            let name = inner.first.map(ShellCommandText.baseName) ?? ""
            let innerArgs = Array(inner.dropFirst())
            if ["bash", "sh", "zsh", "dash", "ksh", "fish"].contains(name),
               let flag = innerArgs.firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("c") }),
               flag + 1 < innerArgs.count {
                runs += Self.runs(in: innerArgs[flag + 1], cwd: here, context: context, depth: depth + 1)
            } else if name == "eval" {
                runs += Self.runs(in: innerArgs.joined(separator: " "), cwd: here, context: context, depth: depth + 1)
            }
            // Heredocs read by a shell run as commands; read by osascript, as a script.
            let bodies = ShellCommandText.heredocMarkers(in: segment.text).compactMap {
                $0 < text.heredocs.count ? text.heredocs[$0] : nil
            }
            guard !bodies.isEmpty else { continue }
            var reader = index
            while ["cat", "tee"].contains(names[reader]), segments[reader].separator == "|", reader + 1 < segments.count {
                reader += 1
            }
            for body in bodies {
                if ["bash", "sh", "zsh", "dash", "ksh", "fish", "source", "."].contains(names[reader]) {
                    runs += Self.runs(in: body, cwd: here, context: context, depth: depth + 1)
                } else if names[reader] == "osascript" {
                    runs.append(Run(words: ["osascript", "-e", body], segment: body, directory: here))
                }
            }
        }
        return runs
    }

    /// The command a wrapper runs: `sudo -u x cmd`, `timeout 5 cmd`, `xcrun simctl`, `npx eas`.
    static func innerCommand(_ words: [String]) -> [String] {
        variants(words).last ?? words
    }

    /// The command as written, then without each wrapper in turn, then git without its global
    /// options. Command names are lowercased file names (`/usr/bin/git` → `git`).
    static func variants(_ words: [String]) -> [[String]] {
        guard !words.isEmpty else { return [] }
        func normalized(_ words: [String]) -> [String] {
            guard let first = words.first else { return words }
            return [ShellCommandText.baseName(first)] + words.dropFirst()
        }
        var list = [normalized(words)]
        var current = list[0]
        while let name = current.first {
            var rest = Array(current.dropFirst())
            switch name {
            case "sudo", "doas":
                let valued: Set<String> = ["-u", "-g", "-U", "-C", "-h", "-p", "-r", "-t"]
                while let flag = rest.first, flag.hasPrefix("-") {
                    rest.removeFirst()
                    if valued.contains(flag), !rest.isEmpty { rest.removeFirst() }
                }
            case "timeout", "gtimeout":
                while let flag = rest.first, flag.hasPrefix("-") { rest.removeFirst() }
                if !rest.isEmpty { rest.removeFirst() }
            case "xcrun":
                while let flag = rest.first, flag.hasPrefix("-") {
                    rest.removeFirst()
                    if ["--sdk", "--toolchain", "-sdk"].contains(flag), !rest.isEmpty { rest.removeFirst() }
                }
            case "arch", "npx", "bunx", "nice", "nohup", "env", "command", "exec", "caffeinate":
                while let flag = rest.first, flag.hasPrefix("-") { rest.removeFirst() }
                while let assignment = rest.first, assignment.contains("="), !assignment.hasPrefix("-") { rest.removeFirst() }
            case "pnpm" where rest.first == "dlx", "yarn" where rest.first == "dlx":
                rest.removeFirst()
            default:
                rest = []
            }
            guard !rest.isEmpty else { break }
            current = normalized(rest)
            list.append(current)
        }
        if current.first == "git" {
            var rest = current.dropFirst()
            var changed = false
            while let first = rest.first, first.hasPrefix("-") {
                let takesValue = ["-c", "-C", "--git-dir", "--work-tree", "--namespace"].contains(first)
                rest = rest.dropFirst(takesValue ? 2 : 1)
                changed = true
            }
            if changed { list.append(["git"] + rest) }
        }
        return list
    }

    /// The folder a git command works in: `-C dir` relative to where it runs.
    static func gitDirectory(_ words: [String], base: String?, context: AgentPolicyContext) -> String? {
        let inner = innerCommand(words)
        guard inner.first == "git" else { return base }
        var directory = base
        let original = words.drop { ShellCommandText.baseName($0) != "git" }
        var index = original.startIndex + 1
        while index < original.endIndex, original[index].hasPrefix("-") {
            if original[index] == "-C", index + 1 < original.endIndex {
                directory = directory.flatMap { resolve(original[index + 1], cwd: $0, context: context) }
                    ?? resolve(original[index + 1], cwd: context.worktree, context: context)
                index += 2
            } else {
                index += ["-c", "--git-dir", "--work-tree"].contains(original[index]) ? 2 : 1
            }
        }
        return directory
    }

    static func commandMatches(_ pattern: String, line: String) -> Bool {
        if let group = AgentPolicyRule.namedCommands[pattern] {
            return group.contains { line.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        if pattern.hasPrefix("re:") {
            return line.range(of: String(pattern.dropFirst(3)), options: [.regularExpression, .caseInsensitive]) != nil
        }
        let wanted = pattern.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        guard !wanted.isEmpty else { return false }
        return glob(wanted, line) || glob(wanted + " *", line)
    }

    static func glob(_ pattern: String, _ text: String) -> Bool {
        fnmatch(pattern, text, 0) == 0
    }

    // MARK: Paths

    /// Files the commands write, delete or read. Any other argument that looks like a path counts
    /// as read, so `any` and `read` rules see `cat`, `cp` sources and the like.
    static func pathUses(_ runs: [Run], context: AgentPolicyContext) -> [PathUse] {
        var uses: [PathUse] = []
        for run in runs {
            let words = innerCommand(run.words)
            guard let name = words.first else { continue }
            let args = Array(words.dropFirst())
            let original = Array(run.words.suffix(args.count))
            var positional: [String] = []
            var afterOptions = false
            for arg in original {
                if !afterOptions, arg == "--" { afterOptions = true; continue }
                if !afterOptions, arg.hasPrefix("-"), arg.count > 1 { continue }
                positional.append(arg)
            }
            func add(_ raw: String, _ access: AgentPolicyRule.Access) {
                // An unknown folder (`cd "$X"`) leaves relative paths unknown too.
                guard let path = resolve(raw, cwd: run.directory ?? "$UNKNOWN", context: context) else { return }
                uses.append(PathUse(path: path, access: access, directory: run.directory))
            }
            var used: Set<String> = []
            switch name {
            case "rm", "unlink", "rmdir", "srm", "trash":
                for target in positional { add(target, .delete); used.insert(target) }
            case "find" where args.contains("-delete") || run.segment.range(of: #"-exec(dir)?\s+(\S*/)?rm\b"#, options: .regularExpression) != nil:
                // find deletes what matches below its roots, not the roots themselves.
                let roots = original.drop { ["-H", "-L", "-P"].contains($0) }.prefix { !$0.hasPrefix("-") && $0 != "(" && $0 != "!" }
                for root in roots.isEmpty ? ["."] : Array(roots) { add(root + "/_", .delete); used.insert(root) }
            case "mv":
                // Moving a file changes both places but deletes nothing.
                for path in positional { add(path, .write); used.insert(path) }
            case "cp", "install", "ditto", "rsync", "ln":
                if let destination = positional.last { add(destination, .write); used.insert(destination) }
                if name == "rsync", args.contains(where: { $0.hasPrefix("--delete") }), let destination = positional.last {
                    add(destination + "/_", .delete)
                }
            case "tee", "touch", "mkdir", "chmod", "chown", "truncate":
                for target in positional { add(target, .write); used.insert(target) }
            case "sed", "perl":
                if args.contains(where: { $0 == "-i" || $0.hasPrefix("-i") || $0 == "--in-place" }) {
                    for target in positional.dropFirst() { add(target, .write); used.insert(target) }
                }
            default:
                break
            }
            for target in ShellCommandText.redirectTargets(run.segment) where !target.hasPrefix("/dev/") {
                add(target, .write)
            }
            for arg in positional where !used.contains(arg)
                && (arg.contains("/") || arg.hasPrefix("~") || arg.hasPrefix(".")) && !arg.contains("://") {
                add(arg, .read)
            }
        }
        return uses
    }

    /// An absolute, standardized path; nil when a variable or substitution makes it unknown. A
    /// glob stands for a file in the folder before it.
    static func resolve(_ raw: String, cwd: String, context: AgentPolicyContext) -> String? {
        var path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        guard !path.isEmpty else { return nil }
        for variable in ["${HOME}", "$HOME"] where path.hasPrefix(variable) {
            path = context.home + path.dropFirst(variable.count)
        }
        for variable in ["${TMPDIR}", "$TMPDIR"] where path.hasPrefix(variable) {
            path = (context.temporaryRoots.last ?? "/tmp") + "/" + path.dropFirst(variable.count)
        }
        path = expandHome(path, home: context.home)
        guard !path.contains("$"), !path.contains("`"), !path.hasPrefix("~") else { return nil }
        if let wildcard = path.firstIndex(where: { "*?[".contains($0) }) {
            let folder = path[..<wildcard].range(of: "/", options: .backwards).map { String(path[..<$0.lowerBound]) } ?? ""
            path = (folder.isEmpty && !path.hasPrefix("/") ? "." : folder) + "/_"
        }
        if !path.hasPrefix("/") {
            guard !cwd.contains("$") else { return nil }
            path = cwd + "/" + path
        }
        return canonical(path)
    }

    /// `..` and `.` removed, and `/private/tmp`, `/private/var` and `/private/etc` written the
    /// short way, whether or not the path exists yet.
    static func canonical(_ path: String) -> String {
        var standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        for prefix in ["/private/tmp", "/private/var", "/private/etc"]
        where standardized == prefix || standardized.hasPrefix(prefix + "/") {
            standardized.removeFirst("/private".count)
        }
        return standardized.isEmpty ? "/" : standardized
    }

    static func expandHome(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// A rule's path with its variables filled in; `$TMP` stands for every temporary folder and
    /// `$PROJECT` for nothing outside a repository.
    static func expand(_ pattern: String, context: AgentPolicyContext) -> [String] {
        var values = [expandHome(pattern, home: context.home)]
        let variables: [(String, [String])] = [
            ("$WORKTREE", [context.worktree]), ("$PROJECT", context.project.map { [$0] } ?? []),
            ("$TMP", context.temporaryRoots), ("$HOME", [context.home]),
        ]
        for (name, replacements) in variables {
            values = values.flatMap { value -> [String] in
                guard value.contains(name) else { return [value] }
                return replacements.map { value.replacingOccurrences(of: name, with: $0) }
            }
        }
        return values.map { value in value.contains("*") ? value : canonical(value) }
    }

    /// A folder covers itself and everything below it; globs match with `*` across folders.
    static func path(_ path: String, matches pattern: String) -> Bool {
        if pattern.contains("*") || pattern.contains("?") {
            return glob(pattern, path) || glob(pattern + "/*", path)
        }
        return path == pattern || path.hasPrefix(pattern == "/" ? "/" : pattern + "/")
    }

    static func access(_ use: AgentPolicyRule.Access, satisfies wanted: AgentPolicyRule.Access) -> Bool {
        switch wanted {
        case .any: return true
        case .write: return use == .write || use == .delete
        case .delete: return use == .delete
        case .read: return use == .read
        }
    }

    static func verb(_ access: AgentPolicyRule.Access) -> String {
        switch access {
        case .read: return "read"
        case .write: return "write"
        case .delete: return "delete"
        case .any: return "use"
        }
    }

    // MARK: MCP and time

    static func mcp(_ pattern: String, server: String, tool: String) -> Bool {
        let lowered = pattern.lowercased()
        let parts = lowered.split(separator: "/", maxSplits: 1).map(String.init)
        let serverPattern = parts.first ?? "*"
        let toolPattern = parts.count > 1 ? parts[1] : "*"
        if glob(serverPattern, server) && glob(toolPattern, tool) { return true }
        // Backends that join names (`mcp_agent_chrome_click`) can split them at the wrong underscore.
        return glob("\(serverPattern)_\(toolPattern)", "\(server)_\(tool)")
    }

    /// `send_message`, `sendMessage`, `API-create-a-comment` → their words.
    static func toolWords(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in name {
            if character == "_" || character == "-" || character == "." || character == " " || character == "/" {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
            } else if character.isUppercase, !current.isEmpty, current.last?.isLowercase == true {
                words.append(current.lowercased())
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    static func inHours(_ ranges: [String], now: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return ranges.contains { range in
            guard let (start, end) = AgentPolicyRule.minutes(range) else { return false }
            return start <= end ? (start...end).contains(minute) : minute >= start || minute <= end
        }
    }
}

// MARK: - Git

/// The repository and author for a folder, cached: rules ask about the same few folders often.
enum AgentPolicyGit {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var repositories: [String: (Date, AgentPolicyRepository?)] = [:]
    nonisolated(unsafe) private static var authors: [String: (Date, String?)] = [:]
    /// A folder's repository and author rarely change; looking them up costs two `git` runs.
    static let cacheLifetime: TimeInterval = 600

    static func repository(at folder: String) -> AgentPolicyRepository? {
        if let cached = lock.withLock({ repositories[folder] }), Date().timeIntervalSince(cached.0) < cacheLifetime { return cached.1 }
        var repository: AgentPolicyRepository?
        if let root = git(["rev-parse", "--show-toplevel"], in: folder), !root.isEmpty {
            repository = AgentPolicyRepository(root: root, remote: git(["config", "--get", "remote.origin.url"], in: folder))
        }
        lock.withLock { repositories[folder] = (Date(), repository) }
        return repository
    }

    static func author(at folder: String) -> String? {
        if let cached = lock.withLock({ authors[folder] }), Date().timeIntervalSince(cached.0) < cacheLifetime { return cached.1 }
        let name = git(["config", "user.name"], in: folder)
        let email = git(["config", "user.email"], in: folder)
        let author = [name, email].compactMap { $0 }.joined(separator: " ")
        let value = author.isEmpty ? nil : author
        lock.withLock { authors[folder] = (Date(), value) }
        return value
    }

    static func git(_ arguments: [String], in folder: String) -> String? {
        guard FileManager.default.fileExists(atPath: folder) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Storage

/// Reads and writes the policy file. Every tool call reads it, so the parsed file is kept until
/// it changes on disk; a file that can't be read keeps the last good copy (or the starter rules).
final class AgentPolicyStore: @unchecked Sendable {
    static let shared = AgentPolicyStore(url: defaultURL)

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cantrip/policy.json")
    }

    struct SaveError: LocalizedError, Equatable {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    let url: URL
    private let lock = NSLock()
    private var cached: (stamp: String, document: AgentPolicyDocument)?
    private(set) var loadError: String?

    init(url: URL) {
        self.url = url
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The policy in effect now.
    func current() -> AgentPolicyDocument {
        let stamp = stamp()
        return lock.withLock {
            if let cached, cached.stamp == stamp { return cached.document }
            var document = cached?.document ?? .starter
            if stamp == "missing" {
                document = .starter
                loadError = nil
            } else {
                do {
                    document = try Self.decoder.decode(AgentPolicyDocument.self, from: Data(contentsOf: url))
                    loadError = nil
                } catch {
                    loadError = "Cantrip couldn't read \(url.path) (\(error.localizedDescription)), so it's using the last policy it could read."
                }
            }
            cached = (stamp, document)
            return document
        }
    }

    /// When the file last changed, to tell whether the parsed copy is current.
    private func stamp() -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(date):\(attributes[.size] as? Int ?? 0)"
    }

    /// Saves `document` if nobody saved since `revision` (nil skips the check). The previous file
    /// is kept next to it as `policy.json.previous`.
    @discardableResult
    func save(_ document: AgentPolicyDocument, basedOn revision: Int?) throws -> AgentPolicyDocument {
        try lock.withLock {
            let existing = try? Self.decoder.decode(AgentPolicyDocument.self, from: Data(contentsOf: url))
            if let revision, let existing, existing.revision != revision {
                throw SaveError(status: 409, message: "The policy changed somewhere else. Reload it and try again.")
            }
            let errors = document.validationErrors()
            guard errors.isEmpty else { throw SaveError(status: 400, message: errors.joined(separator: " ")) }
            var saved = document
            saved.revision = max(existing?.revision ?? 0, document.revision) + 1
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let previous = url.appendingPathExtension("previous")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.copyItem(at: url, to: previous)
            }
            let data = try Self.encoder.encode(saved)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            cached = (stamp(), saved)
            loadError = nil
            return saved
        }
    }

    /// Applies `change` to the saved policy (or the starter rules) and saves it.
    @discardableResult
    func update(_ change: (inout AgentPolicyDocument) throws -> Void) throws -> AgentPolicyDocument {
        var document = current()
        let revision = exists ? document.revision : nil
        try change(&document)
        return try save(document, basedOn: revision)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
