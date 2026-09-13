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

private func text(from events: [BackendEvent]) -> String {
    events.compactMap { event in
        guard case .textDelta(let delta) = event else { return nil }
        return delta
    }.joined()
}

private func testMalformedLineDoesNotAbortBatch() {
    var parser = CopilotJSONStreamParser()
    var errors: [CopilotJSONStreamParserError] = []
    let stream = """
    {"type":"assistant.message_delta","id":"event-1","data":{"messageId":"message-1","deltaContent":"Hello"}}
    {not valid json}
    {"type":"assistant.message_delta","id":"event-2","data":{"messageId":"message-1","deltaContent":" world"}}

    """

    let events = parser.consume(Data(stream.utf8)) { error, _ in
        errors.append(error)
    }

    expect(text(from: events) == "Hello world", "valid events after a malformed line should be parsed")
    expect(parser.answer == "Hello world", "the accumulated answer should include later valid events")
    expect(errors.count == 1, "the malformed line should be reported exactly once")
}

private func testMalformedEventDoesNotPoisonLaterChunks() {
    var parser = CopilotJSONStreamParser()
    var errorCount = 0

    let malformed = Data("{\"data\":{}}\n".utf8)
    let firstEvents = parser.consume(malformed) { _, _ in errorCount += 1 }
    let valid = Data("""
    {"type":"assistant.message_delta","id":"event-3","data":{"messageId":"message-2","deltaContent":"Recovered"}}

    """.utf8)
    let laterEvents = parser.consume(valid) { _, _ in errorCount += 1 }

    expect(firstEvents.isEmpty, "a malformed event should not emit backend events")
    expect(text(from: laterEvents) == "Recovered", "a later chunk should still be parsed")
    expect(errorCount == 1, "only the malformed event should be reported")
}

private func testMalformedFinalLineIsReportedAndSkipped() {
    var parser = CopilotJSONStreamParser()
    var errorCount = 0

    _ = parser.consume(Data("{\"type\":".utf8)) { _, _ in errorCount += 1 }
    let events = parser.finish { _, _ in errorCount += 1 }

    expect(events.isEmpty, "an incomplete final line should not emit backend events")
    expect(errorCount == 1, "an incomplete final line should be reported")
}

private func testSDKMessagesAndUsage() {
    var parser = CopilotJSONStreamParser()
    let events = parser.consume(Data("""
    {"type":"assistant.message_delta","id":"d1","data":{"messageId":"m1","deltaContent":"Streamed"}}
    {"type":"assistant.message","id":"a1","data":{"messageId":"m1","content":"Streamed"}}
    {"type":"assistant.message","id":"a2","data":{"messageId":"m2","content":"Aggregate only"}}
    {"type":"assistant.message","id":"subagent","agentId":"child","data":{"messageId":"m3","content":"Hidden"}}
    {"type":"assistant.usage","id":"u1","data":{"inputTokens":100,"outputTokens":20,"cost":6.5}}

    """.utf8)) { _, _ in expect(false, "SDK messages should parse") }
    expect(text(from: events) == "Streamed\n\nAggregate only", "SDK aggregates must not duplicate streamed content")
    let usages = events.compactMap { if case .usage(let usage) = $0 { return usage }; return nil }
    expect(usages.count == 1 && usages[0].inputTokens == 100 && usages[0].outputTokens == 20,
           "SDK token usage should reach the journal")
    expect(usages.first?.costUSD == 0, "Copilot model multipliers are not dollar costs")
}

testMalformedLineDoesNotAbortBatch()
testMalformedEventDoesNotPoisonLaterChunks()
testMalformedFinalLineIsReportedAndSkipped()
testSDKMessagesAndUsage()

if failures > 0 {
    fputs("\(failures) Copilot parser test(s) failed\n", stderr)
    exit(1)
}
print("All 4 Copilot parser tests passed")
