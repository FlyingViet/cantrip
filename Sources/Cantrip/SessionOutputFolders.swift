import Darwin
import Foundation

/// Agent output folders each Cantrip session may preview images from remotely.
///
/// Copilot CLI gives every SDK session its own `~/.copilot/session-state/<id>/files/`.
/// A tab gets a new CLI session whenever its runtime restarts, so Cantrip records every
/// CLI session a tab (or Home run) used. A session's previews resolve only against its
/// own recorded folders, never another session's.
final class SessionOutputFolders: @unchecked Sendable {
    static var shared = SessionOutputFolders()
    static let maximumPerSession = 64

    let file: URL
    let copilotStateRoot: URL
    private let lock = NSLock()
    private var loaded = false
    private var sessions: [UUID: [String]] = [:]
    private var backfilled = false

    init(
        file: URL = RemoteGeneratedImages.sourceRoot.appendingPathComponent("session-output-folders.json"),
        copilotStateRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/session-state", isDirectory: true)
    ) {
        self.file = file
        self.copilotStateRoot = copilotStateRoot
    }

    /// CLI session IDs become folder names, so only canonical UUIDs are accepted.
    static func cliSessionID(_ raw: String) -> String? {
        UUID(uuidString: raw.trimmingCharacters(in: .whitespaces))?.uuidString.lowercased()
    }

    func folder(forCLISession id: String) -> URL {
        copilotStateRoot.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
    }

    func roots(for sessionID: UUID) -> [URL] {
        lock.withLock {
            loadLocked()
            return (sessions[sessionID] ?? []).reversed().map(folder(forCLISession:))
        }
    }

    func record(_ rawCLISessionID: String, for sessionID: UUID) {
        guard let id = Self.cliSessionID(rawCLISessionID) else { return }
        lock.withLock {
            loadLocked()
            var ids = sessions[sessionID] ?? []
            guard !ids.contains(id) else { return }
            ids.append(id)
            sessions[sessionID] = Array(ids.suffix(Self.maximumPerSession))
            saveLocked()
        }
    }

    /// A finished Home run's messages move into the background log, so its folders do too.
    func transfer(from source: UUID, to destination: UUID) {
        lock.withLock {
            loadLocked()
            guard let moved = sessions.removeValue(forKey: source), !moved.isEmpty else { return }
            let existing = sessions[destination] ?? []
            sessions[destination] = Array((existing + moved.filter { !existing.contains($0) })
                .suffix(Self.maximumPerSession))
            saveLocked()
        }
    }

    func remove(_ sessionID: UUID) {
        lock.withLock {
            loadLocked()
            guard sessions.removeValue(forKey: sessionID) != nil else { return }
            saveLocked()
        }
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var version = 1
        var backfilled: Bool
        var sessions: [String: [String]]
    }

    private func loadLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        backfilled = stored.backfilled
        for (key, ids) in stored.sessions {
            guard let sessionID = UUID(uuidString: key) else { continue }
            let valid = ids.compactMap(Self.cliSessionID)
            if !valid.isEmpty { sessions[sessionID] = Array(valid.suffix(Self.maximumPerSession)) }
        }
    }

    private func saveLocked() {
        let stored = Stored(
            backfilled: backfilled,
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.key.uuidString, $0.value) })
        )
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            Log.write("output-folders: save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - One-time backfill

    /// Older builds never recorded CLI session IDs. Assign a folder that a transcript
    /// already references only when that CLI session's prompts contain user messages
    /// unique to exactly one referencing session. Runs once; never guesses.
    func backfillIfNeeded(transcripts directory: URL) {
        let known: Set<String>? = lock.withLock {
            loadLocked()
            return backfilled ? nil : Set(sessions.values.joined())
        }
        guard let known else { return }
        let found = Self.backfill(transcripts: directory, stateRoot: copilotStateRoot, known: known)
        lock.withLock {
            for (sessionID, ids) in found {
                var current = sessions[sessionID] ?? []
                for id in ids where !current.contains(id) { current.insert(id, at: 0) }
                sessions[sessionID] = Array(current.suffix(Self.maximumPerSession))
            }
            backfilled = true
            saveLocked()
        }
        if !found.isEmpty {
            Log.write("output-folders: backfilled \(found.values.map(\.count).reduce(0, +)) folders "
                + "for \(found.count) sessions")
        }
    }

    static let minimumEvidenceLength = 24
    private static let maximumCandidates = 128
    private static let maximumScanBytes: off_t = 1 << 30
    private static let referencePattern = try! NSRegularExpression(
        pattern: #"/session-state/([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})/files/"#
    )

    static func backfill(transcripts directory: URL, stateRoot: URL,
                         known: Set<String>) -> [UUID: [String]] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [:] }
        var userTexts: [UUID: Set<String>] = [:]
        var references: [String: Set<UUID>] = [:]
        for url in files where url.pathExtension == "json" {
            guard let sessionID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for message in messages {
                guard let text = message["text"] as? String else { continue }
                switch message["role"] as? String {
                case "user":
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count >= minimumEvidenceLength { userTexts[sessionID, default: []].insert(trimmed) }
                case "assistant":
                    let string = text as NSString
                    for match in referencePattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                        guard let id = cliSessionID(string.substring(with: match.range(at: 1))),
                              !known.contains(id) else { continue }
                        references[id, default: []].insert(sessionID)
                    }
                default: continue
                }
            }
        }
        // Text sent from several sessions (copied prompts, handoffs) proves nothing.
        var owners: [String: Int] = [:]
        for texts in userTexts.values { for text in texts { owners[text, default: 0] += 1 } }
        let evidence = userTexts.mapValues { $0.filter { owners[$0] == 1 } }

        var assigned: [UUID: [String]] = [:]
        for (id, referencing) in references.sorted(by: { $0.key < $1.key }).prefix(maximumCandidates) {
            let folder = stateRoot.appendingPathComponent(id, isDirectory: true)
            guard isCantripSession(folder) else { continue }
            let prompts = userPrompts(folder.appendingPathComponent("events.jsonl"))
            guard !prompts.isEmpty else { continue }
            let scores = referencing.map { sessionID -> (UUID, Int) in
                let score = (evidence[sessionID] ?? []).filter { text in
                    prompts.contains { $0.range(of: text, options: .literal) != nil }
                }.count
                return (sessionID, score)
            }
            guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0,
                  scores.filter({ $0.1 == best.1 }).count == 1 else { continue }
            assigned[best.0, default: []].append(id)
        }
        return assigned
    }

    private static func isCantripSession(_ folder: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent("workspace.yaml")),
              let data = try? handle.read(upToCount: 64 << 10) else { return false }
        try? handle.close()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "client_name: Cantrip" }
    }

    /// Every user prompt the CLI session received, read line by line without loading the
    /// whole (often very large) event log.
    private static func userPrompts(_ events: URL) -> [String] {
        guard let stream = fopen(events.path, "r") else { return [] }
        defer { fclose(stream) }
        let prefix = #"{"type":"user.message""#
        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(line) }
        var prompts: [String] = []
        while ftello(stream) < maximumScanBytes {
            let length = getline(&line, &capacity, stream)
            guard length > 0, let line else { break }
            guard length > prefix.utf8.count, strncmp(line, prefix, prefix.utf8.count) == 0,
                  let event = try? JSONSerialization.jsonObject(
                    with: Data(bytesNoCopy: UnsafeMutableRawPointer(line), count: length, deallocator: .none)
                  ) as? [String: Any],
                  let content = (event["data"] as? [String: Any])?["content"] as? String else { continue }
            prompts.append(content)
        }
        return prompts
    }
}
