import Foundation

private final class ChildTabFixtureBackend: Backend {
    var prompts: [String] = []
    var workdirs: [String] = []
    var sink: ((BackendEvent) -> Void)?
    var onSend: (() -> Void)?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        prompts.append(request.prompt)
        workdirs.append(workdir)
        sink = onEvent
        onSend?()
    }
    func cancel() {}
    func reset() {}

    func finish(_ text: String) {
        sink?(.textDelta(text))
        sink?(.done)
    }
}

private final class ChildTabFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension SessionTabTests {
    /// Child tabs: plans for queued messages, shared-resource turns, the record, and the whole
    /// fork → work → merge (clean, conflict, resolve, blocked, no changes, discard) flow in a
    /// real git repository, plus the Remote API.
    @MainActor
    static func testChildTabs() async throws {
        try testQueuePlanningPolicy()
        testChildTabResources()
        try await testChildTabResourceLocks()
        try testChildTabRecord()
        try await testChildTabLifecycle()
        try await testChildTabAPI()
        try await testChildTabAutoFork()
        try await testHomeHandoffChildTabs()
        try await testTabInsight()
        print("Child tab plan, resource, merge, conflict, API and auto-fork tests passed")
    }

    static func testQueuePlanningPolicy() throws {
        // Brian's three tab-section requests all edit the tab list on every client: one batch, no forks.
        let sections = try QueuePlanningDecision.parse(#"""
        {"plans":[
         {"number":1,"title":"Reorderable tab sections","dependsOnCurrent":0.1,"overlaps":["current","2","3"],
          "shared":"tab-list code","exclusive":"none","repo":"Cantrip","touches":["TabSections.swift"]},
         {"number":2,"title":"Empty sections and delete","dependsOnCurrent":0.1,"overlaps":["1","3"],
          "shared":"tab-list code","exclusive":"none","repo":"cantrip","touches":[]},
         {"number":3,"title":"  ","dependsOnCurrent":0.0,"overlaps":["1"],"shared":"the tab list",
          "exclusive":"none","repo":"Elsewhere"}]}
        """#)
        let items = ["Make tab sections reorderable and editable", "Tab sections: create empty sections + delete",
                     "Remove hamburger drag handles; hold-to-drag"]
            .map { QueuedPrompt(text: $0, includesAmbientContext: false) }
        let plans = QueuePlanningPolicy.plans(sections, items: items, repositories: ["Cantrip", "Hermes"], childTitles: [])
        precondition(items.map { plans[$0.id]?.kind } == [.batch, .batch, .batch], "\(plans)")
        precondition(plans[items[0].id]?.reason == "Batched: same tab-list code")
        precondition(plans[items[1].id]?.reason == "Batched with #1: same tab-list code")
        precondition(plans[items[2].id]?.reason == "Batched with #1: same tab list")
        precondition(plans[items[0].id]?.repo == "Cantrip" && plans[items[1].id]?.repo == "Cantrip"
                     && plans[items[2].id]?.repo == nil, "repo names must be real repositories")
        precondition(plans[items[2].id]?.title == "Remove hamburger drag handles; hold-to-drag",
                     "a blank title falls back to the message")
        precondition(plans[items[0].id]?.touches == ["TabSections.swift"])

        func decide(_ json: String, number: Int = 1, children: [String] = []) throws -> (QueuePlan.Kind, String) {
            let entry = try JSONDecoder().decode(QueuePlanningDecision.Item.self, from: Data(json.utf8))
            return QueuePlanningPolicy.decide(entry, number: number, childTitles: children)
        }
        func check(_ json: String, _ kind: QueuePlan.Kind, _ reason: String, number: Int = 1,
                   children: [String] = [], line: UInt = #line) throws {
            let result = try decide(json, number: number, children: children)
            precondition(result.0 == kind && result.1 == reason, "line \(line): \(result)")
        }
        try check(#"{"number":1,"dependsOnCurrent":0.05,"overlaps":[],"exclusive":"none"}"#,
                  .fork, "Independent: can run in a child tab")
        try check(#"{"number":1,"dependsOnCurrent":0.0,"overlaps":["1"]}"#,
                  .fork, "Independent: can run in a child tab", number: 1)
        try check(#"{"number":1,"dependsOnCurrent":0.8,"overlaps":[]}"#, .queue, "Needs the current task's result")
        try check(#"{"number":1,"dependsOnCurrent":0.35,"overlaps":[]}"#, .queue, "Runs after the current task")
        try check(#"{"number":2,"dependsOnCurrent":0.0,"overlaps":["3"],"shared":""}"#,
                  .batch, "Batched with #3: same files", number: 2)
        try check(#"{"number":1,"dependsOnCurrent":0.0,"overlaps":["child:1"],"shared":"the README"}"#,
                  .queue, "Waits for child tab “Update docs”: same README", children: ["Update docs"])
        try check(#"{"number":1,"dependsOnCurrent":0.0,"overlaps":["child:4"]}"#,
                  .fork, "Independent: can run in a child tab", children: ["Update docs"])
        try check(#"{"number":1,"dependsOnCurrent":0.0,"overlaps":[],"exclusive":"release"}"#,
                  .wait, "Waits: releases run one at a time")
        try check(#"{"number":1,"dependsOnCurrent":0.0,"overlaps":["current"],"exclusive":"TestFlight"}"#,
                  .wait, "Waits: TestFlight uploads run one at a time")
        for bad in [#"{"plans":[{"number":1,"dependsOnCurrent":1.5}]}"#, "not json", #"{"plan":[]}"#] {
            do {
                _ = try QueuePlanningDecision.parse(bad)
                preconditionFailure("accepted \(bad)")
            } catch MessageRoutingError.invalidResponse {}
        }
        let plan = QueuePlan(kind: .fork, reason: "Independent: can run in a child tab", title: "Notes", repo: nil, touches: [])
        precondition(plan.snapshot["kind"] as? String == "fork" && plan.snapshot["repo"] == nil)
    }

    static func testChildTabResources() {
        let cases: [(String, ChildTabResource?)] = [
            ("xcodebuild -scheme Hermes -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test", .simulator),
            ("xcodebuild test-without-building -xctestrun x.xctestrun", .simulator),
            ("xcrun simctl boot 1234", .simulator),
            ("xcodebuild -scheme Hermes build", nil),
            ("swift build && make test", nil),
            ("CANTRIP_INSTALL_NOW=1 ./install.sh", .cantrip),
            ("~/Coding/Cantrip/scripts/deploy-when-idle.sh", .cantrip),
            (#"osascript -e 'quit app "Cantrip"'"#, .cantrip),
            ("open -a Cantrip.app", .cantrip),
            ("scripts/ios-testflight.sh Hermes", .testFlight),
            ("xcrun altool --upload-app -f App.ipa", .testFlight),
            ("gh release create v1.2 dist/Gateway.dmg", .release),
            ("gh release view v1.2", nil),
            ("npm run deploy:web", .release),
            ("xcrun devicectl device install app --device X App.app", .device),
            ("git status && git log -3", nil),
        ]
        for (command, expected) in cases {
            precondition(ChildTabResource.resource(for: command) == expected, "\(command) -> \(String(describing: ChildTabResource.resource(for: command)))")
        }
        precondition(ChildTabResource.simulatorBusy(commandLines: ["/usr/bin/xcodebuild -scheme X -destination id=1 test"]))
        precondition(!ChildTabResource.simulatorBusy(commandLines: ["/bin/zsh -c xcodebuild -scheme X test", "git status"]))
        precondition(ChildTabResource.release.denial.hasPrefix("Child tabs leave publishing releases and updates to the parent tab"))
    }

    @MainActor
    static func testChildTabResourceLocks() async throws {
        let interval = ChildTabResourceLocks.pollInterval
        ChildTabResourceLocks.pollInterval = 20_000_000
        defer { ChildTabResourceLocks.pollInterval = interval }
        let locks = ChildTabResourceLocks()
        let busy = ChildTabFlag()
        locks.externallyBusy = { busy.value }
        let first = UUID(), second = UUID(), third = UUID()
        var granted: [UUID] = []
        var statuses: [String] = []
        func acquire(_ id: UUID) {
            locks.acquire(.simulator, session: id, holderTitle: { $0 == first ? "Docs" : nil },
                          status: { statuses.append($0) }) { ok, _ in if ok { granted.append(id) } }
        }
        acquire(first)
        try await waitForJournalTest { granted == [first] }
        acquire(first)
        try await waitForJournalTest { granted == [first, first] }
        acquire(second)
        try await waitForJournalTest { statuses == ["Waiting for the Simulator: child tab “Docs” is using it"] }
        precondition(granted == [first, first], "the second child waits its turn")
        locks.release(first)
        try await waitForJournalTest { granted.last == second }
        // Any other Simulator build or test on the Mac also makes a child wait.
        locks.release(second)
        busy.value = true
        acquire(third)
        try await waitForJournalTest { statuses.last == "Waiting for the Simulator: another build or test is using it" }
        busy.value = false
        try await waitForJournalTest { granted.last == third }
        precondition(locks.holders[.simulator] == third)
        // A child that stops waiting (its turn ended, or it was closed) is never granted later.
        let fourth = UUID()
        var refused: [String] = []
        locks.acquire(.simulator, session: fourth, holderTitle: { _ in nil }, status: { _ in }) { ok, reason in
            if ok { granted.append(fourth) } else { refused.append(reason) }
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        locks.release(fourth)
        locks.release(third)
        try await waitForJournalTest { refused == ["Cantrip stopped waiting for the Simulator."] }
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(locks.holders[.simulator] == nil && !granted.contains(fourth))
    }

    @MainActor
    static func testChildTabRecord() throws {
        var record = ChildTab(id: UUID(), parentID: UUID(), queueItemID: UUID(), title: "Notes file",
                              prompt: "Add a notes file", parentTitle: "Cantrip", createdAt: Date(), updatedAt: Date())
        precondition(record.statusLine == "Working" && record.actions == ["open", "requeue", "discard"])
        precondition(record.displaySummary.isEmpty, "a child started by hand has no auto note")
        record.autoStarted = true
        precondition(record.displaySummary == ChildTab.autoStartedNote)
        record.autoStarted = nil
        record.state = .finished
        precondition(record.actions == ["open"] && record.statusLine == "Done; merges into the parent's branch when the parent tab is idle")
        record.note = "Waiting: uncommitted changes."
        precondition(record.actions == ["retry", "open"] && record.statusLine == "Waiting: uncommitted changes.")
        record.note = nil
        record.state = .conflict
        record.conflictFiles = ["a.swift"]
        record.cleanFileCount = 2
        precondition(record.statusLine == "Merge conflict · 1 of 3 files"
                     && record.actions == ["resolve", "keepParent", "keepChild", "leave", "open"])
        record.state = .failed
        precondition(record.actions == ["open", "discard"], "no branch: nothing to merge")
        record.branch = "cantrip/child/notes-abc123"
        precondition(record.actions == ["merge", "discard", "open"])
        record.state = .noChanges
        precondition(record.statusLine == "Done · no repository to merge")
        record.repoRoot = "/tmp/Cantrip"
        precondition(record.statusLine == "Done · no code changes" && record.repoName == "Cantrip")
        record.state = .merged
        record.baseBranch = "main"
        record.files = [.init(path: "a.swift", added: 3, removed: 1), .init(path: "b.swift", added: 2, removed: 0)]
        record.summary = "Added the notes file."
        precondition(record.statusLine == "Merged into main · 2 files +5 −1")
        precondition(record.contextLine == "[Child tab “Notes file” (Add a notes file…): Merged into main · 2 files +5 −1. Added the notes file. Files: a.swift, b.swift.]",
                     record.contextLine)
        precondition(record.fallbackText == "Child tab “Notes file”: Merged into main · 2 files +5 −1.\n\nAdded the notes file.")

        // The card survives the transcript and reads as a reply to clients that don't draw it.
        var message = ChatMessage(role: .handoff, text: record.fallbackText)
        message.childResult = record
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        precondition(decoded.role == .handoff && decoded.childResult == record && decoded.text == record.fallbackText)
        let remote = RemoteHistory.message(decoded)
        let child = remote["childResult"] as? [String: Any]
        precondition(remote["role"] as? String == "assistant" && child?["state"] as? String == "merged"
                     && child?["added"] as? Int == 5 && (child?["actions"] as? [String]) == ["open"]
                     && child?["branch"] as? String == "cantrip/child/notes-abc123", "\(remote)")

        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        precondition(ChildTabGit.branchName(title: "Fix the Tab-list: drag & drop!", id: id) == "cantrip/child/fix-the-tab-list-drag-abcdef")
        precondition(ChildTabGit.branchName(title: "✨", id: id) == "cantrip/child/task-abcdef")
        let conflict = """
        struct Header {
        <<<<<<< HEAD
            let title = "Parent"
        ||||||| base
            let title = "Base"
        =======
            let title = "Child"
            let subtitle = "New"
        >>>>>>> cantrip/child/header
        }
        """
        let expected = "         struct Header {\nparent + let title = \"Parent\"\nchild  + let title = \"Child\"\nchild  + let subtitle = \"New\""
        precondition(ChildTabGit.conflictExcerpt(conflict) == expected, ChildTabGit.conflictExcerpt(conflict) ?? "nil")
        precondition(ChildTabGit.conflictExcerpt(conflict, parentLabel: "feature/tabs") == "               struct Header {\nfeature/tabs + let title = \"Parent\"\nchild        + let title = \"Child\"\nchild        + let subtitle = \"New\"",
                     ChildTabGit.conflictExcerpt(conflict, parentLabel: "feature/tabs") ?? "nil")
        precondition(ChildTabGit.conflictExcerpt("no markers") == nil)
    }

    /// The whole flow in a real repository with scripted agents.
    @MainActor
    static func testChildTabLifecycle() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.voiceMode)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.voiceMode = false
        defer { (settings.backend, settings.memoryEnabled, settings.voiceMode) = saved }
        let files = FileManager.default
        let repoURL = files.homeDirectoryForCurrentUser.appendingPathComponent("Coding/child-demo", isDirectory: true)
        let scratch = files.temporaryDirectory.appendingPathComponent("cantrip-child-tabs-\(UUID().uuidString)", isDirectory: true)
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
        func git(_ arguments: String..., in directory: String? = nil) -> String {
            let result = ChildTabGit.run(directory ?? repo, arguments, timeout: 30)
            precondition(result?.succeeded == true, "git \(arguments.joined(separator: " ")): \(result?.error ?? "timed out")")
            return result?.output ?? ""
        }
        func write(_ text: String, _ path: String) throws {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        git("init", "-q", "-b", "main")
        git("config", "user.name", "Child Tab Test")
        git("config", "user.email", "child-tabs@example.com")
        try write("one\ntwo\nthree\n", repo + "/a.txt")
        try write("alpha\nbeta\n", repo + "/b.txt")
        git("add", "-A")
        git("commit", "-q", "-m", "Start")
        let resolvedRepo = try requireChild(ChildTabGit.toplevel(repo))
        ChildTabRepositories.invalidate()
        precondition(ChildTabRepositories.path(named: " Child-Demo ") == repo)
        precondition(ChildTabRepositories.repository(mentionedIn: ["ls /tmp", "cd ~/Coding/child-demo && make", "\(repo)/a.txt"]) == repo)
        precondition(ChildTabRepositories.repository(mentionedIn: ["ls /tmp"]) == nil)

        let store = ChildTabStore.shared
        let manager = SessionManager()
        let coordinator: ChildTabCoordinator = manager.childTabs
        var backends: [UUID: ChildTabFixtureBackend] = [:]
        coordinator.makeSession = { id in
            let backend = ChildTabFixtureBackend()
            let session = ChatSession(id: id, copilotBackend: backend)
            backends[session.id] = backend
            return session
        }
        coordinator.worktreesRoot = scratch.appendingPathComponent("worktrees", isDirectory: true)
        func addParent(_ name: String, workdir: String) throws -> (ChatSession, ChildTabFixtureBackend) {
            let backend = ChildTabFixtureBackend()
            let session = ChatSession(copilotBackend: backend)
            session.workdir = workdir
            try session.updateTab(name: name)
            manager.sessions.append(session)
            return (session, backend)
        }
        let (parent, parentBackend) = try addParent("Tab list", workdir: repo)
        manager.select(parent.id)
        defer { for session in manager.sessions { session.cancel() } }
        func fork(_ text: String, from parent: ChatSession) async throws -> (ChatSession, ChildTabFixtureBackend, String) {
            parent.submitRemote(text, mode: .queue)
            let item = try requireChild(parent.queued.last)
            precondition(item.text == text, "not queued: \(text)")
            let child = try await coordinator.fork(parentID: parent.id, itemID: item.id)
            let backend = try requireChild(backends[child.id])
            return (child, backend, store.record(child.id)?.worktree ?? "")
        }
        func record(_ child: ChatSession) throws -> ChildTab { try requireChild(store.record(child.id)) }
        func isOpen(_ child: ChatSession) -> Bool { manager.sessions.contains { $0.id == child.id } }

        // 1. Fork while the parent works; the child edits and commits (and leaves one file uncommitted).
        parent.submitRemote("Refactor the tab list", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == 1 }
        precondition(parent.isStreaming && parent.supportsChildTabs && coordinator.forkUnavailableReason(parent) == nil)
        let (notes, notesBackend, notesTree) = try await fork("Add a notes file to the repo", from: parent)
        var current = try record(notes)
        precondition(parent.queued.isEmpty, "the request left the parent's queue")
        precondition(current.state == .working && current.parentID == parent.id && current.title == "Add a notes file to the repo"
                     && current.parentTitle == "Tab list")
        precondition(current.repoRoot == resolvedRepo && current.baseBranch == "main" && current.baseCommit == ChildTabGit.head(repo))
        precondition(current.branch?.hasPrefix("cantrip/child/add-a-notes-file-to-") == true, current.branch ?? "")
        precondition(notesTree.hasPrefix(coordinator.worktreesRoot.path) && notes.workdir == notesTree
                     && files.fileExists(atPath: notesTree + "/a.txt"))
        precondition(git("worktree", "list", "--porcelain").contains("locked Cantrip child tab"), "storage cleanup skips it")
        let parentIndex = try requireChild(manager.sessions.firstIndex { $0.id == parent.id })
        precondition(manager.sessions[parentIndex + 1].id == notes.id && manager.active.id == parent.id,
                     "the child opens under its parent, which stays selected")
        precondition(manager.parentID(ofChild: notes.id) == parent.id)
        precondition(!notes.supportsChildTabs && coordinator.forkUnavailableReason(notes) == "A child tab can't start its own child tabs.")
        do {
            try manager.moveSession(notes.id, relativeTo: parent.id, after: false)
            preconditionFailure("a child moved away from its parent")
        } catch {}
        let bystander = ChatSession(copilotBackend: ChildTabFixtureBackend())
        manager.sessions.insert(bystander, at: 0)
        try manager.moveSession(bystander.id, relativeTo: notes.id, after: true)
        var order = manager.sessions.map(\.id)
        precondition(order.firstIndex(of: bystander.id) == order.firstIndex(of: notes.id)! + 1,
                     "dropping after a child lands after its parent's group")
        try manager.moveSession(bystander.id, relativeTo: notes.id, after: false)
        order = manager.sessions.map(\.id)
        precondition(order.firstIndex(of: bystander.id)! + 1 == order.firstIndex(of: parent.id),
                     "dropping before a child lands before its parent")
        manager.close(bystander.id)
        try await waitForJournalTest { notesBackend.prompts.count == 1 }
        let brief = notesBackend.prompts[0]
        precondition(brief.contains("child tab of the Cantrip tab “Tab list”") && brief.contains(notesTree)
                     && brief.contains("Add a notes file to the repo"), brief)
        precondition(brief.contains("tab read \(parent.id.uuidString)") && brief.contains("tab ask \(parent.id.uuidString)"),
                     "the child can read its parent's conversation on demand")
        precondition(notesBackend.workdirs[0] == notesTree)
        precondition(notes.messages.first { $0.role == .user }?.text == "Add a notes file to the repo", "the brief stays hidden")
        let cardIndex = try requireChild(parent.messages.firstIndex { $0.childResult?.id == notes.id })
        let requestIndex = try requireChild(parent.messages.lastIndex { $0.role == .user })
        precondition(cardIndex > requestIndex && cardIndex == parent.messages.count - 1 && parent.messages[cardIndex].role == .handoff,
                     "the card follows the parent's reply")
        let replyIndex = try requireChild(parent.messages.lastIndex { $0.role == .assistant })
        parentBackend.sink?(.textDelta("Still refactoring."))
        try await waitForJournalTest { parent.messages[replyIndex].text.hasSuffix("Still refactoring.") }
        precondition(parent.messages.last?.childResult != nil,
                     "the parent's streaming text keeps going to its reply above the card")

        try write("remember the milk\n", notesTree + "/notes.txt")
        try write("one\ntwo\nthree\nfour\n", notesTree + "/a.txt")
        git("commit", "-q", "-am", "Add a fourth line", in: notesTree)
        notesBackend.finish("I added the notes file.\n\nSummary: Added notes.txt and a fourth line to a.txt.")
        try await waitForJournalTest { store.record(notes.id)?.state == .finished }
        current = try record(notes)
        precondition(current.summary == "Added notes.txt and a fourth line to a.txt." && current.replies == ["I added the notes file."],
                     "\(current.summary) \(current.replies)")
        precondition(parent.isStreaming && isOpen(notes), "nothing merges while the parent works")
        precondition(parent.messages.first { $0.childResult?.id == notes.id }?.childResult?.state == .finished,
                     "the card follows the child")

        // 2. The parent finishes: the child merges before the parent's next queued message.
        parent.submitRemote("Run the tests", mode: .queue)
        var stateAtNextTurn: ChildTab.State?
        parentBackend.onSend = { stateAtNextTurn = store.record(notes.id)?.state }
        parentBackend.finish("The tab list is refactored.")
        try await waitForJournalTest { parentBackend.prompts.count == 2 }
        precondition(stateAtNextTurn == .merged, "merge first: \(String(describing: stateAtNextTurn))")
        current = try record(notes)
        precondition(current.mergeCommit == ChildTabGit.head(repo) && git("log", "-1", "--format=%s") == "Merge child tab: Add a notes file to the repo")
        precondition(read(repo + "/notes.txt") == "remember the milk\n" && read(repo + "/a.txt") == "one\ntwo\nthree\nfour\n")
        precondition(Set(current.files.map(\.path)) == ["a.txt", "notes.txt"] && current.added == 2 && current.removed == 0)
        precondition(current.statusLine == "Merged into main · 2 files +2 −0", current.statusLine)
        precondition(!ChildTabGit.branchExists(repo, current.branch ?? "") && !files.fileExists(atPath: notesTree))
        precondition(!isOpen(notes) && !parent.childMergeHold, "a merged child is archived")
        precondition(parent.messages.first { $0.childResult?.id == notes.id }?.childResult?.state == .merged)
        let mergedCard = try requireChild(parent.messages.firstIndex { $0.childResult?.id == notes.id })
        let nextRequest = try requireChild(parent.messages.lastIndex { $0.role == .user })
        precondition(mergedCard < nextRequest && parent.messages[mergedCard - 1].text.hasSuffix("The tab list is refactored."),
                     "the merged card moved to where the merge happened, before the next request")
        let next = parentBackend.prompts[1]
        precondition(next.contains("(Child tabs of this tab") && next.contains("Since your last turn:")
                     && next.contains(current.contextLine) && next.contains("tab read <child ID>")
                     && !next.contains("Now:"), "only the one-line result reaches the parent's model: \(next)")
        precondition(next.contains("Run the tests"))
        let delivered = try record(notes)
        precondition(delivered.contextDelivered && delivered.reportedState == .merged)

        // 3. A conflict: the card asks; Leave, Try Again, then Keep the Child's Version.
        let (greeting, greetingBackend, greetingTree) = try await fork("Change the greeting", from: parent)
        try await waitForJournalTest { greetingBackend.prompts.count == 1 }
        try write("child line\ntwo\nthree\nfour\n", greetingTree + "/a.txt")
        git("commit", "-q", "-am", "Child greeting", in: greetingTree)
        try write("parent line\ntwo\nthree\nfour\n", repo + "/a.txt")
        git("commit", "-q", "-am", "Parent greeting")
        greetingBackend.finish("Summary: Changed the greeting.")
        try await waitForJournalTest { store.record(greeting.id)?.state == .finished }
        parentBackend.finish("Tests pass.")
        try await waitForJournalTest { store.record(greeting.id)?.state == .conflict }
        current = try record(greeting)
        precondition(current.conflictFiles == ["a.txt"] && current.cleanFileCount == 0 && current.statusLine == "Merge conflict · 1 of 1 files")
        precondition(current.conflictExcerpt == "main  + parent line\nchild + child line", current.conflictExcerpt ?? "nil")
        precondition(current.actions == ["resolve", "keepParent", "keepChild", "leave", "open"])
        precondition(isOpen(greeting) && git("status", "--porcelain").isEmpty && !parent.childMergeHold,
                     "the check leaves the checkout alone and the parent free")
        try coordinator.perform("leave", childID: greeting.id)
        current = try record(greeting)
        precondition(current.state == .unmerged && current.note == "Left unmerged on \(current.branch ?? "")."
                     && current.actions == ["retry", "discard", "open"])
        do {
            try coordinator.perform("keepChild", childID: greeting.id)
            preconditionFailure("an action the card doesn't offer ran")
        } catch ChildTabError.notAllowed {}
        try coordinator.perform("retry", childID: greeting.id)
        let retrying = try record(greeting).state
        precondition(retrying == .merging)
        try await waitForJournalTest { store.record(greeting.id)?.state == .conflict }
        try coordinator.perform("keepChild", childID: greeting.id)
        try await waitForJournalTest { store.record(greeting.id)?.state == .merged }
        precondition(read(repo + "/a.txt") == "child line\ntwo\nthree\nfour\n" && !isOpen(greeting))

        // 4. Resolve: the parent gets the merge as a queued message; if it stops short, the card asks again.
        parent.submitRemote("Polish the README", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == 3 }
        let (rename, renameBackend, renameTree) = try await fork("Rename beta", from: parent)
        let renameBranch = try requireChild(try record(rename).branch)
        try await waitForJournalTest { renameBackend.prompts.count == 1 }
        try write("alpha\nchild beta\n", renameTree + "/b.txt")
        git("commit", "-q", "-am", "Child beta", in: renameTree)
        try write("alpha\nparent beta\n", repo + "/b.txt")
        git("commit", "-q", "-am", "Parent beta")
        renameBackend.finish("Summary: Renamed beta.")
        try await waitForJournalTest { store.record(rename.id)?.state == .finished }
        parentBackend.finish("README polished.")
        try await waitForJournalTest { store.record(rename.id)?.state == .conflict }
        try coordinator.perform("resolve", childID: rename.id)
        try await waitForJournalTest { parentBackend.prompts.count == 4 }
        precondition(parentBackend.prompts[3].contains("Merge child tab “Rename beta” (branch \(renameBranch)) into main")
                     && parentBackend.prompts[3].contains("conflict in b.txt"), parentBackend.prompts[3])
        current = try record(rename)
        precondition(current.state == .merging && current.resolveRequested && current.statusLine == "The parent tab is resolving the merge")
        parentBackend.finish("I couldn't decide.")
        try await waitForJournalTest { store.record(rename.id)?.state == .conflict }
        current = try record(rename)
        precondition(!current.resolveRequested && current.note == "The merge isn't finished. Choose again, or merge \(renameBranch) yourself.")
        try coordinator.perform("resolve", childID: rename.id)
        try await waitForJournalTest { parentBackend.prompts.count == 5 }
        git("merge", "-q", "--no-edit", "-X", "ours", renameBranch)
        parentBackend.finish("Merged; kept the parent's wording.")
        try await waitForJournalTest { store.record(rename.id)?.state == .merged }
        precondition(!ChildTabGit.branchExists(repo, renameBranch) && !files.fileExists(atPath: renameTree) && !isOpen(rename))
        precondition(read(repo + "/b.txt") == "alpha\nparent beta\n")

        // 5. Uncommitted edits in the parent's checkout block the merge until they're gone.
        parent.submitRemote("Update the docs", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == 6 }
        let (tidy, tidyBackend, tidyTree) = try await fork("Tidy alpha", from: parent)
        try await waitForJournalTest { tidyBackend.prompts.count == 1 }
        try write("alpha!\nparent beta\n", tidyTree + "/b.txt")
        tidyBackend.finish("Summary: Tidied alpha.")
        try await waitForJournalTest { store.record(tidy.id)?.state == .finished }
        try write("alpha\nparent beta\ngamma\n", repo + "/b.txt")
        parentBackend.finish("Docs updated.")
        try await waitForJournalTest { store.record(tidy.id)?.note?.hasPrefix("Waiting: uncommitted changes in child-demo") == true }
        current = try record(tidy)
        precondition(current.state == .finished && current.actions == ["retry", "open"] && current.statusLine == current.note)
        precondition(read(repo + "/b.txt") == "alpha\nparent beta\ngamma\n", "the parent's edits stay")
        git("checkout", "--", "b.txt")
        try coordinator.perform("retry", childID: tidy.id)
        try await waitForJournalTest { store.record(tidy.id)?.state == .merged }
        precondition(read(repo + "/b.txt") == "alpha!\nparent beta\n", "the child's uncommitted edit was committed and merged")
        precondition(git("log", "-1", "--format=%s", "HEAD^2") == "Tidy alpha")

        // 5b. Someone's unfinished merge in the parent's checkout is left alone; the child waits.
        var asked = parentBackend.prompts.count
        parent.submitRemote("Review the merge", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == asked + 1 }
        let (notesTwo, notesTwoBackend, notesTwoTree) = try await fork("Add a changelog", from: parent)
        try await waitForJournalTest { notesTwoBackend.prompts.count == 1 }
        try write("v1\n", notesTwoTree + "/CHANGELOG.md")
        notesTwoBackend.finish("Summary: Added a changelog.")
        try await waitForJournalTest { store.record(notesTwo.id)?.state == .finished }
        git("checkout", "-q", "-b", "side")
        try write("side line\ntwo\nthree\nfour\n", repo + "/a.txt")
        git("commit", "-q", "-am", "Side")
        git("checkout", "-q", "main")
        try write("main line\ntwo\nthree\nfour\n", repo + "/a.txt")
        git("commit", "-q", "-am", "Main")
        precondition(ChildTabGit.run(repo, ["merge", "side"])?.succeeded == false && ChildTabGit.operationInProgress(repo) == "a merge")
        let userMerge = read(repo + "/a.txt")
        parentBackend.finish("Reviewed.")
        try await waitForJournalTest { store.record(notesTwo.id)?.note?.hasPrefix("Waiting: a merge is unfinished in child-demo") == true }
        precondition(ChildTabGit.operationInProgress(repo) == "a merge" && read(repo + "/a.txt") == userMerge
                     && userMerge.contains("<<<<<<<"), "the user's merge in progress stays untouched")
        git("merge", "--abort")
        try coordinator.perform("retry", childID: notesTwo.id)
        try await waitForJournalTest { store.record(notesTwo.id)?.state == .merged }
        precondition(read(repo + "/CHANGELOG.md") == "v1\n")

        // 5c. A commit that fails (here, signing) keeps the child's work and says so.
        asked = parentBackend.prompts.count
        parent.submitRemote("Sign the commits", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == asked + 1 }
        let (signed, signedBackend, signedTree) = try await fork("Write the license", from: parent)
        try await waitForJournalTest { signedBackend.prompts.count == 1 }
        try write("MIT\n", signedTree + "/LICENSE")
        signedBackend.finish("Summary: Wrote the license.")
        try await waitForJournalTest { store.record(signed.id)?.state == .finished }
        git("config", "commit.gpgsign", "true")
        git("config", "gpg.program", "/usr/bin/false")
        parentBackend.finish("Signing set up.")
        try await waitForJournalTest { store.record(signed.id)?.state == .unmerged }
        current = try record(signed)
        precondition(current.note?.hasPrefix("Cantrip couldn't commit the child's last changes in \(signedTree)") == true
                     && read(signedTree + "/LICENSE") == "MIT\n" && ChildTabGit.branchExists(repo, current.branch ?? ""),
                     "the uncommitted work stays: \(current.note ?? "")")
        git("config", "--unset", "commit.gpgsign")
        try coordinator.perform("retry", childID: signed.id)
        try await waitForJournalTest { store.record(signed.id)?.state == .merged }
        precondition(read(repo + "/LICENSE") == "MIT\n" && !files.fileExists(atPath: signedTree))

        // 5d. Without changes, a checkout that still has uncommitted work isn't deleted.
        let keep = scratch.appendingPathComponent("keep").path
        git("worktree", "add", "-q", "-b", "cantrip/child/keep-000000", keep, "HEAD")
        try write("draft\n", keep + "/draft.txt")
        precondition(!ChildTabGit.cleanup(repo: repo, worktree: keep, branch: "cantrip/child/keep-000000", force: false)
                     && files.fileExists(atPath: keep + "/draft.txt") && ChildTabGit.branchExists(repo, "cantrip/child/keep-000000"))
        precondition(ChildTabGit.cleanup(repo: repo, worktree: keep, branch: "cantrip/child/keep-000000", force: true)
                     && !files.fileExists(atPath: keep))

        // 6. No changes: archived without a merge.
        asked = parentBackend.prompts.count
        parent.submitRemote("Check the build", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == asked + 1 }
        let (look, lookBackend, lookTree) = try await fork("Look at the logs", from: parent)
        try await waitForJournalTest { lookBackend.prompts.count == 1 }
        lookBackend.finish("Summary: The logs are clean.")
        try await waitForJournalTest { store.record(look.id)?.state == .finished }
        parentBackend.finish("Build checked.")
        try await waitForJournalTest { store.record(look.id)?.state == .noChanges }
        current = try record(look)
        precondition(current.statusLine == "Done · no code changes" && !ChildTabGit.branchExists(repo, current.branch ?? "")
                     && !files.fileExists(atPath: lookTree) && !isOpen(look))

        // 7. Caps (2 per tab, 3 overall) and Discard.
        asked = parentBackend.prompts.count
        parent.submitRemote("Plan the release", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == asked + 1 }
        let (first, _, firstTree) = try await fork("First side job", from: parent)
        let (second, _, _) = try await fork("Second side job", from: parent)
        precondition(coordinator.forkUnavailableReason(parent) == "This tab already has 2 child tabs running. Wait for one to finish.")
        parent.submitRemote("Third side job", mode: .queue)
        do {
            _ = try await coordinator.fork(parentID: parent.id, itemID: try requireChild(parent.queued.last).id)
            preconditionFailure("a third child started")
        } catch ChildTabError.limit {}
        precondition(parent.queued.map(\.text) == ["Third side job"], "a refused fork leaves the message queued")
        let (other, otherBackend) = try addParent("Other", workdir: repo)
        other.submitRemote("Other work", mode: .queue)
        try await waitForJournalTest { otherBackend.prompts.count == 1 }
        let (third, _, _) = try await fork("Third child overall", from: other)
        precondition(coordinator.forkUnavailableReason(other) == "3 child tabs are already running. Wait for one to finish.")
        let firstBranch = try requireChild(try record(first).branch)
        for child in [first, second, third] { try coordinator.perform("discard", childID: child.id) }
        for child in [first, second, third] {
            let state = try record(child).state
            precondition(state == .discarded && !isOpen(child))
        }
        precondition(coordinator.forkUnavailableReason(parent) == nil)
        try await waitForJournalTest { !ChildTabGit.branchExists(repo, firstBranch) && !files.fileExists(atPath: firstTree) }

        // 8. No repository: the child shares the folder, asks a question, and has nothing to merge.
        let plain = scratch.appendingPathComponent("plain").path
        try files.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let (loose, looseBackend) = try addParent("Notes", workdir: plain)
        loose.submitRemote("Draft an email", mode: .queue)
        try await waitForJournalTest { looseBackend.prompts.count == 1 }
        let (haiku, haikuBackend, haikuTree) = try await fork("Write a haiku", from: loose)
        current = try record(haiku)
        precondition(current.repoRoot == nil && haikuTree.isEmpty && haiku.workdir == plain)
        try await waitForJournalTest { haikuBackend.prompts.count == 1 }
        precondition(!haikuBackend.prompts[0].contains("worktree"))
        haikuBackend.sink?(.inputRequired(BackendInputRequest(
            kind: .question, source: "Copilot", title: "Copilot needs your answer",
            detail: "Spring or autumn?", choices: ["Spring", "Autumn"]
        ) { _ in }))
        try await waitForJournalTest { store.record(haiku.id)?.state == .needsInput }
        precondition(loose.messages.first { $0.childResult?.id == haiku.id }?.childResult?.statusLine == "Needs your answer")
        try haiku.respondToInput(id: haiku.pendingInputs[0].id, answer: .init(decision: .cancel))
        try await waitForJournalTest { store.record(haiku.id)?.state == .working }
        haikuBackend.finish("Summary: Wrote a spring haiku.")
        try await waitForJournalTest { store.record(haiku.id)?.state == .noChanges }
        let haikuStatus = try record(haiku).statusLine
        precondition(haikuStatus == "Done · no repository to merge" && !isOpen(haiku))
        let leftovers = (try? files.contentsOfDirectory(atPath: coordinator.worktreesRoot.path)) ?? []
        precondition(leftovers.isEmpty, "every worktree was removed: \(leftovers)")
    }

    /// The Remote API: capability flags, plans on queue rows, fork, child metadata, card actions.
    @MainActor
    static func testChildTabAPI() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.copilotPath, ChatSession.queueGroupingDelay)
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("cantrip-child-api-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            (settings.backend, settings.memoryEnabled, settings.copilotPath, ChatSession.queueGroupingDelay) = saved
            try? files.removeItem(at: scratch)
        }
        // Stands in for the router CLI: plans every queued message as independent.
        let router = scratch.appendingPathComponent("router")
        let decision = #"{\"plans\":[{\"number\":1,\"title\":\"Changelog\",\"dependsOnCurrent\":0.05,\"overlaps\":[],\"shared\":\"\",\"exclusive\":\"none\",\"repo\":null,\"touches\":[\"CHANGELOG.md\"]}]}"#
        try """
        #!/bin/sh
        case "$2" in
          "You plan queued chat messages"*) ;;
          *) exit 9 ;;
        esac
        printf '%s\\n' '{"type":"assistant.message_delta","data":{"messageId":"router","deltaContent":"\(decision)"}}'
        """.write(to: router, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: router.path)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.copilotPath = router.path
        ChatSession.queueGroupingDelay = 50_000_000
        let repo = scratch.appendingPathComponent("repo").path
        try files.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@example.com"],
                          ["commit", "-q", "--allow-empty", "-m", "Start"]] {
            precondition(ChildTabGit.run(repo, arguments)?.succeeded == true)
        }

        let manager = SessionManager()
        let coordinator: ChildTabCoordinator = manager.childTabs
        coordinator.makeSession = { ChatSession(id: $0, copilotBackend: ChildTabFixtureBackend()) }
        coordinator.worktreesRoot = scratch.appendingPathComponent("worktrees", isDirectory: true)
        let backend = ChildTabFixtureBackend()
        let parent = ChatSession(copilotBackend: backend)
        parent.workdir = repo
        try parent.updateTab(name: "Release prep")
        manager.sessions.append(parent)
        defer { for session in manager.sessions { session.cancel() } }
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ path: String, _ method: String = "GET") async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if method == "POST" {
                request.httpBody = Data("{}".utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
        }
        let base = "/api/v1/sessions/\(parent.id.uuidString)"

        parent.submitRemote("Prepare the release", mode: .queue)
        try await waitForJournalTest { backend.prompts.count == 1 }
        parent.submitRemote("Write the changelog", mode: .queue)
        let item = try requireChild(parent.queued.first)
        try await waitForJournalTest { parent.queuePlans[item.id] != nil }
        var (status, body) = try await call(base)
        let summary = try requireChild(body["session"] as? [String: Any])
        let queued = try requireChild(summary["queued"] as? [[String: Any]])
        let plan = queued.first?["plan"] as? [String: Any]
        precondition(status == 200 && summary["supportsChildTabs"] as? Bool == true && summary["supportsQueuePlans"] as? Bool == true
                     && summary["childTabsUnavailableReason"] == nil, "\(summary)")
        precondition(plan?["kind"] as? String == "fork" && plan?["reason"] as? String == "Independent: can run in a child tab"
                     && plan?["title"] as? String == "Changelog", "\(queued)")

        (status, body) = try await call("\(base)/queue/not-a-uuid/fork", "POST")
        precondition(status == 400, "\(status) \(body)")
        (status, body) = try await call("\(base)/queue/\(UUID().uuidString)/fork", "POST")
        precondition(status == 409 && (body["error"] as? String)?.contains("no longer queued") == true, "\(status) \(body)")
        (status, body) = try await call("\(base)/queue/\(item.id.uuidString)/fork", "GET")
        precondition(status == 405)
        (status, body) = try await call("\(base)/queue/\(item.id.uuidString)/fork", "POST")
        let childID = try requireChild(body["childID"] as? String)
        let returned = body["session"] as? [String: Any]
        precondition(status == 200 && (returned?["queued"] as? [Any])?.isEmpty == true, "\(status) \(body)")
        let record = try requireChild(ChildTabStore.shared.record(UUID(uuidString: childID)!))
        precondition(record.title == "Changelog", "the plan's title names the child")

        (status, body) = try await call("/api/v1/sessions")
        let sessions = try requireChild(body["sessions"] as? [[String: Any]])
        let ids = sessions.compactMap { $0["id"] as? String }
        let parentAt = try requireChild(ids.firstIndex(of: parent.id.uuidString))
        precondition(ids.indices.contains(parentAt + 1) && ids[parentAt + 1] == childID, "the child follows its parent: \(ids)")
        let listed = sessions[parentAt + 1]
        let child = listed["child"] as? [String: Any]
        precondition(listed["parentID"] as? String == parent.id.uuidString && child?["state"] as? String == "working"
                     && child?["parentTitle"] as? String == "Release prep" && child?["branch"] as? String == record.branch
                     && child?["baseBranch"] as? String == "main" && child?["repoName"] as? String == "repo"
                     && listed["supportsTabReordering"] as? Bool == false && listed["supportsTabSections"] as? Bool == false
                     && listed["supportsChildTabs"] as? Bool == false, "\(listed)")

        (status, body) = try await call(base)
        let messages = try requireChild((body["session"] as? [String: Any])?["messages"] as? [[String: Any]])
        let card = messages.first { ($0["childResult"] as? [String: Any])?["id"] as? String == childID }
        precondition(card?["role"] as? String == "assistant"
                     && (card?["childResult"] as? [String: Any])?["actions"] as? [String] == ["open", "requeue", "discard"],
                     "\(messages)")

        (status, body) = try await call("\(base)/children/\(childID)/resolve", "POST")
        precondition(status == 409, "\(status) \(body)")
        let stranger = try requireChild(manager.sessions.first { $0.id != parent.id && $0.id.uuidString != childID && !$0.isLocalPrivate })
        (status, body) = try await call("/api/v1/sessions/\(stranger.id.uuidString)/children/\(childID)/discard", "POST")
        precondition(status == 404, "only the parent acts on its child: \(status)")
        (status, body) = try await call("\(base)/children/\(childID)/discard", "POST")
        precondition(status == 200 && ChildTabStore.shared.record(UUID(uuidString: childID)!)?.state == .discarded, "\(status) \(body)")
        (status, body) = try await call("/api/v1/sessions")
        precondition(!((body["sessions"] as? [[String: Any]]) ?? []).contains { $0["id"] as? String == childID })
    }

    private static func requireChild<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }
}
