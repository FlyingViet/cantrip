import Foundation
import SQLite3

/// An optional full-text index over the memory vault, used to pick the RETRIEVED snippets.
///
/// The Markdown files stay the source of truth: this SQLite FTS5 database is derived from
/// them, kept outside the vault, refreshed when a file's modification date or size changes,
/// and can be deleted and rebuilt at any time. Notes and session logs are split into chunks
/// by heading and paragraph; fenced code, log lines and lines repeated across a file are left
/// out, so a pasted log can't win on sheer word count. Chunks rank by BM25 (Porter-stemmed),
/// with a boost for recent session entries. It never stores queries and makes no network calls.
final class MemorySearchIndex {
    struct Hit: Equatable {
        /// The file's name, e.g. "deploy.md" or "2026-01-05.md".
        let file: String
        let heading: String
        let text: String
        let isSession: Bool
        let score: Double

        /// The snippet as injected: its heading for context, then the chunk, within `limit`.
        func snippet(limit: Int) -> String {
            let head = heading.isEmpty ? "" : "\(heading)\n"
            return String((head + text).prefix(limit))
        }
    }

    struct Chunk: Equatable {
        let heading: String
        let body: String
        /// Seconds since 1970: a session entry's day and time, or a note's modification date.
        let stamp: Double
    }

    struct RefreshResult: Equatable {
        var indexed = 0
        var removed = 0
        var chunks = 0
    }

    enum Failure: Error, CustomStringConvertible {
        case sqlite(String)
        var description: String { if case .sqlite(let message) = self { return message }; return "" }
    }

    static let schemaVersion: Int32 = 1
    /// Chunks aim for this size; longer paragraphs are split at line or word boundaries.
    static let chunkTarget = 700
    static let maximumFileBytes = 16 << 20
    /// Session entries this many days old get half their recency boost.
    static let sessionHalfLifeDays = 7.0
    static let sessionBoost = 0.6
    /// Curated notes outrank a session entry of equal relevance unless it's from the last week or so.
    static let noteWeight = 1.25

