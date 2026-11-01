import Darwin
import Foundation
import SQLite3

/// What a deleted exchange said, for finding its copies outside the transcript: the prompt and
/// the replies Cantrip showed (either may be empty when only one side is in the conversation).
struct DeletedExchange: Sendable, Equatable {
    let prompt: String
    let replies: [String]

    var fragments: [String] { ([prompt] + replies).filter { !$0.isEmpty } }
}

/// The daily memory session logs (`MemoryStore.logExchange`): one `## HH:mm · backend` section
/// per finished exchange. Deleting a message removes its section.
enum SessionLogScrubber {
    /// How much of a reply has to match the logged one.
    static let replyPrefix = 200
    private static let header = try! NSRegularExpression(pattern: #"\n## \d{2}:\d{2} · "#)

    /// `log` without the sections that recorded one of `exchanges`, and how many went. A section
    /// matches when its reply starts like a deleted reply and its prompt holds the deleted prompt.
    static func removing(_ exchanges: [DeletedExchange], from log: String) -> (log: String, removed: Int) {
        let text = log as NSString
        let starts = header.matches(in: log, range: NSRange(location: 0, length: text.length))
            .map(\.range.location)
        guard !starts.isEmpty else { return (log, 0) }
        var kept = text.substring(to: starts[0])
        var removed = 0
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1] : text.length
            let section = text.substring(with: NSRange(location: start, length: end - start))
            if exchanges.contains(where: { matches(section, $0) }) {
                removed += 1
            } else {
                kept += section
            }
        }
        return (kept, removed)
    }

    private static func matches(_ section: String, _ exchange: DeletedExchange) -> Bool {
        guard let user = section.range(of: "**User:** "),
              let assistant = section.range(of: "\n\n**Assistant:** ", range: user.upperBound..<section.endIndex)
        else { return false }
        let loggedUser = section[user.upperBound..<assistant.lowerBound]
        let loggedReply = section[assistant.upperBound...]
        let prompt = exchange.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty, !loggedUser.contains(prompt) { return false }
        let replies = exchange.replies.filter { !$0.isEmpty }
        if replies.isEmpty { return !prompt.isEmpty && loggedUser.trimmingCharacters(in: .whitespacesAndNewlines) == prompt }
        return replies.contains { loggedReply.hasPrefix($0.prefix(replyPrefix)) }
    }

    /// Removes the exchanges' sections from every daily log (`YYYY-MM-DD.md`) in `directory`.
    @discardableResult
    static func remove(_ exchanges: [DeletedExchange], in directory: URL) -> Int {
        let anchors = exchanges.flatMap(\.replies).filter { !$0.isEmpty }.map { String($0.prefix(40)) }
            + exchanges.map(\.prompt).filter { !$0.isEmpty }
        guard !anchors.isEmpty, let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return 0 }
        var total = 0
        for file in files where file.lastPathComponent.range(
            of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression
        ) != nil {
            guard let log = try? String(contentsOf: file, encoding: .utf8),
                  anchors.contains(where: log.contains) else { continue }
            let result = removing(exchanges, from: log)
            guard result.removed > 0 else { continue }
            do {
                try result.log.write(to: file, atomically: true, encoding: .utf8)
                total += result.removed
            } catch {
                Log.write("delete-message: could not update the session log \(file.lastPathComponent)")
            }
        }
        return total
    }
}

/// Removes deleted exchanges from the backends' own session transcripts, which hold the prompt,
/// every tool call and its output, and the reply. A backend turn whose prompt holds a deleted
/// prompt is dropped whole; copies elsewhere (a later session's replayed history, search
/// indexes, summaries) are redacted.
enum TranscriptScrubber {
    /// Text shorter than this isn't redacted outside its own turn: it's too likely to be
    /// ordinary words. Clipped copies (conversation replays) match on this much of a prefix.
    static let minimumRedactedLength = 24
    /// A prompt this long is distinctive enough to drop a turn without also finding the reply.
    static let distinctivePromptLength = 16
    static let redaction = "[deleted message]"

    struct Locations: Sendable {
        var copilotSessions: [String] = []
        var claudeSession: String?
        var codexThread: String?

        var isEmpty: Bool { copilotSessions.isEmpty && claudeSession == nil && codexThread == nil }
    }

    struct Roots: Sendable {
        var copilotState: URL
        var copilotStore: URL
        var claudeProjects: URL
        var codexSessions: URL

