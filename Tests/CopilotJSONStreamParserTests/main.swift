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
    expect(task?.title == "Count txt files", "subagent metrics belong to the monitor, not the title")
    let info = task?.subagent
    expect(info?.agentID == "agent-1" && info?.name == "Explore" && info?.agentType == "explore",
           "the task should carry the subagent's identity")
    expect(info?.status == .completed && info?.finishedAt != nil, "the subagent should finish")
    expect(info?.model == "gpt-5.6-luna" && info?.tokens == 8367 && info?.toolCalls == 1,
           "completion totals should replace the live estimate")
    expect(info?.latestMessage == "Looking", "the subagent's latest text should be kept for the monitor")
    expect(info?.canCancel == false, "a finished subagent can't be stopped")
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
    expect(task?.title == "Run tests", "late completion metrics should not rename the task")
    expect(task?.subagent?.background == true && task?.subagent?.status == .completed
           && task?.subagent?.model == "claude-haiku-4.5" && task?.subagent?.tokens == 950,
           "late completion metrics should reach the monitor")
}

private func testSubagentLiveProgress() {
    var parser = CopilotJSONStreamParser(canCancelSubagents: true)
    // Shapes captured from Copilot CLI 1.0.88 (background general-purpose agent).
    var events = parser.consume(Data("""
    {"type":"tool.execution_start","id":"p1","data":{"toolCallId":"task-3","toolName":"task","arguments":{"description":"Slow counter","agent_type":"general-purpose","name":"slow-counter","mode":"background"}}}
    {"type":"tool.execution_complete","id":"p2","data":{"toolCallId":"task-3","success":true,"result":{"content":"Agent started"}}}
    {"type":"subagent.started","id":"p3","timestamp":"2026-09-27T09:27:34.000Z","agentId":"agent-3","data":{"toolCallId":"task-3","agentName":"general-purpose","agentDisplayName":"slow-counter","agentDescription":"Slow counter","model":"gpt-5-mini","agentType":"general-purpose","executionMode":"background"}}
    {"type":"subagent.configured","id":"p4","agentId":"agent-3","data":{"model":"gpt-5-mini","reasoningEffort":"high","multiTurn":true}}
    {"type":"assistant.usage","id":"p5","agentId":"agent-3","data":{"inputTokens":4401,"outputTokens":67}}
    {"type":"assistant.intent","id":"p6","agentId":"agent-3","data":{"intent":"Waiting on sleep"}}
    {"type":"assistant.message","id":"p7","agentId":"agent-3","data":{"content":"","parentToolCallId":"task-3","toolRequests":[{"toolCallId":"bash-3","name":"bash","arguments":{"command":"sleep 60","description":"Sleep for 60 seconds"}}]}}
    {"type":"tool.execution_start","id":"p8","agentId":"agent-3","data":{"toolCallId":"bash-3","toolName":"bash","parentToolCallId":"task-3"}}
    {"type":"assistant.usage","id":"p9","agentId":"agent-3","data":{"inputTokens":4494,"outputTokens":10}}

    """.utf8)) { _, _ in expect(false, "live subagent events should parse") }
    var task = lastActivity(events, id: "task-3")
    var info = task?.subagent
    expect(task?.state == .succeeded && info?.status == .running,
           "a background agent keeps running after its task call returns")
    expect(info?.name == "slow-counter" && info?.summary == "Slow counter" && info?.background == true,
           "start details should describe the agent")
    expect(info?.effort == "high", "configured effort should be shown")
    expect(info?.tokens == 4401 + 67 + 4494 + 10, "tokens should accumulate live from subagent usage")
    expect(info?.intent == "Waiting on sleep", "the latest intent should be shown")
    expect(info?.canCancel == true, "an SDK session can stop a running subagent")
    expect(abs((info?.startedAt.timeIntervalSince1970 ?? 0) - 1_790_501_254) < 0.01,
           "the start time should come from the event timestamp")
    expect(task?.children.map(\.state) == [.running], "the running step should be nested")

    // Stopped from Cantrip: the bridge's synthetic event lands before the runtime's report.
    events = parser.consume(Data("""
    {"type":"\(CopilotJSONStreamParser.cancelledEventType)","id":"p10","agentId":"agent-3","data":{}}
    {"type":"subagent.completed","id":"p11","agentId":"agent-3","data":{"toolCallId":"task-3","agentName":"general-purpose","agentDisplayName":"slow-counter","cancelled":true,"model":"gpt-5-mini","totalToolCalls":0,"totalTokens":16750,"durationMs":6215}}

    """.utf8)) { _, _ in expect(false, "cancel events should parse") }
    task = lastActivity(events, id: "task-3")
    info = task?.subagent
    expect(info?.status == .cancelled && info?.canCancel == false, "a stopped agent should read as stopped")
    expect(task?.children.map(\.state) == [.cancelled], "a stopped agent's running steps should stop too")
    expect(info?.tokens == 16750, "the runtime's final total should win")
    expect(abs((info?.elapsed() ?? 0) - 6.215) < 0.01, "the runtime's duration should set the elapsed time")
}

