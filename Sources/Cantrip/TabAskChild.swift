import Foundation

/// What a `tab ask` question's temporary child may do: look, never change. Reads are allowed, and
/// shell commands when every simple command in them is a known read-only one. Writes, other
/// programs, the web, MCP tools, subagents and messages to other tabs are refused, and nothing
/// ever waits for the user's approval.
enum TabAskPolicy {
    static let refusal = "This is an answer-only question: you may read files, logs, git state and the tab's conversation and run read-only commands, but not change anything, run other programs, use the web or MCP tools, or message other tabs. Answer from what you can see; if the answer needs a change, say what would change and suggest a handoff."

    /// Why `request` is refused, or nil when it may run.
    static func denial(for request: CantripHomeActionRequest) -> String? {
        switch request.kind {
        case .read:
            return nil
        case .shell:
            return request.taskInput || request.writesFiles || !isReadOnlyCommand(request.command) ? refusal : nil
        case .write, .url, .mcp, .other:
            return refusal
        }
    }

    /// Whether every simple command in `command` only reads, and its output goes only to the
    /// terminal (or /dev/null).
    static func isReadOnlyCommand(_ command: String) -> Bool {
        let text = ShellCommandText.splitHeredocs(command)
        guard text.heredocs.isEmpty else { return false }
        if ShellCommandText.redirectTargets(text.code).contains(where: { $0 != "/dev/null" }) { return false }
        let segments = ShellCommandText.scopedSegments(of: text.code)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { isReadOnly(ShellCommandText.commandWords($0.text)) }
    }

    /// Programs that only read, whatever their arguments.
    private static let readers: Set<String> = [
        "ls", "cat", "head", "wc", "stat", "file", "du", "df", "pwd", "echo", "printf", "date", "cal", "which",
        "whereis", "type", "ps", "pgrep", "uptime", "sw_vers", "uname", "whoami", "id", "hostname", "groups",
        "grep", "egrep", "fgrep", "rg", "ag", "tree", "cut", "tr", "nl", "column", "jq", "basename", "dirname",
        "realpath", "readlink", "diff", "cmp", "comm", "md5", "shasum", "sha1sum", "sha256sum", "md5sum",
        "cksum", "hexdump", "od", "strings", "otool", "nm", "dwarfdump", "mdls", "mdfind", "lsof", "netstat",
        "system_profiler", "ioreg", "vm_stat", "cd", "pushd", "popd", "true", "false", "test", "[", "[[",
        "sleep", "seq", "printenv", "locale", "fold", "fmt", "expand", "rev", "paste", "join", "tac",
    ]