        static var standard: Roots {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Roots(
                copilotState: home.appendingPathComponent(".copilot/session-state", isDirectory: true),
                copilotStore: home.appendingPathComponent(".copilot/session-store.db"),
                claudeProjects: home.appendingPathComponent(".claude/projects", isDirectory: true),
                codexSessions: home.appendingPathComponent(".codex/sessions", isDirectory: true)
            )
        }
    }

    /// Scrubs every transcript in `locations`. Copilot runtimes still holding a session (being
    /// stopped by the reset) get `runtimeExitWait` seconds to exit first. Returns files changed.
    @discardableResult
    static func scrub(_ locations: Locations, exchanges: [DeletedExchange], roots: Roots = .standard,
                      runtimeExitWait: TimeInterval = 10) -> Int {
        guard !exchanges.isEmpty, !locations.isEmpty else { return 0 }
        var changed = 0
        let folders = locations.copilotSessions.map {
            roots.copilotState.appendingPathComponent($0, isDirectory: true)
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        waitForCopilotRuntimes(in: folders, timeout: runtimeExitWait)
        for folder in folders {
            changed += scrubCopilotSession(folder, exchanges: exchanges)
        }
        if !locations.copilotSessions.isEmpty, FileManager.default.fileExists(atPath: roots.copilotStore.path) {
            do {
                changed += try scrubCopilotStore(roots.copilotStore, sessionIDs: locations.copilotSessions,
                                                 exchanges: exchanges)
            } catch {
                Log.write("delete-message: Copilot session store not updated: \(error.localizedDescription)")
            }
        }
        if let session = locations.claudeSession, let file = claudeTranscript(session, in: roots.claudeProjects) {
            changed += scrubFile(file, exchanges: exchanges, turnText: claudeTurnText)
        }
        if let thread = locations.codexThread, let file = codexRollout(thread, in: roots.codexSessions) {
            changed += scrubFile(file, exchanges: exchanges, turnText: codexTurnText)
        }
        return changed
    }

    // MARK: - Text

    /// `text` without the fragments, including clipped copies (a prefix of at least
    /// `minimumRedactedLength` characters, as replayed history sends).
    static func redact(_ text: String, removing fragments: [String]) -> String {
        var result = text
        for fragment in fragments {
            let wanted = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard wanted.count >= minimumRedactedLength else { continue }
            let anchor = String(wanted.prefix(minimumRedactedLength))
            let anchorEnd = wanted.index(wanted.startIndex, offsetBy: minimumRedactedLength)
            var searchFrom = 0
            while searchFrom <= result.count,
                  let found = result.range(of: anchor, options: .literal,
                                           range: result.index(result.startIndex, offsetBy: searchFrom)..<result.endIndex) {
                var end = found.upperBound
                var probe = anchorEnd
                while end < result.endIndex, probe < wanted.endIndex, result[end] == wanted[probe] {
                    end = result.index(after: end)
                    probe = wanted.index(after: probe)
                }
                let offset = result.distance(from: result.startIndex, to: found.lowerBound)
                result.replaceSubrange(found.lowerBound..<end, with: redaction)
                searchFrom = offset + redaction.count
            }
        }
        return result
    }

    /// Whether a backend turn is a deleted exchange's: its prompt holds the deleted prompt, and
    /// the rest of the turn (`reply`: its answers and tool output) holds the start of a deleted
    /// reply. Without the reply, the deleted prompt has to be the turn's own (not only quoted
    /// in replayed history) and distinctive.
    static func turnMatches(prompt turnPrompt: String, reply: () -> String, exchange: DeletedExchange) -> Bool {
        let prompt = exchange.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, turnPrompt.contains(prompt) else { return false }
        let anchors = exchange.replies.map(replyAnchor).filter { !$0.isEmpty }
        if !anchors.isEmpty {
            let text = collapsed(reply())
            if anchors.contains(where: text.contains) { return true }
        }
        guard holdsAsOwnPrompt(turnPrompt, prompt) else { return false }
        return prompt.count >= distinctivePromptLength || anchors.isEmpty
    }

    /// How replayed history quotes an earlier prompt (`ConversationContextBuilder`).
    private static let replayPrefixes = ["User: ", " | ", "Compact summary:\n"]

    private static func holdsAsOwnPrompt(_ turnPrompt: String, _ prompt: String) -> Bool {
        var searchStart = turnPrompt.startIndex
        while let found = turnPrompt.range(of: prompt, options: .literal, range: searchStart..<turnPrompt.endIndex) {
            let before = turnPrompt[..<found.lowerBound]
            if !replayPrefixes.contains(where: { before.hasSuffix($0) }) { return true }
            searchStart = found.upperBound
        }
        return false
    }

    private static func replyAnchor(_ reply: String) -> String {
        String(collapsed(reply).prefix(40))
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A short run of plain characters from each exchange's prompt (or, without one, its
    /// replies), to skip files that can't hold the exchange without parsing them. A turn is
    /// only dropped when its prompt holds the deleted prompt, and replayed copies start with it,
    /// so the prompt's start is enough. JSON writers escape quotes, newlines and sometimes
    /// slashes, so only letters, digits, spaces and simple punctuation are used. Nil when an
    /// exchange has no such run: then every file is parsed.
    static func quickAnchors(_ exchanges: [DeletedExchange]) -> [Data]? {
        func anchor(_ text: String) -> Data? {
            let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix { $0.isLetter || $0.isNumber || $0 == " " || ",.:;!?'()-".contains($0) }
            return plain.count >= 6 ? Data(plain.prefix(32).utf8) : nil
        }
        var anchors: [Data] = []
        for exchange in exchanges {
            if !exchange.prompt.isEmpty {
                guard let prompt = anchor(exchange.prompt) else { return nil }
                anchors.append(prompt)
            } else {
                let replies = exchange.replies.map(anchor)
                guard !replies.isEmpty, !replies.contains(where: { $0 == nil }) else { return nil }
                anchors += replies.compactMap { $0 }
            }
        }
        return anchors.isEmpty ? nil : anchors
    }

    // MARK: - JSON lines transcripts

    /// Rewrites a JSON-lines transcript without the deleted exchanges. `turnText` returns a
    /// record's user prompt when the record starts a turn (nil otherwise); a deleted turn runs
    /// to the next one. Records whose whole text value is a deleted prompt or reply go too
    /// (queue entries, "last prompt" markers); longer copies elsewhere are redacted. Records
    /// that pointed at a dropped one (`parentId`, `parentUuid`) point at its nearest kept parent.
    static func scrubJSONLines(_ data: Data, exchanges: [DeletedExchange],
                               turnText: ([String: Any]) -> String?) -> (data: Data, changed: Bool) {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let records = lines.map { line -> [String: Any]? in
            line.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
        var dropped = Set<Int>()
        var turnStart: Int?
        var turnPrompt = ""
        func closeTurn(at end: Int) {
            guard let start = turnStart else { return }
            let range = start..<end
            let matched = exchanges.contains { exchange in
                turnMatches(prompt: turnPrompt, reply: {
                    range.dropFirst().compactMap { records[$0].map(strings) }.joined(separator: "\n")
                }, exchange: exchange)
            }
            if matched { dropped.formUnion(range) }
        }
        for (index, record) in records.enumerated() {
            guard let record, let prompt = turnText(record) else { continue }
            closeTurn(at: index)
            turnStart = index
            turnPrompt = prompt
        }
        closeTurn(at: records.count)

        let wholeValues = Set(exchanges.flatMap(\.fragments).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.count >= distinctivePromptLength })
        for (index, record) in records.enumerated() where !dropped.contains(index) {
            guard let record else { continue }
            if containsWholeValue(record, wholeValues) { dropped.insert(index) }
        }

        // Re-parent records whose parent was dropped.
        var parentOf: [String: String?] = [:]
        for index in dropped {
            guard let record = records[index] else { continue }
            for (key, parentKey) in parentKeys {
                if let id = record[key] as? String { parentOf[id] = record[parentKey] as? String }
            }
        }
        func keptParent(_ id: String?) -> String? {
            var current = id
            var hops = 0
            while let value = current, let next = parentOf[value], hops < 10_000 {
                current = next
                hops += 1
            }
            return current
        }

        let fragments = exchanges.flatMap(\.fragments)
        var output = Data()
        var changed = !dropped.isEmpty
        for (index, line) in lines.enumerated() where !dropped.contains(index) {
            defer { if index < lines.count - 1 { output.append(0x0A) } }
            guard var record = records[index] else {
                output.append(contentsOf: line)
                continue
            }
            var edited = false
            for (_, parentKey) in parentKeys {
                if let parent = record[parentKey] as? String, parentOf[parent] != nil {
                    record[parentKey] = keptParent(parent) ?? NSNull()
                    edited = true
                }
            }
            let (redacted, didRedact) = redactValue(record, fragments)
            if didRedact, let value = redacted as? [String: Any] {
                record = value
                edited = true
            }
            if edited, let encoded = try? JSONSerialization.data(
                withJSONObject: record, options: [.withoutEscapingSlashes]
            ) {
                output.append(encoded)
                changed = true
            } else {
                output.append(contentsOf: line)
            }
        }
        return (output, changed)
    }

    private static let parentKeys = [("id", "parentId"), ("uuid", "parentUuid")]

    private static func strings(_ value: Any) -> String {
        switch value {
        case let text as String: return text
        case let object as [String: Any]: return object.values.map(strings).joined(separator: "\n")
        case let array as [Any]: return array.map(strings).joined(separator: "\n")
        default: return ""
        }
    }

    private static func containsWholeValue(_ value: Any, _ wanted: Set<String>) -> Bool {
        switch value {
        case let text as String: return wanted.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case let object as [String: Any]: return object.values.contains { containsWholeValue($0, wanted) }
        case let array as [Any]: return array.contains { containsWholeValue($0, wanted) }
        default: return false
        }
    }

    private static func redactValue(_ value: Any, _ fragments: [String]) -> (Any, Bool) {
        switch value {
        case let text as String:
            let redacted = redact(text, removing: fragments)
            return (redacted, redacted != text)
        case let object as [String: Any]:
            var copy = object
            var changed = false
            for (key, item) in object {
                let (redacted, didChange) = redactValue(item, fragments)
                if didChange { copy[key] = redacted; changed = true }
            }
            return (copy, changed)
        case let array as [Any]:
            var changed = false
            let copy = array.map { item -> Any in
                let (redacted, didChange) = redactValue(item, fragments)
                if didChange { changed = true }
                return redacted
            }
            return (copy, changed)
        default:
            return (value, false)
        }
    }

    /// Scrubs one transcript file in place (atomically, keeping its permissions). Returns 1 when
    /// it changed.
    static func scrubFile(_ file: URL, exchanges: [DeletedExchange],
                          turnText: ([String: Any]) -> String?) -> Int {
        guard let data = try? Data(contentsOf: file) else { return 0 }
        if let anchors = quickAnchors(exchanges), !anchors.contains(where: { data.range(of: $0) != nil }) {
            return 0
        }
        let result = scrubJSONLines(data, exchanges: exchanges, turnText: turnText)
        guard result.changed else { return 0 }
        return write(result.data, to: file) ? 1 : 0
    }

    private static func write(_ data: Data, to file: URL) -> Bool {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) ?? 0o600
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
            return true
        } catch {
            Log.write("delete-message: could not rewrite \(file.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Copilot CLI

    static func copilotTurnText(_ record: [String: Any]) -> String? {
        guard record["type"] as? String == "user.message", let data = record["data"] as? [String: Any] else {
            return nil
        }
        return [data["content"], data["transformedContent"]].compactMap { $0 as? String }.joined(separator: "\n")
    }

    /// A session folder: `events.jsonl` (the transcript the CLI resumes from), plus checkpoint
    /// summaries and `workspace.yaml`'s summary, which may quote the prompt.
    static func scrubCopilotSession(_ folder: URL, exchanges: [DeletedExchange]) -> Int {
        var changed = scrubFile(folder.appendingPathComponent("events.jsonl"), exchanges: exchanges,
                                turnText: copilotTurnText)
        let checkpoints = folder.appendingPathComponent("checkpoints", isDirectory: true)
        let notes = ((try? FileManager.default.contentsOfDirectory(at: checkpoints, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" } + [folder.appendingPathComponent("workspace.yaml")]
        for file in notes {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let redacted = redact(text, removing: exchanges.flatMap(\.fragments))
            if redacted != text, write(Data(redacted.utf8), to: file) { changed += 1 }
        }
        return changed
    }

    /// Waits until no Copilot runtime holds these sessions (`inuse.<pid>.lock`), up to `timeout`.
    static func waitForCopilotRuntimes(in folders: [URL], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        func busy() -> Bool {
            folders.contains { folder in
                ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { name in
                    let parts = name.split(separator: ".")
                    guard parts.count == 3, parts[0] == "inuse", parts[2] == "lock",
                          let pid = pid_t(parts[1]), pid > 0 else { return false }
                    return kill(pid, 0) == 0
                }
            }
        }
        while busy(), Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
    }

    /// The CLI's global session index (`~/.copilot/session-store.db`): its `turns` rows hold each
    /// turn's prompt and reply and feed a full-text index. The deleted turns' rows go (with their
    /// file, ref, trajectory and usage rows); copies in other rows are redacted. Deleted content
    /// is overwritten (`secure_delete`) and the search index rebuilt so no token survives.
    static func scrubCopilotStore(_ database: URL, sessionIDs: [String], exchanges: [DeletedExchange]) throws -> Int {
        let store = try SQLiteStore(database)
        guard store.columns("turns").isSuperset(of: ["id", "session_id", "turn_index", "user_message", "assistant_response"])
        else { return 0 }
        let fragments = exchanges.flatMap(\.fragments)
        var changed = 0
        var removedSearchRows = false
        try store.execute("PRAGMA secure_delete = ON")
        try store.execute("BEGIN IMMEDIATE")
        do {
            let hasSearch = store.columns("search_index").isSuperset(of: ["content", "session_id", "source_id"])
            for session in sessionIDs {
                var deletedTurns: [Int64] = []
                for row in try store.rows("SELECT id, turn_index, user_message, assistant_response FROM turns WHERE session_id = ?", [session]) {
                    guard let rowID = row[0] as? Int64, let turn = row[1] as? Int64 else { continue }
                    let user = row[2] as? String ?? ""
                    let reply = row[3] as? String ?? ""
                    if exchanges.contains(where: { turnMatches(prompt: user, reply: { reply }, exchange: $0) }) {
                        try store.execute("DELETE FROM turns WHERE id = ?", [rowID])
                        deletedTurns.append(turn)
                        changed += 1
                        continue
                    }
                    let newUser = redact(user, removing: fragments)
                    let newReply = redact(reply, removing: fragments)
                    if newUser != user || newReply != reply {
                        try store.execute("UPDATE turns SET user_message = ?, assistant_response = ? WHERE id = ?",
                                          [newUser, newReply, rowID])
                        changed += 1
                    }
                }
                for table in ["session_files", "session_refs", "forge_trajectory_events", "assistant_usage_events"]
                where store.columns(table).isSuperset(of: ["session_id", "turn_index"]) {
                    for turn in deletedTurns {
                        try store.execute("DELETE FROM \(table) WHERE session_id = ? AND turn_index = ?", [session, turn])
                    }
                }
                if hasSearch {
                    let deletedSources = Set(deletedTurns.map { "\(session):turn:\($0)" })
                    for row in try store.rows("SELECT rowid, source_id, content FROM search_index WHERE session_id = ?", [session]) {
                        guard let rowID = row[0] as? Int64 else { continue }
                        let content = row[2] as? String ?? ""
                        if let source = row[1] as? String, deletedSources.contains(source) {
                            try store.execute("DELETE FROM search_index WHERE rowid = ?", [rowID])
                            removedSearchRows = true
                            continue
                        }
                        let redacted = redact(content, removing: fragments)
                        if redacted != content {
                            try store.execute("UPDATE search_index SET content = ? WHERE rowid = ?", [redacted, rowID])
                            removedSearchRows = true
                        }
                    }
                }
                changed += try redactColumns(store, table: "checkpoints", session: session, fragments: fragments)
                changed += try redactColumns(store, table: "forge_trajectory_events", session: session, fragments: fragments)
                if store.columns("sessions").isSuperset(of: ["id", "summary"]),
                   let summary = try store.rows("SELECT summary FROM sessions WHERE id = ?", [session]).first?[0] as? String {
                    let redacted = redact(summary, removing: fragments)
                    if redacted != summary {
                        try store.execute("UPDATE sessions SET summary = ? WHERE id = ?", [redacted, session])
                        changed += 1
                    }
                }
            }
            try store.execute("COMMIT")
        } catch {
            try? store.execute("ROLLBACK")
            throw error
        }
        if removedSearchRows {
            try store.execute("INSERT INTO search_index(search_index) VALUES('optimize')")
        }
        try? store.execute("PRAGMA wal_checkpoint(PASSIVE)")
        return changed
    }

    private static func redactColumns(_ store: SQLiteStore, table: String, session: String,
                                      fragments: [String]) throws -> Int {
        let columns = store.columns(table)
        guard columns.contains("session_id"), columns.contains("id") else { return 0 }
        let textColumns = store.textColumns(table).filter { !["id", "session_id"].contains($0) }
        guard !textColumns.isEmpty else { return 0 }
        let list = textColumns.map { "\"\($0)\"" }.joined(separator: ", ")
        var changed = 0
        for row in try store.rows("SELECT id, \(list) FROM \(table) WHERE session_id = ?", [session]) {
            var updates: [(String, String)] = []
            for (offset, column) in textColumns.enumerated() {
                guard let value = row[offset + 1] as? String else { continue }
                let redacted = redact(value, removing: fragments)
                if redacted != value { updates.append((column, redacted)) }
            }
            guard !updates.isEmpty, let rowID = row[0] else { continue }
            let assignments = updates.map { "\"\($0.0)\" = ?" }.joined(separator: ", ")
            let arguments: [Any] = updates.map(\.1) + [rowID]
            try store.execute("UPDATE \(table) SET \(assignments) WHERE id = ?", arguments)
            changed += 1
        }
        return changed
    }

    // MARK: - Claude Code and Codex

    /// A Claude Code prompt: a `user` record with text (tool results continue the turn; a
    /// subagent's own prompts stay inside it).
    static func claudeTurnText(_ record: [String: Any]) -> String? {
        guard record["type"] as? String == "user", record["isSidechain"] as? Bool != true,
              let message = record["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        let texts = (message["content"] as? [[String: Any]] ?? []).compactMap { item -> String? in
            item["type"] as? String == "text" ? item["text"] as? String : nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// A Codex prompt: a user `message` response item, or its `user_message` event.
    static func codexTurnText(_ record: [String: Any]) -> String? {
        guard let payload = record["payload"] as? [String: Any] else { return nil }
        switch (record["type"] as? String, payload["type"] as? String) {
        case ("response_item", "message"):
            guard payload["role"] as? String == "user" else { return nil }
            let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            return texts.joined(separator: "\n")
        case ("event_msg", "user_message"):
            return payload["message"] as? String
        default:
            return nil
        }
    }

    static func claudeTranscript(_ session: String, in projects: URL) -> URL? {
        guard UUID(uuidString: session) != nil,
              let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        else { return nil }
        return folders.map { $0.appendingPathComponent("\(session).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func codexRollout(_ thread: String, in sessions: URL) -> URL? {
        guard UUID(uuidString: thread) != nil,
              let files = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) else { return nil }
        let suffix = "-\(thread.lowercased()).jsonl"
        for case let file as URL in files where file.lastPathComponent.lowercased().hasSuffix(suffix) {
            return file
        }
        return nil
    }
}

/// A minimal SQLite connection for editing another tool's database.
final class SQLiteStore {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteStoreError(message)
        }
        sqlite3_busy_timeout(handle, 10_000)
    }

    deinit { sqlite3_close(handle) }

    func columns(_ table: String) -> Set<String> {
        Set(((try? rows("PRAGMA table_info(\"\(table)\")")) ?? []).compactMap { $0[1] as? String })
    }

    /// Columns declared TEXT (or untyped), which may hold quoted prompts.
    func textColumns(_ table: String) -> [String] {
        ((try? rows("PRAGMA table_info(\"\(table)\")")) ?? []).compactMap { row in
            guard let name = row[1] as? String else { return nil }
            let type = (row[2] as? String ?? "").uppercased()
            return type.isEmpty || type.contains("TEXT") ? name : nil
        }
    }

    func execute(_ sql: String, _ arguments: [Any] = []) throws {
        _ = try rows(sql, arguments)
    }

    func rows(_ sql: String, _ arguments: [Any] = []) throws -> [[Any?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch argument {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            default: sqlite3_bind_null(statement, index)
            }
        }
        var result: [[Any?]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error() }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: return sqlite3_column_int64(statement, column)
                case SQLITE_FLOAT: return sqlite3_column_double(statement, column)
                case SQLITE_TEXT: return sqlite3_column_text(statement, column).map { String(cString: $0) }
                default: return nil
                }
            })
        }
        return result
    }

    private func error() -> SQLiteStoreError {
        SQLiteStoreError(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error")
    }
}

struct SQLiteStoreError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
