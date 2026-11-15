import Foundation

extension SessionTabTests {
    /// A question's temporary copy only looks: reads and read-only commands run, the rest is refused
    /// and nothing ever asks the user.
    static func testTabAskPolicy() throws {
        let cantrip = "'/Users/someone/Coding/Cantrip/Cantrip.app/Contents/MacOS/Cantrip'"
        let allowed = [
            "git status", "git -C /tmp/project log --oneline -5", "git --no-pager diff HEAD~1 -- README.md",
            "ls -la && cat README.md | head -20", "grep -rn port . 2>/dev/null", "rg -n TODO Sources | wc -l",
            "sed -n '1,40p' notes.txt", "cat log.txt | sed 's/secret/x/g'", "gh run view 123 --log",
            "gh api repos/acme/app/actions/runs", "gh api -X GET repos/acme/app", "defaults read com.example.app key",
            "find . -name '*.swift' -newer Package.swift", "tail -n 50 build.log", "git branch -a",
            "git branch --contains abc123", "git branch --list 'feature/*'", "git tag -l 'v*'", "git tag",
            "git config --get user.name", "git stash list", "git worktree list", "git remote -v",
            "xcodebuild -list -project App.xcodeproj", "xcrun simctl list devices", "plutil -p Info.plist",
            "\(cantrip) tab read 1A2B3C4D --turns 5", "\(cantrip) tab list", "echo $(git rev-parse HEAD)",
            "cd /tmp/project && git log -1 --format=%H", "ps aux | grep -i copilot", "log show --last 5m --predicate 'x'",
            "launchctl list | grep cantrip", "du -sh build", "swift --version", "FOO=1 git status",
        ]
        for command in allowed {
            precondition(TabAskPolicy.isReadOnlyCommand(command), "should be read-only: \(command)")
        }
        let refused = [
            "rm -rf build", "git commit -m x", "git push", "git checkout main", "git branch new-feature", "git tag v1.0",
            "git -c core.pager=x status", "git fetch", "git stash", "echo hi > notes.txt", "cat a >> b", "ls | tee out.txt",
            "sed -i '' 's/a/b/' notes.txt", "sed 's/a/b/w out' notes.txt", "sed -n '1p;w copy' notes.txt",
            "find . -delete", "find . -exec rm {} \\;", "tail -f build.log", "tail -F log", "python3 -c 'print(1)'",
            "curl https://example.com", "\(cantrip) tab ask 1A2B3C4D hi", "\(cantrip) sim acquire --device iPhone",
            "make build", "xcodebuild build", "xcodebuild -list build", "gh pr create", "gh api -X POST repos/acme/app/issues",
            "gh api repos/acme/app/issues -f title=x", "gh pr view 3 --web", "npm install", "awk '{print > \"f\"}' x",
            "cat <<EOF\nhi\nEOF", "ls | xargs rm", "open .", "sort -o out.txt in.txt", "osascript -e 'beep'", "$CMD --go",
            "defaults write com.example.app key 1", "plutil -convert json Info.plist", "launchctl kickstart gui/501/x",
            "swift build", "codesign --sign - App.app", "git diff --output=patch.txt", "kill 123", "",
        ]
        for command in refused {
            precondition(!TabAskPolicy.isReadOnlyCommand(command), "should be refused: \(command)")
        }

        func decide(_ request: CantripHomeActionRequest) -> AgentPolicyOutcome {
            AgentPolicyGate.decide(request, guardrail: .answerOnly, approval: .ask, label: "Question", workdir: "/tmp",
                                   policy: AgentPolicyDocument())
        }
        func denied(_ outcome: AgentPolicyOutcome) -> Bool {
            if case .deny(let reason, let by) = outcome { return by == "Answer-only question" && reason.contains("suggest a handoff") }
            return false
        }
        precondition(decide(.init(kind: .read, paths: ["/tmp/a.txt"])) == .allow(by: "Answer-only question"))
        precondition(decide(.shell("git log -3")) == .allow(by: "Answer-only question"), "no approval needed, even on Ask")
        precondition(denied(decide(.shell("git push"))) && denied(decide(.write("/tmp/a.txt")))
                     && denied(decide(.init(kind: .url, url: "https://example.com")))
                     && denied(decide(.init(kind: .mcp, server: "notion", tool: "search", readOnly: true)))
                     && denied(decide(.init(kind: .other, tool: "Task"))), "change, web, MCP and subagents are refused")
        var redirected = CantripHomeActionRequest.shell("cat a")
        redirected.writesFiles = true
        precondition(denied(decide(redirected)))
        precondition(CodexBackend.threadPolicy(.guardrail(.answerOnly)) == ("read-only", "untrusted"),
                     "Codex runs a question in its read-only sandbox")
        print("Tab ask policy: reads and read-only commands only, nothing waits for approval")
    }

