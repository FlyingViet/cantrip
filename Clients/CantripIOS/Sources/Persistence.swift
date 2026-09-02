import Foundation

/// Per-lane conversation persistence, including enough run identity to reconnect
/// after iOS suspends or terminates the app.
enum ChatStore {
    struct Snapshot: Codable {
        var turns: [ChatTurn]
        var previousResponseId: String?
        var conversationID: String?
        var gatewayIdentity: String?
        var pendingRun: PendingHermesRun?
        var activeRun: ActiveHermesRun?
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
        conversationID: String,
        gatewayIdentity: String?,
        pendingRun: PendingHermesRun?,
        activeRun: ActiveHermesRun?,
        for lane: ExecutionLane
    ) {
        let liveAssistantID = activeRun?.assistantTurnID ?? pendingRun?.assistantTurnID
        let cleaned = turns.map { turn -> ChatTurn in
            var copy = turn
            copy.streaming = turn.id == liveAssistantID
            return copy
        }
        let snap = Snapshot(
            turns: cleaned,
            previousResponseId: nil,
            conversationID: conversationID,
            gatewayIdentity: gatewayIdentity,
            pendingRun: pendingRun,
            activeRun: activeRun
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: fileURL(for: lane), options: .atomic)
    }

    static func load(for lane: ExecutionLane) -> Snapshot {
        migrateLegacyCopilotHistoryIfNeeded(for: lane)
        guard let data = try? Data(contentsOf: fileURL(for: lane)),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot(
                turns: [],
                previousResponseId: nil,
                conversationID: nil,
                gatewayIdentity: nil,
                pendingRun: nil,
                activeRun: nil
            )
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
        snapshot.pendingRun = nil
        snapshot.activeRun = nil
        guard let migrated = try? JSONEncoder().encode(snapshot) else { return }
        try? migrated.write(to: fileURL(for: lane), options: .atomic)
        try? FileManager.default.removeItem(at: legacyFileURL)
    }
}
