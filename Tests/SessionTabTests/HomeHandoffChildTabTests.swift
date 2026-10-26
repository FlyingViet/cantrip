import Foundation

private final class HandoffChildFixtureBackend: Backend {
    var prompts: [String] = []
    var sink: ((BackendEvent) -> Void)?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        prompts.append(request.prompt)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}

    func finish(_ text: String) {
        let sink = self.sink
        self.sink = nil
        sink?(.textDelta(text))
        sink?(.done)
    }
}

extension SessionTabTests {
    /// A Home handoff whose queued request moves into a child tab (Run in Child Tab, or auto-fork)
    /// follows it: it shows running in the child, finishes with the child's reply, then shows the
    /// child's merge outcome. Plain removal still reads as cancelled; Run in This Tab Instead
    /// brings it back to the parent's queue; records from before this follow their child too.
    @MainActor
    static func testHomeHandoffChildTabs() async throws {
        testHomeHandoffChildTabRule()

        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork, settings.attachScreen)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.voiceMode = false
        settings.attachScreen = false
        settings.childTabsAutoFork = true
        defer {
            (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork, settings.attachScreen) = saved
        }
        let files = FileManager.default
        let repoURL = files.homeDirectoryForCurrentUser.appendingPathComponent("Coding/handoff-child-demo", isDirectory: true)
        let scratch = files.temporaryDirectory.appendingPathComponent("cantrip-handoff-child-\(UUID().uuidString)", isDirectory: true)
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
        git("init", "-q", "-b", "main")
        git("config", "user.name", "Handoff Child Test")
        git("config", "user.email", "handoff-child@example.com")
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        git("add", "-A")
        git("commit", "-q", "-m", "Start")

