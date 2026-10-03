import Foundation

/// How much Cantrip trusts a Home session to act without asking: the Home chat has the user
/// present; scheduled tasks and incidents run unattended in hidden sessions.
enum CantripHomeGuardrail: String {
    case attended, unattended
}

/// Backends that run tools for a Home session consult the same host policy before each one.
protocol CantripHomeGuardedBackend: AnyObject {
    var guardrail: CantripHomeGuardrail? { get set }
    /// Names the run in approval requests ("Daily follow-up tracker wants to send a message").
    var guardrailLabel: String { get set }
}

/// One tool call, normalized from whichever backend asked to run it.
struct CantripHomeActionRequest: Equatable {
    enum Kind: String { case shell, write, read, url, mcp, other }
    var kind: Kind
    var command = ""
    var paths: [String] = []
    var url: String?
    var server: String?
    var tool: String?
    var readOnly = false
    var writesFiles = false

    static func shell(_ command: String) -> Self { .init(kind: .shell, command: command) }
    static func write(_ path: String) -> Self { .init(kind: .write, paths: [path]) }

    /// The bridge's summary of a Copilot SDK permission request.
    init?(copilotJSON text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let raw = object["kind"] as? String else { return nil }
        let kind = Kind(rawValue: raw) ?? .other
        self.init(kind: kind)
        command = object["fullCommandText"] as? String ?? ""
        paths = (object["possiblePaths"] as? [String] ?? [])
            + [object["fileName"] as? String, object["path"] as? String].compactMap { $0 }
        url = object["url"] as? String
        server = object["serverName"] as? String
        tool = object["toolName"] as? String
        readOnly = object["readOnly"] as? Bool ?? false
        writesFiles = object["hasWriteFileRedirection"] as? Bool ?? false
    }

    init(kind: Kind, command: String = "", paths: [String] = [], url: String? = nil,
         server: String? = nil, tool: String? = nil, readOnly: Bool = false,
         writesFiles: Bool = false) {
        self.kind = kind
        self.command = command
        self.paths = paths
        self.url = url
        self.server = server
        self.tool = tool
        self.readOnly = readOnly
        self.writesFiles = writesFiles
    }

    /// A Claude Code `can_use_tool` request.
    init(claudeTool name: String, input: [String: Any]) {
        switch name {
        case "Bash":
            self.init(kind: .shell, command: input["command"] as? String ?? "")
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            let path = input["file_path"] as? String ?? input["notebook_path"] as? String ?? ""
            self.init(kind: .write, paths: path.isEmpty ? [] : [path])
        case "WebFetch", "WebSearch":
            self.init(kind: .url, url: input["url"] as? String)
        case let tool where tool.hasPrefix("mcp__"):
            let parts = tool.components(separatedBy: "__")
            self.init(kind: .mcp, server: parts.count > 1 ? parts[1] : nil,
                      tool: parts.count > 2 ? parts[2...].joined(separator: "__") : tool)
        default:
            self.init(kind: .other, tool: name)
        }
    }
}

struct CantripHomeActionDecision: Equatable {
    enum Verdict: String { case allow, ask, deny }
    let verdict: Verdict
    /// Shown to the model when the action is refused, and logged.
    var reason = ""
    /// What the action does, for approval titles ("send a message").
    var action = ""
    var detail = ""
    /// Approving an action lets the identical action repeat in the same turn without asking.
    var scope = ""

    static let allow = Self(verdict: .allow)
}

/// Host-enforced safety rules for Cantrip Home, independent of which model or CLI runs it.
/// Catastrophic actions are always refused. In unattended runs, outbound or irreversible
/// actions wait for the user's approval; in the attended Home chat they run as asked.
enum CantripHomeActionPolicy {
    struct Environment {
        var home: String
        var workdir: String
        var temporaryRoots: [String]
        /// Home's own state: tasks, records, runs, inboxes. Only Cantrip writes it.
        var protectedRoot: String
        /// Deliverables Home may freely replace or delete.
        var artifactRoot: String
        var cacheRoot: String

        static func current(workdir: String = "") -> Self {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
            return .init(
                home: home,
                workdir: workdir.isEmpty ? home : workdir,
                temporaryRoots: ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", temporary],
                protectedRoot: CantripHomeStore.rootDirectory.standardizedFileURL.path,
                artifactRoot: CantripHomeStore.artifactDirectory.standardizedFileURL.path,
                cacheRoot: home + "/.cache/Cantrip"
            )
        }

