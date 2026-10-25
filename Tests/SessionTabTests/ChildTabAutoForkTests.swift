import Foundation

private final class AutoForkFixtureBackend: Backend {
    var prompts: [String] = []
    var sink: ((BackendEvent) -> Void)?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        prompts.append(request.prompt)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}

    func finish(_ text: String) {
        sink?(.textDelta(text))
        sink?(.done)
    }
}

extension SessionTabTests {
    /// Auto-fork (Phase 3): the rule, then in a real git repository: an Auto-delivered message rated
    /// independent starts in a child tab on its own; one that touches the parent's uncommitted file,
    /// one sent with an explicit Queue, and any message with auto-fork off stay queued; and Run in
    /// This Tab Instead puts a child's request back at the front of the parent's queue.
    @MainActor
    static func testChildTabAutoFork() async throws {
        testChildTabAutoForkRule()

        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.voiceMode = false
        settings.childTabsAutoFork = true
        defer { (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork) = saved }
        let files = FileManager.default
        let repoURL = files.homeDirectoryForCurrentUser.appendingPathComponent("Coding/child-auto-demo", isDirectory: true)
        let scratch = files.temporaryDirectory.appendingPathComponent("cantrip-child-auto-\(UUID().uuidString)", isDirectory: true)
        try? files.removeItem(at: repoURL)
        try files.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            try? files.removeItem(at: repoURL)
            try? files.removeItem(at: scratch)
            ChildTabRepositories.invalidate()
        }
        let repo = repoURL.path
        @discardableResult
        func git(_ arguments: String...) -> String {
            let result = ChildTabGit.run(repo, arguments, timeout: 30)
            precondition(result?.succeeded == true, "git \(arguments.joined(separator: " ")): \(result?.error ?? "timed out")")
            return result?.output ?? ""
        }
        git("init", "-q", "-b", "main")
        git("config", "user.name", "Auto Fork Test")
        git("config", "user.email", "auto-fork@example.com")
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "docs\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        git("add", "-A")
        git("commit", "-q", "-m", "Start")

        let store = ChildTabStore.shared
        let manager = SessionManager()
        let coordinator: ChildTabCoordinator = manager.childTabs
        var backends: [UUID: AutoForkFixtureBackend] = [:]
        coordinator.makeSession = { id in
            let backend = AutoForkFixtureBackend()
            backends[id] = backend
            return ChatSession(id: id, copilotBackend: backend)
        }
        coordinator.worktreesRoot = scratch.appendingPathComponent("worktrees", isDirectory: true)
        let parentBackend = AutoForkFixtureBackend()
        let parent = ChatSession(copilotBackend: parentBackend)
        parent.workdir = repo
        try parent.updateTab(name: "Auto parent")
        manager.sessions.append(parent)
        manager.select(parent.id)
        defer { for session in manager.sessions { session.cancel() } }

        parent.submitRemote("Refactor the parser", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == 1 }
        precondition(parent.isStreaming)
        // The parent has uncommitted work in a.txt (and an untracked notes file).
        try "one\nparent edit\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "notes\n".write(toFile: repo + "/notes.txt", atomically: true, encoding: .utf8)
        precondition(ChildTabGit.changedFiles(repo) == ["a.txt", "notes.txt"], "\(ChildTabGit.changedFiles(repo))")

        func queue(_ text: String, auto: Bool, touches: [String]) throws -> QueuedPrompt {
            parent.submitRemote(text, mode: .queue)
            let item = try requireAutoFork(parent.queued.last)
            precondition(item.text == text)
            parent.applyQueuePlans([item.id: QueuePlan(kind: .fork, reason: "Independent: can run in a child tab",
                                                       title: String(text.prefix(20)), repo: nil, touches: touches)])
            if auto { parent.noteAutoDelivered(item.id) }
            return item
        }
        func child(for text: String) -> ChildTab? {
            store.children(of: parent.id).first { $0.prompt == text }
        }

        precondition(coordinator.forkUnavailableReason(parent) == nil,
                     "\(coordinator.forkUnavailableReason(parent) ?? "") running: \(store.running.map(\.title))")
        // 1. Explicit Queue: "after this", even when the plan says independent.
        let explicit = try queue("Write the changelog", auto: false, touches: ["CHANGELOG.md"])
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(child(for: explicit.text) == nil && parent.queued.contains(explicit), "an explicit Queue isn't auto-forked")

        // 2. Auto delivery, independent, files don't overlap: it starts in a child tab on its own.
        let docs = try queue("Add a docs page", auto: true, touches: ["docs/page.md"])
        try await waitForJournalTest { child(for: docs.text) != nil }
        var record = try requireAutoFork(child(for: docs.text))
        precondition(record.autoStarted == true && record.state == .working && record.branch != nil, "\(record)")
        precondition(!parent.queued.contains(where: { $0.id == docs.id }), "it left the parent's queue")
        precondition(record.displaySummary == ChildTab.autoStartedNote && record.actions.contains("requeue"))
        let card = try requireAutoFork(parent.messages.first { $0.childResult?.id == record.id }?.childResult)
        precondition(card.snapshot["summary"] as? String == ChildTab.autoStartedNote && card.snapshot["autoStarted"] as? Bool == true)
        precondition(parent.queued.contains(explicit), "the explicit one still waits")

