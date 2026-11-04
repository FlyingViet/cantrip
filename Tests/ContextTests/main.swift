import Foundation

private var failures = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func testAlwaysKeepsThreeMostRecentTurns() {
    let turns = (1...6).map {
        ConversationTurn(user: "Question \($0)", assistant: "Answer \($0)")
    }
    let selection = ConversationContextBuilder.select(
        for: "A completely new topic",
        from: turns
    )
    expect(
        selection.recentTurns.map(\.user) == [
            "Question 4", "Question 5", "Question 6",
        ],
        "selector should keep exactly the three most recent turns"
    )
}

private func testRetrievesRelatedOlderTurnWithoutFullHistory() {
    let related = ConversationTurn(
        user: "How should Swift concurrency actor isolation work?",
        assistant: "Keep mutable state isolated to the actor."
    )
    let turns = [
        related,
        ConversationTurn(user: "Best tomato soup?", assistant: "Roast the tomatoes."),
        ConversationTurn(user: "Weather tomorrow?", assistant: "It should be sunny."),
        ConversationTurn(user: "Who won the game?", assistant: "The home team."),
        ConversationTurn(user: "Convert ten miles.", assistant: "About sixteen kilometers."),
    ]
    let selection = ConversationContextBuilder.select(
        for: "Revisit the Swift actor isolation design",
        from: turns
    )
    expect(
        selection.relatedTurns.contains(related),
        "selector should retrieve a related older turn"
    )
    expect(
        selection.fullHistoryTurns == nil,
        "normal queries should not load full history"
    )
    expect(
        selection.relatedTurns.count <= ConversationContextBuilder.relatedTurnCount,
        "selector should cap related older turns"
    )
}

private func testAugmentedCurrentPromptAppearsOnlyOnce() {
    let marker = "CURRENT_MEMORY_MARKER"
    let prompt = ConversationContextBuilder.composePrompt(
        currentPrompt: "New question\n\(marker)",
        query: "New question",
        turns: [
            ConversationTurn(user: "Earlier raw question", assistant: "Earlier answer"),
        ]
    )
    expect(
        prompt.components(separatedBy: marker).count - 1 == 1,
        "current augmented prompt should appear only once"
    )
    expect(
        prompt.contains("Earlier raw question"),
        "raw recent context should be preserved"
    )
}

private func testSelectedContextIsBounded() {
    let hugeAnswer = "ANSWER_START " + String(repeating: "x", count: 50_000) + " ANSWER_END"
    let turns = (1...12).map {
        ConversationTurn(
            user: "Conversation context topic \($0)",
            assistant: hugeAnswer
        )
    }
    let prompt = ConversationContextBuilder.composePrompt(
        currentPrompt: "Continue the conversation context topic",
        query: "Continue the conversation context topic",
        turns: turns
    )
    let recentBudget = 3 * 2 * ConversationContextBuilder.recentTurnLimit
    expect(prompt.count < recentBudget + 6_000, "selected context should stay within the recent-turn budget")
    expect(prompt.contains("...[clipped]"), "oversized turns should be visibly clipped")
    let recent = prompt.components(separatedBy: "Most recent turns:").last ?? ""
    expect(recent.components(separatedBy: "ANSWER_END").count - 1 == 3,
           "a huge recent turn keeps its conclusion")
}

private func testRecentTurnsAreSentWhole() {
    let longAnswer = (1...200).map { "Detail line \($0) of the earlier answer." }.joined(separator: "\n")
    let longQuestion = String(repeating: "Here is the pasted error output. ", count: 60)
    let turns = [
        ConversationTurn(user: "Older topic", assistant: String(repeating: "older ", count: 400)),
        ConversationTurn(user: "Second topic", assistant: "Second answer"),
        ConversationTurn(user: "Third topic", assistant: "Third answer"),
        ConversationTurn(user: longQuestion, assistant: longAnswer),
    ]
    let prompt = ConversationContextBuilder.composePrompt(
        currentPrompt: "Follow up", query: "Follow up", turns: turns
    )
    let recent = prompt.components(separatedBy: "Most recent turns:").last ?? ""
    expect(recent.contains(longAnswer), "a recent assistant reply is sent whole")
    expect(recent.contains(longQuestion), "a recent user message is sent whole")
    expect(!recent.contains("[clipped]"), "recent turns under the limit are never clipped")
    let messages = ConversationContextBuilder.chatMessages(for: "Follow up", turns: turns)
    expect(messages.contains { $0.content.contains("[clipped]") },
           "small-window chat backends keep the short recent-turn clips")
}

private func testExplicitRequestLoadsEveryTurn() {
    let turns = (1...6).map {
        ConversationTurn(user: "Question \($0)", assistant: "Answer \($0)")
    }
    let selection = ConversationContextBuilder.select(
        for: "Review the entire conversation",
        from: turns
    )
    expect(
        selection.fullHistoryTurns == turns,
        "explicit full-history request should include every turn"
    )
    expect(selection.recentTurns.isEmpty, "full-history mode should replace recent mode")
    expect(selection.relatedTurns.isEmpty, "full-history mode should replace retrieval mode")
}

testAlwaysKeepsThreeMostRecentTurns()
testRetrievesRelatedOlderTurnWithoutFullHistory()
testAugmentedCurrentPromptAppearsOnlyOnce()
testSelectedContextIsBounded()
testRecentTurnsAreSentWhole()
testExplicitRequestLoadsEveryTurn()

let pasted = String(repeating: "swift actor swift network ", count: 40_000)
expect(ConversationContextBuilder.terms(from: pasted) == ["swift", "actor", "network"],
       "large pasted queries should deduplicate retrieval terms")
let manyTerms = (0..<500).map { "term\($0)" }.joined(separator: " ")
expect(ConversationContextBuilder.terms(from: manyTerms).count == ConversationContextBuilder.retrievalTermLimit,
       "retrieval must have a fixed term budget")
expect(ConversationContextBuilder.composePrompt(currentPrompt: pasted, query: pasted, turns: []).hasSuffix(pasted),
       "retrieval budgets must never truncate the actual prompt")

if failures > 0 {
    fputs("\(failures) context test(s) failed\n", stderr)
    exit(1)
}
print("Context selection and long-prompt retrieval budgets passed")
