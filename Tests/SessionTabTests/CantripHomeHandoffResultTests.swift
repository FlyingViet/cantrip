import Foundation

extension SessionTabTests {
    /// Result cards Home posts when a handed-off tab finishes, fails, stops or needs the user.
    @MainActor
    static func testCantripHomeHandoffResults() async throws {
        // A tab's outcome, shortened to plain text.
        let labelled = """
        I'll start with the notes, then read the code.

        Fixed it and ran the tests:

        ```
        make test
        ```

        **Outcome:** shipped `a1b2c3d` to [TestFlight](https://example.com) as 1.0 (100132).
        """
        precondition(CantripHomeDelegations.briefOutcome(labelled)
                     == "Shipped a1b2c3d to TestFlight as 1.0 (100132).",
                     "A labelled outcome is the summary, without Markdown")
        precondition(CantripHomeDelegations.briefOutcome("Done.\n\nOutcome: headliners sort first.")
                     == "Headliners sort first.")
        precondition(CantripHomeDelegations.briefOutcome("Checked everything.\n\nDone.")
                     == "Checked everything. Done.",
                     "A bare closing line keeps the paragraph before it")
        precondition(CantripHomeDelegations.briefOutcome("## Result\n\n- Added stage filters\n- Tests pass")
                     == "Added stage filters Tests pass",
                     "Lists flatten into one line")
        let long = String(repeating: "The watchdog recovered a stalled chapter. ", count: 20)
        let shortened = CantripHomeDelegations.briefOutcome(long)
        precondition(shortened.count <= CantripHomeDelegations.briefLimit && shortened.hasSuffix("chapter."),
                     "Long outcomes end at a sentence: \(shortened)")
        precondition(CantripHomeDelegations.shortened(String(repeating: "word ", count: 100), limit: 40)
                     .hasSuffix("word…"))

        // A reply that ends by asking the user something.
        let netLibQuestion = """
        Copilot needs your answer

        I checked Suwayomi and Komga: there's only one **Pick Up a Grimoire**. Is that where you saw the duplicate?
        """
        precondition(CantripHomeDelegations.trailingQuestion(netLibQuestion)
                     == "I checked Suwayomi and Komga: there's only one Pick Up a Grimoire. Is that where you saw the duplicate?")
        precondition(CantripHomeDelegations.trailingQuestion("Shipped. Tests pass.") == nil
                     && CantripHomeDelegations.trailingQuestion("Run this:\n\n```\ncurl 'x?'\n```") == nil
                     && CantripHomeDelegations.trailingQuestion("Should I also ship it? (Recommended)") == nil
                     && CantripHomeDelegations.trailingQuestion("Want me to ship it (to TestFlight)?") != nil,
                     "Only a closing question counts")

        // Run boundaries: answers and resumes continue a handoff; new work ends it.
        let tab = ChatSession(copilotBackend: CantripHomeBackendFixture())
        try tab.updateTab(name: "NetLib")
        let prompt = "(Handed off by Cantrip Home. This tab can't see the Home conversation.)\n\nFix duplicates."
        let created = Date().addingTimeInterval(-60)
        func message(_ role: ChatMessage.Role, _ text: String, _ run: UUID?) -> ChatMessage {
            var message = ChatMessage(role: role, text: text)
            message.runID = run
            return message
        }
        func evaluated(_ messages: [ChatMessage]) -> CantripHomeDelegation {
            tab.messages = messages
            return CantripHomeDelegations.evaluate(
                CantripHomeDelegation(tabID: tab.id, tabTitle: "NetLib", summary: "Fix duplicates",
                                      prompt: prompt, createdAt: created, status: .running),
                target: tab
            )
        }
        let runA = UUID(), runB = UUID(), runC = UUID()
        let answered = evaluated([
            message(.user, prompt, runA),
            message(.assistant, "Checking the servers.", runA),
            message(.assistant, netLibQuestion, runA),
            message(.user, "The Home tab, but why is it missing chapters", runA),
            message(.assistant, "Chapter 1 was stranded.\n\nOutcome: one copy with chapters 1-3.", runA),
        ])
        precondition(answered.status == .completed
                     && answered.outcome == "One copy with chapters 1-3."
                     && answered.result?.contains("Chapter 1 was stranded") == true,
                     "Answering the tab's question in chat continues the same handoff: \(answered)")
        let pickedInChat = evaluated([
            message(.user, prompt, runA),
            message(.assistant, "Copilot needs your answer\n\nPick the branch to ship from: master or release.", runA),
            message(.user, "release", runA),
            message(.assistant, "Shipped from release.", runA),
        ])
        precondition(pickedInChat.status == .completed && pickedInChat.outcome == "Shipped from release.",
                     "An input request answered in chat stays in the same run: \(pickedInChat)")
        let asking = evaluated([
            message(.user, prompt, runA),
            message(.assistant, "Which screen showed it twice?", runA),
        ])
        precondition(asking.status == .running && asking.needsInput == true
                     && asking.question == "Which screen showed it twice?"
                     && asking.latestStatus == "Needs your answer" && asking.finishedAt == nil,
                     "A reply ending in a question waits for the user: \(asking)")
        let replied = evaluated([
            message(.user, prompt, runA),
            message(.assistant, "Which screen showed it twice?", runA),
            message(.user, "Recently Added", runB),
            message(.assistant, "Merged the two rows.", runB),
        ])
        precondition(replied.status == .completed && replied.outcome == "Merged the two rows.",
                     "The user's reply carries the handoff into the next run: \(replied)")
        let resumed = evaluated([
            message(.user, prompt, runA),
            message(.assistant, "Halfway through.", runA),
            message(.user, ChatSession.resumePrompt, runC),
            message(.assistant, "Finished the migration.", runC),
        ])
        precondition(resumed.status == .completed && resumed.outcome == "Finished the migration.",
                     "An automatic resume continues the handoff")
        let failedAfterText = evaluated([
            message(.user, prompt, runA),
            message(.assistant, "Building the player target.", runA),
            message(.error, "xcodebuild failed: no signing certificate.", runA),
            message(.user, ChatSession.resumePrompt, runC),
            message(.assistant, "Building the player target.", runC),
            message(.error, "xcodebuild failed: no signing certificate.", runC),
        ])
        precondition(failedAfterText.status == .failed
                     && failedAfterText.error == "xcodebuild failed: no signing certificate.",
                     "A run that ends on an error failed, even after some reply text: \(failedAfterText)")
        let superseded = evaluated([
            message(.user, prompt, runA),
            message(.assistant, "Which screen showed it twice?", runA),
            message(.user, "(Handed off by Cantrip Home. Another job.)", runB),
        ])
        precondition(superseded.status == .completed && superseded.needsInput == nil,
                     "A new handoff is not an answer")
        let legacy = evaluated([
            message(.user, prompt, nil),
            message(.assistant, "Done the old way.", nil),
            message(.user, "Next request", nil),
        ])
        precondition(legacy.status == .completed && legacy.outcome == "Done the old way.",
                     "Messages without run IDs end at the next request")

        // Background-run handoffs never wait: their unattended runs must finish and release.
        tab.messages = [message(.user, prompt, runA), message(.assistant, "Fixed it. Want me to redeploy?", runA)]
        let unattended = CantripHomeDelegations.evaluate(
            CantripHomeDelegation(tabID: tab.id, tabTitle: "NetLib", summary: "Fix", prompt: prompt,
                                  createdAt: created, status: .running),
            target: tab, waitsForAnswer: false
        )
        precondition(unattended.status == .completed && unattended.needsInput == nil,
                     "Background handoffs finish even when the tab ends with a question")
        let closedWhileAsking = CantripHomeDelegations.evaluate(asking, target: nil)
        precondition(closedWhileAsking.status == .cancelled
                     && closedWhileAsking.error == "The tab was closed before you answered it.")
        // Cantrip quit mid-run: the tab offers Resume, and the handoff waits for it.
        tab.canResume = true
        let quitMidRun = evaluated([
            message(.user, prompt, runA),
            message(.assistant, "Halfway through.", runA),
            message(.error, "Run interrupted when Cantrip exited.", runA),
        ])
        tab.canResume = false
        precondition(quitMidRun.status == .running && quitMidRun.needsInput == true
                     && quitMidRun.question?.contains("resume it") == true,
                     "A run Cantrip's exit interrupted needs the user's Resume: \(quitMidRun)")

        // A live interruption auto-resumes after a short delay; the handoff keeps waiting for it,
        // follows the resumed run, and fails only if that run fails too.
        let flaky = CantripHomeBackendFixture()
        let flakyTab = ChatSession(copilotBackend: flaky)
        defer { flakyTab.cancel() }
        try flakyTab.updateTab(name: "Plexible")
        let flakyPrompt = "(Handed off by Cantrip Home.)\n\nFix the scrubber."
        flakyTab.submitRemote(flakyPrompt)
        try await waitForJournalTest { flaky.sink != nil && flakyTab.isStreaming }
        var live = CantripHomeDelegation(tabID: flakyTab.id, tabTitle: "Plexible", summary: "Fix the scrubber",
                                         prompt: flakyPrompt, createdAt: created, status: .running)
        flaky.sink?(.textDelta("Building the player target."))
        try await waitForJournalTest { flakyTab.messages.last?.text == "Building the player target." }
        let firstRun = flaky.sink
        flaky.sink = nil
        firstRun?(.failure("Copilot runtime lost"))
        try await waitForJournalTest { !flakyTab.isStreaming }
        live = CantripHomeDelegations.evaluate(live, target: flakyTab)
        precondition(flakyTab.autoResumePending && live.status == .running && live.needsInput == nil
                     && live.latestStatus == "Resuming after an interruption…",
                     "An interruption about to auto-resume is not a failure: \(live)")
        try await waitForJournalTest { flaky.sink != nil && flakyTab.isStreaming }
        live = CantripHomeDelegations.evaluate(live, target: flakyTab)
        precondition(live.status == .running && !flakyTab.autoResumePending,
                     "The handoff follows the resumed run")
        flaky.sink?(.textDelta("Still failing."))
        try await waitForJournalTest { flakyTab.messages.last?.text == "Still failing." }
        flaky.sink?(.failure("xcodebuild failed: no signing certificate."))
        try await waitForJournalTest { !flakyTab.isStreaming }
        live = CantripHomeDelegations.evaluate(live, target: flakyTab)
        precondition(live.status == .failed && live.error == "xcodebuild failed: no signing certificate.",
                     "A resumed run that fails again fails the handoff: \(live)")

        // Posting: one card per handoff, updated in place.
        let home = ChatSession(copilotBackend: CantripHomeBackendFixture())
        home.messages = [message(.user, "Fix NetLib duplicates", nil),
                         message(.assistant, "NetLib is taking this.", nil)]
        var handoff = asking
        precondition(CantripHomeDelegations.noteResult(handoff, in: home)
                     && home.messages.count == 3 && home.messages[2].role == .handoff,
                     "A handoff that needs the user posts a card at the end")
        let card = try requireHome(home.messages[2].handoffResult)
        precondition(card.state == .needsInput && card.detail == "Which screen showed it twice?"
                     && card.delegationID == handoff.id && card.tabTitle == "NetLib"
                     && home.messages[2].text.hasPrefix("**NetLib needs your answer** · Fix duplicates"))
        precondition(!CantripHomeDelegations.noteResult(handoff, in: home) && home.messages.count == 3,
                     "Re-noting an unchanged handoff never posts twice")
        handoff.status = .running
        handoff.needsInput = nil
        handoff.question = nil
        precondition(CantripHomeDelegations.noteResult(handoff, in: home)
                     && home.messages.count == 3 && home.messages[2].handoffResult?.state == .working,
                     "An answered question turns the same card back to working")
        let askingID = handoff.id
        handoff = replied
        handoff.id = askingID
        precondition(CantripHomeDelegations.noteResult(handoff, in: home)
                     && home.messages.count == 3
                     && home.messages[2].handoffResult?.state == .completed
                     && home.messages[2].handoffResult?.detail == "Merged the two rows."
                     && home.messages[2].handoffResult?.finishedAt != nil,
                     "Finishing updates the card in place")
        var working = asking
        working.id = UUID()
        working.needsInput = nil
        working.question = nil
        precondition(!CantripHomeDelegations.noteResult(working, in: home) && home.messages.count == 3,
                     "Working handoffs have no card yet")
        var failed = working
        failed.status = .failed
        failed.error = "```cantrip-delegate\n{}\n``` exploded"
        failed.finishedAt = Date()
        precondition(CantripHomeDelegations.noteResult(failed, in: home)
                     && home.messages.last?.handoffResult?.state == .failed
                     && home.messages.last?.text.hasPrefix("**Failed in NetLib**") == true)

        // While Home is replying, a card goes above the request so the reply stays last.
        let backend = CantripHomeBackendFixture()
        let busyHome = ChatSession(copilotBackend: backend)
        defer { busyHome.cancel() }
        busyHome.submitRemote("Plan my week")
        try await waitForJournalTest { backend.sink != nil && busyHome.isStreaming }
        backend.sink?(.textDelta("Here is "))
        try await waitForJournalTest { busyHome.messages.last?.text == "Here is " }
        var stopped = failed
        stopped.id = UUID()
        stopped.status = .cancelled
        stopped.error = "Stopped in the tab."
        precondition(CantripHomeDelegations.noteResult(stopped, in: busyHome))
        let roles = busyHome.messages.map(\.role)
        precondition(roles.suffix(3) == [.handoff, .user, .assistant]
                     && busyHome.messages.last?.text == "Here is ",
                     "A card posted mid-reply must not take over the streaming reply: \(roles)")
        backend.sink?(.textDelta("your plan."))
        backend.sink?(.done)
        try await waitForJournalTest { !busyHome.isStreaming }
        precondition(busyHome.messages.last?.text == "Here is your plan."
                     && busyHome.messages.last?.role == .assistant,
                     "The reply finishes where it started")
        // Queued messages combined into one turn stay together: the card goes above all of them.
        let combinedHome = ChatSession(copilotBackend: CantripHomeBackendFixture())
        defer { combinedHome.isStreaming = false; combinedHome.cancel() }
        let combinedRun = UUID()
        var firstAsk = ChatMessage(role: .user, text: "Make the save button blue")
        var secondAsk = ChatMessage(role: .user, text: "Also make it bigger")
        var combinedReply = ChatMessage(role: .assistant, text: "Working")
        firstAsk.runID = combinedRun
        secondAsk.runID = combinedRun
        combinedReply.runID = combinedRun
        combinedHome.messages = [firstAsk, secondAsk, combinedReply]
        combinedHome.isStreaming = true
        var another = stopped
        another.id = UUID()
        precondition(CantripHomeDelegations.noteResult(another, in: combinedHome))
        precondition(combinedHome.messages.map(\.role) == [.handoff, .user, .user, .assistant],
                     "A card never splits a combined turn: \(combinedHome.messages.map(\.role))")
        combinedHome.messages.swapAt(0, 1)
        precondition(combinedHome.turnUserText(endingAt: 2) == "Make the save button blue\n\nAlso make it bigger",
                     "A combined turn's words include every message, even with a legacy card between them")
        // Even a card sitting between a request and its reply stays out of the model's history.
        let lateCard = try requireHome(busyHome.messages.first { $0.role == .handoff })
        busyHome.messages.removeAll { $0.role == .handoff }
        busyHome.messages.insert(lateCard, at: busyHome.messages.count - 1)
        backend.sink = nil
        busyHome.submitRemote("And next week?")
        try await waitForJournalTest { backend.sink != nil && busyHome.isStreaming }
        precondition(backend.lastTurns.map(\.user) == ["Plan my week"]
                     && backend.lastTurns.map(\.assistant) == ["Here is your plan."],
                     "Result cards never become part of Home's model history: \(backend.lastTurns)")
        backend.sink?(.done)
        try await waitForJournalTest { !busyHome.isStreaming }

        // Transcript and remote shape.
        let encoded = try JSONEncoder().encode(home.messages)
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: encoded)
        precondition(decoded == home.messages, "Result cards persist with the transcript")
        let stored = try requireHome(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        precondition(stored.map { $0["role"] as? String }.allSatisfy { ["user", "assistant", "error"].contains($0) }
                     && stored.contains { $0["handoffResult"] != nil && $0["role"] as? String == "assistant" },
                     "Cards are saved with roles older builds decode, so a rollback keeps Home's history")
        let remote = RemoteHistory.message(home.messages[2])
        let remoteCard = try requireHome(remote["handoffResult"] as? [String: Any])
        precondition(remote["role"] as? String == "handoff"
                     && remoteCard["state"] as? String == "completed"
                     && remoteCard["tabID"] as? String == tab.id.uuidString
                     && remoteCard["delegationID"] as? String == handoff.id.uuidString
                     && remoteCard["detail"] as? String == "Merged the two rows."
                     && remoteCard["finishedAt"] as? Double != nil)
    }
}
