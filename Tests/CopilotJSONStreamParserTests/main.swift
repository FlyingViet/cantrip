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

private func lastActivity(_ events: [BackendEvent], id: String) -> ToolActivity? {
    events.compactMap { event -> ToolActivity? in
        guard case .activity(let activity) = event, activity.id == id else { return nil }
        return activity
    }.last
}

private func testSubagentStepsNestUnderTask() {
    var parser = CopilotJSONStreamParser()
    // Shapes captured from Copilot CLI 1.0.88 with an explore subagent.
    let events = parser.consume(Data("""
    {"type":"assistant.message","id":"r1","data":{"messageId":"m1","content":"","toolRequests":[{"toolCallId":"task-1","name":"task","arguments":{"description":"Count txt files","agent_type":"explore"}}]}}
    {"type":"tool.execution_start","id":"r2","data":{"toolCallId":"task-1","toolName":"task"}}
    {"type":"subagent.started","id":"s1","agentId":"agent-1","data":{"toolCallId":"task-1","agentName":"explore","agentDisplayName":"Explore","agentDescription":"","model":"gpt-5.6-luna"}}
    {"type":"assistant.usage","id":"s2","agentId":"agent-1","data":{"parentToolCallId":"task-1","inputTokens":7000,"outputTokens":300}}
    {"type":"assistant.message","id":"s3","agentId":"agent-1","data":{"messageId":"c1","content":"Looking","parentToolCallId":"task-1","toolRequests":[{"toolCallId":"glob-1","name":"glob","arguments":{"pattern":"**/*.txt"}}]}}
    {"type":"tool.execution_start","id":"s4","agentId":"agent-1","data":{"toolCallId":"glob-1","toolName":"glob","parentToolCallId":"task-1"}}
    {"type":"tool.execution_complete","id":"s5","agentId":"agent-1","data":{"toolCallId":"glob-1","success":true,"result":{"content":"3 files"}}}
    {"type":"session.idle","id":"s6","agentId":"agent-1","data":{}}
    {"type":"subagent.completed","id":"s7","agentId":"agent-1","data":{"toolCallId":"task-1","agentName":"explore","agentDisplayName":"Explore","model":"gpt-5.6-luna","totalTokens":8367,"totalToolCalls":1}}
    {"type":"tool.execution_complete","id":"r3","data":{"toolCallId":"task-1","success":true,"result":{"content":"3"}}}
    {"type":"assistant.message","id":"r4","data":{"messageId":"m2","content":"3"}}

    """.utf8)) { _, _ in expect(false, "subagent events should parse") }

    let topLevel = Set(events.compactMap { event -> String? in
        guard case .activity(let activity) = event else { return nil }
        return activity.id
    })
    expect(topLevel == ["task-1"], "subagent steps must not appear as top-level activities")
    let task = lastActivity(events, id: "task-1")
    expect(task?.state == .succeeded, "the task activity should complete")
    expect(task?.children.map(\.id) == ["glob-1"], "the subagent's tool call should be nested once")
    expect(task?.children.first?.state == .succeeded, "the nested step should complete")
    expect(task?.title == "Count txt files · gpt-5.6-luna · 8.4k tokens",
           "the task title should report the subagent's model and token use")
    expect(text(from: events) == "3", "subagent text must stay out of the answer")
    let usage = events.compactMap { event -> Int? in
        guard case .usage(let usage) = event else { return nil }
        return usage.inputTokens
    }
    expect(usage == [7000], "subagent token usage should still be counted")
}

private func testBackgroundSubagentKeepsReporting() {
    var parser = CopilotJSONStreamParser()
    let events = parser.consume(Data("""
    {"type":"tool.execution_start","id":"b1","data":{"toolCallId":"task-2","toolName":"task","arguments":{"description":"Run tests"}}}
    {"type":"subagent.started","id":"b2","agentId":"agent-2","data":{"toolCallId":"task-2","agentName":"task","agentDisplayName":"Task","agentDescription":"","executionMode":"background"}}
    {"type":"tool.execution_complete","id":"b3","data":{"toolCallId":"task-2","success":true,"result":{"content":"Agent started"}}}
    {"type":"tool.execution_start","id":"b4","agentId":"agent-2","data":{"toolCallId":"bash-1","toolName":"bash","arguments":{"command":"make test"}}}
    {"type":"tool.execution_complete","id":"b5","agentId":"agent-2","data":{"toolCallId":"bash-1","success":false,"result":{"content":"1 failure"}}}
    {"type":"subagent.completed","id":"b6","agentId":"agent-2","data":{"toolCallId":"task-2","agentName":"task","agentDisplayName":"Task","model":"claude-haiku-4.5","totalTokens":950}}

    """.utf8)) { _, _ in expect(false, "background subagent events should parse") }
    let task = lastActivity(events, id: "task-2")
    expect(lastActivity(events, id: "bash-1") == nil, "background steps should nest under their task")
    expect(task?.children.first?.state == .failed, "a background step's outcome should be kept")
    expect(task?.title == "Run tests · claude-haiku-4.5 · 950 tokens", "late completion metrics should be shown")
}

private func testUnknownSubagentFallsBackToTopLevel() {
    var parser = CopilotJSONStreamParser()
    let events = parser.consume(Data("""
    {"type":"tool.execution_start","id":"u1","agentId":"unknown","data":{"toolCallId":"view-1","toolName":"view"}}

    """.utf8)) { _, _ in expect(false, "orphan events should parse") }
    expect(lastActivity(events, id: "view-1") != nil, "steps without a tracked task should still be visible")
    expect(CopilotJSONStreamParser.tokenLabel(1_250_000) == "1.2M tokens", "large token counts should be compact")
}

testMalformedLineDoesNotAbortBatch()
testMalformedEventDoesNotPoisonLaterChunks()
testMalformedFinalLineIsReportedAndSkipped()
testSDKMessagesAndUsage()
testSubagentStepsNestUnderTask()
testBackgroundSubagentKeepsReporting()
testUnknownSubagentFallsBackToTopLevel()
failures += runMCPAppTests()

if failures > 0 {
    fputs("\(failures) Copilot parser test(s) failed\n", stderr)
    exit(1)
}
print("All 8 Copilot parser test groups passed (incl. MCP Apps)")