        var temporaryDirectory: String { temporaryRoots.last ?? "/tmp" }
    }

    static func evaluate(
        _ request: CantripHomeActionRequest, mode: CantripHomeGuardrail,
        environment: Environment = .current()
    ) -> CantripHomeActionDecision {
        var findings: [CantripHomeActionDecision] = []
        switch request.kind {
        case .shell:
            findings = shellFindings(request.command, environment: environment, depth: 0)
            if request.writesFiles {
                for path in request.paths {
                    if let resolved = resolve(path, environment), isProtected(resolved, environment) {
                        findings.append(protectedWrite)
                    }
                }
            }
        case .write:
            if request.paths.contains(where: {
                resolve($0, environment).map { isProtected($0, environment) } ?? false
            }) {
                findings.append(protectedWrite)
            }
        case .mcp:
            let name = (request.tool ?? "").lowercased()
            if !request.readOnly, name.range(of: mutatingToolPattern, options: .regularExpression) != nil {
                let tool = "\(request.server ?? "an MCP server") \(request.tool ?? "tool")"
                findings.append(ask(
                    "use \(tool)", "This tool can change or send data outside the Mac.",
                    scope: "mcp:\(request.server ?? ""):\(name)"
                ))
            }
        case .read, .url, .other:
            break
        }
        if let denied = findings.first(where: { $0.verdict == .deny }) { return denied }
        guard mode == .unattended, var asked = findings.first(where: { $0.verdict == .ask }) else {
            return .allow
        }
        let text = request.kind == .shell ? request.command
            : (request.paths + [request.server, request.tool].compactMap { $0 }).joined(separator: " ")
        asked.detail = """
        Cantrip paused this unattended Home run before it could \(asked.action). \
        \(asked.reason) Approve to let the run continue, or deny to have it skip this step.

        \(String(text.prefix(2_000)))
        """
        asked.scope += "|" + text
        return asked
    }

    // MARK: - Findings

    private static let protectedWrite = deny(
        "Cantrip Home's own task, record and run files change only through Cantrip. Use a "
            + "cantrip-task or cantrip-task-records block (or tell the user) instead."
    )

    private static func deny(_ reason: String) -> CantripHomeActionDecision {
        .init(verdict: .deny,
              reason: "Blocked by Cantrip Home's safety policy: \(reason) Don't try another way to do this; "
                + "tell the user it was blocked if it matters.")
    }

    private static func ask(_ action: String, _ reason: String, scope: String) -> CantripHomeActionDecision {
        .init(verdict: .ask, reason: reason, action: action, scope: scope)
    }

    private static let mutatingToolPattern =
        #"(^|[_\-.])(send|post|create|update|delete|remove|merge|push|publish|write|close|comment|reply|transfer|pay|purchase|order|archive|move)([_\-.]|$)"#