        let homeChat = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture(),
                                   makeJournal: { _ in try RunJournal(sessionID: UUID()) })
        homeChat.messages = []
        let manager = SessionManager(
            homeSession: homeChat,
            homeBackgroundSession: ChatSession(
                id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture(),
                makeJournal: { _ in try RunJournal(sessionID: UUID()) }
            )
        )
        let store = ChildTabStore.shared
        let coordinator: ChildTabCoordinator = manager.childTabs
        var backends: [UUID: HandoffChildFixtureBackend] = [:]
        coordinator.makeSession = { id in
            let backend = HandoffChildFixtureBackend()
            backends[id] = backend
            return ChatSession(id: id, copilotBackend: backend)
        }
        coordinator.worktreesRoot = scratch.appendingPathComponent("worktrees", isDirectory: true)
        let parentBackend = HandoffChildFixtureBackend()
        let parent = ChatSession(copilotBackend: parentBackend)
        parent.workdir = repo
        try parent.updateTab(name: "Cantrip")
        manager.sessions = [parent]
        manager.select(parent.id)
        let delegations = CantripHomeDelegations.shared
        delegations.attach(manager: manager)
        defer {
            homeChat.cancel()
            for session in manager.sessions { session.cancel() }
        }

        parent.submitRemote("Refactor the parser", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == 1 }
        precondition(parent.isStreaming)

        func handOff(_ summary: String) throws -> CantripHomeDelegation {
            let prompt = "(Handed off by Cantrip Home.)\n\nGoal: \(summary)"
            let handoff = try delegations.dispatch(.init(tabID: parent.id, summary: summary, prompt: prompt))
            var reply = ChatMessage(role: .assistant, text: "I'm handing this to Cantrip.")
            reply.delegations = [handoff]
            homeChat.messages.append(ChatMessage(role: .user, text: summary))
            homeChat.messages.append(reply)
            precondition(handoff.status == .queued && parent.queued.contains { $0.text == prompt }, "\(handoff.status)")
            return handoff
        }
        func current(_ handoff: CantripHomeDelegation) throws -> CantripHomeDelegation {
            delegations.refresh()
            return try requireHandoffChild(homeChat.messages.flatMap(\.delegations).first { $0.id == handoff.id })
        }
        func card(_ handoff: CantripHomeDelegation) -> CantripHomeHandoffResult? {
            homeChat.messages.compactMap(\.handoffResult).first { $0.delegationID == handoff.id }
        }
        func childOf(_ handoff: CantripHomeDelegation) -> ChildTab? {
            store.children(of: parent.id).first { $0.prompt == handoff.prompt && $0.state != .requeued }
        }
        func fork(_ handoff: CantripHomeDelegation) async throws -> ChatSession {
            let item = try requireHandoffChild(parent.queued.first { $0.text == handoff.prompt })
            return try await coordinator.fork(parentID: parent.id, itemID: item.id)
        }

        // 1. Run in Child Tab: the handoff follows its request and shows it running there.
        let docs = try handOff("Add a docs page")
        let docsChild = try await fork(docs)
        var now = try current(docs)
        precondition(now.tabID == docsChild.id && now.parentTabID == parent.id && now.parentTabTitle == "Cantrip"
                     && now.status == .running && now.tabTitle == docsChild.title && now.childState == .working,
                     "\(now)")
        let child = now.snapshot["childTab"] as? [String: Any]
        precondition(child?["parentTabID"] as? String == parent.id.uuidString && child?["state"] as? String == "working"
                     && now.snapshot["tabID"] as? String == docsChild.id.uuidString, "\(now.snapshot)")
        precondition(delegations.activeHandoff(to: parent.id, containing: "Add a docs page")?.id == docs.id,
                     "Home doesn't hand the same work to the parent again")
        precondition(delegations.homeTabsData.contains("child tab “\(docsChild.title)” of Cantrip · Add a docs page · running"),
                     delegations.homeTabsData)
        precondition(card(docs) == nil, "no card while it works")
        let docsBackend = try requireHandoffChild(backends[docsChild.id])
        try await waitForJournalTest { docsBackend.prompts.count == 1 }
        let tree = try requireHandoffChild(store.record(docsChild.id)?.worktree)
        try "# Docs\n".write(toFile: tree + "/docs.md", atomically: true, encoding: .utf8)
        git("add", "-A", in: tree)
        git("commit", "-q", "-m", "Add docs", in: tree)
        docsBackend.finish("I added the docs page.\n\nSummary: Added docs.md.")
        try await waitForJournalTest { store.record(docsChild.id)?.state == .finished }
        now = try current(docs)
        precondition(now.status == .completed && now.childState == .finished && now.result?.contains("docs page") == true, "\(now)")
        var result = try requireHandoffChild(card(docs))
        precondition(result.state == .completed && result.tabID == docsChild.id && result.parentTabTitle == "Cantrip"
                     && result.headline == "Done in child tab \(docsChild.title)"
                     && result.detail.hasSuffix("Child tab of Cantrip · Done; merges into main when the parent tab is idle"),
                     "\(result.headline) | \(result.detail)")

        // 2. Auto-fork: an independent message forked on its own is followed the same way.
        let notes = try handOff("Write release notes")
        let notesItem = try requireHandoffChild(parent.queued.first { $0.text == notes.prompt })
        parent.applyQueuePlans([notesItem.id: QueuePlan(kind: .fork, reason: "Independent: can run in a child tab",
                                                        title: "Write release notes", repo: nil, touches: ["NOTES.md"])])
        parent.noteAutoDelivered(notesItem.id)
        try await waitForJournalTest { childOf(notes) != nil }
        let notesRecord = try requireHandoffChild(childOf(notes))
        precondition(notesRecord.autoStarted == true)
        try await waitForJournalTest { (try? current(notes))?.tabID == notesRecord.id }
        now = try current(notes)
        precondition(now.isInChildTab && now.status == .running && now.tabTitle == "Write release notes", "\(now)")
        let notesBackend = try requireHandoffChild(backends[notesRecord.id])
        try await waitForJournalTest { notesBackend.prompts.count == 1 }
        notesBackend.finish("Nothing needed changing.\n\nSummary: The notes were already current.")
        try await waitForJournalTest { store.record(notesRecord.id)?.state == .finished }
        now = try current(notes)
        precondition(now.status == .completed && now.outcome == "The notes were already current.", "\(now)")

        // 3. Removing the queued message is still a cancel.
        let removed = try handOff("Rename the parser module")
        let removedItem = try requireHandoffChild(parent.queued.first { $0.text == removed.prompt })
        parent.removeQueued(id: removedItem.id)
        now = try current(removed)
        precondition(now.status == .cancelled && now.error == CantripHomeDelegations.removedBeforeRunning
                     && !now.isInChildTab, "\(now)")

        // 4. Run in This Tab Instead: the request and its handoff go back to the parent's queue.
        let lint = try handOff("Fix the lint warnings")
        let lintChild = try await fork(lint)
        now = try current(lint)
        precondition(now.tabID == lintChild.id)
        try coordinator.perform("requeue", childID: lintChild.id)
        now = try current(lint)
        precondition(now.tabID == parent.id && !now.isInChildTab && now.status == .queued && now.tabTitle == "Cantrip"
                     && parent.queued.first?.text == lint.prompt, "\(now)")

        // 5. A record that an older build marked "removed" follows its child once Cantrip starts.
        let icons = try handOff("Redraw the tab icons")
        let iconsChild = try await fork(icons)
        for messageIndex in homeChat.messages.indices {
            for index in homeChat.messages[messageIndex].delegations.indices
            where homeChat.messages[messageIndex].delegations[index].id == icons.id {
                homeChat.messages[messageIndex].delegations[index].status = .cancelled
                homeChat.messages[messageIndex].delegations[index].error = CantripHomeDelegations.removedBeforeRunning
                homeChat.messages[messageIndex].delegations[index].finishedAt = Date()
            }
        }
        delegations.reviveForkedHandoffs()
        now = try current(icons)
        precondition(now.tabID == iconsChild.id && now.status == .running && now.error == nil && now.finishedAt == nil, "\(now)")
        let iconsBackend = try requireHandoffChild(backends[iconsChild.id])
        try await waitForJournalTest { iconsBackend.prompts.count == 1 }
        let iconsTree = try requireHandoffChild(store.record(iconsChild.id)?.worktree)
        try "icons\n".write(toFile: iconsTree + "/icons.txt", atomically: true, encoding: .utf8)
        git("add", "-A", in: iconsTree)
        git("commit", "-q", "-m", "Redraw icons", in: iconsTree)
        iconsBackend.finish("Redrew them.\n\nSummary: Redrew the tab icons.")
        try await waitForJournalTest { store.record(iconsChild.id)?.state == .finished }
        now = try current(icons)
        precondition(now.status == .completed)

        // 6. The parent goes idle: the children merge, and each finished handoff shows the outcome,
        // read from the child's record after the child leaves the tab list.
        parentBackend.finish("The parser is refactored.")
        // Three git merges, after any left over from earlier tests: allow more than the usual wait.
        let ours = [docsChild.id, notesRecord.id, iconsChild.id]
        let deadline = Date().addingTimeInterval(60)
        while !ours.allSatisfy({ store.record($0)?.state.isSettled == true }), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        precondition(ours.allSatisfy { store.record($0)?.state.isSettled == true },
                     "merges: \(ours.map { store.record($0).map { "\($0.title): \($0.state.rawValue) \($0.note ?? "")" } ?? "gone" }), parent busy: \(parent.isStreaming), queued: \(parent.queued.count)")
        precondition(store.record(docsChild.id)?.state == .merged && store.record(notesRecord.id)?.state == .noChanges,
                     "\(String(describing: store.record(docsChild.id)?.state)) \(String(describing: store.record(notesRecord.id)?.state))")
        precondition(!manager.sessions.contains { $0.id == docsChild.id }, "a merged child is archived")
        now = try current(docs)
        precondition(now.status == .completed && now.childState == .merged && !now.followsChild, "\(now)")
        result = try requireHandoffChild(card(docs))
        precondition(result.state == .completed && result.childStatus?.hasPrefix("Child tab of Cantrip · Merged into main") == true
                     && result.detail.contains("Merged into main · 1 file +1 −0"), result.detail)
        now = try current(notes)
        precondition(now.childState == .noChanges)
        precondition(card(notes)?.detail.hasSuffix("Child tab of Cantrip · Done · no code changes") == true, card(notes)?.detail ?? "")
        now = try current(icons)
        precondition(now.childState == .merged)
        // The requeued request runs in the parent now, and its handoff with it.
        try await waitForJournalTest { (try? current(lint))?.status == .running }
        now = try current(lint)
        precondition(now.tabID == parent.id)
        print("Home handoffs in child tabs passed")
    }

    /// The rule that moves a handoff into a child tab (and back), and how one reads once the
    /// child has left the tab list.
    @MainActor
    static func testHomeHandoffChildTabRule() {
        let parentID = UUID()
        let created = Date(timeIntervalSince1970: 1_000)
        let prompt = "(Handed off by Cantrip Home.)\n\nGoal: Add @-mention tab autocomplete"
        let handoff = CantripHomeDelegation(tabID: parentID, tabTitle: "Cantrip", summary: "@-mention auto-suggest",
                                            prompt: prompt, createdAt: created)
        func child(_ state: ChildTab.State = .working, parent: UUID = parentID, prompt: String = prompt,
                   at offset: TimeInterval = 60, id: UUID = UUID()) -> ChildTab {
            var record = ChildTab(id: id, parentID: parent, queueItemID: UUID(), title: "Add @-mention tab autocomplete",
                                  prompt: prompt, parentTitle: "Cantrip", createdAt: created.addingTimeInterval(offset),
                                  updatedAt: created.addingTimeInterval(offset))
            record.state = state
            return record
        }
        let forked = child()
        let moved = CantripHomeDelegations.followingChildTab(handoff, children: [forked], claimed: [])
        precondition(moved.tabID == forked.id && moved.parentTabID == parentID && moved.parentTabTitle == "Cantrip"
                     && moved.tabTitle == forked.title && moved.status == .queued && moved.childState == .working, "\(moved)")
        for other in [child(parent: UUID()), child(prompt: "Something else"), child(at: -60), child(.requeued)] {
            precondition(CantripHomeDelegations.followingChildTab(handoff, children: [other], claimed: []) == handoff,
                         "only a later child of the same tab, from the same request, that kept it")
        }
        precondition(CantripHomeDelegations.followingChildTab(handoff, children: [forked], claimed: [forked.id]) == handoff,
                     "a child another handoff follows isn't taken twice")
        var started = handoff
        started.tabMessageID = UUID()
        precondition(CantripHomeDelegations.followingChildTab(started, children: [forked], claimed: []) == started,
                     "a request that ran in its tab doesn't move")
        var reported = handoff
        reported.status = .cancelled
        reported.error = CantripHomeDelegations.removedBeforeRunning
        reported.finishedAt = created.addingTimeInterval(60)
        let revived = CantripHomeDelegations.followingChildTab(reported, children: [forked], claimed: [])
        precondition(revived.tabID == forked.id && revived.status == .running && revived.error == nil
                     && revived.finishedAt == nil, "\(revived)")
        var stopped = reported
        stopped.error = "Stopped in the tab."
        precondition(CantripHomeDelegations.followingChildTab(stopped, children: [forked], claimed: []) == stopped)
        let back = CantripHomeDelegations.followingChildTab(moved, children: [child(.requeued, id: forked.id)], claimed: [])
        precondition(back.tabID == parentID && back.parentTabID == nil && back.status == .queued && back.tabTitle == "Cantrip"
                     && back.childState == nil, "Run in This Tab Instead brings it back: \(back)")

        // Read from the record once the child has left the tab list.
        var running = moved
        running.status = .running
        var merged = child(.merged, id: forked.id)
        merged.baseBranch = "main"
        merged.summary = "Typing @ in the composer suggests tabs."
        merged.replies = ["Added the @ suggestions.", "Tests pass."]
        merged.files = [.init(path: "Sources/Composer.swift", added: 40, removed: 2)]
        let now = created.addingTimeInterval(600)
        let done = CantripHomeDelegations.evaluateInChild(running, child: merged, target: nil, now: now)
        precondition(done.status == .completed && done.outcome == "Typing @ in the composer suggests tabs."
                     && done.result?.contains("Tests pass.") == true && done.childState == .merged
                     && done.childStatus == "Merged into main · 1 file +40 −2" && done.finishedAt == now, "\(done)")
        let card = try? requireHandoffChild(CantripHomeHandoffResult(done, now: now))
        precondition(card?.headline == "Done in child tab Add @-mention tab autocomplete" && card?.tabID == forked.id
                     && card?.detail == "Typing @ in the composer suggests tabs.\n\nChild tab of Cantrip · Merged into main · 1 file +40 −2"
                     && card?.snapshot["parentTabTitle"] as? String == "Cantrip", "\(String(describing: card))")
        for (state, status, error) in [(ChildTab.State.discarded, CantripHomeDelegation.Status.cancelled, "Discarded in the child tab."),
                                       (.stopped, .cancelled, "The child tab was closed before this finished."),
                                       (.failed, .failed, "The child tab's run failed.")] {
            let ended = CantripHomeDelegations.evaluateInChild(running, child: child(state, id: forked.id), target: nil, now: now)
            precondition(ended.status == status && ended.error == error, "\(state): \(ended)")
        }
        let gone = CantripHomeDelegations.evaluateInChild(running, child: nil, target: nil, now: now)
        precondition(gone.status == .cancelled && gone.error == "The child tab was closed before this finished.")
        precondition(CantripHomeDelegations.handoffTabLabel(running) == "child tab “Add @-mention tab autocomplete” of Cantrip")
    }

    private static func requireHandoffChild<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }
}
