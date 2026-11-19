import Foundation

/// The size of a Copilot CLI session's saved history, which decides whether a new runtime resumes it.
///
/// Resuming replays the session's whole event log (`events.jsonl`, including everything before its
/// compactions and every image the agent viewed), and the runtime keeps about 6.5 times the log's
/// size in memory: a 98 MB log resumed into 806 MB, a 254 MB one into 2.2 GB, against 163 MB for a
/// new session (Copilot CLI 1.0.113, 2026-11-19). Past `maximumResumedBytes`, a tab's next runtime
/// starts a new session instead, seeded with the conversation's recap (`initialPrompt`), as when
/// its saved session can't be resumed; the tab and its visible history are unchanged.
enum CopilotSessionHistory {
    /// About 0.5 GB once resumed.
    static let maximumResumedBytes: Int64 = 64 << 20

    /// The CLI's session folder: `$COPILOT_HOME/session-state`, else `~/.copilot/session-state`.
    static func folder(environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let base = environment["COPILOT_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".copilot")
        return base.appendingPathComponent("session-state", isDirectory: true)
    }

    /// The session's event log size; nil when there's none (or the ID isn't a plain name).
    static func bytes(of sessionID: String, in folder: URL = folder()) -> Int64? {
        guard !sessionID.isEmpty, !sessionID.contains("/"), sessionID != ".", sessionID != ".." else { return nil }
        let log = folder.appendingPathComponent(sessionID).appendingPathComponent("events.jsonl")
        return (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.int64Value
    }

    /// The history's size when it is too large to resume; nil when the session can resume.
    static func tooLargeToResume(_ sessionID: String, in folder: URL = folder(),
                                 limit: Int64 = maximumResumedBytes) -> Int64? {
        guard let size = bytes(of: sessionID, in: folder), size > limit else { return nil }
        return size
    }
}
