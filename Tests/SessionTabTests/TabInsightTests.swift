import Foundation

private final class InsightFixtureBackend: Backend {
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
    /// Looking into other tabs: the parent's live child lines, reading a tab on demand, private
    /// tabs never exposed, Home's tab data, and `tab ask` there and back.
    @MainActor
    static func testTabInsight() async throws {
        testChildStatusLines()
        testTabTranscriptText()
        try testTabCommandParsing()
        testTabCommandGuardrails()
        try await testTabInsightFlow()
        try await testTabMentions()
        print("Tab insight: child status lines, reading, privacy, Home tab data and tab ask passed")
    }

    static func testChildStatusLines() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var record = ChildTab(id: id, parentID: UUID(), queueItemID: UUID(), title: "Notes file",
                              prompt: "Add a notes file", parentTitle: "Cantrip", createdAt: Date(), updatedAt: Date())
        record.baseBranch = "main"
        let prefix = "- “Notes file” (\(id.uuidString)): "
        var line = record.liveStatusLine(activity: "Running swift build", touched: ["notes.txt", "a.swift"])
        precondition(line == prefix + "working · now: Running swift build · files so far: notes.txt, a.swift", line ?? "nil")
        precondition(record.liveStatusLine() == prefix + "working")
        record.state = .needsInput
        line = record.liveStatusLine(question: "Which port?\nPick one.")
        precondition(line == prefix + "needs the user's answer: Which port? Pick one.", line ?? "nil")
        record.state = .finished
        precondition(record.liveStatusLine() == prefix + "done, waiting to merge into main (Cantrip merges it when this tab is idle)")
        record.note = "Waiting: uncommitted changes in Cantrip touch the same files."
        precondition(record.liveStatusLine() == prefix + "done; Waiting: uncommitted changes in Cantrip touch the same files.")
        record.note = nil
        record.state = .merging
        precondition(record.liveStatusLine() == prefix + "merging into main")
        record.resolveRequested = true
        precondition(record.liveStatusLine() == prefix + "you were asked to resolve its merge conflict")
        record.resolveRequested = false
        record.state = .conflict
        record.conflictFiles = ["a.txt"]
        precondition(record.liveStatusLine() == prefix + "merge conflict in a.txt; the user picks how to merge on its card")
        record.state = .working
        line = record.liveStatusLine(touched: ["1", "2", "3", "4", "5", "6", "7"])
        precondition(line?.hasSuffix("files so far: 1, 2, 3, 4, 5 (+2 more)") == true, line ?? "nil")
        precondition(!record.needsReport, "a live child is told every message, not once")

