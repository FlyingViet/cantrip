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
    let hugeAnswer = String(repeating: "x", count: 50_000)
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
    expect(prompt.count < 10_000, "selected context should remain under 10,000 characters")
    expect(prompt.contains("...[clipped]"), "oversized turns should be visibly clipped")
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
testExplicitRequestLoadsEveryTurn()

if failures > 0 {
    fputs("\(failures) context test(s) failed\n", stderr)
    exit(1)
}
print("All 5 context tests passed")
