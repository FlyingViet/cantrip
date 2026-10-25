import Foundation

extension SessionTabTests {
    /// Done when: a finished handoff is checked against its finish line; work the tab can still do
    /// goes back to it (at most twice), the rest is reported on Home's card.
    @MainActor
    static func testCantripHomeDoneWhen() async throws {
        typealias Check = CantripHomeDoneWhen
        // The criteria Home's brief puts in the prompt.
        let prompt = try CantripHomeHandoffBrief(
            goal: "Fix the lineup sort", context: ["Headliners sort last today"], constraints: ["Don't change the API"],
            doneWhen: "Headliners sort first, the lineup tests pass, and the change is pushed."
        ).composed(origin: .home(request: nil))
        precondition(Check.criteria(in: prompt) == "Headliners sort first, the lineup tests pass, and the change is pushed.")
        precondition(Check.goal(in: prompt) == "Fix the lineup sort")
        precondition(Check.criteria(in: "(Handed off by Cantrip Home.)\n\nGoal: Fix it") == nil, "no Done when, no check")
        let input = try requireDoneWhen(Check.input(prompt: prompt, replies: ["a", "", "b", "c", "d"]))
        precondition(input.replies == ["b", "c", "d"] && input.goal == "Fix the lineup sort", "\(input)")
        precondition(Check.input(prompt: prompt, replies: ["  "]) == nil, "nothing to judge without a reply")

        // The verdict and what follows from it.
        let parsed = try Check.Verdict.parse(#"{"met":false,"missing":"Not pushed yet.","confidence":0.9}"#)
        precondition(parsed == .init(met: false, missing: "Not pushed yet.", needsUser: false, confidence: 0.9))
        do {
            _ = try Check.Verdict.parse(#"{"met":"maybe"}"#)
            preconditionFailure("an invalid verdict is rejected")
        } catch {}
        precondition(Check.outcome(of: .init(met: true), sendBacks: 0) == .met)
        precondition(Check.outcome(of: .init(met: false, missing: "Not pushed yet.", confidence: 0.9), sendBacks: 0)
                     == .sendBack("Not pushed yet."))
        precondition(Check.outcome(of: .init(met: false, missing: "Not pushed yet.", confidence: 0.9), sendBacks: 2)
                     == .notMet("Not pushed yet."), "two send-backs at most")
        precondition(Check.outcome(of: .init(met: false, missing: "Waiting for App Review.", needsUser: true), sendBacks: 0)
                     == .notMet("It needs you: Waiting for App Review."), "what needs the user is reported, not sent back")
        precondition(Check.outcome(of: .init(met: false, missing: "Unclear.", confidence: 0.3), sendBacks: 0)
                     == .unchecked("Not sure it's met: Unclear."))
        let back = Check.sendBack(missing: "Not pushed yet.", doneWhen: "It's pushed.", attempt: 1)
        precondition(back.hasPrefix(Check.sendBackPrefix) && back.contains("1 of 2") && back.contains("Done when: It's pushed."))
        precondition(Check.cardLine(state: .met, note: nil) == "Checked against Done when: met."
                     && Check.cardLine(state: .notMet, note: "Not pushed yet.") == "Done when not met. Not pushed yet."
                     && Check.cardLine(state: .checking, note: nil) == nil)

        // A real handoff: finished but not pushed → sent back; then pushed → done and confirmed.
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.attachScreen)
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        let savedCheck = Check.check
        defer {
            (settings.backend, settings.memoryEnabled, settings.attachScreen) = saved
            Check.check = savedCheck
        }
        var verdicts: [Check.Verdict] = [.init(met: false, missing: "The change isn't pushed yet.", confidence: 0.9),
                                         .init(met: true)]
        var asked: [Check.Input] = []
        Check.check = { input, _ in
            asked.append(input)
            return verdicts.removeFirst()
        }
        let homeChat = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture(),
                                   makeJournal: { _ in try RunJournal(sessionID: UUID()) })
        homeChat.messages = []
        let tabFixture = CantripHomeBackendFixture()
        let tab = ChatSession(copilotBackend: tabFixture)
        try tab.updateTab(name: "Bass Compass")
        let manager = SessionManager(
            homeSession: homeChat,
            homeBackgroundSession: ChatSession(
                id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture(),
                makeJournal: { _ in try RunJournal(sessionID: UUID()) }
            )
        )
        manager.sessions = [tab]
        let delegations = CantripHomeDelegations.shared
        delegations.attach(manager: manager)
        defer {
            homeChat.cancel()
            tab.cancel()
        }
        let handoff = try delegations.dispatch(.init(tabID: tab.id, summary: "Fix lineup sorting", prompt: prompt))
        var reply = ChatMessage(role: .assistant, text: "I'm handing this to Bass Compass.")
        reply.delegations = [handoff]
        homeChat.messages.append(ChatMessage(role: .user, text: "Fix the lineup sort"))
        homeChat.messages.append(reply)
        func finishTab(_ text: String, line: UInt = #line) async throws {
            try await waitForJournalTest(line: line) { tabFixture.sink != nil }
            let sink = tabFixture.sink
            tabFixture.sink = nil
            sink?(.textDelta(text))
            sink?(.done)
            try await waitForJournalTest(line: line) { !tab.isStreaming }
        }
        func current() -> CantripHomeDelegation? {
            homeChat.messages.flatMap(\.delegations).first { $0.id == handoff.id }
        }
        try await finishTab("Headliners now sort first and the lineup tests pass.\n\nOutcome: sorting fixed, tests pass.")
        delegations.refresh()
        try await waitForJournalTest { current()?.doneWhenSendBacks == 1 }
        precondition(asked.first?.doneWhen == Check.criteria(in: prompt)
                     && asked.first?.replies.last?.contains("lineup tests pass") == true, "\(asked)")
        precondition(current()?.isActive == true && homeChat.messages.allSatisfy { $0.handoffResult == nil },
                     "a handoff sent back has no card yet")
        try await waitForJournalTest { tab.messages.contains { $0.role == .user && $0.text.hasPrefix(Check.sendBackPrefix) } }
        precondition(tabFixture.lastPrompt?.contains("The change isn't pushed yet.") == true, tabFixture.lastPrompt ?? "")
        try await finishTab("Pushed a1b2c3d.\n\nOutcome: sorting fixed, tests pass, pushed a1b2c3d.")
        delegations.refresh()
        try await waitForJournalTest { current()?.status == .completed }
        let done = try requireDoneWhen(current())
        precondition(done.doneWhenState == .met && done.outcome == "Sorting fixed, tests pass, pushed a1b2c3d.", "\(done)")
        precondition(asked.count == 2 && asked[1].replies.last?.contains("Pushed a1b2c3d") == true,
                     "the second check reads the work after the send-back")
        let card = try requireDoneWhen(homeChat.messages.compactMap(\.handoffResult).first { $0.delegationID == handoff.id })
        precondition(card.state == .completed && card.doneWhenState == .met
                     && card.detail == "Sorting fixed, tests pass, pushed a1b2c3d.\n\nChecked against Done when: met."
                     && (card.snapshot["doneWhen"] as? [String: Any])?["state"] as? String == "met", "\(card)")

        // When the check can't run, the card says so instead of claiming it's done.
        verdicts = []
        Check.check = { _, _ in throw MessageRoutingError.unavailable("offline") }
        let second = try delegations.dispatch(.init(tabID: tab.id, summary: "Tidy the README", prompt: prompt))
        var secondReply = ChatMessage(role: .assistant, text: "Handing this over.")
        secondReply.delegations = [second]
        homeChat.messages.append(secondReply)
        try await finishTab("Tidied the README.")
        delegations.refresh()
        try await waitForJournalTest { homeChat.messages.flatMap(\.delegations).first { $0.id == second.id }?.status == .completed }
        let unchecked = try requireDoneWhen(homeChat.messages.compactMap(\.handoffResult).first { $0.delegationID == second.id })
        precondition(unchecked.doneWhenState == .unchecked && unchecked.detail.hasPrefix("Done when not confirmed."),
                     unchecked.detail)
        print("Cantrip Home Done when checks passed")
    }

    private static func requireDoneWhen<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }
}