    private static func shellFindings(
        _ command: String, environment: Environment, depth: Int
    ) -> [CantripHomeActionDecision] {
        guard depth < 4 else { return [deny("The command nests too many shells to check.")] }
        let lower = command.lowercased()
        var findings: [CantripHomeActionDecision] = []
        if lower.range(
            of: #"\b(kill|pkill|killall)\b[^\n;]*\b(cantrip|agentspotlight)(\.app)?(?![\w.-])"#,
            options: .regularExpression
        ) != nil {
            findings.append(deny("Home can't stop Cantrip; it runs inside it."))
        }
        if pipesDownloadIntoProgram(lower) {
            findings.append(deny("Piping downloaded content into a shell or interpreter isn't allowed."))
        }
        for redirect in redirectTargets(command) {
            if let path = resolve(redirect, environment), isProtected(path, environment) {
                findings.append(protectedWrite)
            }
        }
        let segments = segments(of: command)
        let commandNames = Set(segments.compactMap { commandWords($0).first.map(baseName) })
        if commandNames.contains("osascript") {
            findings += appleScriptFindings(lower)
        }
        if !commandNames.isDisjoint(with: ["sqlite3", "psql", "mysql", "mariadb", "mongosh"]),
           lower.range(
               of: #"\b(drop\s+(table|database|schema|index|view)|delete\s+from|truncate\s|alter\s+table|update\s+["`\w.]+\s+set\b|insert\s+(or\s+\w+\s+)?into)"#,
               options: .regularExpression
           ) != nil {
            findings.append(ask(
                "change a database", "The command writes to a database.", scope: "db"
            ))
        }
        for segment in segments {
            var words = commandWords(segment)
            guard !words.isEmpty else { continue }
            var name = baseName(words[0])
            if ["sudo", "su", "doas"].contains(name) {
                findings.append(deny("Cantrip Home never runs commands as an administrator."))
                continue
            }
            if ["npx", "bunx"].contains(name) || (["pnpm", "yarn"].contains(name) && words.count > 1 && words[1] == "dlx") {
                words.removeFirst(name == "npx" || name == "bunx" ? 1 : 2)
                while let first = words.first, first.hasPrefix("-") { words.removeFirst() }
                guard let first = words.first else { continue }
                name = packageCommand(first)
                words[0] = name
            }
            let args = Array(words.dropFirst())
            if ["bash", "sh", "zsh", "dash", "ksh", "fish"].contains(name),
               let flag = args.firstIndex(where: { $0 == "-c" || $0 == "-lc" || $0 == "-ic" || $0 == "-ec" }),
               flag + 1 < args.count {
                findings += shellFindings(args[flag + 1], environment: environment, depth: depth + 1)
                continue
            }
            if name == "eval" {
                findings += shellFindings(args.joined(separator: " "), environment: environment, depth: depth + 1)
                continue
            }
            findings += commandFindings(name, args, full: lower, environment: environment)
        }
        return findings
    }