    /// Where Cantrip keeps the index: `~/Library/Application Support/Cantrip/memory-index.sqlite`.
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cantrip/memory-index.sqlite")
    }

    let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()

    init(url: URL = MemorySearchIndex.defaultURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw Failure.sqlite(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        do { try prepareSchema() } catch { close(); throw error }
    }

    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if let db { sqlite3_close(db) }
        db = nil
    }

    /// Deletes the index and its WAL files. The vault is untouched.
    static func remove(at url: URL = MemorySearchIndex.defaultURL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    // MARK: - Refresh

    /// Brings the index up to date with `vault`: notes at its top level (except the always-loaded
    /// MEMORY.md and USER.md) and `sessions/*.md`. Only files whose modification date or size
    /// changed are read again; files that are gone are dropped.
    @discardableResult
    func refresh(vault: URL) throws -> RefreshResult {
        lock.lock(); defer { lock.unlock() }
        let root = vault.standardizedFileURL.resolvingSymlinksInPath()
        var sources: [(relative: String, url: URL)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        where url.pathExtension.lowercased() == "md" && !["MEMORY.md", "USER.md"].contains(url.lastPathComponent) {
            sources.append((url.lastPathComponent, url))
        }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        for url in (try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: keys)) ?? []
        where url.pathExtension.lowercased() == "md" {
            sources.append(("sessions/" + url.lastPathComponent, url))
        }

        try execute("BEGIN IMMEDIATE")
        do {
            if try meta("vault") != root.path {
                try execute("DELETE FROM chunks")
                try execute("DELETE FROM files")
                try run("INSERT OR REPLACE INTO meta(key, value) VALUES ('vault', ?)", [root.path])
            }
            var known: [String: (mtime: Double, size: Int64)] = [:]
            try query("SELECT path, mtime, size FROM files") { row in
                known[text(row, 0)] = (sqlite3_column_double(row, 1), sqlite3_column_int64(row, 2))
            }
            var result = RefreshResult()
            var present = Set<String>()
            for source in sources {
                guard let values = try? source.url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                present.insert(source.relative)
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                let size = Int64(values.fileSize ?? 0)
                if let old = known[source.relative], old.mtime == mtime, old.size == size { continue }
                let isSession = source.relative.hasPrefix("sessions/")
                var chunks: [Chunk] = []
                if size <= Self.maximumFileBytes, let data = try? Data(contentsOf: source.url) {
                    let base = isSession ? Self.sessionDay(source.url.lastPathComponent) ?? mtime : mtime
                    chunks = Self.chunks(of: String(decoding: data, as: UTF8.self), isSession: isSession, stamp: base)
                }
                try run("DELETE FROM chunks WHERE path = ?", [source.relative])
                for chunk in chunks {
                    try run("INSERT INTO chunks(body, heading, path, stamp, session) VALUES (?, ?, ?, ?, ?)",
                            [chunk.body, chunk.heading, source.relative, chunk.stamp, isSession ? 1 : 0])
                }
                try run("INSERT OR REPLACE INTO files(path, mtime, size) VALUES (?, ?, ?)",
                        [source.relative, mtime, size])
                result.indexed += 1
                result.chunks += chunks.count
            }
            for path in known.keys where !present.contains(path) {
                try run("DELETE FROM chunks WHERE path = ?", [path])
                try run("DELETE FROM files WHERE path = ?", [path])
                result.removed += 1
            }
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Search

    /// The best chunks for `terms` (already lowercased words), at most one per file, highest
    /// score first. `now` sets how recent a session entry is.
    func search(terms: [String], limit: Int = 3, now: Date = Date()) throws -> [Hit] {
        lock.lock(); defer { lock.unlock() }
        let words = terms.filter { !$0.isEmpty && $0.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) }
        guard !words.isEmpty, limit > 0 else { return [] }
        let match = words.map { "\"\($0)\"" }.joined(separator: " OR ")
        var rows: [Hit] = []
        try query("""
            SELECT path, heading, body, stamp, session, bm25(chunks, 1.0, 0.5) AS rank
            FROM chunks WHERE chunks MATCH ? ORDER BY rank LIMIT 300
            """, [match]) { row in
            let path = text(row, 0)
            let isSession = sqlite3_column_int(row, 4) == 1
            let relevance = -sqlite3_column_double(row, 5)
            let age = max(0, now.timeIntervalSince1970 - sqlite3_column_double(row, 3)) / 86_400
            let weight = isSession
                ? 1 + Self.sessionBoost * pow(0.5, age / Self.sessionHalfLifeDays)
                : Self.noteWeight
            rows.append(Hit(file: (path as NSString).lastPathComponent, heading: text(row, 1),
                            text: text(row, 2), isSession: isSession, score: relevance * weight))
        }
        rows.sort { $0.score != $1.score ? $0.score > $1.score : $0.file > $1.file }
        var hits: [Hit] = []
        var chosenWords: [Set<String>] = []
        for row in rows where !hits.contains(where: { $0.file == row.file }) {
            let wordSet = Self.wordSet(row.text)
            if chosenWords.contains(where: { Self.similarity($0, wordSet) >= 0.8 }) { continue }
            hits.append(row)
            chosenWords.append(wordSet)
            if hits.count == limit { break }
        }
        return hits
    }

    // MARK: - Chunking

    /// Splits Markdown into chunks: paragraphs grouped under their heading up to `chunkTarget`
    /// characters. Fenced code, log lines (timestamped or repeated three or more times in the
    /// file) and very long unbroken tokens are skipped; identical chunks are kept once.
    static func chunks(of text: String, isSession: Bool, stamp: Double) -> [Chunk] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let keys = lines.map(normalized)
        var repeats: [String: Int] = [:]
        for key in keys where key.count >= 16 { repeats[key, default: 0] += 1 }
        var result: [Chunk] = []
        var seen = Set<String>()
        var heading = ""
        var headingStamp = stamp
        var paragraphs: [String] = []
        var paragraph: [Substring] = []
        var inFence = false

        func endParagraph() {
            let body = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            guard !body.isEmpty else { return }
            paragraphs.append(contentsOf: split(body))
        }
        func endSection() {
            endParagraph()
            var current = ""
            func emit() {
                let body = current.trimmingCharacters(in: .whitespacesAndNewlines)
                current = ""
                let key = normalized(Substring(body))
                guard key.filter({ $0 != " " }).count >= 12, seen.insert(key).inserted else { return }
                result.append(Chunk(heading: heading, body: body, stamp: headingStamp))
            }
            for piece in paragraphs {
                if !current.isEmpty, current.count + piece.count + 2 > chunkTarget { emit() }
                current += current.isEmpty ? piece : "\n\n" + piece
            }
            emit()
            paragraphs = []
        }

        for (line, key) in zip(lines, keys) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                endParagraph()
                continue
            }
            if inFence { continue }
            if trimmed.hasPrefix("#"), let title = headingTitle(trimmed) {
                endSection()
                heading = String(line.trimmingCharacters(in: .whitespaces))
                if isSession, let minutes = minutesOfDay(title) { headingStamp = stamp + minutes * 60 }
                continue
            }
            if trimmed.isEmpty { endParagraph(); continue }
            if isLogLine(trimmed) || (repeats[key] ?? 0) >= 3 || hasRunawayToken(trimmed) { continue }
            paragraph.append(line)
        }
        endSection()
        return result
    }

    /// A paragraph longer than the target, cut at line breaks, then at spaces.
    private static func split(_ body: String) -> [String] {
        guard body.count > chunkTarget else { return [body] }
        var pieces: [String] = []
        var current = ""
        for line in body.split(separator: "\n") {
            var rest = Substring(line)
            while rest.count > chunkTarget {
                let window = rest.prefix(chunkTarget)
                let cut = window.lastIndex(of: " ") ?? window.endIndex
                let head = rest[rest.startIndex..<cut]
                if !current.isEmpty { pieces.append(current); current = "" }
                pieces.append(String(head))
                rest = rest[cut...].drop { $0 == " " }
            }
            if !current.isEmpty, current.count + rest.count + 1 > chunkTarget { pieces.append(current); current = "" }
            current += current.isEmpty ? String(rest) : "\n" + rest
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func headingTitle(_ line: Substring) -> Substring? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return rest.drop { $0 == " " }
    }

    /// "14:24 · Copilot" -> 864 (minutes after midnight).
    private static func minutesOfDay(_ title: Substring) -> Double? {
        let digits = Array(title.prefix(5))
        guard digits.count == 5, digits[2] == ":",
              let hours = Int(String(digits[0...1])), let minutes = Int(String(digits[3...4])),
              (0..<24).contains(hours), (0..<60).contains(minutes) else { return nil }
        return Double(hours * 60 + minutes)
    }

    /// A session log's day ("2026-01-05.md") as local midnight.
    static func sessionDay(_ name: String) -> Double? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(name.prefix(10)))?.timeIntervalSince1970
    }

    private static let logPattern = try! NSRegularExpression(pattern: #"""
        ^\[?(?:\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}|\d{1,2}:\d{2}:\d{2}|[A-Z][a-z]{2} +\d{1,2} \d{2}:\d{2}:\d{2})
        """#.trimmingCharacters(in: .whitespacesAndNewlines))

    /// A line that starts with a timestamp: "14:24:31.620 [subsystem] …", "2026-01-05T08:46:17Z …".
    static func isLogLine(_ line: Substring) -> Bool {
        let head = String(line.prefix(32))
        return logPattern.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) != nil
    }

    /// Hashes, base64 and minified blobs: a single run of 120+ characters without a space.
    private static func hasRunawayToken(_ line: Substring) -> Bool {
        guard line.count >= 120 else { return false }
        var run = 0
        for character in line {
            run = character == " " ? 0 : run + 1
            if run >= 120 { return true }
        }
        return false
    }

    /// Lowercased words without digits, so lines differing only in numbers compare equal.
    static func normalized(_ line: Substring) -> String {
        var out = ""
        var space = false
        for scalar in line.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                if space, !out.isEmpty { out.append(" ") }
                space = false
                out.unicodeScalars.append(scalar)
            } else {
                space = true
            }
        }
        return out.lowercased()
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(normalized(Substring(text)).split(separator: " ").map(String.init))
    }

    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    // MARK: - SQLite

    private func prepareSchema() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        // Deleted chunks (a message deleted from a session log) are zeroed, not left in free pages.
        try execute("PRAGMA secure_delete=ON")
        var version: Int32 = 0
        try query("PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
        if version != Self.schemaVersion {
            try execute("DROP TABLE IF EXISTS chunks")
            try execute("DROP TABLE IF EXISTS files")
            try execute("DROP TABLE IF EXISTS meta")
        }
        try execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, mtime REAL NOT NULL, size INTEGER NOT NULL)")
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
                body, heading, path UNINDEXED, stamp UNINDEXED, session UNINDEXED,
                tokenize = 'porter unicode61 remove_diacritics 2')
            """)
        // Also drop a deleted chunk's words from the full-text index (SQLite 3.42+).
        try? execute("INSERT INTO chunks(chunks, rank) VALUES ('secure-delete', 1)")
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    private func meta(_ key: String) throws -> String? {
        var value: String?
        try query("SELECT value FROM meta WHERE key = ?", [key]) { value = text($0, 0) }
        return value
    }

    private func error() -> Failure {
        .sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "the index is closed")
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw error() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func run(_ sql: String, _ values: [Any]) throws {
        try query(sql, values) { _ in }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func query(_ sql: String, _ values: [Any] = [], row: (OpaquePointer) -> Void) throws {
        guard let db else { throw error() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Double: sqlite3_bind_double(statement, index, value)
            default: sqlite3_bind_null(statement, index)
            }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { row(statement); continue }
            guard step == SQLITE_DONE else { throw error() }
            return
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