    private static func isReadOnly(_ words: [String]) -> Bool {
        // A line of variable assignments only.
        guard let first = words.first else { return true }
        let name = ShellCommandText.baseName(first)
        let args = Array(words.dropFirst())
        if readers.contains(name) { return true }
        func flag(matching pattern: String) -> Bool {
            args.contains { $0.range(of: pattern, options: .regularExpression) != nil }
        }
        let positional = args.filter { !$0.hasPrefix("-") }
        switch name {
        case "tail":
            return !flag(matching: #"^-[A-Za-z0-9]*[fF]|^--follow"#)
        case "find":
            let acting: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"]
            return !args.contains(where: acting.contains)
        case "fd":
            return !args.contains { ["-x", "-X", "--exec", "--exec-batch"].contains($0) }
        case "sort":
            return !flag(matching: #"^-[A-Za-z]*o|^--output"#)
        case "uniq":
            return positional.count <= 1
        case "xxd":
            return positional.count <= 1 && !flag(matching: #"^-r"#)
        case "sed":
            return sedIsReadOnly(args)
        case "awk", "gawk":
            return !args.contains("-f") && !args.contains { arg in
                [">", "|", "system", "getline", "close(", "fflush", "printf >"].contains { arg.contains($0) }
            }
        case "plutil":
            if args.contains(where: { ["-convert", "-replace", "-insert", "-remove", "-create"].contains($0) }) { return false }
            if let output = args.firstIndex(of: "-o") { return args.indices.contains(output + 1) && args[output + 1] == "-" }
            return args.contains { ["-p", "-lint", "-type", "-help", "-extract"].contains($0) }
        case "defaults":
            return ["read", "read-type", "domains", "find", "help"].contains(args.first ?? "")
        case "log":
            return args.first == "show"
        case "launchctl":
            return ["list", "print", "print-disabled"].contains(args.first ?? "")
        case "pmset":
            return args.first == "-g"
        case "diskutil":
            return ["list", "info"].contains(args.first ?? "")
        case "sysctl":
            return !args.contains { $0 == "-w" || $0.contains("=") }
        case "ifconfig":
            return args.count <= 1
        case "codesign":
            return args.contains { ["-d", "-v", "--display", "--verify"].contains($0) || $0.hasPrefix("-dv") || $0.hasPrefix("-vv") }
                && !args.contains { ["-s", "--sign", "-f", "--force", "--remove-signature"].contains($0) }
        case "spctl":
            return args.contains { ["-a", "--assess"].contains($0) || $0.hasPrefix("-a") }
                && !args.contains { $0.hasPrefix("--add") || $0.hasPrefix("--remove") || $0.hasPrefix("--enable")
                    || $0.hasPrefix("--disable") || $0.hasPrefix("--master") }
        case "lipo":
            return args.contains { ["-info", "-archs", "-detailed_info"].contains($0) } && !args.contains("-output")
        case "pkgutil":
            return args.contains { ["--pkgs", "--pkg-info", "--files", "--file-info"].contains($0) }
                && !args.contains { $0.hasPrefix("--forget") || $0.hasPrefix("--expand") || $0.hasPrefix("--flatten") }
        case "xcrun":
            if args.first == "simctl" { return args.dropFirst().first == "list" }
            if args.first == "xcodebuild" { return isReadOnly(Array(args)) }
            return args.first.map { $0.hasPrefix("--show") || $0 == "--find" } ?? false
        case "xcodebuild":
            let actions: Set<String> = ["build", "test", "archive", "clean", "install", "analyze", "build-for-testing",
                                        "test-without-building", "docbuild", "installsrc", "-exportArchive",
                                        "-resolvePackageDependencies", "-exportLocalizations", "-importLocalizations",
                                        "-create-xcframework", "-runFirstLaunch", "-downloadPlatform", "-downloadAllPlatforms"]
            return args.contains { ["-version", "-showsdks", "-list", "-showBuildSettings", "-showdestinations"].contains($0) }
                && !args.contains(where: actions.contains)
        case "swift", "node", "python3", "python", "ruby", "go", "java", "rustc", "cargo", "clang", "gcc":
            return args == ["--version"] || args == ["-version"] || args == ["version"]
        case "brew":
            return ["list", "ls", "info", "--version", "config", "deps", "leaves", "--prefix"].contains(args.first ?? "")
        case "npm", "pnpm", "yarn":
            return ["ls", "list", "view", "info", "why", "explain", "--version", "-v"].contains(args.first ?? "")
        case "docker":
            return ["ps", "images", "inspect", "version", "info", "logs"].contains(args.first ?? "")
                && !args.contains { $0 == "-f" || $0 == "--follow" }
        case "tailscale":
            return ["status", "ip", "version"].contains(args.first ?? "")
        case "git":
            return gitIsReadOnly(args)
        case "gh":
            return ghIsReadOnly(args)
        case "cantrip":
            // Reading tabs is fine; asking one (or anything else Cantrip does) isn't.
            if args.first == "tab" { return ["list", "read"].contains(args.dropFirst().first ?? "list") }
            if args.first == "env" { return ["list", "show"].contains(args.dropFirst().first ?? "list") }
            return args.first == "handoffs"
        default:
            return false
        }
    }

    /// `sed` that prints or substitutes on stdout: no in-place edit, no `w`/`e` commands.
    private static func sedIsReadOnly(_ args: [String]) -> Bool {
        var scripts: [String] = []
        var index = 0
        var sawScript = false
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("-i") || arg.hasPrefix("-I") || arg.hasPrefix("--in-place") || arg == "-f" || arg.hasPrefix("--file") {
                return false
            }
            if arg == "-e" || arg == "--expression" {
                guard index + 1 < args.count else { return false }
                scripts.append(args[index + 1])
                sawScript = true
                index += 2
                continue
            }
            if !arg.hasPrefix("-"), !sawScript {
                scripts.append(arg)
                sawScript = true
            }
            index += 1
        }
        let address = #"(?:\d+|\$|/[^/]*/)"#
        let printRange = #"^\s*(?:\#(address)(?:\s*,\s*\#(address))?)?\s*[pd=]?\s*$"#
        let substitution = #"^\s*(?:\#(address)(?:\s*,\s*\#(address))?)?\s*s(.).*\1.*\1[gpiI0-9]*\s*$"#
        return scripts.allSatisfy { script in
            script.split(separator: ";").allSatisfy { part in
                let piece = String(part)
                return piece.range(of: printRange, options: .regularExpression) != nil
                    || piece.range(of: substitution, options: .regularExpression) != nil
            }
        }
    }

    private static func gitIsReadOnly(_ args: [String]) -> Bool {
        var rest = args[...]
        while let first = rest.first, first.hasPrefix("-") {
            switch first {
            case "-C", "--git-dir", "--work-tree", "--namespace":
                rest = rest.dropFirst(2)
            case "--no-pager", "-P", "--no-optional-locks", "--bare", "--literal-pathspecs":
                rest = rest.dropFirst()
            default:
                guard first.hasPrefix("--git-dir=") || first.hasPrefix("--work-tree=") else { return false }
                rest = rest.dropFirst()
            }
        }
        guard let command = rest.first else { return true }
        let more = Array(rest.dropFirst())
        if more.contains(where: { $0 == "--output" || $0.hasPrefix("--output=") || $0 == "-O" || $0.hasPrefix("--open-files-in-pager") }) {
            return false
        }
        let reading: Set<String> = [
            "status", "log", "show", "diff", "blame", "annotate", "rev-parse", "rev-list", "describe", "ls-files",
            "ls-tree", "ls-remote", "cat-file", "shortlog", "grep", "name-rev", "merge-base", "for-each-ref",
            "count-objects", "check-ignore", "check-attr", "var", "version", "help", "whatchanged", "cherry",
            "range-diff", "show-ref", "show-branch", "verify-commit", "verify-tag", "diff-tree", "diff-files", "diff-index",
        ]
        if reading.contains(command) { return true }
        switch command {
        case "branch", "tag":
            let changing: Set<String> = ["-d", "-D", "-m", "-M", "-c", "-C", "-f", "-a", "-s", "-u", "-F", "-t",
                                         "--delete", "--move", "--copy", "--force", "--set-upstream-to", "--unset-upstream",
                                         "--edit-description", "--track", "--no-track", "--annotate", "--sign", "--file",
                                         "--message", "--create-reflog", "-e", "--edit"]
            // -a lists every branch; for tags it annotates.
            let changes = command == "branch" ? changing.subtracting(["-a"]) : changing
            if more.contains(where: { changes.contains($0) || $0.hasPrefix("--set-upstream-to=") || $0.hasPrefix("--message=")
                || ($0.hasPrefix("-m") && $0.count > 2) }) { return false }
            let valued: Set<String> = ["--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--format", "--sort", "--column"]
            let listing = more.contains("--list") || more.contains("-l")
            var index = 0
            while index < more.count {
                let arg = more[index]
                if valued.contains(arg) { index += 2; continue }
                if !arg.hasPrefix("-"), !listing { return false }
                index += 1
            }
            return true
        case "remote":
            return more.isEmpty || more == ["-v"] || more == ["--verbose"] || ["show", "get-url"].contains(more.first ?? "")
        case "config":
            if ["get", "list"].contains(more.first ?? "") { return true }
            let setting: Set<String> = ["--unset", "--unset-all", "--add", "--replace-all", "--rename-section",
                                        "--remove-section", "-e", "--edit", "set", "unset"]
            return more.contains { ["--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l"].contains($0) }
                && !more.contains(where: setting.contains)
        case "stash":
            return ["list", "show"].contains(more.first ?? "")
        case "worktree":
            return more.first == "list"
        case "reflog":
            return !more.contains { ["expire", "delete"].contains($0) }
        case "notes":
            return ["list", "show"].contains(more.first ?? "list")
        case "submodule":
            return more.isEmpty || ["status", "summary"].contains(more.first ?? "")
        case "lfs":
            return ["ls-files", "status", "env", "version"].contains(more.first ?? "")
        default:
            return false
        }
    }

    private static func ghIsReadOnly(_ args: [String]) -> Bool {
        guard let group = args.first else { return true }
        if args.contains(where: { ["--web", "-w", "--watch"].contains($0) }) { return false }
        let action = args.dropFirst().first ?? ""
        switch group {
        case "--version", "version", "search", "status":
            return true
        case "run": return ["list", "view"].contains(action)
        case "pr": return ["list", "view", "status", "checks", "diff"].contains(action)
        case "issue": return ["list", "view", "status"].contains(action)
        case "release", "repo", "workflow", "label", "secret", "variable": return ["list", "view"].contains(action)
        case "cache": return action == "list"
        case "auth": return action == "status"
        case "api":
            var index = 1
            while index < args.count {
                let arg = args[index]
                if ["-f", "-F", "--field", "--raw-field", "--input"].contains(arg) || arg.hasPrefix("--field=")
                    || arg.hasPrefix("--raw-field=") || arg.hasPrefix("--input=") { return false }
                if arg == "-X" || arg == "--method" {
                    guard index + 1 < args.count, args[index + 1].uppercased() == "GET" else { return false }
                    index += 2
                    continue
                }
                if arg.hasPrefix("--method=") || (arg.hasPrefix("-X") && arg.count > 2) {
                    let method = arg.hasPrefix("--method=") ? String(arg.dropFirst(9)) : String(arg.dropFirst(2))
                    guard method.uppercased() == "GET" else { return false }
                }
                index += 1
            }
            return true
        default:
            return false
        }
    }
}

/// A `tab ask` question's temporary child of the tab asked: a fresh session of that tab's backend
/// and model, in its folder, given its conversation (earlier turns as a compact summary and recent
/// turns, and the turn it's on now with its steps so far) and its memory notes, read-only. It
/// answers one question (`TabAskPolicy`), and is then deleted: its backend process, session files
/// and defaults. It never joins the tab's history, queue or child tabs, so it answers at once
/// while the tab works, and the tab's turn goes on untouched.
@MainActor
final class TabAskChild {
    /// What deleting a child's backend session takes, saved with its ask so a child cut off by a
    /// crash is still deleted at the next launch.
    struct Footprint: Codable, Equatable {
        var childID: UUID
        var backend: String
        /// Where Claude Code, Codex and Antigravity keep the session ID (Cantrip's defaults).
        var persistKey: String
        /// Backend session IDs (Copilot CLI sessions, or the one Claude/Codex/Antigravity session).
        var sessions: [String] = []
        var workdir: String
    }

    struct Spec {
        let id: UUID
        let kind: BackendKind
        let selection: SessionModelSelection?
        let workdir: String
        let label: String
        var persistKey: String { "tabAskChild.\(id.uuidString)" }
        var model: String { selection?.model.isEmpty == false ? selection!.model : "default model" }
    }

    /// A question's child stops (and is deleted) after this long. The `tabAskTimeLimit` default
    /// (seconds) overrides it, to check a timeout on a running Mac.
    static var timeLimit: TimeInterval = 300
    private static var effectiveTimeLimit: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "tabAskTimeLimit")
        return override > 0 ? override : timeLimit
    }
    /// Tests stand in for the real backends here.
    static var makeBackend: ((Spec) -> Backend)?
    /// Seconds before deleting the session (the backend's process exits after reset) and before
    /// deleting again what it wrote on its way out.
    static var cleanupDelays: (first: TimeInterval, second: TimeInterval) = (1.5, 3)
    /// Children answering now: their processes can't ask other tabs.
    private(set) static var running: Set<UUID> = []

