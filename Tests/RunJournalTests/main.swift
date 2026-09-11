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

    var pendingRoute = RunJournal.Event(sessionID: sessionID, runID: claimedRunID, kind: .queueAdded)
    pendingRoute.queueItem = firstQueue
    try journal.append(pendingRoute, durable: true)
    var routing = RunJournal.Event(sessionID: sessionID, runID: claimedRunID, kind: .messageRouted)
    routing.queueItemID = firstQueue.id
    routing.reason = "Added context to the current task."
    try journal.append(routing, durable: true)
    expect(journal.recoveryState()?.queued == [firstQueue],
           "A router decision alone never consumes a saved message")
    var injected = RunJournal.Event(sessionID: sessionID, runID: claimedRunID, kind: .messageStarted)
    injected.messageID = UUID()
    injected.role = "user"
    injected.text = firstQueue.text
    injected.queueItemID = firstQueue.id
    try journal.append(injected, durable: true)
    expect(journal.recoveryState()?.queued.isEmpty == true,
           "Delivered injections atomically claim the queue item during replay")

    let duplicatePrompts = (0..<3).map { _ in
        RunJournal.QueueItem(id: UUID(), text: "Continue", includesAmbientContext: false)
    }
    for item in duplicatePrompts {
        var added = RunJournal.Event(sessionID: sessionID, runID: claimedRunID, kind: .queueAdded)
        added.queueItem = item
        try journal.append(added, durable: true)
    }
    var removedDuplicate = RunJournal.Event(
        sessionID: sessionID, runID: claimedRunID, kind: .queueRemoved
    )
    removedDuplicate.queueItem = duplicatePrompts[1]
    try journal.append(removedDuplicate, durable: true)
    let reopened = try RunJournal(sessionID: sessionID, directory: directory)
    expect(
        reopened.recoveryState()?.queued == [duplicatePrompts[0], duplicatePrompts[2]],
        "Removing by identity persists without removing equal-text prompts or changing their order"
    )
    expect(
        reopened.recoveryState()?.activeRun?.id == claimedRunID,
        "Removing a queued message does not cancel the active run"
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

    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let acknowledged = DispatchSemaphore(value: 0)
    var blockNextSync = true
    let backgroundID = UUID()
    let background = try RunJournal(sessionID: backgroundID, directory: directory) { handle in
        if blockNextSync {
            blockNextSync = false
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try handle.synchronize()
    }
    let backgroundStart = RunJournal.Event(sessionID: backgroundID, runID: UUID(), kind: .turnStarted)
    background.enqueue(backgroundStart, durable: true) { result in
        if case .failure = result { fatalError("Unexpected background write failure") }
        acknowledged.signal()
    }
    expect(entered.wait(timeout: .now() + 2) == .success, "writer should reach fsync")
    let enqueueStart = Date()
    for index in 0..<100 {
        var delta = RunJournal.Event(sessionID: backgroundID, runID: backgroundStart.runID, kind: .output)
        delta.text = "delta-\(index)"
        background.enqueue(delta) { result in
            if case .failure = result { fatalError("Unexpected delta failure") }
        }
    }
    expect(Date().timeIntervalSince(enqueueStart) < 0.1,
           "enqueueing streamed events must not wait on blocked disk I/O")
    expect(acknowledged.wait(timeout: .now() + 0.05) == .timedOut,
           "durable completion must not acknowledge before fsync")
    let flushed = DispatchSemaphore(value: 0)
    background.flush { result in
        if case .failure = result { fatalError("Unexpected flush failure") }
        flushed.signal()
    }
    expect(flushed.wait(timeout: .now() + 0.05) == .timedOut, "flush must wait for pending records")
    release.signal()
    expect(acknowledged.wait(timeout: .now() + 2) == .success, "fsync should acknowledge after release")
    expect(flushed.wait(timeout: .now() + 2) == .success, "flush should drain queued output")
    let ordered = RunJournal.loadEvents(from: background.fileURL)
    expect(ordered.map(\.sequence) == Array(1...101), "background records must have contiguous FIFO sequences")
    expect(ordered.dropFirst().compactMap(\.text) == (0..<100).map { "delta-\($0)" },
           "all output must retain submission order")

    let brokenID = UUID()
    let broken = try RunJournal(sessionID: brokenID, directory: directory) { _ in
        throw CocoaError(.fileWriteOutOfSpace)
    }
    let failedWrite = DispatchSemaphore(value: 0)
    broken.enqueue(RunJournal.Event(sessionID: brokenID, runID: runID, kind: .turnStarted),
                   durable: true) { result in
        guard case .failure = result else { fatalError("fsync failure must be explicit") }
        failedWrite.signal()
    }
    expect(failedWrite.wait(timeout: .now() + 2) == .success, "fsync failure should reach the caller")
    do {
        try broken.append(RunJournal.Event(sessionID: brokenID, runID: runID, kind: .result), durable: true)
        expect(false, "a failed journal must reject later terminal results")
    } catch {}
    expect(!RunJournal.loadEvents(from: broken.fileURL).contains { $0.kind == .result },
           "a write failure cannot be hidden by a later successful result")
    let failedFlush = DispatchSemaphore(value: 0)
    broken.flush { result in
        guard case .failure = result else { fatalError("flush must retain a prior failure") }
        failedFlush.signal()
    }
    expect(failedFlush.wait(timeout: .now() + 2) == .success, "flush must surface the sticky failure")

    let malformedID = UUID()
    let malformed = try RunJournal(sessionID: malformedID, directory: directory)
    var invalid = RunJournal.Event(sessionID: malformedID, runID: runID, kind: .usage)
    invalid.usage = RunJournal.Usage(backend: "fixture", inputTokens: 0, outputTokens: 0, costUSD: .nan)
    do {
        try malformed.append(invalid)
        expect(false, "encoding errors must propagate")
    } catch {}
    expect(RunJournal.loadEvents(from: malformed.fileURL).isEmpty, "invalid events must not write partial JSON")

    let tailID = UUID()
    let tailJournal = try RunJournal(sessionID: tailID, directory: directory)
    try tailJournal.append(RunJournal.Event(sessionID: tailID, runID: runID, kind: .turnStarted))
    let truncatedHandle = try FileHandle(forWritingTo: tailJournal.fileURL)
    try truncatedHandle.seekToEnd()
    try truncatedHandle.write(contentsOf: Data(#"{"partial":"#.utf8))
    try truncatedHandle.close()
    let repaired = try RunJournal(sessionID: tailID, directory: directory)
    try repaired.append(RunJournal.Event(sessionID: tailID, runID: runID, kind: .result), durable: true)
    expect(RunJournal.loadEvents(from: repaired.fileURL).map(\.kind) == [.turnStarted, .result],
           "reopening after a partial tail must not swallow the first new event")

    let deletionID = UUID()
    let deletion = try RunJournal(sessionID: deletionID, directory: directory)
    for _ in 0..<20 {
        deletion.enqueue(RunJournal.Event(sessionID: deletionID, runID: runID, kind: .output)) { result in
            if case .failure = result { fatalError("Unexpected pre-deletion write failure") }
        }
    }
    try deletion.remove()
    expect(!FileManager.default.fileExists(atPath: deletion.fileURL.path),
           "privacy deletion must drain queued writes without recreating the journal")
    expect(!RunJournal.drainForTermination().isEmpty,
           "exit drain must surface the injected failed journals")
} catch {
    failures += 1
    fputs("FAIL: unexpected error: \(error)\n", stderr)
}

if failures == 0 {
    print("Run journal tests passed")
} else {
    exit(1)
}
