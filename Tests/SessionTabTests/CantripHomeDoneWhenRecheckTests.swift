import Foundation

/// Done when after the handoff's turn: what waits on an install, a schedule or the user shows as
/// waiting, a later turn of the tab checks it again (at most three times), and the checker's notes
/// stay in the handoff log.
extension SessionTabTests {
    @MainActor
    static func testCantripHomeDoneWhenRechecks() async throws {
        try testDoneWhenWaitingForInstallScheduleAndUser()
        try testDoneWhenRecheckReadsLaterTurnsNotOtherHandoffs()
        try await testDoneWhenLaterTabReplyFlipsNotMetToMet()
        try await testDoneWhenRecheckCap()
        try await testDoneWhenNoteSavedInHandoffLog()
        print("Cantrip Home Done when re-checks passed")
    }

    /// (2) An install, a scheduled run or the user: a waiting state, never a send-back, with its own card line.
    @MainActor
    static func testDoneWhenWaitingForInstallScheduleAndUser() throws {
        typealias Check = CantripHomeDoneWhen
        let parsed = try Check.Verdict.parse(
            #"{"met":false,"missing":"Proofs run after the install.","waitingFor":"install","confidence":0.9}"#)
        precondition(parsed.waitingFor == .install, "\(parsed)")
        let none = try Check.Verdict.parse(#"{"met":false,"waitingFor":"","confidence":0.9}"#)
        let unknown = try Check.Verdict.parse(#"{"met":false,"waitingFor":"later","confidence":0.9}"#)
        precondition(none.waitingFor == nil && unknown.waitingFor == nil, "an empty or unknown reason is no reason")
        let cases: [(Check.Waiting, String, String)] = [
            (.install, "waitingInstall", "Done when waits for an install. Proofs run after the install."),
            (.schedule, "waitingSchedule", "Done when waits for a scheduled run. Proofs run after the install."),
            (.user, "waitingUser", "Done when waits for you. Proofs run after the install."),
        ]
        for (waiting, label, line) in cases {
            let verdict = Check.Verdict(met: false, missing: "Proofs run after the install.", confidence: 0.9, waitingFor: waiting)
            precondition(Check.outcome(of: verdict, sendBacks: 0) == .waiting(waiting, "Proofs run after the install."),
                         "\(waiting): waits, not sent back")
            precondition(Check.label(.notMet, waiting: waiting) == label)
            precondition(Check.cardLine(state: .notMet, note: "Proofs run after the install.", waiting: waiting) == line)
        }
        precondition(Check.outcome(of: .init(met: false, missing: "Needs approval.", needsUser: true), sendBacks: 0)
                     == .waiting(.user, "Needs approval."), "needsUser without a reason waits for the user")
        precondition(Check.label(.notMet, waiting: nil) == "notMet" && Check.label(.met, waiting: .install) == "met")
        // A re-check never sends work back: the handoff has already finished.
        precondition(Check.outcome(of: .init(met: false, missing: "Not pushed.", confidence: 0.9), sendBacks: 0,
                                   canSendBack: false) == .notMet("Not pushed."))
        // A waiting reason from a newer build still reads as one.
        let decoded = try JSONDecoder().decode([Check.Waiting].self, from: Data(#"["install","review"]"#.utf8))
        precondition(decoded == [.install, .user], "\(decoded)")
    }

    /// A re-check reads the tab's later turns, but not another handoff's run in the same tab.
    @MainActor
    static func testDoneWhenRecheckReadsLaterTurnsNotOtherHandoffs() throws {
        let tabID = UUID()
        func user(_ text: String, run: UUID) -> ChatMessage {
            var message = ChatMessage(role: .user, text: text)
            message.runID = run
            return message
        }
        func reply(_ text: String, run: UUID) -> ChatMessage {
            var message = ChatMessage(role: .assistant, text: text)
            message.runID = run
            return message
        }
        let runA = UUID(), runB = UUID(), runC = UUID()
        var messages = [user("PROMPT-A", run: runA), reply("A is staged.", run: runA),
                        user("PROMPT-B", run: runB), reply("B is half done", run: runB)]
        var first = CantripHomeDelegation(tabID: tabID, tabTitle: "Cantrip", summary: "A", prompt: "PROMPT-A", createdAt: Date())
        first.tabMessageID = messages[0].id
        var second = CantripHomeDelegation(tabID: tabID, tabTitle: "Cantrip", summary: "B", prompt: "PROMPT-B", createdAt: Date())
        second.tabMessageID = messages[2].id
        let own = CantripHomeDelegations.handoffReplies(first, in: messages)
        precondition(CantripHomeDelegations.laterReplies(first, others: [first, second], in: messages) == nil,
                     "another handoff's run isn't a later turn of this one")
        messages += [user("(Automated: Cantrip v2 is live.) Run the proofs.", run: runC), reply("Proofs pass.", run: runC)]
        let later = try requireRecheck(CantripHomeDelegations.laterReplies(first, others: [first, second], in: messages))
        precondition(later.replies == ["Proofs pass."] && later.lastID == messages[5].id, "\(later)")
        precondition(CantripHomeDoneWhen.recheckReplies(own: own, later: ["one", "two", "three"]) == ["A is staged.", "two", "three"],
                     "a re-check keeps the handoff's own last reply and the latest two")
    }

    /// (1) A handoff waiting on its install is checked again when a later turn of its tab reports
    /// the proofs, and its card, entry and history turn to met.
    @MainActor
    static func testDoneWhenLaterTabReplyFlipsNotMetToMet() async throws {
        let fixture = try DoneWhenFixture()
        defer { fixture.close() }
        fixture.verdicts = [.init(met: false, missing: "The proofs run after the install.", confidence: 0.9, waitingFor: .install),
                            .init(met: true)]
        let handoff = try fixture.handOff("Ship the relay")
        try await fixture.finishTab("Built and staged v2.\n\nOutcome: staged; the proofs run after the install.")
        fixture.delegations.refresh()
        try await waitForJournalTest { fixture.current(handoff)?.doneWhenState == .notMet }
        let waiting = try requireRecheck(fixture.current(handoff))
        precondition(waiting.status == .completed && waiting.doneWhenWaiting == .install && waiting.doneWhenSendBacks == nil,
                     "an install wait is reported, not sent back: \(waiting)")
        precondition(!fixture.tab.messages.contains { $0.text.hasPrefix(CantripHomeDoneWhen.sendBackPrefix) })
        let waitingCard = try fixture.card(handoff)
        precondition(waitingCard.detail.hasPrefix("Done when waits for an install."), waitingCard.detail)
        // No later turn, no re-check.
        fixture.delegations.refresh()
        fixture.delegations.refresh()
        precondition(fixture.asked.count == 1)

        // The proofs arrive in a later turn of the same tab (a notifier waking it after the install).
        fixture.tab.submitRemote("(Automated: Cantrip v2 is live.) Run the proofs.", mode: .queue)
        try await fixture.finishTab("Every proof passes on v2.\n\nOutcome: v2 live, all proofs pass.")
        fixture.delegations.refresh()
        try await waitForJournalTest { fixture.current(handoff)?.doneWhenState == .met }
        let met = try requireRecheck(fixture.current(handoff))
        precondition(fixture.asked.count == 2 && fixture.asked[1].replies.first?.contains("Built and staged v2") == true
                     && fixture.asked[1].replies.last?.contains("Every proof passes") == true, "\(fixture.asked)")
        precondition(met.doneWhenRechecks == 1 && met.doneWhenWaiting == nil && met.doneWhenNote == nil
                     && met.doneWhenHistory?.map(\.state) == ["waitingInstall", "met"]
                     && met.doneWhenHistory?.map(\.recheck) == [false, true], "\(met)")
        let card = try fixture.card(handoff)
        precondition(card.doneWhenState == .met && card.detail.hasSuffix("Checked against Done when: met after a later turn.")
                     && (card.snapshot["doneWhen"] as? [String: Any])?["state"] as? String == "met", card.detail)
        fixture.delegations.refresh()
        precondition(fixture.asked.count == 2, "a met handoff isn't checked again")
    }

    /// (3) At most three re-checks per handoff, only within 72 hours of finishing, one per new reply.
    @MainActor
    static func testDoneWhenRecheckCap() async throws {
        let fixture = try DoneWhenFixture()
        defer { fixture.close() }
        let unsure = CantripHomeDoneWhen.Verdict(met: false, missing: "No proof shown.", confidence: 0.3)
        fixture.verdicts = Array(repeating: unsure, count: 5)
        let handoff = try fixture.handOff("Measure the round")
        try await fixture.finishTab("Measured part of it.")
        fixture.delegations.refresh()
        try await waitForJournalTest { fixture.current(handoff)?.doneWhenState == .unchecked }
        for turn in 1...4 {
            fixture.tab.submitRemote("(Automated: the round ran.) Turn \(turn).", mode: .queue)
            try await fixture.finishTab("Still measuring, turn \(turn).")
            fixture.delegations.refresh()
            if turn <= CantripHomeDoneWhen.maximumRechecks {
                try await waitForJournalTest { fixture.current(handoff)?.doneWhenRechecks == turn }
            } else {
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        let capped = try requireRecheck(fixture.current(handoff))
        precondition(fixture.asked.count == 1 + CantripHomeDoneWhen.maximumRechecks && capped.doneWhenRechecks == 3
                     && capped.doneWhenHistory?.count == 4, "the fourth later turn isn't checked: \(fixture.asked.count)")
        precondition(!CantripHomeDoneWhen.awaitsRecheck(capped, now: Date()))
        var recent = capped
        recent.doneWhenRechecks = 0
        let finished = try requireRecheck(recent.finishedAt)
        precondition(CantripHomeDoneWhen.awaitsRecheck(recent, now: finished.addingTimeInterval(71 * 3_600))
                     && !CantripHomeDoneWhen.awaitsRecheck(recent, now: finished.addingTimeInterval(73 * 3_600)),
                     "only within 72 hours")
        var older = recent
        older.doneWhenHistory = nil
        precondition(!CantripHomeDoneWhen.awaitsRecheck(older, now: finished), "a handoff checked before this build isn't re-checked")
        recent.doneWhenState = .met
        precondition(!CantripHomeDoneWhen.awaitsRecheck(recent, now: finished), "a met handoff isn't re-checked")
    }

    /// (4) The note, the waiting reason and each check's result are kept in handoff-log.json (still
    /// readable as `notMet` by older builds); `cantrip handoffs --json` shows the state, and the note
    /// only with --notes.
    @MainActor
    static func testDoneWhenNoteSavedInHandoffLog() async throws {
        let fixture = try DoneWhenFixture()
        defer { fixture.close() }
        fixture.verdicts = [.init(met: false, missing: "The 10 PM round hasn't run yet.", confidence: 0.9, waitingFor: .schedule)]
        let handoff = try fixture.handOff("Compare the rounds")
        try await fixture.finishTab("The sampler is scheduled.\n\nOutcome: waiting for the 10 PM round.")
        fixture.delegations.refresh()
        try await waitForJournalTest { fixture.current(handoff)?.doneWhenState == .notMet }
        let url = fixture.scratch.appendingPathComponent("handoff-log.json")
        let log = HandoffLog(url: url)
        let store = ChildTabStore(url: fixture.scratch.appendingPathComponent("child-tabs.json"))
        HandoffReport.sync(manager: fixture.manager, runs: [], childStore: store, log: log)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] ?? []
        let record = try requireRecheck(saved.first { $0["id"] as? String == handoff.id.uuidString })
        let history = record["doneWhenHistory"] as? [[String: Any]] ?? []
        precondition(record["doneWhen"] as? String == "notMet" && record["doneWhenWaiting"] as? String == "schedule"
                     && record["doneWhenNote"] as? String == "The 10 PM round hasn't run yet."
                     && history.first?["state"] as? String == "waitingSchedule"
                     && history.first?["note"] as? String == "The 10 PM round hasn't run yet.", "\(record)")
        precondition(HandoffLog(url: url).records[handoff.id]?.doneWhenNote == "The 10 PM round hasn't run yet.", "it reloads")
        func entry(notes: Bool) throws -> [String: Any] {
            let report = HandoffReport.snapshot(manager: fixture.manager, runs: [], childStore: store, log: log, notes: notes)
            return try requireRecheck((report["handoffs"] as? [[String: Any]])?.first { $0["id"] as? String == handoff.id.uuidString })
        }
        let plain = try entry(notes: false), withNotes = try entry(notes: true)
        precondition(plain["doneWhen"] as? String == "waitingSchedule" && plain["doneWhenNote"] is NSNull
                     && (plain["doneWhenHistory"] as? [[String: Any]])?.first?["note"] is NSNull, "no notes by default: \(plain)")
        precondition(withNotes["doneWhenNote"] as? String == "The 10 PM round hasn't run yet.", "\(withNotes)")
        let options = try CantripCLI.parseHandoffs(["--notes", "--json"])
        precondition(options.notes && options.json)
    }

    private static func requireRecheck<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }

    /// Home with one project tab whose replies the test writes, and a scripted checker.
    @MainActor
    final class DoneWhenFixture {
        let homeChat: ChatSession
        let tab: ChatSession
        let tabBackend = CantripHomeBackendFixture()
        let manager: SessionManager
        let delegations = CantripHomeDelegations.shared
        let scratch: URL
        var verdicts: [CantripHomeDoneWhen.Verdict] = []
        var asked: [CantripHomeDoneWhen.Input] = []
        private let savedCheck = CantripHomeDoneWhen.check
        private let savedSettings: (BackendKind, Bool, Bool)

        init() throws {
            let settings = AppSettings.shared
            savedSettings = (settings.backend, settings.memoryEnabled, settings.attachScreen)
            settings.backend = .copilot
            settings.memoryEnabled = false
            settings.attachScreen = false
            scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-done-when-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            homeChat = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture(),
                                   makeJournal: { _ in try RunJournal(sessionID: UUID()) })
            homeChat.messages = []
            tab = ChatSession(copilotBackend: tabBackend)
            try tab.updateTab(name: "Cantrip")
            manager = SessionManager(
                homeSession: homeChat,
                homeBackgroundSession: ChatSession(id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture(),
                                                   makeJournal: { _ in try RunJournal(sessionID: UUID()) })
            )
            manager.sessions = [tab]
            delegations.attach(manager: manager)
            CantripHomeDoneWhen.check = { [unowned self] input, _ in
                asked.append(input)
                guard !verdicts.isEmpty else { throw MessageRoutingError.unavailable("no verdict left") }
                return verdicts.removeFirst()
            }
        }

        func handOff(_ summary: String) throws -> CantripHomeDelegation {
            let prompt = try CantripHomeHandoffBrief(
                goal: summary, context: [], constraints: [],
                doneWhen: "The change is live and its proofs pass."
            ).composed(origin: .home(request: nil))
            let handoff = try delegations.dispatch(.init(tabID: tab.id, summary: summary, prompt: prompt))
            var reply = ChatMessage(role: .assistant, text: "Handing this to Cantrip.")
            reply.delegations = [handoff]
            homeChat.messages.append(ChatMessage(role: .user, text: summary))
            homeChat.messages.append(reply)
            return handoff
        }

        func finishTab(_ text: String, line: UInt = #line) async throws {
            try await waitForJournalTest(line: line) { self.tabBackend.sink != nil }
            let sink = tabBackend.sink
            tabBackend.sink = nil
            sink?(.textDelta(text))
            sink?(.done)
            try await waitForJournalTest(line: line) { !self.tab.isStreaming }
        }

        func current(_ handoff: CantripHomeDelegation) -> CantripHomeDelegation? {
            homeChat.messages.flatMap(\.delegations).first { $0.id == handoff.id }
        }

        func card(_ handoff: CantripHomeDelegation) throws -> CantripHomeHandoffResult {
            guard let card = homeChat.messages.compactMap(\.handoffResult).first(where: { $0.delegationID == handoff.id }) else {
                preconditionFailure("no card for \(handoff.summary)")
            }
            return card
        }

        func close() {
            CantripHomeDoneWhen.check = savedCheck
            (AppSettings.shared.backend, AppSettings.shared.memoryEnabled, AppSettings.shared.attachScreen) = savedSettings
            homeChat.cancel()
            tab.cancel()
            try? FileManager.default.removeItem(at: scratch)
        }
    }
}