private func testQueuedBackgroundSubagentShowsAtLaunch() {
    var parser = CopilotJSONStreamParser(canCancelSubagents: true)
    // Shapes captured from Copilot CLI 1.0.88: the agent starts only once the root waits.
    var events = parser.consume(Data("""
    {"type":"assistant.message","id":"q1","timestamp":"2026-09-28T06:21:14.900Z","data":{"messageId":"m1","content":"","toolRequests":[{"toolCallId":"task-q","name":"task","arguments":{"agent_type":"general-purpose","description":"Build notification permission prompts","mode":"background","name":"notif-prompts","prompt":"Implement the prompts."}}]}}
    {"type":"tool.execution_start","id":"q2","timestamp":"2026-09-28T06:21:14.918Z","data":{"toolCallId":"task-q","toolName":"task","arguments":{"agent_type":"general-purpose","description":"Build notification permission prompts","mode":"background","name":"notif-prompts"}}}
    {"type":"tool.execution_complete","id":"q3","timestamp":"2026-09-28T06:21:14.921Z","data":{"toolCallId":"task-q","success":true,"result":{"content":"Agent started in background with agent_id: 84c6dca2-b522-4aa0-9337-123d56cd1088. You'll be notified when it completes."}}}
    {"type":"tool.execution_start","id":"q4","data":{"toolCallId":"bash-q","toolName":"bash","arguments":{"command":"make test"}}}

    """.utf8)) { _, _ in expect(false, "queued launch events should parse") }
    var info = lastActivity(events, id: "task-q")?.subagent
    expect(info?.status == .queued && info?.isActive == true, "a launched background agent should show as queued")
    expect(info?.name == "notif-prompts" && info?.agentType == "general-purpose"
           && info?.summary == "Build notification permission prompts" && info?.background == true,
           "the launch arguments should describe the queued agent")
    expect(info?.agentID == "84c6dca2-b522-4aa0-9337-123d56cd1088" && info?.canCancel == true,
           "the task result's agent ID should make a queued agent stoppable")
    expect(abs((info?.startedAt.timeIntervalSince1970 ?? 0) - 1_790_576_474.9) < 0.01,
           "queued time should count from the launch")

    events = parser.consume(Data("""
    {"type":"subagent.started","id":"q5","timestamp":"2026-09-28T06:27:00.000Z","agentId":"84c6dca2-b522-4aa0-9337-123d56cd1088","data":{"toolCallId":"task-q","agentName":"general-purpose","agentDisplayName":"notif-prompts","agentDescription":"Build notification permission prompts","executionMode":"background"}}
    {"type":"tool.execution_start","id":"q6","agentId":"84c6dca2-b522-4aa0-9337-123d56cd1088","data":{"toolCallId":"view-q","toolName":"view","arguments":{"path":"src/app.tsx"}}}

    """.utf8)) { _, _ in expect(false, "queued start events should parse") }
    var task = lastActivity(events, id: "task-q")
    info = task?.subagent
    expect(info?.status == .running && info?.canCancel == true, "a queued agent should run once Copilot starts it")
    expect(abs((info?.startedAt.timeIntervalSince1970 ?? 0) - 1_790_576_820) < 0.01,
           "run time should count from the actual start")
    expect(task?.children.map(\.id) == ["view-q"], "the started agent's steps should nest under its task")

    events = parser.consume(Data("""
    {"type":"subagent.completed","id":"q7","agentId":"84c6dca2-b522-4aa0-9337-123d56cd1088","data":{"toolCallId":"task-q","agentName":"general-purpose","agentDisplayName":"notif-prompts","totalTokens":1200}}

    """.utf8)) { _, _ in expect(false, "queued completion should parse") }
    expect(lastActivity(events, id: "task-q")?.subagent?.status == .completed, "the agent should finish normally")

    // A sync agent shows as running from its launch; a failed launch never runs.
    events = parser.consume(Data("""
    {"type":"tool.execution_start","id":"s1","data":{"toolCallId":"task-s","toolName":"task","arguments":{"agent_type":"explore","description":"Map callers","name":"map-callers"}}}
    {"type":"tool.execution_start","id":"f1","data":{"toolCallId":"task-f","toolName":"task","arguments":{"agent_type":"task","description":"Run tests","mode":"background"}}}
    {"type":"tool.execution_complete","id":"f2","data":{"toolCallId":"task-f","success":false,"error":{"message":"Too many subagents are running."}}}

    """.utf8)) { _, _ in expect(false, "launch variants should parse") }
    expect(lastActivity(events, id: "task-s")?.subagent?.status == .running, "a sync agent should show as running at launch")
    let failed = lastActivity(events, id: "task-f")?.subagent
    expect(failed?.status == .failed && failed?.error == "Too many subagents are running." && failed?.canCancel == false,
           "a failed launch should end its card with the reason")

    // Stopped while queued: a late start must not revive it.
    events = parser.consume(Data("""
    {"type":"tool.execution_start","id":"c1","data":{"toolCallId":"task-c","toolName":"task","arguments":{"agent_type":"task","description":"Lint","mode":"background"}}}
    {"type":"tool.execution_complete","id":"c2","data":{"toolCallId":"task-c","success":true,"result":{"content":"Agent started in background with agent_id: agent-c. You'll be notified when it completes."}}}
    {"type":"\(CopilotJSONStreamParser.cancelledEventType)","id":"c3","agentId":"agent-c","data":{}}
    {"type":"subagent.started","id":"c4","agentId":"agent-c","data":{"toolCallId":"task-c","agentName":"task","agentDisplayName":"Lint","executionMode":"background"}}

    """.utf8)) { _, _ in expect(false, "queued cancel events should parse") }
    task = lastActivity(events, id: "task-c")
    expect(task?.subagent?.status == .cancelled, "an agent stopped while queued should stay stopped")
    expect(CopilotJSONStreamParser.backgroundAgentID(in: "Agent started in background with agent_id: notif-prompts-2. You'll") == "notif-prompts-2",
           "named agent IDs should parse without the sentence's period")
}