    private static func appleScriptFindings(_ command: String) -> [CantripHomeActionDecision] {
        let script = command.replacingOccurrences(of: "\\\"", with: "\"")
        var findings: [CantripHomeActionDecision] = []
        let sends = script.range(of: #"\bsend\b"#, options: .regularExpression) != nil
        if sends, script.contains("application \"messages\"") || script.contains("com.apple.mobilesms")
            || script.contains("application id \"com.apple.ichat\"") {
            findings.append(ask("send a message", "Messages can't be unsent.", scope: "message"))
        }
        if script.contains("application \"mail\""),
           sends || script.contains("outgoing message") {
            findings.append(ask("send an email", "Email can't be unsent.", scope: "email"))
        }
        if script.range(of: #"\bquit\b"#, options: .regularExpression) != nil,
           script.contains("cantrip") || script.contains("agentspotlight") {
            findings.append(deny("Home can't quit Cantrip; it runs inside it."))
        }
        if script.contains("system events"),
           script.range(of: #"\b(shut down|restart|log out)\b"#, options: .regularExpression) != nil {
            findings.append(deny("Home can't shut down, restart or log out the Mac."))
        }
        return findings
    }

    private static func commandFindings(
        _ name: String, _ args: [String], full: String, environment: Environment
    ) -> [CantripHomeActionDecision] {
        let lowered = args.map { $0.lowercased() }
        let positional = args.filter { !$0.hasPrefix("-") }
        let sub = positional.first?.lowercased() ?? ""
        func has(_ flags: String...) -> Bool { lowered.contains { flags.contains($0) } }
        switch name {
        case "diskutil":
            if lowered.contains(where: {
                ["erasedisk", "erasevolume", "zerodisk", "randomdisk", "secureerase", "partitiondisk",
                 "reformat", "deletecontainer", "deletevolume", "eraseapfs"].contains($0)
            }) { return [deny("Erasing or repartitioning disks isn't allowed.")] }
        case "dd":
            if lowered.contains(where: { $0.hasPrefix("of=/dev/") }) {
                return [deny("Writing directly to a disk device isn't allowed.")]
            }
        case let mk where mk.hasPrefix("mkfs") || mk.hasPrefix("newfs"):
            return [deny("Formatting disks isn't allowed.")]
        case "csrutil", "nvram", "fdesetup", "tccutil", "systemsetup", "shutdown", "reboot", "halt":
            return [deny("Changing macOS security, startup or power state isn't allowed.")]
        case "spctl":
            if has("--master-disable", "--global-disable", "--disable") {
                return [deny("Turning off Gatekeeper isn't allowed.")]
            }
        case "make":
            if lowered.contains("run"), full.contains("cantrip") {
                return [deny("Rebuilding and relaunching Cantrip would end this run.")]
            }
        case "launchctl":
            if lowered.contains(where: { $0.contains("agentspotlight") || $0.contains("cantrip") }) {
                return [deny("Home can't stop or reload Cantrip.")]
            }
            if ["bootout", "unload", "remove", "disable", "bootstrap", "load", "enable", "kickstart"].contains(sub) {
                return [ask("change a background service (launchctl \(sub))",
                            "It changes what runs on the Mac.", scope: "system")]
            }
        case "crontab":
            if !has("-l") {
                return [ask("change scheduled cron jobs", "It changes what runs on the Mac.", scope: "system")]
            }
        case "defaults":
            if ["delete", "write", "import", "rename"].contains(sub) {
                if sub == "delete", positional.count <= 2, full.contains("com.brian.agentspotlight") {
                    return [deny("Erasing Cantrip's settings isn't allowed.")]
                }
                return [ask("change app or system settings (defaults \(sub))",
                            "It changes saved settings.", scope: "system")]
            }
        case "networksetup":
            if lowered.contains(where: { $0.hasPrefix("-set") || $0.hasPrefix("-remove") || $0.hasPrefix("-create") || $0.hasPrefix("-delete") }) {
                return [ask("change network settings", "It can disconnect the Mac.", scope: "system")]
            }
        case "pmset":
            if !has("-g") {
                return [ask("change power settings", "It changes how the Mac sleeps.", scope: "system")]
            }
        case "brew":
            if ["uninstall", "remove", "rm", "autoremove", "cleanup"].contains(sub) {
                return [ask("remove installed software (brew \(sub))", "Removed software must be reinstalled.", scope: "system")]
            }
        case "messages-send":
            if !has("--detect") {
                return [ask("send a message", "Messages can't be unsent.", scope: "message")]
            }
        case "sendmail", "msmtp":
            return [ask("send an email", "Email can't be unsent.", scope: "email")]
        case "mail", "mailx":
            if has("-s") || positional.contains(where: { $0.contains("@") }) {
                return [ask("send an email", "Email can't be unsent.", scope: "email")]
            }
        case "git":
            return gitFindings(args)
        case "gh":
            return githubFindings(args)
        case "rm", "unlink", "srm":
            return deletionFindings(name, args, environment: environment)
        case "find":
            if has("-delete") || full.range(of: #"-exec(dir)?\s+(/bin/)?rm\b"#, options: .regularExpression) != nil {
                let roots = Array(args.drop { ["-H", "-L", "-P"].contains($0) }
                    .prefix { !$0.hasPrefix("-") && $0 != "(" && $0 != "!" })
                // find deletes everything that matches below its roots, like a recursive rm.
                return deletionFindings("find", ["-r"] + (roots.isEmpty ? ["."] : roots), environment: environment)
            }
        case "mv", "cp", "tee", "truncate", "ln", "install", "rsync", "ditto", "touch", "chmod", "chown":
            // Moving a folder that holds Home's state removes it; so does rsync deleting from a
            // destination (--delete…) or its sources (--remove-source-files).
            var removed = name == "mv" || has("--remove-source-files") ? Array(positional.dropLast()) : []
            if lowered.contains(where: { $0.hasPrefix("--delete") }), let destination = positional.last {
                removed.append(destination)
            }
            if positional.contains(where: {
                resolve($0, environment).map { isProtected($0, environment) } ?? false
            }) || removed.contains(where: {
                resolve($0, environment).map { containsProtected($0, environment) } ?? false
            }) {
                return [protectedWrite]
            }
        case "sed", "perl":
            if lowered.contains(where: { $0 == "-i" || $0.hasPrefix("-i") || $0 == "--in-place" }),
               positional.contains(where: {
                   resolve($0, environment).map { isProtected($0, environment) } ?? false
               }) {
                return [protectedWrite]
            }
        case "eas":
            if ["update", "submit", "build", "deploy", "channel:edit", "branch:delete"].contains(sub) {
                return [deploy("eas \(sub)")]
            }
        case "fastlane", "flyctl", "fly", "heroku":
            return [deploy(name)]
        case "xcrun":
            if lowered.contains("altool") || (lowered.contains("notarytool") && lowered.contains("submit")) {
                return [deploy("xcrun upload")]
            }
        case "vercel", "netlify", "firebase", "wrangler":
            if has("--prod", "--production") || ["deploy", "publish", "promote"].contains(sub) {
                return [deploy(name)]
            }
        case "supabase":
            let action = positional.prefix(2).joined(separator: " ").lowercased()
            if ["db push", "db reset", "functions deploy", "migration up", "secrets set",
                "secrets unset", "functions delete"].contains(action) {
                return [deploy("supabase \(action)")]
            }
        case "npm", "pnpm", "yarn", "bun":
            if sub == "publish" || sub == "unpublish" { return [deploy("\(name) \(sub)")] }
        case "docker", "podman":
            if sub == "push" { return [deploy("\(name) push")] }
        case "kubectl":
            if ["apply", "delete", "rollout", "scale", "patch", "replace", "set"].contains(sub) {
                return [deploy("kubectl \(sub)")]
            }
        case "terraform", "tofu", "pulumi":
            if ["apply", "destroy", "up", "import"].contains(sub) { return [deploy("\(name) \(sub)")] }
        default:
            break
        }
        return []
    }

    private static func deploy(_ tool: String) -> CantripHomeActionDecision {
        ask("deploy or publish (\(tool))", "It changes what other people or devices get.", scope: "deploy")
    }

    private static func gitFindings(_ args: [String]) -> [CantripHomeActionDecision] {
        var rest = args[...]
        while let first = rest.first, first.hasPrefix("-") {
            rest = rest.dropFirst(["-C", "-c", "--git-dir", "--work-tree"].contains(first) ? 2 : 1)
        }
        guard let sub = rest.first?.lowercased() else { return [] }
        let options = rest.dropFirst().map { $0.lowercased() }
        switch sub {
        case "push":
            return [ask("push to a git remote", "Pushed commits reach other people and CI.", scope: "git-push")]
        case "reset" where options.contains("--hard"),
             "clean" where options.contains(where: { $0.hasPrefix("-") && $0.contains("f") }),
             "checkout" where options.contains("--") || options.contains("."),
             "restore" where !options.contains("--staged"),
             "stash" where options.first == "drop" || options.first == "clear",
             "branch" where rest.contains("-D"):
            return [ask("discard uncommitted or unmerged git work (git \(sub))",
                        "Discarded work can't be recovered.", scope: "git-discard")]
        default:
            return []
        }
    }

    private static func githubFindings(_ args: [String]) -> [CantripHomeActionDecision] {
        let positional = args.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
        guard let group = positional.first else { return [] }
        let action = positional.dropFirst().first ?? ""
        let writes: [String: Set<String>] = [
            "pr": ["merge", "create", "close", "comment", "review", "edit", "reopen", "ready"],
            "release": ["create", "upload", "delete", "edit"],
            "workflow": ["run", "enable", "disable"],
            "run": ["rerun", "cancel", "delete"],
            "issue": ["create", "close", "comment", "edit", "delete", "reopen", "transfer"],
            "repo": ["create", "delete", "edit", "archive", "rename"],
            "secret": ["set", "delete"],
            "variable": ["set", "delete"],
        ]
        if writes[group]?.contains(action) == true {
            return [ask("change GitHub (gh \(group) \(action))", "Other people see the change.", scope: "github")]
        }
        if group == "api" {
            let lowered = args.map { $0.lowercased() }
            let method = zip(lowered, lowered.dropFirst()).first { $0.0 == "-x" || $0.0 == "--method" }?.1
                ?? lowered.first { $0.hasPrefix("--method=") }.map { String($0.dropFirst(9)) }
            let hasFields = lowered.contains { ["-f", "-F", "--field", "--raw-field", "--input"].contains($0) }
            if let method, method != "get" {
                return [ask("change GitHub (gh api \(method.uppercased()))", "Other people see the change.", scope: "github")]
            }
            if method == nil, hasFields {
                return [ask("change GitHub (gh api POST)", "Other people see the change.", scope: "github")]
            }
        }
        return []
    }

    private static func deletionFindings(
        _ name: String, _ args: [String], environment: Environment
    ) -> [CantripHomeActionDecision] {
        var targets: [String] = []
        var isRecursive = false
        var afterOptions = false
        for arg in args {
            if !afterOptions, arg == "--" { afterOptions = true; continue }
            if !afterOptions, arg.hasPrefix("-"), arg.count > 1 {
                if arg == "--recursive" || (!arg.hasPrefix("--") && (arg.contains("r") || arg.contains("R"))) {
                    isRecursive = true
                }
                continue
            }
            targets.append(arg)
        }
        guard !targets.isEmpty else {
            return [ask("delete files", "Deleted files can't be recovered.", scope: "delete")]
        }
        var resolved: [String] = []
        for target in targets {
            guard let path = resolve(target, environment) else {
                return [ask("delete files", "Cantrip can't tell what this deletes.", scope: "delete")]
            }
            resolved.append(path)
        }
        if resolved.contains(where: { isProtected($0, environment) || containsProtected($0, environment) }) {
            return [protectedWrite]
        }
        if isRecursive, resolved.contains(where: { isCriticalRoot($0, environment) }) {
            return [deny("Recursively deleting the home folder, a top-level folder in it, or a system folder isn't allowed.")]
        }
        if resolved.allSatisfy({ isDisposable($0, environment) }) { return [] }
        let outside = resolved.first { !isDisposable($0, environment) } ?? ""
        return [ask("delete \(outside)", "Deleted files outside temporary folders and Artifacts can't be recovered.",
                    scope: "delete")]
    }

    // MARK: - Paths

    static func resolve(_ raw: String, _ environment: Environment) -> String? {
        var path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        guard !path.isEmpty else { return nil }
        for variable in ["${HOME}", "$HOME"] where path.hasPrefix(variable) {
            path = environment.home + path.dropFirst(variable.count)
        }
        for variable in ["${TMPDIR}", "$TMPDIR"] where path.hasPrefix(variable) {
            path = environment.temporaryDirectory + "/" + path.dropFirst(variable.count)
        }
        if path == "~" { path = environment.home }
        if path.hasPrefix("~/") { path = environment.home + path.dropFirst(1) }
        guard !path.contains("$"), !path.contains("`"), !path.hasPrefix("~") else { return nil }
        if !path.hasPrefix("/") { path = environment.workdir + "/" + path }
        while path.count > 1, path.hasSuffix("/*") || path.hasSuffix("/.") || path.hasSuffix("/") {
            path.removeLast(path.hasSuffix("/") ? 1 : 2)
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.isEmpty ? "/" : standardized
    }

    private static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func isProtected(_ path: String, _ environment: Environment) -> Bool {
        contains(environment.protectedRoot, path) && !contains(environment.artifactRoot, path)
    }

    private static func isDisposable(_ path: String, _ environment: Environment) -> Bool {
        if environment.temporaryRoots.contains(where: { contains($0, path) && path != $0 }) { return true }
        if contains(environment.artifactRoot, path) && path != environment.artifactRoot { return true }
        if contains(environment.cacheRoot, path), path != environment.cacheRoot,
           !contains(environment.protectedRoot, path) { return true }
        return false
    }

    /// A folder above Home's state: removing it removes every task, record and run.
    static func containsProtected(_ path: String, _ environment: Environment) -> Bool {
        environment.protectedRoot.hasPrefix(path == "/" ? "/" : path + "/")
    }

    private static func isSystemRoot(_ path: String) -> Bool {
        ["/", "/Users", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
         "/etc", "/var", "/private", "/opt", "/Volumes", "/private/var", "/private/etc"].contains(path)
    }

    /// Piping a download into a shell, or into an interpreter that reads its program from
    /// stdin. `| python3 -c …`, `| python3 -m json.tool` and `| node script.js` only read data.
    static func pipesDownloadIntoProgram(_ command: String) -> Bool {
        let pattern = try! NSRegularExpression(
            pattern: #"\b(curl|wget)\b[^;&\n|]*(?:\|[^;&\n|]*)*?\|\s*(?:sudo\s+)?(?:env\s+)?(bash|sh|zsh|ksh|dash|fish|python3?|ruby|perl|node|php|osascript)\b([^;&\n|]*)"#
        )
        let range = NSRange(command.startIndex..., in: command)
        for match in pattern.matches(in: command, range: range) {
            guard let nameRange = Range(match.range(at: 2), in: command),
                  let argsRange = Range(match.range(at: 3), in: command) else { continue }
            let name = String(command[nameRange])
            if ["bash", "sh", "zsh", "ksh", "dash", "fish"].contains(name) { return true }
            let args = String(command[argsRange]).split(separator: " ").map {
                String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            if args.contains(where: { ["-", "/dev/stdin", "/dev/fd/0"].contains($0) }) { return true }
            // Only an inline program (-c/-m/-e, or -pe style) or a script file keeps stdin as data.
            let inline = args.contains { $0.range(of: #"^-[A-Za-z]*[cemE]$"#, options: .regularExpression) != nil }
            let script = args.contains {
                !$0.hasPrefix("-") && ($0.contains("/")
                    || $0.range(of: #"\.(py|js|mjs|cjs|ts|rb|pl|php|scpt|applescript)$"#, options: .regularExpression) != nil)
            }
            if !inline && !script { return true }
        }
        return false
    }

    private static func isCriticalRoot(_ path: String, _ environment: Environment) -> Bool {
        if isSystemRoot(path) || path == environment.home { return true }
        return URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
            == environment.home
    }

    // MARK: - Shell text

    /// Splits a command line into simple commands at unquoted separators, pipes, subshells
    /// and command substitutions. Heredoc bodies become their own (harmless) segments.
    static func segments(of command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { segments.append(trimmed) }
            current = ""
        }
        for character in command {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { current.append(character); escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
                if open == "\"", character == "`" { flush(); continue }
                current.append(character)
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                current.append(character)
            case ";", "&", "|", "\n", "\r", "(", ")", "`":
                if character == "(", current.hasSuffix("$") { current.removeLast() }
                flush()
            default:
                current.append(character)
            }
        }
        flush()
        return segments
    }

    /// Words of one simple command, without quotes, leading variable assignments,
    /// redirections, or wrappers like `env`, `nohup` and `time`.
    static func commandWords(_ segment: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasWord = false
        var escaped = false
        for character in segment {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character; hasWord = true; continue }
            if character == " " || character == "\t" {
                if hasWord || !current.isEmpty { words.append(current) }
                current = ""
                hasWord = false
                continue
            }
            current.append(character)
        }
        if hasWord || !current.isEmpty { words.append(current) }
        var index = 0
        var cleaned: [String] = []
        while index < words.count {
            let word = words[index]
            if word.range(of: #"^[0-9&]*>{1,2}&?$|^<{1,3}$"#, options: .regularExpression) != nil {
                index += 2
                continue
            }
            if word.range(of: #"^[0-9&]*>{1,2}|^<{1,3}"#, options: .regularExpression) != nil {
                index += 1
                continue
            }
            cleaned.append(word)
            index += 1
        }
        let wrappers: Set<String> = ["env", "nohup", "time", "command", "exec", "builtin", "nice", "caffeinate", "noglob", "xargs"]
        while let first = cleaned.first {
            if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=.*"#, options: .regularExpression) != nil
                || wrappers.contains(baseName(first)) {
                cleaned.removeFirst()
                while let flag = cleaned.first, flag.hasPrefix("-") { cleaned.removeFirst() }
                continue
            }
            break
        }
        return cleaned
    }

    private static func redirectTargets(_ command: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"(?<![<>&0-9])(?:[0-9&]?>{1,2}\|?)\s*("[^"]+"|'[^']+'|[^\s;&|<>()]+)"#)
        let range = NSRange(command.startIndex..., in: command)
        return pattern.matches(in: command, range: range).compactMap { match in
            Range(match.range(at: 1), in: command).map { String(command[$0]) }
        }.filter { !$0.hasPrefix("&") }
    }

    private static func baseName(_ word: String) -> String {
        (word as NSString).lastPathComponent.lowercased()
    }

    private static func packageCommand(_ word: String) -> String {
        var name = word.lowercased()
        if let at = name.dropFirst().firstIndex(of: "@") { name = String(name[..<at]) }
        name = (name as NSString).lastPathComponent
        switch name {
        case "eas-cli": return "eas"
        case "firebase-tools": return "firebase"
        default: return name
        }
    }
}
