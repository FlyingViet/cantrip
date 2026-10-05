import Foundation

/// How much Cantrip trusts a Home session to act without asking: the Home chat has the user
/// present; scheduled tasks and incidents run unattended in hidden sessions.
enum CantripHomeGuardrail: String {
    case attended, unattended
}

/// The approval setting the user chose in Cantrip for the backend running Home. Cantrip's blocked
/// list is checked first under every mode; the mode only decides what happens to the rest.
enum CantripHomeApproval: String {
    /// "Act on my behalf" (or Claude's "Allow everything"): anything Cantrip doesn't block runs,
    /// including outbound actions an unattended run would otherwise pause for.
    case automatic
    /// Claude's "Allow file edits": edits run; everything else follows `.ask`.
    case fileEdits
    /// Tools ask first, and unattended runs pause before outbound or irreversible actions.
    case ask

    /// The mode the user picked for `backend`. Local models keep Cantrip's own pauses; Codex and
    /// Copilot Remote run commands Cantrip never sees, so their modes can't be honored safely.
    static func chosen(for backend: BackendKind, settings: AppSettings) -> Self {
        switch backend {
        case .copilot:
            return settings.allowActions ? .automatic : .ask
        case .claudeCode:
            if settings.allowActions || settings.claudePermissionMode == "bypassPermissions" { return .automatic }
            return settings.claudePermissionMode == "acceptEdits" ? .fileEdits : .ask
        case .copilotRemote, .codex, .localModel:
            return .ask
        }
    }

    /// Whether an action Cantrip allowed runs without the backend's usual per-tool prompt.
    func runsWithoutAsking(_ request: CantripHomeActionRequest) -> Bool {
        switch self {
        case .automatic: return true
        case .fileEdits: return request.kind == .write || request.kind == .read
        case .ask: return request.kind == .read
        }
    }
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
    /// Allowed only because the backend's approval mode is automatic; an unattended run on a
    /// stricter mode would have paused for the user.
    var automatic = false
    /// Asked because Cantrip can't check the action against its blocked list (for example a delete
    /// whose target is a variable), so automatic approval never covers it.
    var unverifiable = false

    static let allow = Self(verdict: .allow)
}