private func testSubagentFailureAndNesting() {
    var parser = CopilotJSONStreamParser()
    let events = parser.consume(Data("""
    {"type":"tool.execution_start","id":"n1","data":{"toolCallId":"task-4","toolName":"task","arguments":{"description":"Outer"}}}
    {"type":"subagent.started","id":"n2","agentId":"agent-4","data":{"toolCallId":"task-4","agentName":"general-purpose","agentDisplayName":"Outer","agentDescription":""}}
    {"type":"tool.execution_start","id":"n3","agentId":"agent-4","data":{"toolCallId":"task-5","toolName":"task","arguments":{"description":"Inner"}}}
    {"type":"subagent.started","id":"n4","agentId":"agent-5","data":{"toolCallId":"task-5","agentName":"explore","agentDisplayName":"Inner","agentDescription":"","executionMode":"sync"}}
    {"type":"tool.execution_start","id":"n5","agentId":"agent-5","data":{"toolCallId":"grep-5","toolName":"grep"}}
    {"type":"subagent.failed","id":"n6","agentId":"agent-5","data":{"toolCallId":"task-5","agentName":"explore","agentDisplayName":"Inner","error":"Model call failed"}}
    {"type":"tool.execution_complete","id":"n7","agentId":"agent-4","data":{"toolCallId":"task-5","success":false,"result":{"content":"failed"}}}
    {"type":"tool.execution_complete","id":"n8","data":{"toolCallId":"task-4","success":true,"result":{"content":"done"}}}

    """.utf8)) { _, _ in expect(false, "nested subagent events should parse") }
    let outer = lastActivity(events, id: "task-4")
    let agents = outer?.subagentActivities ?? []
    expect(agents.map(\.id) == ["task-4", "task-5"], "nested subagents should be listed after their parent")
    let inner = agents.last?.subagent
    expect(inner?.status == .failed && inner?.error == "Model call failed", "a failure should keep its reason")
    expect(inner?.canCancel == false, "without SDK support Stop stays hidden")
    expect(outer?.children.map(\.id) == ["task-5"], "an inner agent's steps should nest under its own task")
    expect(agents.last?.children.map(\.state) == [.failed], "a failed agent's unfinished steps should end")
    expect(outer?.subagent?.status == .completed, "a sync agent ends when its task call returns")
}