        // 3. Same file as the parent's uncommitted work: it stays queued and says why.
        let overlap = try queue("Tidy a.txt", auto: true, touches: ["a.txt"])
        try await waitForJournalTest { parent.queuePlans[overlap.id]?.kind == .queue }
        precondition(parent.queuePlans[overlap.id]?.reason == "Runs after the current task: it also changes a.txt",
                     parent.queuePlans[overlap.id]?.reason ?? "")
        precondition(child(for: overlap.text) == nil)

        // 4. Auto-fork off in Settings: independent messages wait for Run in Child Tab.
        settings.childTabsAutoFork = false
        let off = try queue("Update the README", auto: true, touches: ["README.md"])
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(child(for: off.text) == nil && parent.queuePlans[off.id]?.kind == .fork)
        settings.childTabsAutoFork = true

        // 5. Run in This Tab Instead: the child stops, its branch goes, and the request is next here.
        let docsChild = try requireAutoFork(manager.sessions.first { $0.id == record.id })
        try await waitForJournalTest { backends[docsChild.id]?.prompts.count == 1 }
        let branch = try requireAutoFork(record.branch)
        try coordinator.perform("requeue", childID: record.id)
        record = try requireAutoFork(store.record(record.id))
        precondition(record.state == .requeued && record.contextDelivered, "\(record.state)")
        precondition(record.statusLine == "Moved back to Auto parent's queue", record.statusLine)
        precondition(!manager.sessions.contains { $0.id == docsChild.id }, "the child closed")
        precondition(parent.queued.first?.text == docs.text, "the request is first in the parent's queue")
        precondition(!parent.autoDeliveredItemIDs.contains(parent.queued[0].id), "it isn't auto-forked again")
        try await waitForJournalTest { !ChildTabGit.branchExists(repo, branch) }
        precondition(parent.messages.first { $0.childResult?.id == record.id }?.childResult?.state == .requeued)
        // The freed slot is checked again: the message that waited while auto-fork was off starts now.
        try await waitForJournalTest { child(for: off.text) != nil }
        precondition(child(for: off.text)?.autoStarted == true && child(for: overlap.text) == nil)
        do {
            try coordinator.perform("requeue", childID: record.id)
            preconditionFailure("requeue applies only while the child runs")
        } catch {}
        print("Child tab auto-fork tests passed")
    }

    static func testChildTabAutoForkRule() {
        typealias Rule = ChildTabAutoFork
        precondition(Rule.verdict(touches: ["docs/page.md"], hasRepository: true, changedFiles: ["a.txt"],
                                  activity: [], childTouches: []) == .fork)
        precondition(Rule.verdict(touches: ["Sources/Cantrip/CantripHome.swift"], hasRepository: true,
                                  changedFiles: ["Sources/Cantrip/CantripHome.swift"], activity: [],
                                  childTouches: []) == .stay("Runs after the current task: it also changes CantripHome.swift"))
        precondition(Rule.verdict(touches: ["windows/"], hasRepository: true, changedFiles: ["windows/src/app.ts"],
                                  activity: [], childTouches: []) == .stay("Runs after the current task: it also changes windows"),
                     "a folder covers the files in it")
        precondition(Rule.verdict(touches: ["TabSections.swift"], hasRepository: true, changedFiles: [],
                                  activity: ["/Users/me/Coding/Cantrip/Sources/Cantrip/TabSections.swift"],
                                  childTouches: []) != .fork, "a file the current run edited")
        precondition(Rule.verdict(touches: ["Makefile.swift"], hasRepository: true, changedFiles: [],
                                  activity: ["swift build && sed -i '' s/a/b/ Sources/Makefile.swift"],
                                  childTouches: []) != .fork, "a file the current run's commands named")
        precondition(Rule.verdict(touches: ["README"], hasRepository: true, changedFiles: [],
                                  activity: ["cat README && make"], childTouches: []) == .fork,
                     "a bare word in a command isn't a file")
        precondition(Rule.verdict(touches: ["QueuePlanning.swift"], hasRepository: true, changedFiles: [],
                                  activity: [], childTouches: ["Sources/Cantrip/QueuePlanning.swift"])
                     == .stay("Runs after the current task: a child tab is changing QueuePlanning.swift"))
        precondition(Rule.verdict(touches: [], hasRepository: true, changedFiles: [], activity: [], childTouches: [])
                     == .stay("Independent; its files are unclear, so it waits for Run in Child Tab"))
        precondition(Rule.verdict(touches: ["a.txt"], hasRepository: false, changedFiles: [], activity: [], childTouches: [])
                     == .stay("Independent; outside a repository it waits for Run in Child Tab"))
        let key = Rule.normalized
        precondition(!Rule.overlaps(key("main.swift"), key("Tests/main.swiftlint"))
                     && Rule.overlaps(key("./Docs/"), key("docs/a.md")) && !Rule.overlaps(key("docs"), key("docsite/a.md")))
    }

    private static func requireAutoFork<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }
}