/// Host-enforced safety rules for Cantrip Home, independent of which model or CLI runs it.
/// Catastrophic actions are always refused, whatever the approval mode. In unattended runs,
/// outbound or irreversible actions wait for the user's approval unless the backend is set to
/// approve automatically; in the attended Home chat they run as asked.
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
        /// Cantrip's own process ID: a `kill` aimed at it would end every Home run.
        var cantripPIDs: Set<Int32> = []
        /// What `ps` shows for Cantrip, so pkill/killall/grep patterns can be tested against it.
        var cantripProcess = ["Cantrip", "/Applications/Cantrip.app/Contents/MacOS/Cantrip"]
        /// Whether `cd` into a path will succeed, so later relative paths resolve where they run.
        var directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        static func current(workdir: String = "") -> Self {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
            var environment = Self(
                home: home,
                workdir: workdir.isEmpty ? home : workdir,
                temporaryRoots: ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", temporary],
                protectedRoot: CantripHomeStore.rootDirectory.standardizedFileURL.path,
                artifactRoot: CantripHomeStore.artifactDirectory.standardizedFileURL.path,
                cacheRoot: home + "/.cache/Cantrip"
            )
            environment.cantripPIDs = [ProcessInfo.processInfo.processIdentifier]
            if let executable = Bundle.main.executablePath { environment.cantripProcess.append(executable) }
            return environment
        }

        var temporaryDirectory: String { temporaryRoots.last ?? "/tmp" }

        /// The same environment with commands running in `directory` (nil: somewhere unknown).
        func running(in directory: String?) -> Self {
            var copy = self
            // A `$` makes every relative path unresolvable, so deletes there become unverifiable.
            copy.workdir = directory ?? "$UNKNOWN"
            return copy
        }
    }

    static func evaluate(
        _ request: CantripHomeActionRequest, mode: CantripHomeGuardrail,
        approval: CantripHomeApproval = .ask, environment: Environment = .current()
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
        // Automatic approval covers actions Cantrip has checked, never ones it can't verify.
        if approval == .automatic {
            guard let unverifiable = findings.first(where: { $0.verdict == .ask && $0.unverifiable }) else {
                return .init(verdict: .allow, action: asked.action, automatic: true)
            }
            asked = unverifiable
            asked.reason += " Act on my behalf doesn't cover actions Cantrip can't check."
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

    private static func ask(
        _ action: String, _ reason: String, scope: String, unverifiable: Bool = false
    ) -> CantripHomeActionDecision {
        .init(verdict: .ask, reason: reason, action: action, scope: scope, unverifiable: unverifiable)
    }

    private static let mutatingToolPattern =
        #"(^|[_\-.])(send|post|create|update|delete|remove|merge|push|publish|write|close|comment|reply|transfer|pay|purchase|order|archive|move)([_\-.]|$)"#

    private static let shells: Set<String> = ["bash", "sh", "zsh", "dash", "ksh", "fish"]
    private static let databases: Set<String> = ["sqlite3", "psql", "mysql", "mariadb", "mongosh"]
    private static let interpreters: Set<String> = [
        "python", "python3", "node", "ruby", "perl", "php", "deno", "bun", "swift", "osascript",
    ]

    /// What runs a piece of text: a shell, AppleScript, SQL, another interpreter, or nothing.
    private enum Consumer { case shell, appleScript, sql, script, data }

    private static func consumer(_ name: String) -> Consumer {
        if shells.contains(name) || name == "source" || name == "." { return .shell }
        if name == "osascript" { return .appleScript }
        if databases.contains(name) { return .sql }
        if interpreters.contains(name) || name.hasPrefix("python3.") { return .script }
        return .data
    }

    /// Judges what a command line actually does. Heredoc bodies and quoted text are data unless
    /// a shell, AppleScript, database or interpreter runs them, and relative paths resolve in
    /// the directory each command runs in after `cd`.
    private static func shellFindings(
        _ command: String, environment: Environment, depth: Int
    ) -> [CantripHomeActionDecision] {
        guard depth < 4 else { return [deny("The command nests too many shells to check.")] }
        let text = splitHeredocs(command)
        let lower = text.code.lowercased()
        let segments = scopedSegments(of: text.code)
        let words = segments.map { commandWords($0.text) }
        let names = words.map { $0.first.map(baseName) ?? "" }
        var findings: [CantripHomeActionDecision] = []
        if pipesDownloadIntoProgram(lower) {
            findings.append(deny("Piping downloaded content into a shell or interpreter isn't allowed."))
        }
        findings += stopCantripFindings(words, code: lower, environment: environment)

        // Where each segment runs, per subshell depth; several candidates when a `cd` might fail.
        var directories: [[String?]] = [[environment.workdir]]
        var runsIn: [[String?]] = []
        for (index, segment) in segments.enumerated() {
            while directories.count > segment.depth + 1 { directories.removeLast() }
            while directories.count < segment.depth + 1 { directories.append(directories.last ?? [nil]) }
            let here = directories[segment.depth]
            runsIn.append(here)
            if ["cd", "pushd"].contains(names[index]), !["|", "&"].contains(segment.separator) {
                let target = words[index].dropFirst().first { !$0.hasPrefix("-") || $0 == "-" }
                var next: [String?] = []
                for directory in here {
                    let resolved: String? = switch target {
                    case nil: environment.home
                    case "-": nil
                    case let target?: directory.flatMap { resolve(target, environment.running(in: $0)) }
                    }
                    if let resolved, environment.directoryExists(resolved) {
                        next.append(resolved)
                    } else {
                        // A failed cd leaves later commands where they were; an unknown one, anywhere.
                        next += [directory, resolved]
                    }
                }
                directories[segment.depth] = next.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            }
        }

        // Heredoc bodies go to whatever reads them; `cat <<EOF | sh` and scripts written from a
        // heredoc and then run in the same command are code, everything else is data.
        let executed = executedFiles(words, runsIn: runsIn, environment: environment)
        var sqlText = lower
        // `eval "$(cat <<EOF …)"` and `bash -c "$(…)"` run what a substitution prints.
        let runsSubstitution = segments.indices.contains { index in
            let args = Array(words[index].dropFirst())
            let runs = ["eval", "source", "."].contains(names[index])
                || (shells.contains(names[index]) && shellCommandFlag(args) != nil)
            return runs && ["$(", "`"].contains(segments[index].separator)
        }
        // Data heredocs could still reach a shell reading stdin elsewhere in the line (`>(sh)`).
        let shellReadsStdin = text.code.contains(">(") || text.code.contains("<(") || words.contains { words in
            guard let first = words.first, consumer(baseName(first)) == .shell else { return false }
            let args = Array(words.dropFirst())
            return shellCommandFlag(args) == nil && !args.contains { !$0.hasPrefix("-") }
        }
        for (index, segment) in segments.enumerated() {
            let bodies = heredocMarkers(in: segment.text).compactMap {
                $0 < text.heredocs.count ? text.heredocs[$0] : nil
            } + hereStrings(in: segment.text)
            guard !bodies.isEmpty else { continue }
            var reader = index
            while ["cat", "tee"].contains(names[reader]), segments[reader].separator == "|",
                  reader + 1 < segments.count {
                reader += 1
            }
            var kind = consumer(names[reader])
            if kind == .data, shellReadsStdin || (segment.depth > 0 && runsSubstitution) { kind = .shell }
            if kind == .data {
                let written = redirectTargets(segment.text)
                    + (names[index] == "tee" ? words[index].dropFirst().filter { !$0.hasPrefix("-") } : [])
                for path in written {
                    for directory in runsIn[index] {
                        if let resolved = directory.flatMap({ resolve(path, environment.running(in: $0)) }),
                           let runner = executed[resolved] {
                            kind = runner
                        }
                    }
                }
            }
            for body in bodies {
                switch kind {
                case .shell:
                    for directory in runsIn[reader] {
                        findings += shellFindings(body, environment: environment.running(in: directory), depth: depth + 1)
                    }
                case .appleScript:
                    findings += appleScriptFindings(body.lowercased())
                case .sql:
                    sqlText += "\n" + body.lowercased()
                case .script:
                    for directory in runsIn[reader] {
                        findings += scriptFindings(body, environment: environment.running(in: directory))
                    }
                case .data:
                    break
                }
            }
        }

        if names.contains(where: databases.contains),
           sqlText.range(
               of: #"\b(drop\s+(table|database|schema|index|view)|delete\s+from|truncate\s|alter\s+table|update\s+["`\w.]+\s+set\b|insert\s+(or\s+\w+\s+)?into)"#,
               options: .regularExpression
           ) != nil {
            findings.append(ask(
                "change a database", "The command writes to a database.", scope: "db"
            ))
        }

        for (index, segment) in segments.enumerated() {
            let scoped = runsIn[index].map { environment.running(in: $0) }
            for redirect in redirectTargets(segment.text) {
                if scoped.contains(where: { env in resolve(redirect, env).map { isProtected($0, env) } ?? false }) {
                    findings.append(protectedWrite)
                }
            }
            var words = words[index]
            guard !words.isEmpty else { continue }
            var name = names[index]
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
            if shells.contains(name), let flag = shellCommandFlag(args), flag + 1 < args.count {
                for env in scoped {
                    findings += shellFindings(args[flag + 1], environment: env, depth: depth + 1)
                }
                continue
            }
            if name == "eval" {
                for env in scoped {
                    findings += shellFindings(args.joined(separator: " "), environment: env, depth: depth + 1)
                }
                continue
            }
            if name == "osascript" {
                // A script assembled at run time (`-e "$(…)"`) can't be read, so the whole line counts.
                let assembled = ["$(", "`"].contains(segment.separator) || args.contains { $0.contains("$") }
                findings += appleScriptFindings(assembled ? lower : inlineCode(args, flags: ["-e"]).lowercased())
            } else if consumer(name) == .script {
                let code = inlineCode(args, flags: ["-c", "-e", "-E", "-r", "--eval", "-p", "--print"])
                if !code.isEmpty {
                    for env in scoped { findings += scriptFindings(code, environment: env) }
                }
            }
            for env in scoped {
                findings += commandFindings(name, args, full: lower, environment: env)
            }
        }
        return findings
    }

    /// Where `bash -c`, `sh -xc`, `zsh -lic` and the like name the command string.
    private static func shellCommandFlag(_ args: [String]) -> Int? {
        for (index, arg) in args.enumerated() {
            guard arg.hasPrefix("-") else { return nil }
            if !arg.hasPrefix("--"), arg.dropFirst().contains("c") { return index }
        }
        return nil
    }

    /// The text of `<<< word` here-strings in one segment, unquoted.
    private static func hereStrings(in segment: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"<<<\s*(?:\$?'([^']*)'|\$?"((?:[^"\\]|\\.)*)"|([^\s;&|<>()]+))"#)
        return regex.matches(in: segment, range: NSRange(segment.startIndex..., in: segment)).compactMap { match in
            (1...3).lazy.compactMap { Range(match.range(at: $0), in: segment) }.first.map { String(segment[$0]) }
        }
    }

    /// The program text an interpreter gets on its command line (`-e '…'`, `-c '…'`, `-pe '…'`).
    private static func inlineCode(_ args: [String], flags: Set<String>) -> String {
        var code: [String] = []
        for (index, arg) in args.enumerated() where index + 1 < args.count {
            if flags.contains(arg) || arg.range(of: #"^-[A-Za-z]*[ce]$"#, options: .regularExpression) != nil {
                code.append(args[index + 1])
            }
        }
        return code.joined(separator: "\n")
    }

    /// Script files a command runs (`bash x.sh`, `python3 x.py`, `source x`, `./x`), resolved.
    private static func executedFiles(
        _ words: [[String]], runsIn: [[String?]], environment: Environment
    ) -> [String: Consumer] {
        var files: [String: Consumer] = [:]
        for (index, words) in words.enumerated() {
            guard let first = words.first else { continue }
            let name = baseName(first)
            var path: String?
            var kind = Consumer.shell
            if first.contains("/") {
                path = first
            } else if consumer(name) != .data, name != "osascript" || words.count > 1 {
                kind = consumer(name)
                path = words.dropFirst().first { !$0.hasPrefix("-") }
            }
            guard let path else { continue }
            for directory in runsIn[index] {
                if let resolved = directory.flatMap({ resolve(path, environment.running(in: $0)) }) {
                    files[resolved] = kind
                }
            }
        }
        return files
    }

    // MARK: - Stopping Cantrip

    private static let stopCantrip = deny("Home can't stop Cantrip; it runs inside it.")

    /// kill, pkill and killall judged by what they'd actually signal: Cantrip's PID, a name or
    /// pattern that matches Cantrip's process, or PIDs looked up from Cantrip in the same command.
    private static func stopCantripFindings(
        _ commands: [[String]], code: String, environment: Environment
    ) -> [CantripHomeActionDecision] {
        var signalsLookedUpPIDs = false
        var namesComputedTargets = false
        var findings: [CantripHomeActionDecision] = []
        for words in commands {
            // Wrappers like `timeout 5` or `launchctl asuser 501` can put the command anywhere.
            guard let index = words.firstIndex(where: { ["kill", "pkill", "killall"].contains(baseName($0)) }) else {
                continue
            }
            let name = baseName(words[index])
            let args = Array(words[(index + 1)...])
            // Names from variables, substitutions or stdin (`killall $P`, `xargs pkill`) are unknown.
            let named = args.filter { !$0.hasPrefix("-") }
            if name != "kill", named.isEmpty || named.contains(where: { $0.isEmpty || $0.contains("$") || $0.contains("`") }) {
                namesComputedTargets = true
            }
            switch name {
            case "killall":
                if killallTargetsCantrip(args, environment) { findings.append(stopCantrip) }
            case "pkill":
                if pkillTargetsCantrip(args, environment) { findings.append(stopCantrip) }
            default:
                guard let targets = killTargets(args) else { continue }
                if targets.isEmpty || targets.contains(where: { Int32($0) == nil }) { signalsLookedUpPIDs = true }
                if targets.contains(where: { target in
                    guard let pid = Int32(target) else { return false }
                    // 0 and -1 signal this process group or every process the user owns.
                    return pid == 0 || pid == -1 || environment.cantripPIDs.contains(abs(pid))
                }) {
                    findings.append(stopCantrip)
                }
            }
        }
        if signalsLookedUpPIDs || namesComputedTargets,
           commands.contains(where: { looksUpCantrip($0, environment) })
            || (namesComputedTargets && mentionsCantrip(code)) {
            findings.append(stopCantrip)
        }
        return findings
    }

    /// The PID or job arguments of `kill`, after its signal option; nil when it only lists signals.
    private static func killTargets(_ args: [String]) -> [String]? {
        var rest = args[...]
        if let first = rest.first {
            if ["-s", "-n"].contains(first) { rest = rest.dropFirst(2) }
            else if first == "-l" || first == "-L" { return nil }
            else if first.hasPrefix("-"), first != "--" { rest = rest.dropFirst() }
        }
        if rest.first == "--" { rest = rest.dropFirst() }
        return Array(rest)
    }

    /// Cantrip named anywhere in the command line (`P=Cantrip; killall $P`).
    private static func mentionsCantrip(_ code: String) -> Bool {
        code.range(of: #"\b(?:cantrip(?:\.app)?|agentspotlight)\b(?![\w.-]|\s+(?:gateway|memory))"#,
                   options: .regularExpression) != nil
    }

    private static func isCantripName(_ value: String) -> Bool {
        let name = (value.lowercased() as NSString).lastPathComponent
        return ["cantrip", "cantrip.app", "agentspotlight", "com.brian.agentspotlight"].contains(name)
    }

    /// Whether a pkill/pgrep/grep pattern matches Cantrip's name or command line (case-insensitively,
    /// to stay on the safe side of `-i`).
    private static func patternMatchesCantrip(_ pattern: String, _ environment: Environment) -> Bool {
        let candidates = environment.cantripProcess + ["com.brian.agentspotlight"]
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            return candidates.contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
        return candidates.contains { $0.range(of: pattern, options: .caseInsensitive) != nil }
    }

    private static func killallTargetsCantrip(_ args: [String], _ environment: Environment) -> Bool {
        let matchesRegex = args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("m") && !$0.contains(where: \.isNumber) }
        var names: [String] = []
        var skip = false
        for (index, arg) in args.enumerated() {
            if skip { skip = false; continue }
            if ["-u", "-t"].contains(arg) { skip = true; continue }
            if arg == "-c", index + 1 < args.count { names.append(args[index + 1]); skip = true; continue }
            if arg.hasPrefix("-") { continue }
            names.append(arg)
        }
        return names.contains { isCantripName($0) || (matchesRegex && patternMatchesCantrip($0, environment)) }
    }

    private static func pkillTargetsCantrip(_ args: [String], _ environment: Environment) -> Bool {
        let valued: Set<String> = ["-F", "-G", "-g", "-P", "-U", "-u", "-t", "-s", "-J", "-M", "-N", "-L"]
        var patterns: [String] = []
        var skip = false
        for arg in args {
            if skip { skip = false; continue }
            if valued.contains(arg) { skip = true; continue }
            if arg.hasPrefix("-") { continue }
            patterns.append(arg)
        }
        return patterns.contains { isCantripName($0) || patternMatchesCantrip($0, environment) }
    }

    /// A PID lookup in the same command that would find Cantrip (`pgrep Cantrip`, `ps … | grep -i cantrip`).
    private static func looksUpCantrip(_ words: [String], _ environment: Environment) -> Bool {
        guard let first = words.first else { return false }
        let name = baseName(first)
        let args = words.dropFirst().filter { !$0.hasPrefix("-") }
        switch name {
        case "pgrep", "grep", "egrep", "fgrep", "rg":
            return args.contains { isCantripName($0) || patternMatchesCantrip($0, environment) }
        case "pidof", "ps", "lsof", "awk", "launchctl":
            return args.contains { $0.lowercased().contains("cantrip") || $0.lowercased().contains("agentspotlight") }
        default:
            return false
        }
    }

    /// `application "Cantrip"`, `app id "com.brian.agentspotlight"`, JXA `Application("Cantrip")`.
    private static let cantripAppReference =
        #"\b(?:application|app|process)\s*\(?\s*(?:id\s+)?\\?["'](?:[^"'\n]*/)?(?:cantrip(?:\.app)?|com\.brian\.agentspotlight)\\?["']"#

    /// Program text for an interpreter: only code that names Cantrip as what it stops, or that
    /// writes Home's state on the same line, counts. Prose in strings doesn't.
    static func targetsCantrip(_ code: String) -> Bool {
        let patterns = [
            #"\b(?:killall|pkill)\b[\s"',\[\]]*(?:-[\w-]+["',\s]+)*["']?(?:[^\s"']*/)?(?:cantrip(?:\.app)?|agentspotlight|com\.brian\.agentspotlight)(?![\w.-]|\s+gateway)"#,
            cantripAppReference + #"[^\n]*\b(?:quit|kill)\b"#,
            #"\b(?:quit|kill)\b[^\n]*"# + cantripAppReference,
            #"\blaunchctl\b[^\n]*\b(?:bootout|unload|kill|stop|remove|disable)\b[^\n]*(?:agentspotlight|cantrip)"#,
            #"\bpgrep\b[\s"',\[\]]*(?:-[\w-]+["',\s]+)*["']?(?:cantrip|agentspotlight)\b(?![\w.-]|\s+gateway)[\s\S]*\bkill"#,
        ]
        let lower = code.lowercased()
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    /// Code run by python, node, ruby, perl and similar: refused only when it stops Cantrip or
    /// writes Home's own state (path and write on the same line).
    private static func scriptFindings(_ code: String, environment: Environment) -> [CantripHomeActionDecision] {
        var findings: [CantripHomeActionDecision] = []
        if targetsCantrip(code) { findings.append(stopCantrip) }
        if code.range(of: #"\bkill"#, options: .regularExpression) != nil,
           environment.cantripPIDs.contains(where: { code.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }) {
            findings.append(stopCantrip)
        }
        let writes = #"open\([^\n]*,\s*['"][^'"]*[wax+]|\.write_(?:text|bytes)\(|\b(?:os|shutil)\.(?:remove|unlink|rename|replace|rmdir|rmtree|move)\(|\.(?:unlink|rename|rmdir)\(|\bfs\.(?:writeFile|appendFile|rm|unlink|rename|truncate)|File\.(?:write|delete|rename)|\bunlink\b"#
        let protected = [environment.protectedRoot, environment.protectedRoot.replacingOccurrences(of: environment.home, with: "~"),
                         environment.protectedRoot.replacingOccurrences(of: environment.home, with: "$HOME")]
        if isProtected(environment.workdir, environment), code.range(of: writes, options: .regularExpression) != nil {
            return findings + [protectedWrite]
        }
        let artifacts = String(environment.artifactRoot.dropFirst(environment.protectedRoot.count))
        for line in code.split(separator: "\n") where line.range(of: writes, options: .regularExpression) != nil {
            let mentions = protected.contains { root in
                var range = line.startIndex..<line.endIndex
                while let found = line.range(of: root, range: range) {
                    if !line[found.upperBound...].hasPrefix(artifacts + "/") { return true }
                    range = found.upperBound..<line.endIndex
                }
                return false
            }
            if mentions { findings.append(protectedWrite); break }
        }
        return findings
    }

    /// AppleScript actually passed to osascript (its `-e` lines or a heredoc).
    private static func appleScriptFindings(_ script: String) -> [CantripHomeActionDecision] {
        let script = script.replacingOccurrences(of: "\\\"", with: "\"")
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
        let quitsCantrip = script.range(of: cantripAppReference, options: .regularExpression) != nil && script.range(of: #"\b(?:quit|kill)\b"#, options: .regularExpression) != nil
        if quitsCantrip || targetsCantrip(script) {
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
            return [ask("delete files", "Cantrip can't tell what this deletes.", scope: "delete", unverifiable: true)]
        }
        var resolved: [String] = []
        for target in targets {
            guard let path = resolve(target, environment) else {
                return [ask("delete files", "Cantrip can't tell what this deletes.", scope: "delete", unverifiable: true)]
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
        if !path.hasPrefix("/") {
            // Relative to a directory Cantrip couldn't determine (`cd "$X"`).
            guard !environment.workdir.contains("$") else { return nil }
            path = environment.workdir + "/" + path
        }
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

    /// A command line with its heredoc bodies taken out. `code` keeps a `<<HEREDOC#n` marker
    /// where body n was introduced, so the command reading it can be found. Comments are dropped.
    struct ShellText: Equatable {
        var code: String
        var heredocs: [String]
    }

    static func splitHeredocs(_ command: String) -> ShellText {
        let characters = Array(command)
        var code = ""
        var bodies: [String] = []
        var pending: [(delimiter: String, stripsTabs: Bool)] = []
        var quote: Character?
        var escaped = false
        var arithmetic = 0
        // `$(…)` and backticks start fresh quoting, even inside double quotes.
        var substitutions: [(restore: Character?, backtick: Bool)] = []
        var index = 0
        func atWordStart() -> Bool {
            guard let last = code.last else { return true }
            return " \t\n;&|()".contains(last)
        }
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if escaped { code.append(character); escaped = false; index += 1; continue }
            if character == "\\", quote != "'" { code.append(character); escaped = true; index += 1; continue }
            if quote != "'", character == "$", next == "(" {
                let isArithmetic = index + 2 < characters.count && characters[index + 2] == "("
                if isArithmetic { arithmetic += 1 }
                code += isArithmetic ? "$((" : "$("
                index += isArithmetic ? 3 : 2
                substitutions.append((quote, false))
                quote = nil
                continue
            }
            if quote != "'", character == "`" {
                code.append(character)
                index += 1
                if let last = substitutions.last, last.backtick {
                    substitutions.removeLast()
                    quote = last.restore
                } else {
                    substitutions.append((quote, true))
                    quote = nil
                }
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
                code.append(character)
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                code.append(character)
                index += 1
                continue
            }
            if character == "#", atWordStart() {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == ")", let last = substitutions.last, !last.backtick {
                if arithmetic > 0, next == ")" {
                    arithmetic -= 1
                    code += "))"
                    index += 2
                } else {
                    code.append(character)
                    index += 1
                }
                substitutions.removeLast()
                quote = last.restore
                continue
            }
            if character == "(", next == "(" {
                arithmetic += 1
            } else if character == ")", arithmetic > 0, next == ")" {
                arithmetic -= 1
            }
            if character == "<", arithmetic == 0, index + 1 < characters.count, characters[index + 1] == "<",
               code.last != "<", !(index + 2 < characters.count && characters[index + 2] == "<") {
                var cursor = index + 2
                var stripsTabs = false
                if cursor < characters.count, characters[cursor] == "-" { stripsTabs = true; cursor += 1 }
                while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" { cursor += 1 }
                var delimiter = ""
                var delimiterQuote: Character?
                while cursor < characters.count {
                    let next = characters[cursor]
                    if let open = delimiterQuote {
                        if next == open { delimiterQuote = nil } else { delimiter.append(next) }
                    } else if next == "'" || next == "\"" {
                        delimiterQuote = next
                    } else if next == "\\" {
                        // `<<\EOF` quotes the delimiter like `<<'EOF'`.
                    } else if " \t\n;&|<>()".contains(next) {
                        break
                    } else {
                        delimiter.append(next)
                    }
                    cursor += 1
                }
                if !delimiter.isEmpty {
                    code += "<<HEREDOC#\(bodies.count + pending.count)"
                    pending.append((delimiter, stripsTabs))
                    index = cursor
                    continue
                }
            }
            if character == "\n", !pending.isEmpty {
                code.append("\n")
                index += 1
                for heredoc in pending {
                    var lines: [String] = []
                    while index < characters.count {
                        var line = ""
                        while index < characters.count, characters[index] != "\n" { line.append(characters[index]); index += 1 }
                        if index < characters.count { index += 1 }
                        let compared = heredoc.stripsTabs ? String(line.drop { $0 == "\t" }) : line
                        if compared == heredoc.delimiter { break }
                        lines.append(line)
                    }
                    bodies.append(lines.joined(separator: "\n"))
                }
                pending.removeAll()
                continue
            }
            code.append(character)
            index += 1
        }
        // A heredoc with no body before the command ended reads nothing.
        bodies += pending.map { _ in "" }
        return .init(code: code, heredocs: bodies)
    }

    /// Indices of the heredocs a segment reads, from its `<<HEREDOC#n` markers.
    static func heredocMarkers(in segment: String) -> [Int] {
        let regex = try! NSRegularExpression(pattern: #"<<HEREDOC#(\d+)"#)
        return regex.matches(in: segment, range: NSRange(segment.startIndex..., in: segment)).compactMap { match in
            Range(match.range(at: 1), in: segment).flatMap { Int(segment[$0]) }
        }
    }

    /// One simple command, the separator that ended it (`&&`, `||`, `;`, `|`, `&`, newline,
    /// `(`, `)`, `$(`, a backtick, or empty at the end), and how many subshells deep it runs.
    struct ShellSegment: Equatable {
        var text: String
        var separator: String
        var depth: Int
    }

    /// Splits a command line into simple commands at unquoted separators, pipes, subshells
    /// and command substitutions (also inside double quotes).
    static func scopedSegments(of command: String) -> [ShellSegment] {
        enum Scope { case parenthesis(Character?), backtick(Character?) }
        let characters = Array(command)
        var segments: [ShellSegment] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var scopes: [Scope] = []
        var index = 0
        func flush(_ separator: String) {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { segments.append(.init(text: trimmed, separator: separator, depth: scopes.count)) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            index += 1
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { current.append(character); escaped = true; continue }
            if quote == "'" {
                if character == "'" { quote = nil }
                current.append(character)
                continue
            }
            if character == "`" {
                flush("`")
                if case .backtick(let restore)? = scopes.last {
                    scopes.removeLast()
                    quote = restore
                } else {
                    scopes.append(.backtick(quote))
                    quote = nil
                }
                continue
            }
            if character == "$", next == "(" {
                index += 1
                flush("$(")
                scopes.append(.parenthesis(quote))
                quote = nil
                continue
            }
            if quote == "\"" {
                if character == "\"" { quote = nil }
                current.append(character)
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                current.append(character)
            case "(":
                flush("(")
                scopes.append(.parenthesis(nil))
            case ")":
                flush(")")
                if case .parenthesis(let restore)? = scopes.last {
                    scopes.removeLast()
                    quote = restore
                }
            case "&", "|":
                if next == character {
                    index += 1
                    flush(String([character, character]))
                } else if character == "|", next == "&" {
                    index += 1
                    flush("|")
                } else if character == "&", next == ">" || current.last == ">" || current.last == "<" {
                    current.append(character)
                } else {
                    flush(String(character))
                }
            case ";", "\n", "\r":
                flush(character == "\r" ? "\n" : String(character))
            default:
                current.append(character)
            }
        }
        flush("")
        return segments
    }

    static func segments(of command: String) -> [String] {
        scopedSegments(of: splitHeredocs(command).code).map(\.text)
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
            if character == "'" || character == "\"" {
                // `$'…'` and `$"…"` are quoting, not a variable.
                if current.hasSuffix("$") { current.removeLast() }
                quote = character
                hasWord = true
                continue
            }
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
        // Shell keywords that start a command inside if/while/for/{ … } blocks.
        let keywords: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!", "{"]
        while let first = cleaned.first {
            if keywords.contains(first) {
                cleaned.removeFirst()
                continue
            }
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