private func testUnknownSubagentFallsBackToTopLevel() {
    var parser = CopilotJSONStreamParser()
    let events = parser.consume(Data("""
    {"type":"tool.execution_start","id":"u1","agentId":"unknown","data":{"toolCallId":"view-1","toolName":"view"}}

    """.utf8)) { _, _ in expect(false, "orphan events should parse") }
    expect(lastActivity(events, id: "view-1") != nil, "steps without a tracked task should still be visible")
    expect(CopilotJSONStreamParser.tokenLabel(1_250_000) == "1.2M tokens", "large token counts should be compact")
}

private func thinking(from events: [BackendEvent]) -> String {
    events.compactMap { event in
        guard case .thinkingDelta(let delta) = event else { return nil }
        return delta
    }.joined()
}

private func testReasoningBlocksAndSteps() {
    var parser = CopilotJSONStreamParser()
    // Shapes captured from Copilot CLI 1.0.88: Claude repeats block r1 under r2 on later calls.
    var events = parser.consume(Data("""
    {"type":"assistant.reasoning_delta","id":"r1","data":{"reasoningId":"rid-1","deltaContent":"Look for the parser."}}
    {"type":"assistant.reasoning","id":"r2","data":{"reasoningId":"rid-1","content":"Look for the parser."}}
    {"type":"assistant.reasoning","id":"r3","data":{"reasoningId":"rid-2","content":"Look for the parser.\\n"}}
    {"type":"assistant.reasoning_delta","id":"r3b","data":{"reasoningId":"rid-2b","deltaContent":"\\n"}}
    {"type":"assistant.reasoning_delta","id":"r4","data":{"reasoningId":"rid-3","deltaContent":"**Checking results**\\n\\nIt"}}
    {"type":"assistant.reasoning_delta","id":"r4b","data":{"reasoningId":"rid-3","deltaContent":"\\n\\n"}}
    {"type":"assistant.reasoning_delta","id":"r4c","data":{"reasoningId":"rid-3","deltaContent":"worked."}}
    {"type":"assistant.reasoning","id":"r5","data":{"reasoningId":"rid-4","content":"A block that never streamed."}}

    """.utf8)) { _, _ in expect(false, "reasoning events should parse") }
    expect(thinking(from: events) == "Look for the parser.\n\n**Checking results**\n\nIt\n\nworked.\n\nA block that never streamed.",
           "blocks should be separated, streamed aggregates, repeats and blank blocks skipped")

    events = parser.consume(Data("""
    {"type":"tool.execution_start","id":"r6","data":{"toolCallId":"task-9","toolName":"task","arguments":{"description":"Find"}}}
    {"type":"subagent.started","id":"r7","agentId":"agent-9","data":{"toolCallId":"task-9","agentName":"explore","agentDisplayName":"find-parser","agentDescription":"Find"}}
    {"type":"assistant.reasoning","id":"r8","agentId":"agent-9","data":{"reasoningId":"a1","content":"**Exploring local repository options**\\n\\nI'm considering rg."}}
    {"type":"assistant.reasoning","id":"r9","agentId":"agent-9","data":{"reasoningId":"a2","content":""}}
    {"type":"assistant.reasoning","id":"r10","agentId":"agent-9","data":{"reasoningId":"a3","content":"**Exploring local repository options**\\n\\nI'm considering rg."}}
    {"type":"assistant.reasoning_delta","id":"r11","agentId":"agent-9","data":{"reasoningId":"a4","deltaContent":"ignored"}}

    """.utf8)) { _, _ in expect(false, "subagent reasoning should parse") }
    let info = lastActivity(events, id: "task-9")?.subagent
    expect(info?.reasoning == ["**Exploring local repository options**\n\nI'm considering rg."],
           "subagent blocks should be kept once, without empties or deltas")
    expect(thinking(from: events).isEmpty, "subagent reasoning should stay out of the reply's reasoning")

    var window = SubagentInfo(agentID: "a", name: "", agentType: "", summary: "")
    for block in 1...(SubagentInfo.reasoningLimit + 2) {
        window.addReasoning(block == 1 ? "**One**\n\na\n\n**Two**\n\nb" : "Block \(block).")
    }
    expect(window.reasoning.count == SubagentInfo.reasoningLimit && window.reasoning.first == "Block 3."
           && window.reasoningStepOffset == 3,
           "dropped blocks should keep later step numbers stable: \(window.reasoningStepOffset)")

    let steps = ReasoningStep.steps(from: [
        "**Crafting prompt**\n\nI'm putting it together.\n\n**Checking scope**\n\nOnly Swift files.",
        "I need to check the parser. Then the tests.",
        "No sentence end\nsecond line",
        String(repeating: "word ", count: 40) + "end.",
    ])
    expect(steps.map(\.title).prefix(4) == ["Crafting prompt", "Checking scope", "I need to check the parser", "No sentence end"],
           "headings and first sentences should title steps")
    expect(steps.map(\.text).prefix(4) == ["I'm putting it together.", "Only Swift files.", "Then the tests.", "second line"],
           "step text should follow its title")
    expect(steps.last?.title.hasSuffix("word…") == true && (steps.last?.title.count ?? 0) <= ReasoningStep.titleLimit + 1
           && steps.last?.text.hasSuffix("end.") == true,
           "a long first sentence should be shortened and keep the full text")
}

testMalformedLineDoesNotAbortBatch()
testMalformedEventDoesNotPoisonLaterChunks()
testMalformedFinalLineIsReportedAndSkipped()
testSDKMessagesAndUsage()
testSubagentStepsNestUnderTask()
testBackgroundSubagentKeepsReporting()
testSubagentLiveProgress()
testQueuedBackgroundSubagentShowsAtLaunch()
testSubagentFailureAndNesting()
testUnknownSubagentFallsBackToTopLevel()
testReasoningBlocksAndSteps()
failures += runMCPAppTests()

if failures > 0 {
    fputs("\(failures) Copilot parser test(s) failed\n", stderr)
    exit(1)
}
print("All 12 Copilot parser test groups passed (incl. MCP Apps)")
