import Foundation

/// Local persistence for the conversation so the transcript survives app
/// restarts — reopening shows the prior history (and keeps chaining the same
/// server-side session via `previousResponseId`) instead of a blank chat.
enum ChatStore {
    struct Snapshot: Codable {
        var turns: [ChatTurn]
        var previousResponseId: String?
    }

    private static var directoryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for lane: ExecutionLane) -> URL {
        directoryURL.appendingPathComponent("hermes_chat_\(lane.rawValue).json")
    }

    private static var legacyFileURL: URL {
        directoryURL.appendingPathComponent("hermes_chat.json")
    }

    static func save(
        turns: [ChatTurn],
        previousResponseId: String?,
        for lane: ExecutionLane
    ) {
        // Don't persist an in-flight (streaming) turn; mark it settled.
        let cleaned = turns.filter { !$0.streaming || !$0.isEmpty }.map { t -> ChatTurn in
            var c = t; c.streaming = false; return c
        }
        let snap = Snapshot(turns: cleaned, previousResponseId: previousResponseId)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: fileURL(for: lane), options: .atomic)
    }

    static func load(for lane: ExecutionLane) -> Snapshot {
        migrateLegacyCopilotHistoryIfNeeded(for: lane)
        guard let data = try? Data(contentsOf: fileURL(for: lane)),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot(turns: [], previousResponseId: nil)
        }
        return snap
    }

    static func clear(for lane: ExecutionLane) {
        try? FileManager.default.removeItem(at: fileURL(for: lane))
    }

    private static func migrateLegacyCopilotHistoryIfNeeded(for lane: ExecutionLane) {
        guard lane == .copilot,
              !FileManager.default.fileExists(atPath: fileURL(for: lane).path),
              FileManager.default.fileExists(atPath: legacyFileURL.path) else {
            return
        }
        guard let data = try? Data(contentsOf: legacyFileURL),
              var snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        // The legacy response chain used the gateway's implicit global route.
        // Preserve the visible transcript, but start a new explicit Copilot chain.
        snapshot.previousResponseId = nil
        guard let migrated = try? JSONEncoder().encode(snapshot) else { return }
        try? migrated.write(to: fileURL(for: lane), options: .atomic)
        try? FileManager.default.removeItem(at: legacyFileURL)
    }
}