    /// Deleting a question's copy removes its backend session everywhere it lives, and nothing else.
    static func testTabAskCleanup() throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("cantrip-tab-ask-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: home) }
        let roots = TabAskChildCleanup.Roots(home: home)
        func touch(_ path: URL) throws {
            try files.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: path)
        }
        let mine = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()

        // Copilot: the session folder and every row of it in the CLI's index.
        try touch(roots.copilotState.appendingPathComponent("\(mine)/events.jsonl"))
        try touch(roots.copilotState.appendingPathComponent("\(mine)/files/answer.md"))
        try touch(roots.copilotState.appendingPathComponent("\(other)/events.jsonl"))
        func database(_ url: URL) throws -> SQLiteStore {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            files.createFile(atPath: url.path, contents: nil)
            return try SQLiteStore(url)
        }
        let store = try database(roots.copilotStore)
        try store.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT)")
        try store.execute("CREATE TABLE turns (id INTEGER PRIMARY KEY, session_id TEXT, user_message TEXT)")
        try store.execute("CREATE TABLE session_files (id INTEGER PRIMARY KEY, session_id TEXT, file_path TEXT)")
        try store.execute("CREATE VIRTUAL TABLE search_index USING fts5(content, session_id, source_type, source_id)")
        for id in [mine, other] {
            try store.execute("INSERT INTO sessions (id, cwd) VALUES (?, '/tmp')", [id])
            try store.execute("INSERT INTO turns (session_id, user_message) VALUES (?, 'Which port?')", [id])
            try store.execute("INSERT INTO session_files (session_id, file_path) VALUES (?, 'a.txt')", [id])
            try store.execute("INSERT INTO search_index (content, session_id, source_type, source_id) VALUES ('Which port?', ?, 'turn', 'x')", [id])
        }
        var copilot = TabAskChild.Footprint(childID: UUID(), backend: BackendKind.copilot.rawValue,
                                            persistKey: "tabAskChild.test-\(UUID().uuidString)", workdir: "/tmp")
        copilot.sessions = [mine]
        UserDefaults.standard.set("x", forKey: copilot.persistKey)
        var left = TabAskChildCleanup.remove(copilot, roots: roots)
        precondition(left.isEmpty && !files.fileExists(atPath: roots.copilotState.appendingPathComponent(mine).path)
                     && files.fileExists(atPath: roots.copilotState.appendingPathComponent("\(other)/events.jsonl").path), "\(left)")
        for table in ["sessions", "turns", "session_files", "search_index"] {
            let column = table == "sessions" ? "id" : "session_id"
            let mineLeft = try store.rows("SELECT count(*) FROM \(table) WHERE \(column) = ?", [mine]).first?.first as? Int64
            let otherLeft = try store.rows("SELECT count(*) FROM \(table) WHERE \(column) = ?", [other]).first?.first as? Int64
            precondition(mineLeft == 0 && otherLeft == 1, "\(table): \(String(describing: mineLeft)) / \(String(describing: otherLeft))")
        }
        precondition(UserDefaults.standard.object(forKey: copilot.persistKey) == nil)

        // Claude Code: the transcript, its folder, session environment and file history.
        let project = roots.claudeProjects.appendingPathComponent("-tmp-project", isDirectory: true)
        try touch(project.appendingPathComponent("\(mine).jsonl"))
        try touch(project.appendingPathComponent("\(mine)/subagents/agent-1.jsonl"))
        try touch(home.appendingPathComponent(".claude/session-env/\(mine)/env"))
        try touch(home.appendingPathComponent(".claude/file-history/\(mine)/a@v1"))
        try touch(project.appendingPathComponent("\(other).jsonl"))
        var claude = TabAskChild.Footprint(childID: UUID(), backend: BackendKind.claudeCode.rawValue,
                                           persistKey: "tabAskChild.test-\(UUID().uuidString)", workdir: "/tmp")
        claude.sessions = [mine]
        UserDefaults.standard.set(mine, forKey: claude.persistKey)
        UserDefaults.standard.set(2, forKey: claude.persistKey + ".seenTurns")
        left = TabAskChildCleanup.remove(claude, roots: roots)
        precondition(left.isEmpty && !files.fileExists(atPath: project.appendingPathComponent("\(mine).jsonl").path)
                     && !files.fileExists(atPath: project.appendingPathComponent(mine).path)
                     && !files.fileExists(atPath: home.appendingPathComponent(".claude/session-env/\(mine)").path)
                     && !files.fileExists(atPath: home.appendingPathComponent(".claude/file-history/\(mine)").path)
                     && files.fileExists(atPath: project.appendingPathComponent("\(other).jsonl").path), "\(left)")
        precondition(UserDefaults.standard.object(forKey: claude.persistKey) == nil
                     && UserDefaults.standard.object(forKey: claude.persistKey + ".seenTurns") == nil)

        // Codex: the rollout and the thread's rows in its state and history databases.
        let day = roots.codexSessions.appendingPathComponent("2026/11/14", isDirectory: true)
        try touch(day.appendingPathComponent("rollout-2026-11-14T00-00-00-\(mine).jsonl"))
        try touch(day.appendingPathComponent("rollout-2026-11-14T00-00-00-\(other).jsonl"))
        let state = try database(roots.codex.appendingPathComponent("state_5.sqlite"))
        try state.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT)")
        try state.execute("CREATE TABLE thread_dynamic_tools (thread_id TEXT, name TEXT)")
        try state.execute("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT, status TEXT)")
        let history = try database(roots.codex.appendingPathComponent("thread_history_1.sqlite"))
        try history.execute("CREATE TABLE thread_items (thread_id TEXT, item_id TEXT)")
        for id in [mine, other] {
            try state.execute("INSERT INTO threads (id, rollout_path) VALUES (?, 'x')", [id])
            try state.execute("INSERT INTO thread_dynamic_tools (thread_id, name) VALUES (?, 'x')", [id])
            try history.execute("INSERT INTO thread_items (thread_id, item_id) VALUES (?, 'x')", [id])
        }
        try state.execute("INSERT INTO thread_spawn_edges VALUES (?, ?, 'done')", [mine, other])
        var codex = TabAskChild.Footprint(childID: UUID(), backend: BackendKind.codex.rawValue,
                                          persistKey: "tabAskChild.test-\(UUID().uuidString)", workdir: "/tmp")
        codex.sessions = [mine]
        left = TabAskChildCleanup.remove(codex, roots: roots)
        precondition(left.isEmpty && !files.fileExists(atPath: day.appendingPathComponent("rollout-2026-11-14T00-00-00-\(mine).jsonl").path)
                     && files.fileExists(atPath: day.appendingPathComponent("rollout-2026-11-14T00-00-00-\(other).jsonl").path), "\(left)")
        for (database, table, column) in [(state, "threads", "id"), (state, "thread_dynamic_tools", "thread_id"),
                                          (history, "thread_items", "thread_id")] {
            let mineLeft = try database.rows("SELECT count(*) FROM \(table) WHERE \(column) = ?", [mine]).first?.first as? Int64
            let otherLeft = try database.rows("SELECT count(*) FROM \(table) WHERE \(column) = ?", [other]).first?.first as? Int64
            precondition(mineLeft == 0 && otherLeft == 1, table)
        }
        let edges = try state.rows("SELECT count(*) FROM thread_spawn_edges").first?.first as? Int64
        precondition(edges == 0)

        // Antigravity: the agent's brain folder, conversation database and annotations.
        try touch(roots.antigravity.appendingPathComponent("brain/\(mine)/task.md"))
        try touch(roots.antigravity.appendingPathComponent("conversations/\(mine).db"))
        try touch(roots.antigravity.appendingPathComponent("annotations/\(mine).pbtxt"))
        try touch(roots.antigravity.appendingPathComponent("brain/\(other)/task.md"))
        var antigravity = TabAskChild.Footprint(childID: UUID(), backend: BackendKind.antigravity.rawValue,
                                                persistKey: "tabAskChild.test-\(UUID().uuidString)", workdir: "/tmp")
        antigravity.sessions = [mine]
        left = TabAskChildCleanup.remove(antigravity, roots: roots)
        precondition(left.isEmpty && TabAskChildCleanup.paths(antigravity, roots: roots).allSatisfy { !files.fileExists(atPath: $0.path) }
                     && files.fileExists(atPath: roots.antigravity.appendingPathComponent("brain/\(other)/task.md").path), "\(left)")
        print("Tab ask cleanup: Copilot, Claude Code, Codex and Antigravity sessions deleted, others kept")
    }

    /// A copy that doesn't answer in time is stopped and deleted, and the question fails.
    @MainActor
    static func testTabAskTimeout() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled)
        settings.backend = .copilot
        settings.memoryEnabled = false
        defer { (settings.backend, settings.memoryEnabled) = saved }
        let manager = SessionManager()
        let quiet = InsightFixtureBackend()
        let tab = ChatSession(copilotBackend: InsightFixtureBackend())
        try tab.updateTab(name: "Slow tab")
        manager.sessions.append(tab)
        defer { tab.cancel() }
        TabAskChild.makeBackend = { _ in quiet }
        TabAskChild.cleanupDelays = (0, 0)
        TabAskChild.timeLimit = 0.3
        defer { TabAskChild.makeBackend = nil; TabAskChild.cleanupDelays = (1.5, 3); TabAskChild.timeLimit = 300 }
        let ask = try manager.tabAsks.ask(tab.id.uuidString, question: "Are you done?", from: nil, steer: false)
        try await waitForJournalTest { quiet.prompts.count == 1 }
        try await waitForJournalTest { manager.tabAsks.lookup(ask.id, markDelivered: false)?.status == "failed" }
        let failed = try requireTabAsk(manager.tabAsks.asks[ask.id])
        precondition(failed.tracking.error?.contains("didn't answer within") == true && quiet.cancels >= 1 && quiet.resets >= 1,
                     failed.tracking.error ?? "nil")
        try await waitForJournalTest { manager.tabAsks.asks[ask.id]?.child == nil && manager.tabAsks.children.isEmpty }
        precondition(TabAskChild.running.isEmpty && tab.messages.isEmpty, "nothing of it is left, in the tab or running")
        // A late answer from the stopped copy changes nothing.
        quiet.finish("Yes.")
        precondition(manager.tabAsks.asks[ask.id]?.status == "failed")
        print("Tab ask timeout: the copy is stopped and deleted, and the question fails")
    }

    /// Live (CANTRIP_TABASK_LIVE_TEST=1, real Copilot, one small question): a temporary copy reads a
    /// scratch repository, is refused an edit and a commit, answers, and its session is deleted.
    @MainActor
    static func testTabAskLive() async throws {
        let environment = ProcessInfo.processInfo.environment
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled)
        settings.backend = .copilot
        settings.memoryEnabled = false
        defer { (settings.backend, settings.memoryEnabled) = saved }
        let started = Date()
        func log(_ text: String) { print(String(format: "%6.1fs %@", Date().timeIntervalSince(started), text)) }
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("cantrip-tab-ask-live-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        try Data("The dev server listens on port 8765.\n".utf8).write(to: scratch.appendingPathComponent("notes.txt"))
        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", scratch.path] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        _ = try git(["init", "-q"])
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "add", "notes.txt"])
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "Document the dev server port"])

        let tab = ChatSession(id: UUID())
        defer { tab.cancel() }
        tab.workdir = scratch.path
        tab.messages = [ChatMessage(role: .user, text: "Write down where the dev server listens."),
                        ChatMessage(role: .assistant, text: "I wrote it in notes.txt and committed it.")]
        let spec = TabAskChild.Spec(id: UUID(), kind: .copilot,
                                    selection: SessionModelSelection(model: environment["CANTRIP_LIVE_MODEL"] ?? "claude-haiku-4.5",
                                                                     effort: "", contextTier: ""),
                                    workdir: scratch.path, label: "Live question")
        let question = "What is the subject of the latest git commit in this folder, and which port does notes.txt give? "
            + "Then create a file named changed.txt containing hi, and run `git commit --allow-empty -m extra`; tell me whether each worked."
        let context = tab.questionContext()
        let runner = TabAskChild(spec: spec)
        var result: Result<String, TabInsight.Failure>?
        var cleaned: TabAskChild.Footprint?
        var steps: [String] = []
        var folderDuringRun = false
        runner.onStatus = { steps.append($0) }
        runner.onFinish = { outcome in
            result = outcome
            folderDuringRun = runner.footprint.sessions.contains { session in
                files.fileExists(atPath: TabAskChildCleanup.Roots.standard.copilotState.appendingPathComponent(session).path)
            }
        }
        runner.onCleaned = { cleaned = $0 }
        runner.start(prompt: TabAskChild.prompt(question: question, askerTitle: "the live test", tab: tab, context: context,
                                                child: nil, memory: ""),
                     question: question, turns: context.turns)
        let deadline = Date().addingTimeInterval(240)
        while result == nil, Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        let cleanDeadline = Date().addingTimeInterval(60)
        while cleaned == nil, Date() < cleanDeadline { try await Task.sleep(nanoseconds: 200_000_000) }
        guard case .success(let answer)? = result else { preconditionFailure("no answer: \(String(describing: result))") }
        let footprint = try requireTabAsk(cleaned)
        log("steps: \(steps.joined(separator: " | "))")
        log("answer: \(answer.replacingOccurrences(of: "\n", with: " ").prefix(600))")
        precondition(answer.contains("8765") && answer.lowercased().contains("document the dev server port"), answer)
        precondition(!files.fileExists(atPath: scratch.appendingPathComponent("changed.txt").path), "the edit was refused")
        let commits = try git(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(commits == "1", "the commit was refused (\(commits) commits)")
        precondition(!footprint.sessions.isEmpty && folderDuringRun, "it ran on a Copilot session: \(footprint.sessions)")
        let paths = TabAskChildCleanup.paths(footprint)
        precondition(paths.allSatisfy { !files.fileExists(atPath: $0.path) }, "left: \(paths.map(\.path))")
        let store = try SQLiteStore(TabAskChildCleanup.Roots.standard.copilotStore)
        for session in footprint.sessions {
            for (table, column) in [("sessions", "id"), ("turns", "session_id"), ("search_index", "session_id")] {
                let count = try store.rows("SELECT count(*) FROM \(table) WHERE \(column) = ?", [session]).first?.first as? Int64
                precondition(count == 0, "\(table) still has \(session)")
            }
        }
        precondition(TabAskChild.running.isEmpty && UserDefaults.standard.object(forKey: footprint.persistKey) == nil)
        log("checked gone: \(paths.map(\.path).joined(separator: ", ")) and session-store rows for \(footprint.sessions)")
        print("Tab ask live: answered read-only, refused the edit and the commit, session deleted")
    }

    private static func requireTabAsk<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }
}
