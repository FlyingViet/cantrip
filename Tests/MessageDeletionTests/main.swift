import Foundation
import SQLite3

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("cantrip-message-deletion-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

private let prompt = "What is the confirmation code for the garden club order?"
private let reply = "The garden club order's confirmation code is **ZX-4471-QQ**, from the receipt email."
private let exchange = DeletedExchange(prompt: prompt, replies: [reply])

private func jsonLine(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func count(_ needle: String, in data: Data) -> Int {
    String(decoding: data, as: UTF8.self).components(separatedBy: needle).count - 1
}

// MARK: Redaction

do {
    let clipped = "User: earlier\nAssistant: \(reply.prefix(40)) ...[clipped]\nUser: next"
    let redacted = TranscriptScrubber.redact(clipped, removing: [reply])
    expect(!redacted.contains("garden club order's"), "a clipped copy of a deleted reply is redacted")
    expect(redacted.contains("User: earlier") && redacted.contains("User: next"),
           "text around a redacted copy stays")
    expect(TranscriptScrubber.redact("ok then", removing: ["ok"]) == "ok then",
           "short fragments are never redacted outside their turn")
    let twice = TranscriptScrubber.redact("\(reply) and again \(reply)", removing: [reply])
    expect(!twice.contains("ZX-4471"), "every copy is redacted")
}

// MARK: Memory session log

do {
    let log = """
    # 2026-01-02

    ## 09:00 · Copilot
    **User:** Plan the weekend

    **Assistant:** Here's a plan for the weekend.

    ## 09:05 · Copilot
    **User:** \(prompt)

    **Assistant:** \(reply)

    ## 09:10 · Claude Code
    **User:** Thanks

    **Assistant:** You're welcome.

    """
    let result = SessionLogScrubber.removing([exchange], from: log)
    expect(result.removed == 1, "the deleted exchange's section is removed")
    expect(!result.log.contains("ZX-4471") && !result.log.contains(prompt), "no trace of the exchange stays")
    expect(result.log.contains("Plan the weekend") && result.log.contains("You're welcome."),
           "other sections stay")
    expect(result.log.hasPrefix("# 2026-01-02"), "the log's header stays")
    let unrelated = SessionLogScrubber.removing(
        [DeletedExchange(prompt: "Thanks", replies: ["Something else entirely."])], from: log
    )
    expect(unrelated.removed == 0, "a section whose reply differs stays")

    let sessions = directory.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try log.write(to: sessions.appendingPathComponent("2026-01-02.md"), atomically: true, encoding: .utf8)
    try log.write(to: sessions.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    expect(SessionLogScrubber.remove([exchange], in: sessions) == 1, "daily logs are scrubbed on disk")
    let notes = try String(contentsOf: sessions.appendingPathComponent("notes.md"), encoding: .utf8)
    expect(notes.contains("ZX-4471"), "only daily logs (YYYY-MM-DD.md) are touched")
}

// MARK: Copilot events

do {
    let lines = [
        jsonLine(["type": "session.start", "id": "e1", "data": ["sessionId": "s"]]),
        jsonLine(["type": "user.message", "id": "e2", "parentId": "e1", "data": ["content": "Context...\n\nPlan the weekend"]]),
        jsonLine(["type": "assistant.message", "id": "e3", "parentId": "e2", "data": ["content": "Here's a plan."]]),
        jsonLine(["type": "user.message", "id": "e4", "parentId": "e3", "data": ["content": "Memory notes...\n\n\(prompt)"]]),
        jsonLine(["type": "tool.execution_complete", "id": "e5", "parentId": "e4", "data": ["result": ["content": "Receipt: code ZX-4471-QQ, Pass:: example-only"]]]),
        jsonLine(["type": "assistant.message", "id": "e6", "parentId": "e5", "data": ["content": reply]]),
        jsonLine(["type": "user.message", "id": "e7", "parentId": "e6", "data": ["content": "Thanks"]]),
        jsonLine(["type": "assistant.message", "id": "e8", "parentId": "e7", "data": ["content": "You're welcome."]]),
    ]
    let session = directory.appendingPathComponent("copilot-state/11111111-2222-4333-8444-555555555555")
    try FileManager.default.createDirectory(at: session.appendingPathComponent("checkpoints"), withIntermediateDirectories: true)
    let events = session.appendingPathComponent("events.jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: events)
    try "## Summary\nThe user asked: \(prompt)\n".write(
        to: session.appendingPathComponent("checkpoints/001-summary.md"), atomically: true, encoding: .utf8
    )
    let changed = TranscriptScrubber.scrubCopilotSession(session, exchanges: [exchange])
    let data = try Data(contentsOf: events)
    expect(changed == 2, "the events log and the checkpoint summary change")
    expect(count("ZX-4471", in: data) == 0 && count("Pass::", in: data) == 0,
           "the deleted turn's tool output and reply are gone")
    expect(count("Plan the weekend", in: data) == 1 && count("You're welcome.", in: data) == 1,
           "other turns stay")
    let records = String(decoding: data, as: UTF8.self).split(separator: "\n").map {
        try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    expect(records.count == 5, "the deleted turn's records are dropped")
    expect(records.first { $0["id"] as? String == "e7" }?["parentId"] as? String == "e3",
           "the next turn points at the last kept record")
    expect(String(decoding: data, as: UTF8.self).hasSuffix("\n"), "the log still ends with a newline")
    let checkpoint = try String(contentsOf: session.appendingPathComponent("checkpoints/001-summary.md"), encoding: .utf8)
    expect(!checkpoint.contains(prompt), "the checkpoint no longer quotes the prompt")

    // A later session replays the deleted turn in its first prompt.
    let replay = jsonLine(["type": "user.message", "id": "r1",
                           "data": ["content": "Earlier:\nUser: \(prompt)\nAssistant: \(reply.prefix(60)) ...[clipped]\n\nNew question"]])
    let replayed = TranscriptScrubber.scrubJSONLines(Data((replay + "\n").utf8), exchanges: [exchange],
                                                     turnText: TranscriptScrubber.copilotTurnText)
    let replayText = String(decoding: replayed.data, as: UTF8.self)
    expect(replayed.changed && !replayText.contains(prompt) && !replayText.contains("garden club order's")
            && replayText.contains("New question"),
           "a replay of the deleted turn is redacted but the new prompt stays")
}

// MARK: Short prompts need the reply too

do {
    let short = DeletedExchange(prompt: "yes", replies: ["Done: the folder was archived to the backup disk."])
    let lines = [
        jsonLine(["type": "user.message", "id": "a", "data": ["content": "yes"]]),
        jsonLine(["type": "assistant.message", "id": "b", "data": ["content": "Okay, I'll keep going."]]),
        jsonLine(["type": "permission.completed", "id": "b2", "data": ["result": "yes"]]),
        jsonLine(["type": "user.message", "id": "c", "data": ["content": "yes"]]),
        jsonLine(["type": "assistant.message", "id": "d", "data": ["content": "Done: the folder was archived to the backup disk."]]),
    ]
    let result = TranscriptScrubber.scrubJSONLines(Data(lines.joined(separator: "\n").utf8), exchanges: [short],
                                                   turnText: TranscriptScrubber.copilotTurnText)
    let text = String(decoding: result.data, as: UTF8.self)
    expect(text.contains("keep going") && text.contains("permission.completed") && !text.contains("archived"),
           "a short prompt drops only the turn with its reply")
}

// MARK: Claude Code and Codex

do {
    let claude = [
        jsonLine(["type": "queue-operation", "content": prompt]),
        jsonLine(["type": "user", "uuid": "u1", "parentUuid": NSNull(), "message": ["role": "user", "content": prompt]]),
        jsonLine(["type": "assistant", "uuid": "a1", "parentUuid": "u1", "message": ["content": [["type": "tool_use", "name": "Bash"]]]]),
        jsonLine(["type": "user", "uuid": "t1", "parentUuid": "a1", "message": ["role": "user", "content": [["type": "tool_result", "content": "code ZX-4471-QQ"]]]]),
        jsonLine(["type": "assistant", "uuid": "a2", "parentUuid": "t1", "message": ["content": [["type": "text", "text": reply]]]]),
        jsonLine(["type": "last-prompt", "lastPrompt": prompt]),
        jsonLine(["type": "user", "uuid": "u2", "parentUuid": "a2", "message": ["role": "user", "content": "Thanks"]]),
    ]
    let result = TranscriptScrubber.scrubJSONLines(Data(claude.joined(separator: "\n").utf8), exchanges: [exchange],
                                                   turnText: TranscriptScrubber.claudeTurnText)
    let text = String(decoding: result.data, as: UTF8.self)
    expect(!text.contains("ZX-4471") && !text.contains(prompt), "Claude's turn, tool results and prompt markers go")
    expect(text.contains("Thanks") && text.contains("\"parentUuid\":null"), "Claude's next turn stays and is re-parented")

    let codex = [
        jsonLine(["type": "session_meta", "payload": ["id": "x"]]),
        jsonLine(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": prompt]]]]),
        jsonLine(["type": "response_item", "payload": ["type": "custom_tool_call_output", "output": "ZX-4471-QQ"]]),
        jsonLine(["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": reply]]]]),
        jsonLine(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Thanks"]]]]),
    ]
    let codexResult = TranscriptScrubber.scrubJSONLines(Data(codex.joined(separator: "\n").utf8), exchanges: [exchange],
                                                        turnText: TranscriptScrubber.codexTurnText)
    let codexText = String(decoding: codexResult.data, as: UTF8.self)
    expect(!codexText.contains("ZX-4471") && codexText.contains("session_meta") && codexText.contains("Thanks"),
           "Codex's deleted turn goes and the rest stays")

    let projects = directory.appendingPathComponent("claude-projects/-tmp-project")
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let session = "22222222-3333-4444-8555-666666666666"
    try Data(claude.joined(separator: "\n").utf8).write(to: projects.appendingPathComponent("\(session).jsonl"))
    expect(TranscriptScrubber.claudeTranscript(session, in: projects.deletingLastPathComponent()) != nil,
           "Claude's transcript is found by session ID")
    let rollouts = directory.appendingPathComponent("codex-sessions/2026/01/02")
    try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
    let thread = "33333333-4444-4555-8666-777777777777"
    try Data(codex.joined(separator: "\n").utf8).write(to: rollouts.appendingPathComponent("rollout-2026-01-02T09-00-00-\(thread).jsonl"))
    let roots = TranscriptScrubber.Roots(
        copilotState: directory.appendingPathComponent("copilot-state"),
        copilotStore: directory.appendingPathComponent("missing.db"),
        claudeProjects: projects.deletingLastPathComponent(),
        codexSessions: directory.appendingPathComponent("codex-sessions")
    )
    let changed = TranscriptScrubber.scrub(
        .init(copilotSessions: [], claudeSession: session, codexThread: thread),
        exchanges: [exchange], roots: roots, runtimeExitWait: 0
    )
    expect(changed == 2, "scrub finds and rewrites the Claude and Codex transcripts")
}

// MARK: Copilot session store

do {
    let url = directory.appendingPathComponent("session-store.db")
    var db: OpaquePointer?
    sqlite3_open(url.path, &db)
    let schema = """
    PRAGMA journal_mode=WAL;
    CREATE TABLE sessions (id TEXT PRIMARY KEY, summary TEXT);
    CREATE TABLE turns (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, turn_index INTEGER NOT NULL,
        user_message TEXT, assistant_response TEXT, UNIQUE(session_id, turn_index));
    CREATE TABLE forge_trajectory_events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
        turn_index INTEGER, command TEXT, output TEXT);
    CREATE TABLE checkpoints (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, title TEXT, history TEXT);
    CREATE VIRTUAL TABLE search_index USING fts5(content, session_id UNINDEXED, source_type UNINDEXED, source_id UNINDEXED);
    INSERT INTO sessions VALUES ('s1', 'Weekend planning');
    INSERT INTO turns (session_id, turn_index, user_message, assistant_response) VALUES
        ('s1', 0, 'Context Plan the weekend', 'Here is a plan.'),
        ('s1', 1, 'Context \(prompt)', '\(reply.replacingOccurrences(of: "'", with: "''"))'),
        ('s1', 2, 'Context Thanks', 'You are welcome.'),
        ('s2', 0, 'Context \(prompt)', 'other session');
    INSERT INTO forge_trajectory_events (session_id, turn_index, command, output) VALUES
        ('s1', 1, 'grep ZX-4471-QQ mail', 'ZX-4471-QQ'), ('s1', 2, 'ls', 'files');
    INSERT INTO checkpoints (session_id, title, history) VALUES ('s1', 'Weekend', 'The user asked: \(prompt)');
    INSERT INTO search_index VALUES ('Plan the weekend Here is a plan', 's1', 'turn', 's1:turn:0'),
        ('\(prompt) ZX-4471-QQ', 's1', 'turn', 's1:turn:1'), ('Thanks', 's1', 'turn', 's1:turn:2');
    """
    expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK, "fixture store is created")
    sqlite3_close(db)

    let changed = try TranscriptScrubber.scrubCopilotStore(url, sessionIDs: ["s1"], exchanges: [exchange])
    expect(changed >= 2, "the turn and the checkpoint change")
    let store = try SQLiteStore(url)
    let turns = try store.rows("SELECT session_id, turn_index FROM turns ORDER BY session_id, turn_index")
    expect(turns.count == 3 && !turns.contains { $0[0] as? String == "s1" && $0[1] as? Int64 == 1 },
           "the deleted turn's row is gone and other sessions are untouched")
    let trajectory = try store.rows("SELECT count(*) FROM forge_trajectory_events WHERE turn_index = 1")[0][0] as? Int64
    expect(trajectory == 0, "the deleted turn's tool trajectory is gone")
    let found = try store.rows("SELECT count(*) FROM search_index WHERE search_index MATCH '\"ZX-4471-QQ\"'")[0][0] as? Int64
    expect(found == 0, "the search index no longer finds the deleted turn")
    let searchRows = try store.rows("SELECT count(*) FROM search_index")[0][0] as? Int64
    expect(searchRows == 2, "other search rows stay")
    let history = try store.rows("SELECT history FROM checkpoints")[0][0] as? String ?? ""
    expect(!history.contains(prompt) && history.contains(TranscriptScrubber.redaction), "the checkpoint is redacted")
}

// MARK: Cantrip's log (the make target runs with a temporary home)

if ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil {
    Log.write("send: \"\(prompt)\" via copilot")
    Log.write("send: \"Plan the weekend\" via copilot")
    Log.flush()
    Log.redact(["\"\(prompt)\""], with: "\"[deleted message]\"")
    Log.flush()
    let text = (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? ""
    expect(!text.contains(prompt) && text.contains("[deleted message]") && text.contains("Plan the weekend"),
           "the deleted prompt leaves Cantrip's log")
} else {
    print("Skipping the log test: set CFFIXED_USER_HOME to a temporary folder")
}

if failures == 0 {
    print("Message deletion tests passed")
} else {
    exit(1)
}