    let spec: Spec
    private(set) var footprint: Footprint
    let startedAt = Date()
    var onStatus: ((String) -> Void)?
    var onFootprint: ((Footprint) -> Void)?
    var onFinish: ((Result<String, TabInsight.Failure>) -> Void)?
    var onCleaned: ((Footprint) -> Void)?
    private var backend: Backend?
    private var text = ""
    private var timer: Task<Void, Never>?
    private var finished = false

    init(spec: Spec) {
        self.spec = spec
        footprint = Footprint(childID: spec.id, backend: spec.kind.rawValue, persistKey: spec.persistKey, workdir: spec.workdir)
    }

    func start(prompt: String, question: String, turns: [ConversationTurn]) {
        Self.running.insert(spec.id)
        let backend = Self.makeBackend?(spec) ?? Self.standardBackend(spec) { [weak self] session in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.recordSession(session) }
            }
        }
        self.backend = backend
        if spec.kind != .localModel { UsageTracker.shared.recordQuery(backend: spec.kind) }
        let request = BackendRequest(prompt: prompt, userMessage: question, previousTurns: turns)
        backend.send(request, workdir: spec.workdir) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        let limit = Self.effectiveTimeLimit
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(.init("It didn't answer within \(Self.minutes(limit)), so its temporary copy was stopped and deleted.")))
        }
    }

    /// Stops it now (Cantrip quitting, or the ask withdrawn).
    func stop(_ reason: String) { finish(.failure(.init(reason))) }

    private func recordSession(_ session: String) {
        guard !footprint.sessions.contains(session) else { return }
        footprint.sessions.append(session)
        guard !finished else {
            // Named only after it stopped: delete that session too.
            var late = footprint
            late.sessions = [session]
            let delay = Self.cleanupDelays.first
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                TabAskChildCleanup.remove(late)
                Log.write("tab-ask: child \(late.childID.uuidString.prefix(8)) deleted a session named after it stopped (\(session))")
            }
            return
        }
        onFootprint?(footprint)
    }

    private func handle(_ event: BackendEvent) {
        guard !finished else { return }
        switch event {
        case .textDelta(let delta):
            text += delta
        case .activity(let activity) where activity.state == .running:
            onStatus?(activity.title)
        case .inputRequired(let request):
            // Nobody answers for a question's child: no approvals, no questions to the user.
            request.cancel()
        case .done:
            let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(answer.isEmpty ? .failure(.init("Its temporary copy finished without an answer.")) : .success(answer))
        case .failure(let message):
            finish(.failure(.init(String(message.prefix(300)))))
        default:
            break
        }
    }

    private func finish(_ result: Result<String, TabInsight.Failure>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        Self.running.remove(spec.id)
        // Claude Code, Codex and Antigravity keep their session ID in defaults; read it before reset.
        if spec.kind != .copilot, spec.kind != .copilotRemote,
           let session = UserDefaults.standard.string(forKey: spec.persistKey), !session.isEmpty,
           !footprint.sessions.contains(session) {
            footprint.sessions.append(session)
        }
        let backend = self.backend
        self.backend = nil
        backend?.cancel()
        backend?.reset()
        onFinish?(result)
        let footprint = self.footprint
        let delays = Self.cleanupDelays
        Task.detached(priority: .utility) {
            // The backend's process exits after reset; files it writes on its way out go too.
            try? await Task.sleep(nanoseconds: UInt64(delays.first * 1_000_000_000))
            TabAskChildCleanup.remove(footprint)
            try? await Task.sleep(nanoseconds: UInt64(delays.second * 1_000_000_000))
            let left = TabAskChildCleanup.remove(footprint)
            let checked = TabAskChildCleanup.paths(footprint).map(\.path)
            await MainActor.run { [weak self] in
                if left.isEmpty {
                    Log.write("tab-ask: child \(footprint.childID.uuidString.prefix(8)) deleted (\(footprint.backend) sessions \(footprint.sessions); "
                              + "gone: \(checked.isEmpty ? "no session files" : checked.joined(separator: ", ")))")
                } else {
                    Log.write("tab-ask: child \(footprint.childID.uuidString.prefix(8)) left \(left.count) path(s): \(left.prefix(3).joined(separator: ", "))")
                }
                self?.onCleaned?(footprint)
            }
        }
    }

    nonisolated static func minutes(_ seconds: TimeInterval) -> String {
        seconds >= 60 ? "\(Int((seconds / 60).rounded())) minute\(Int((seconds / 60).rounded()) == 1 ? "" : "s")" : "\(Int(seconds)) seconds"
    }

    /// The tab's backend and model, read-only through the answer-only guardrail.
    static func standardBackend(_ spec: Spec, onSession: @escaping (String) -> Void) -> Backend {
        let selection = spec.selection
        switch spec.kind {
        case .copilot, .copilotRemote:
            // Copilot Remote sessions can't be found again to delete, so its question runs on the
            // Copilot CLI with the same model.
            let copilot = CopilotBackend()
            copilot.tabID = spec.id
            copilot.modelOverride = selection?.model
            copilot.effortOverride = selection?.effort
            copilot.contextTierOverride = selection?.contextTier
            copilot.allowToolsOverride = true
            copilot.excludedTools = ["task"]
            copilot.sessionStorageKey = nil
            copilot.guardrail = .answerOnly
            copilot.guardrailLabel = spec.label
            copilot.onAgentSession = onSession
            return copilot
        case .claudeCode:
            let claude = ClaudeCodeBackend(persistKey: spec.persistKey)
            claude.tabID = spec.id
            claude.modelOverride = selection.map { $0.model.isEmpty ? "default" : $0.model }
            claude.effortOverride = selection?.effort
            claude.guardrail = .answerOnly
            claude.guardrailLabel = spec.label
            return claude
        case .codex:
            let codex = CodexBackend(persistKey: spec.persistKey,
                                     modelOverride: selection.flatMap { $0.model.isEmpty ? nil : $0.model },
                                     effortOverride: selection.flatMap { $0.effort.isEmpty ? nil : $0.effort })
            codex.tabID = spec.id
            codex.guardrail = .answerOnly
            codex.guardrailLabel = spec.label
            return codex
        case .antigravity:
            let antigravity = AntigravityBackend(persistKey: spec.persistKey,
                                                 modelOverride: selection.flatMap { $0.model.isEmpty ? nil : $0.model },
                                                 effortOverride: selection.flatMap { $0.effort.isEmpty ? nil : $0.effort })
            antigravity.guardrail = .answerOnly
            antigravity.guardrailLabel = spec.label
            return antigravity
        case .localModel:
            let local = OpenAICompatibleBackend()
            local.modelOverride = selection.flatMap { $0.model.isEmpty ? nil : $0.model }
            local.readOnly = true
            return local
        }
    }

    // MARK: - The prompt

    /// The child's message: who it is and its rules, the tab's state and the turn it's on, then the
    /// question. Earlier turns travel as `previousTurns` (the backend sends a compact summary and
    /// the recent ones); `memory` is the vault's read-only block.
    static func prompt(question: String, askerTitle: String, tab: ChatSession, context: ChatSession.QuestionContext,
                       child: ChildTab?, memory: String) -> String {
        let title = TabInsight.oneLine(tab.title, 80)
        var lines = [
            """
            (You are a temporary, read-only copy of the tab “\(title)”, started only to answer one question from \(askerTitle), sent with `tab ask`. The tab keeps working and never sees this. You have its conversation (earlier turns above as context, and the turn it's on now below), and you run in its project folder with its model.

            Answer only. You may read files, logs, git state and the conversation, and run read-only commands. Don't edit files, commit, push, deploy, start builds or simulators, create handoffs, tasks or child tabs, or message other tabs: Cantrip refuses those. If answering needs a change, say what would need to change and suggest a handoff to the tab. Answer briefly and directly; your reply goes back to \(askerTitle), and this copy is deleted afterwards.)
            """,
        ]
        var state = "Tab “\(title)” (\(tab.id.uuidString)); folder \(tab.workdir.isEmpty ? "none" : tab.workdir); " + TabInsight.state(of: tab)
        if let child { state += "; child tab of “\(TabInsight.oneLine(child.parentTitle, 60))” (\(child.statusLine.lowercased()))" }
        lines.append(state + ".")
        if let current = context.current {
            var block = ["The turn it's working on now (still running"
                         + (current.startedAt.map { ", started \(Self.clock.string(from: $0))" } ?? "") + "):",
                         "Request: " + TabInsight.clip(current.request, head: 3_000, tail: 1_000)]
            let steps = current.steps.suffix(15)
            if !steps.isEmpty {
                block.append("Steps so far" + (current.steps.count > steps.count ? " (latest \(steps.count) of \(current.steps.count))" : "") + ":")
                for step in steps {
                    let mark = switch step.state {
                    case .running: "… "
                    case .succeeded: "✓ "
                    case .failed: "✗ "
                    case .cancelled: "– "
                    }
                    block.append("- " + mark + TabInsight.oneLine(step.title, 160)
                                 + (step.state == .running ? " (running)" : ""))
                }
            }
            if !current.reply.isEmpty {
                block.append("Its reply so far: " + TabInsight.clip(current.reply, head: 1_000, tail: 3_000))
            }
            lines.append(block.joined(separator: "\n"))
        }
        if !context.queued.isEmpty {
            lines.append("Waiting in its queue: " + context.queued.prefix(3).map { "“\(TabInsight.oneLine($0, 100))”" }.joined(separator: "; ")
                         + (context.queued.count > 3 ? " and \(context.queued.count - 3) more" : "") + ".")
        }
        lines.append("Question from \(askerTitle):\n\(question)")
        return lines.joined(separator: "\n\n") + memory
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// Deletes a question's child: its backend session files and index rows, and its defaults.
enum TabAskChildCleanup {
    struct Roots: Sendable {
        var home: URL

        static var standard: Roots { Roots(home: FileManager.default.homeDirectoryForCurrentUser) }
        var copilotState: URL { home.appendingPathComponent(".copilot/session-state", isDirectory: true) }
        var copilotStore: URL { home.appendingPathComponent(".copilot/session-store.db") }
        var claudeProjects: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }
        var codexSessions: URL { home.appendingPathComponent(".codex/sessions", isDirectory: true) }
        var codex: URL { home.appendingPathComponent(".codex", isDirectory: true) }
        var antigravity: URL { home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true) }
    }

    /// The paths a child's sessions would leave, for checks: each must be gone after `remove`.
    static func paths(_ footprint: TabAskChild.Footprint, roots: Roots = .standard) -> [URL] {
        var paths: [URL] = []
        let files = FileManager.default
        for session in footprint.sessions where UUID(uuidString: session) != nil {
            switch BackendKind(rawValue: footprint.backend) {
            case .copilot, .copilotRemote, nil:
                paths.append(roots.copilotState.appendingPathComponent(session, isDirectory: true))
            case .claudeCode:
                let folders = (try? files.contentsOfDirectory(at: roots.claudeProjects, includingPropertiesForKeys: nil)) ?? []
                for folder in folders {
                    paths.append(folder.appendingPathComponent("\(session).jsonl"))
                    paths.append(folder.appendingPathComponent(session, isDirectory: true))
                }
                for name in ["session-env", "file-history", "todos", "tasks"] {
                    paths.append(roots.home.appendingPathComponent(".claude/\(name)/\(session)"))
                }
            case .codex:
                if let rollout = TranscriptScrubber.codexRollout(session, in: roots.codexSessions) { paths.append(rollout) }
            case .antigravity:
                paths.append(roots.antigravity.appendingPathComponent("brain/\(session)", isDirectory: true))
                for suffix in [".db", ".db-wal", ".db-shm", ".pb"] {
                    paths.append(roots.antigravity.appendingPathComponent("conversations/\(session)\(suffix)"))
                }
                paths.append(roots.antigravity.appendingPathComponent("annotations/\(session).pbtxt"))
            case .localModel:
                break
            }
        }
        return paths
    }

    /// Deletes everything; returns the paths still there.
    @discardableResult
    static func remove(_ footprint: TabAskChild.Footprint, roots: Roots = .standard) -> [String] {
        let files = FileManager.default
        let kind = BackendKind(rawValue: footprint.backend)
        if kind == .copilot || kind == .copilotRemote {
            let folders = footprint.sessions.map { roots.copilotState.appendingPathComponent($0, isDirectory: true) }
            TranscriptScrubber.waitForCopilotRuntimes(in: folders, timeout: 10)
        }
        for path in paths(footprint, roots: roots) where files.fileExists(atPath: path.path) {
            do { try files.removeItem(at: path) } catch {
                Log.write("tab-ask: couldn't delete \(path.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let sessions = footprint.sessions.filter { UUID(uuidString: $0) != nil }
        if !sessions.isEmpty {
            switch kind {
            case .copilot, .copilotRemote, nil:
                deleteRows(in: roots.copilotStore, ids: sessions, idColumn: "session_id", ownTable: "sessions")
            case .codex:
                for database in codexDatabases(roots) {
                    deleteRows(in: database, ids: sessions, idColumn: "thread_id", ownTable: "threads")
                }
            default:
                break
            }
        }
        let defaults = UserDefaults.standard
        for suffix in ["", ".seenTurns", ".folder", ".workdir", ".folderRules"] {
            defaults.removeObject(forKey: footprint.persistKey + suffix)
        }
        return paths(footprint, roots: roots).filter { files.fileExists(atPath: $0.path) }.map(\.path)
    }

    private static func codexDatabases(_ roots: Roots) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: roots.codex.path)) ?? []
        return names.filter { ($0.hasPrefix("state_") || $0.hasPrefix("thread_history_")) && $0.hasSuffix(".sqlite") }
            .map { roots.codex.appendingPathComponent($0) }
    }

    /// Removes a session's rows: every table with `idColumn`, and its own row in `ownTable`.
    static func deleteRows(in database: URL, ids: [String], idColumn: String, ownTable: String) {
        guard FileManager.default.fileExists(atPath: database.path) else { return }
        do {
            let store = try SQLiteStore(database)
            let tables = try store.rows("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.first as? String }
            try store.execute("PRAGMA secure_delete = ON")
            try store.execute("BEGIN IMMEDIATE")
            do {
                for table in tables where !table.hasPrefix("sqlite_") && !table.contains("_data") && !table.contains("_idx")
                    && !table.contains("_docsize") && !table.contains("_config") && !table.contains("_content") {
                    let columns = store.columns(table)
                    for id in ids {
                        if columns.contains(idColumn) {
                            try store.execute("DELETE FROM \"\(table)\" WHERE \(idColumn) = ?", [id])
                        }
                        if table == ownTable, columns.contains("id") {
                            try store.execute("DELETE FROM \"\(table)\" WHERE id = ?", [id])
                        }
                        if columns.contains("parent_thread_id"), columns.contains("child_thread_id") {
                            try store.execute("DELETE FROM \"\(table)\" WHERE parent_thread_id = ? OR child_thread_id = ?", [id, id])
                        }
                    }
                }
                try store.execute("COMMIT")
            } catch {
                try? store.execute("ROLLBACK")
                throw error
            }
        } catch {
            Log.write("tab-ask: couldn't remove a child's rows from \(database.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