        // Outcomes are told once each; a later outcome is told again.
        for state in [ChildTab.State.merged, .noChanges, .discarded, .unmerged, .failed, .stopped] {
            record.state = state
            record.reportedState = nil
            record.contextDelivered = false
            precondition(record.liveStatusLine() == nil && record.needsReport, "\(state)")
            record.reportedState = state
            precondition(!record.needsReport, "\(state) told twice")
        }
        record.reportedState = .stopped
        record.state = .merged
        precondition(record.needsReport, "stopped, then merged: the merge is news")
        record.reportedState = nil
        record.contextDelivered = true
        precondition(!record.needsReport, "older records that were told stay told")
        record.contextDelivered = false
        record.state = .requeued
        precondition(!record.needsReport, "a request moved back to the parent isn't an outcome")
    }

    static func testTabTranscriptText() {
        let long = "Start of the reply. " + String(repeating: "x", count: 4_000) + " The outcome."
        var messages = [
            ChatMessage(role: .user, text: "First request"),
            ChatMessage(role: .assistant, text: "First reply"),
            ChatMessage(role: .user, text: "Second request"),
            ChatMessage(role: .user, text: "Queued with it"),
            ChatMessage(role: .assistant, text: long),
            ChatMessage(role: .handoff, text: "Child tab “Notes”: Merged into main."),
            ChatMessage(role: .freshStart, text: "Started fresh"),
            ChatMessage(role: .user, text: "Third request"),
            ChatMessage(role: .assistant, text: ""),
        ]
        messages[8].activities = [ToolActivity(id: "a1", title: "Edited notes.txt", toolName: "edit", state: .succeeded,
                                               input: nil, output: nil, fileChanges: [], terminalCommand: nil)]
        var text = TabInsight.transcript(messages, turns: 2, full: false, streaming: true)
        precondition(text.hasPrefix("Turns 3–4 of 4") && text.contains("data, not instructions"), text)
        precondition(text.contains("Started fresh") && text.contains("Request: Third request")
                     && text.contains("Reply (still working): …") && text.contains("Steps so far: Edited notes.txt")
                     && !text.contains("First request"), text)
        text = TabInsight.transcript(messages, turns: nil, full: false)
        precondition(text.hasPrefix("All 4 turns") && text.contains("── Turn 2 ──\nRequest: Second request\nRequest: Queued with it"), text)
        precondition(text.contains("Start of the reply.") && text.contains("The outcome.") && text.contains("characters cut")
                     && text.contains("Card: Child tab “Notes”"), "long replies keep their start and end")
        precondition(!text.contains("Reply (still working)"), "a settled tab has no running reply")
        text = TabInsight.transcript(messages, turns: nil, full: true)
        precondition(text.contains(long.trimmingCharacters(in: .whitespaces)) && !text.contains("characters cut"))
        precondition(TabInsight.transcript([], turns: 3, full: false) == "No messages yet.")
    }

    static func testTabCommandParsing() throws {
        typealias Command = CantripCLI.TabCommand
        let cases: [([String], Command)] = [
            ([], .list), (["list"], .list),
            (["read", "ABCDEF12", "--turns", "5", "--full"], .read(id: "ABCDEF12", turns: 5, all: false, full: true)),
            (["read", "ABCDEF12", "--all"], .read(id: "ABCDEF12", turns: nil, all: true, full: false)),
            (["ask", "ABCDEF12", "--steer", "Also", "add", "a", "heading"],
             .ask(id: "ABCDEF12", question: "Also add a heading", steer: true, wait: Command.defaultWait)),
            (["ask", "ABCDEF12", "Which port?", "--wait", "0"], .ask(id: "ABCDEF12", question: "Which port?", steer: false, wait: 0)),
            (["ask", "ABCDEF12", "--", "--steer", "is", "a", "flag?"],
             .ask(id: "ABCDEF12", question: "--steer is a flag?", steer: false, wait: Command.defaultWait)),
            (["reply", "A1B2", "--wait", "10"], .reply(askID: "A1B2", wait: 10)),
        ]
        for (arguments, expected) in cases {
            let parsed = try Command.parse(arguments)
            precondition(parsed == expected, "\(arguments) -> \(parsed)")
        }
        for bad in [["ask", "ABCDEF12"], ["read"], ["read", "X", "--turns", "many"], ["frobnicate"]] {
            do {
                _ = try Command.parse(bad)
                preconditionFailure("parsed \(bad)")
            } catch let failure as CantripCLI.Failure {
                precondition(failure.code == 2, failure.message)
            }
        }
        precondition(CantripCLI.commands.isSuperset(of: ["tab", "tabs"]))
    }

    /// The reading commands run under Home's guardrails and in child tabs.
    static func testTabCommandGuardrails() {
        let id = UUID().uuidString
        for binary in [TabInsight.command, "/Users/me/Coding/Cantrip/Cantrip.app/Contents/MacOS/Cantrip"] {
            for command in ["\(binary) tab read \(id) --turns 5", "\(binary) tab list",
                            "\(binary) tab ask \(id) \"Which port does it use?\""] {
                for mode in [CantripHomeGuardrail.attended, .unattended] {
                    let decision = CantripHomeActionPolicy.evaluate(.shell(command), mode: mode)
                    precondition(decision.verdict == .allow, "\(mode) \(command): \(decision)")
                }
                precondition(ChildTabResource.resource(for: command) == nil, command)
            }
        }
    }

    @MainActor
    static func testTabInsightFlow() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.voiceMode = false
        settings.childTabsAutoFork = false
        defer { (settings.backend, settings.memoryEnabled, settings.voiceMode, settings.childTabsAutoFork) = saved }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-tab-insight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let manager = SessionManager()
        var backends: [UUID: InsightFixtureBackend] = [:]
        manager.childTabs.makeSession = { id in
            let backend = InsightFixtureBackend()
            backends[id] = backend
            return ChatSession(id: id, copilotBackend: backend)
        }
        func addTab(_ name: String) throws -> (ChatSession, InsightFixtureBackend) {
            let backend = InsightFixtureBackend()
            let session = ChatSession(copilotBackend: backend)
            session.workdir = scratch.path
            try session.updateTab(name: name)
            manager.sessions.append(session)
            return (session, backend)
        }
        defer { for session in manager.sessions { session.cancel() } }
        let (parent, parentBackend) = try addTab("Planner")
        let (docs, docsBackend) = try addTab("Docs")
        let (secret, secretBackend) = try addTab("Secret plans")
        secret.isPrivate = true
        let host = HostControl(manager: manager)

        // 1. A running child: the parent hears a live line with each message, and steers it.
        parent.submitRemote("Work on the planner", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == 1 }
        parent.submitRemote("Write the notes file", mode: .queue)
        let item = try requireInsight(parent.queued.last)
        let child = try await manager.childTabs.fork(parentID: parent.id, itemID: item.id)
        let childBackend = try requireInsight(backends[child.id])
        try await waitForJournalTest { childBackend.prompts.count == 1 }
        childBackend.sink?(.activity(ToolActivity(
            id: "edit-1", title: "Edit notes.txt", toolName: "edit", state: .running, input: nil, output: nil,
            fileChanges: [ToolFileChange(id: "c1", path: "notes.txt", diff: "+milk")], terminalCommand: nil)))
        try await waitForJournalTest { child.currentActivity != nil }
        parent.submitRemote("Next planner step", mode: .queue)
        parentBackend.finish("Planner work done.")
        try await waitForJournalTest { parentBackend.prompts.count == 2 }
        var prompt = parentBackend.prompts[1]
        precondition(prompt.contains("(Child tabs of this tab") && prompt.contains("Now:")
                     && prompt.contains("“Write the notes file” (\(child.id.uuidString)): working · now: Edit notes.txt · files so far: notes.txt")
                     && prompt.contains("tab read <child ID>") && prompt.contains("--steer")
                     && !prompt.contains("Since your last turn:") && prompt.contains("Next planner step"), prompt)

        let steer = try manager.tabAsks.ask(String(child.id.uuidString.prefix(8)), question: "Also add a heading.",
                                            from: parent.id, steer: true)
        precondition(steer.isActive && steer.steer)
        let steerCard = try requireInsight(parent.messages.last?.handoffResult)
        precondition(steerCard.isAsk && steerCard.state == .working && steerCard.headline == "Asked Write the notes file"
                     && steerCard.summary == "Also add a heading.", "\(steerCard)")
        try await waitForJournalTest { !child.queued.isEmpty || childBackend.prompts.count == 2 }
        childBackend.finish("Wrote notes.txt.")
        try await waitForJournalTest { childBackend.prompts.count == 2 }
        precondition(childBackend.prompts[1].contains("(From your parent tab “Planner”")
                     && childBackend.prompts[1].contains("Also add a heading."), childBackend.prompts[1])
        precondition(child.messages.contains { $0.role == .user && $0.text.contains("Also add a heading.") },
                     "the steering is a visible turn in the child")
        childBackend.finish("Added a heading too.\n\nSummary: Wrote notes.txt with a heading.")
        try await waitForJournalTest {
            manager.tabAsks.lookup(steer.id, markDelivered: false)?.status == "answered"
                && ChildTabStore.shared.record(child.id)?.state == .noChanges
        }
        let steered = try requireInsight(manager.tabAsks.asks[steer.id])
        precondition(steered.reply?.contains("Added a heading too.") == true, steered.reply ?? "nil")
        let answeredCard = try requireInsight(parent.messages.last { $0.handoffResult?.delegationID == steer.id }?.handoffResult)
        precondition(answeredCard.state == .completed && answeredCard.headline == "Answer from Write the notes file"
                     && answeredCard.detail.contains("Added a heading too."), "\(answeredCard)")
        precondition(ChildTabStore.shared.record(child.id)?.summary == "Wrote notes.txt with a heading.")

        parent.submitRemote("Wrap up", mode: .queue)
        parentBackend.finish("Next step done.")
        try await waitForJournalTest { parentBackend.prompts.count == 3 }
        prompt = parentBackend.prompts[2]
        precondition(prompt.contains("Since your last turn:") && prompt.contains("Done · no repository to merge")
                     && prompt.contains("(ID \(child.id.uuidString))") && !prompt.contains("Now:"), prompt)
        precondition(prompt.contains("answered “Also add a heading.”: Added a heading too."),
                     "a reply the command never printed comes with the next message: \(prompt)")
        parent.submitRemote("One more", mode: .queue)
        parentBackend.finish("Wrapped up.")
        try await waitForJournalTest { parentBackend.prompts.count == 4 }
        precondition(!parentBackend.prompts[3].contains("Child tabs of this tab")
                     && !parentBackend.prompts[3].contains("Questions this tab asked"), "nothing new: no block")
        parentBackend.finish("Done.")
        try await waitForJournalTest { !parent.isStreaming }

        // 2. Reading: open, closed child, never private; read-only.
        let archived = try TabInsight.read(String(child.id.uuidString.prefix(8)), turns: 5, full: false, manager: manager)
        precondition(archived.contains("Tab “Write the notes file”") && archived.contains("Child tab of “Planner” (\(parent.id.uuidString))")
                     && archived.contains("Closed") && archived.contains("Request: Write the notes file")
                     && archived.contains("Summary: Wrote notes.txt with a heading."), archived)
        precondition(!manager.sessions.contains { $0.id == child.id }, "the finished child is archived")
        let parentCount = parent.messages.count
        let reading = try TabInsight.read(parent.id.uuidString, turns: 1, full: false, manager: manager)
        precondition(reading.contains("Tab “Planner”") && reading.contains("Open · idle")
                     && reading.contains("Child tabs: \(child.id.uuidString)") && reading.contains("Request: One more"), reading)
        precondition(parent.messages.count == parentCount, "reading adds nothing")
        secret.messages = [ChatMessage(role: .user, text: "The secret request")]
        for hidden in [secret.id, ChatSession.privateLocalID, ChatSession.cantripHomeID, ChatSession.cantripHomeBackgroundID] {
            do {
                _ = try TabInsight.read(hidden.uuidString, turns: 3, full: true, manager: manager)
                preconditionFailure("read a private or Home conversation: \(hidden)")
            } catch let failure as TabInsight.Failure {
                precondition(failure.message.hasPrefix("No readable tab"), failure.message)
            }
        }
        // Private Local saves its conversation, but it is never readable by ID or prefix.
        manager.sessions.first { $0.isLocalPrivate }?.messages = [ChatMessage(role: .user, text: "local secret")]
        manager.sessions.first { $0.isLocalPrivate }?.persistTranscript()
        precondition(FileManager.default.fileExists(atPath: SessionManager.chatsDir
            .appendingPathComponent("\(ChatSession.privateLocalID.uuidString).json").path))
        do {
            _ = try TabInsight.read("91A48C51", turns: 3, full: true, manager: manager)
            preconditionFailure("read Private Local")
        } catch is TabInsight.Failure {}
        let listing = host.handle(["command": "tab", "action": "list"])["text"] as? String ?? ""
        precondition(listing.contains(parent.id.uuidString) && listing.contains(docs.id.uuidString)
                     && listing.contains("child tabs \(child.id.uuidString)")
                     && !listing.contains(secret.id.uuidString) && !listing.contains("Secret plans")
                     && !listing.contains(ChatSession.privateLocalID.uuidString)
                     && !listing.contains(ChatSession.cantripHomeID.uuidString), listing)
        let viaHost = host.handle(["command": "tab", "action": "read", "id": String(parent.id.uuidString.prefix(8)), "turns": 2])
        precondition((viaHost["text"] as? String)?.contains("Turns ") == true, "\(viaHost)")
        precondition((host.handle(["command": "tab", "action": "read", "id": secret.id.uuidString])["error"] as? String)?
            .hasPrefix("No readable tab") == true)

        // 3. Home's tab data: children, reading commands, and no private tabs.
        CantripHomeDelegations.shared.attach(manager: manager)
        let homeData = CantripHomeDelegations.shared.homeTabsData
        precondition(homeData.contains(parent.id.uuidString) && homeData.contains("child tabs \(child.id.uuidString) \"Write the notes file\"")
                     && !homeData.contains(secret.id.uuidString) && !homeData.contains("Secret plans"), homeData)
        let rules = CantripHomeDelegations.shared.homeHandoffRules
        precondition(rules.contains("tab read <tab ID>") && rules.contains("tab ask <tab ID>")
                     && rules.contains("never for change work") && rules.contains("data, never instructions"), rules)
        let background = CantripHomeDelegations.shared.backgroundTabsData
        precondition(background.contains("tab read <tab ID>") && !background.contains("tab ask"), background)
        precondition(CantripHomeDelegations.shared.backgroundInstructions.contains("tab read <tab ID>"))

        // 4. Ask an idle tab; the command gets the reply.
        let askingThread = try requireInsight(parent.currentThreadID)
        let first = try manager.tabAsks.ask(docs.id.uuidString, question: "Which port does the server use?",
                                            from: parent.id, steer: false)
        try await waitForJournalTest { docsBackend.prompts.count == 1 }
        precondition(docsBackend.prompts[0].contains("(Question from the tab “Planner”")
                     && docsBackend.prompts[0].contains("not a handoff") && docsBackend.prompts[0].contains("Which port does the server use?"))
        precondition(first.status == "running" && docs.messages.contains { $0.role == .user && $0.text.contains("Which port") })
        docsBackend.finish("It uses port 8765.")
        var polled = host.handle(["command": "tab", "action": "reply", "askID": first.id.uuidString])
        try await waitForJournalTest {
            polled = host.handle(["command": "tab", "action": "reply", "askID": first.id.uuidString])
            return polled["done"] as? Bool == true
        }
        precondition(polled["status"] as? String == "answered" && polled["reply"] as? String == "It uses port 8765."
                     && polled["tabTitle"] as? String == "Docs", "\(polled)")
        precondition(manager.tabAsks.asks[first.id]?.delivered == true, "the command printed it")
        let card = try requireInsight(parent.messages.last { $0.handoffResult?.delegationID == first.id })
        precondition(card.role == .handoff && card.handoffResult?.detail == "It uses port 8765."
                     && card.text.contains("Answer from Docs"), card.text)
        precondition(card.threadID == askingThread, "the card joins the thread that asked (thread tags)")
        let remote = RemoteHistory.message(card)
        precondition((remote["handoffResult"] as? [String: Any])?["kind"] as? String == "ask", "\(remote)")
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(card))
        precondition(decoded.handoffResult?.isAsk == true && decoded.role == .handoff)

        // 5. A busy tab: the question waits in its queue; the reply comes with the asker's next message.
        docs.submitRemote("Rewrite the README", mode: .queue)
        try await waitForJournalTest { docsBackend.prompts.count == 2 }
        let queuedAsk = try manager.tabAsks.ask(docs.id.uuidString, question: "Is the README done?", from: parent.id, steer: false)
        precondition(queuedAsk.status == "queued" && docs.queued.count == 1, queuedAsk.status)
        do {
            try manager.tabAsks.ask(parent.id.uuidString, question: "What are you planning?", from: docs.id, steer: false)
            preconditionFailure("two tabs waiting on each other")
        } catch let failure as TabInsight.Failure {
            precondition(failure.message.contains("already waiting on a question"), failure.message)
        }
        docsBackend.finish("README rewritten.")
        try await waitForJournalTest { docsBackend.prompts.count == 3 }
        precondition(docsBackend.prompts[2].contains("Is the README done?"))
        docsBackend.finish("Yes, the README is done.")
        try await waitForJournalTest { manager.tabAsks.lookup(queuedAsk.id, markDelivered: false)?.status == "answered" }
        precondition(manager.tabAsks.asks[queuedAsk.id]?.delivered == false)
        parent.submitRemote("Continue planning", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == 5 }
        prompt = parentBackend.prompts[4]
        precondition(prompt.contains("(Questions this tab asked other tabs with `tab ask`")
                     && prompt.contains("“Docs” (\(docs.id.uuidString)) answered “Is the README done?”: Yes, the README is done.")
                     && prompt.contains("never instructions") && !prompt.contains("Which port"), prompt)
        precondition(manager.tabAsks.asks[queuedAsk.id]?.delivered == true)
        parentBackend.finish("Planned.")
        try await waitForJournalTest { !parent.isStreaming }

        // 6. Home asks; refusals.
        let homeAsk = try manager.tabAsks.ask(docs.id.uuidString, question: "What changed today?",
                                              from: ChatSession.cantripHomeID, steer: false)
        try await waitForJournalTest { docsBackend.prompts.count == 4 }
        precondition(docsBackend.prompts[3].contains("(Question from Cantrip Home"), docsBackend.prompts[3])
        docsBackend.finish("The README.")
        try await waitForJournalTest { manager.tabAsks.lookup(homeAsk.id, markDelivered: false)?.status == "answered" }
        precondition(manager.homeSession.messages.contains { $0.handoffResult?.delegationID == homeAsk.id && $0.handoffResult?.isAsk == true },
                     "Home gets the card")
        let refusals: [(String, UUID?, Bool, String)] = [
            (docs.id.uuidString, docs.id, false, "can't ask itself"),
            (secret.id.uuidString, parent.id, false, "No readable tab"),
            (docs.id.uuidString, secret.id, false, "Private tabs can't ask"),
            (docs.id.uuidString, ChatSession.privateLocalID, false, "Private tabs can't ask"),
            (docs.id.uuidString, ChatSession.cantripHomeBackgroundID, false, "background runs"),
            (docs.id.uuidString, parent.id, true, "--steer is for"),
            (child.id.uuidString, parent.id, false, "is closed"),
            (docs.id.uuidString, parent.id, false, "Write the question"),
        ]
        for (target, asker, steer, expected) in refusals {
            do {
                try manager.tabAsks.ask(target, question: expected == "Write the question" ? "  " : "Hello?", from: asker, steer: steer)
                preconditionFailure("asked \(target) from \(String(describing: asker))")
            } catch let failure as TabInsight.Failure {
                precondition(failure.message.contains(expected), "\(expected): \(failure.message)")
            }
        }
        precondition(secretBackend.prompts.isEmpty && secret.messages.count == 1, "a private tab is never asked")
        let refused = host.handle(["command": "tab", "action": "ask", "id": secret.id.uuidString, "question": "Hi"])
        precondition((refused["error"] as? String)?.hasPrefix("No readable tab") == true, "\(refused)")

        // 7. Framing, and asks surviving a relaunch of the coordinator.
        precondition(TabAskCoordinator.framed("Why?", askerTitle: "x", isHome: false, fromParent: false, fromTerminal: true)
            .hasPrefix("(Question sent with `cantrip tab ask` from a terminal."))
        let reloaded = TabAskCoordinator(manager: manager)
        precondition(reloaded.asks[first.id]?.reply == "It uses port 8765." && reloaded.asks.count == manager.tabAsks.asks.count)

        // 8. A child that isn't running can't be asked (it would restart outside the caps and
        // merge on its own); a child made private later, and a private parent, stay unnamed.
        parent.submitRemote("Plan the release", mode: .queue)
        try await waitForJournalTest { parentBackend.prompts.count == 6 }
        parent.submitRemote("Draft the changelog", mode: .queue)
        let sideItem = try requireInsight(parent.queued.last)
        let side = try await manager.childTabs.fork(parentID: parent.id, itemID: sideItem.id)
        let sideBackend = try requireInsight(backends[side.id])
        try await waitForJournalTest { sideBackend.prompts.count == 1 }
        side.cancel()
        try await waitForJournalTest { ChildTabStore.shared.record(side.id)?.state == .stopped }
        precondition(manager.sessions.contains { $0.id == side.id }, "a stopped child stays open")
        do {
            try manager.tabAsks.ask(side.id.uuidString, question: "Why did you stop?", from: parent.id, steer: false)
            preconditionFailure("asked a stopped child")
        } catch let failure as TabInsight.Failure {
            precondition(failure.message.contains("isn't running") && failure.message.contains("tab read"), failure.message)
        }
        precondition(sideBackend.prompts.count == 1 && ChildTabStore.shared.record(side.id)?.state == .stopped)
        side.isPrivate = true
        let afterPrivate = TabInsight.list(manager: manager)
        precondition(!afterPrivate.contains(side.id.uuidString) && afterPrivate.contains(child.id.uuidString), afterPrivate)
        precondition(!CantripHomeDelegations.shared.homeTabsData.contains(side.id.uuidString))
        do {
            _ = try TabInsight.read(side.id.uuidString, turns: 3, full: false, manager: manager)
            preconditionFailure("read a child made private")
        } catch is TabInsight.Failure {}
        parent.submitRemote("Ship it", mode: .queue)
        parentBackend.finish("Release planned.")
        try await waitForJournalTest { parentBackend.prompts.count == 7 }
        precondition(!parentBackend.prompts[6].contains(side.id.uuidString), parentBackend.prompts[6])
        precondition(ChildTabStore.shared.record(side.id)?.reportedState == nil, "a private child's outcome isn't told")
        parentBackend.finish("Shipped.")
        try await waitForJournalTest { !parent.isStreaming }
        parent.isPrivate = true
        let orphan = try TabInsight.read(child.id.uuidString, turns: 1, full: false, manager: manager)
        let orphanHeader = orphan.split(separator: "\n").prefix(3).joined(separator: "\n")
        precondition(orphanHeader.contains("\nChild tab · ") && !orphanHeader.contains(parent.id.uuidString)
                     && !orphanHeader.contains("Planner"), orphanHeader)
        precondition(!TabInsight.list(manager: manager).contains(parent.id.uuidString))
    }

    private static func requireInsight<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }
}
