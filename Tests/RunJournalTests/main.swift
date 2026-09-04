import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("cantrip-run-journal-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }

do {
    let sessionID = UUID()
    let runID = UUID()
    let assistantID = UUID()
    let firstQueue = RunJournal.QueueItem(
        id: UUID(),
        text: "queued first",
        includesAmbientContext: false
    )
    let secondQueue = RunJournal.QueueItem(
        id: UUID(),
        text: "queued second",
        includesAmbientContext: true
    )
    let journal = try RunJournal(sessionID: sessionID, directory: directory)

    var start = RunJournal.Event(
        timestamp: Date(timeIntervalSince1970: 100),
        sessionID: sessionID,
        runID: runID,
        kind: .turnStarted
    )
    start.prompt = "finish the migration"
    start.mode = .single
    start.backends = ["Claude Code"]
    start.workdir = "/tmp/project"
    start.includesAmbientContext = false
    try journal.append(start, durable: true)

    var message = RunJournal.Event(
        sessionID: sessionID,
        runID: runID,
        kind: .messageStarted
    )
    message.messageID = assistantID
    message.role = "assistant"
    try journal.append(message)

    var output = RunJournal.Event(
        sessionID: sessionID,
        runID: runID,
        kind: .output
    )
    output.messageID = assistantID
    output.text = "Partial answer"
    try journal.append(output)

    var activity = RunJournal.Event(
        sessionID: sessionID,
        runID: runID,
        kind: .toolActivity
    )
    activity.messageID = assistantID
    activity.activity = RunJournal.Activity(
        id: "tool-1",
        title: "Editing schema.sql",
        toolName: "Edit",
        state: "succeeded",
        input: "{\"path\":\"schema.sql\"}",
        output: "Done",
        fileChanges: [
            RunJournal.FileChange(
                id: "schema.sql#edit",
                path: "schema.sql",
                diff: "+ALTER TABLE runs ADD status TEXT;"
            )
        ],
        terminalCommand: nil,
        children: []
    )
    try journal.append(activity)

    for item in [firstQueue, secondQueue] {
        var queued = RunJournal.Event(
            sessionID: sessionID,
            runID: runID,
            kind: .queueAdded
        )
        queued.queueItem = item
        try journal.append(queued, durable: true)
    }
    var removed = RunJournal.Event(
        sessionID: sessionID,
        runID: runID,
        kind: .queueRemoved
    )
    removed.queueItem = firstQueue
    try journal.append(removed, durable: true)

    var attempt = RunJournal.Event(
        sessionID: sessionID,
        runID: runID,
        kind: .attempt
    )
    attempt.attemptNumber = 2
    attempt.reason = "resume"
    try journal.append(attempt, durable: true)

    var interruption = RunJournal.Event(
        sessionID: sessionID,
        runID: runID,
        kind: .interruption
    )
    interruption.reason = "backend disconnected"
    try journal.append(interruption, durable: true)

    let state = journal.recoveryState()
    expect(state?.activeRun?.id == runID, "the unfinished run should be recoverable")
    expect(
        state?.activeRun?.messages.first?.text == "Partial answer",
        "partial streamed output should replay"
    )
    expect(
        state?.activeRun?.messages.first?.activities.first?.fileChanges.first?.path
            == "schema.sql",
        "tool state and artifacts should replay"
    )
    expect(state?.activeRun?.attemptNumber == 2, "attempt count should replay")
    expect(
        state?.activeRun?.lastInterruptionReason == "backend disconnected",
        "interruption reason should replay"
    )
    expect(state?.queued == [secondQueue], "queue mutations should replay in order")

    let tail = try FileHandle(forWritingTo: journal.fileURL)
    try tail.seekToEnd()
    try tail.write(contentsOf: Data("{\"truncated\":".utf8))
    try tail.close()
    let afterTruncatedTail = RunJournal.recoveryState(
        from: RunJournal.loadEvents(from: journal.fileURL)
    )
    expect(
        afterTruncatedTail?.activeRun?.messages.first?.text == "Partial answer",
        "a truncated tail must not discard prior complete events"
    )

    var result = RunJournal.Event(
        sessionID: sessionID,
        runID: runID,
        kind: .result
    )
    result.status = "succeeded"
    result.summaryDigest = RunJournal.digest("Partial answer")
    try journal.append(result, durable: true)
    let completed = journal.recoveryState()
    expect(completed?.activeRun == nil, "terminal results should close a run")
    expect(completed?.queued == [secondQueue], "terminal results should not erase the queue")
    expect(
        RunJournal.digest("same") == RunJournal.digest("same")
            && RunJournal.digest("same") != RunJournal.digest("different"),
        "summary digests should be deterministic"
    )

    let claimedRunID = UUID()
    var claimedStart = RunJournal.Event(
        sessionID: sessionID,
        runID: claimedRunID,
        kind: .turnStarted
    )
    claimedStart.prompt = secondQueue.text
    claimedStart.mode = .single
    claimedStart.queueItemID = secondQueue.id
    try journal.append(claimedStart, durable: true)
    let claimed = journal.recoveryState()
    expect(
        claimed?.queued.isEmpty == true,
        "starting a queued turn should atomically claim it during replay"
    )

    let oldID = UUID()
    let oldJournal = try RunJournal(sessionID: oldID, directory: directory)
    let oldDate = Date(timeIntervalSince1970: 1)
    try FileManager.default.setAttributes(
        [.modificationDate: oldDate],
        ofItemAtPath: oldJournal.fileURL.path
    )
    try RunJournal.prune(
        directory: directory,
        olderThan: 60,
        now: Date(timeIntervalSince1970: 1_000)
    )
    expect(
        !FileManager.default.fileExists(atPath: oldJournal.fileURL.path),
        "retention should remove expired journals"
    )
} catch {
    failures += 1
    fputs("FAIL: unexpected error: \(error)\n", stderr)
}

if failures == 0 {
    print("Run journal tests passed")
} else {
    exit(1)
}
