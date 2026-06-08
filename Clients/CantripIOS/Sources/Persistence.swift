import Foundation

/// Local persistence for the conversation so the transcript survives app
/// restarts — reopening shows the prior history (and keeps chaining the same
/// server-side session via `previousResponseId`) instead of a blank chat.
enum ChatStore {
    struct Snapshot: Codable {
        var turns: [ChatTurn]
        var previousResponseId: String?
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hermes_chat.json")
    }

    static func save(turns: [ChatTurn], previousResponseId: String?) {
        // Don't persist an in-flight (streaming) turn; mark it settled.
        let cleaned = turns.filter { !$0.streaming || !$0.isEmpty }.map { t -> ChatTurn in
            var c = t; c.streaming = false; return c
        }
        let snap = Snapshot(turns: cleaned, previousResponseId: previousResponseId)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> Snapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot(turns: [], previousResponseId: nil)
        }
        return snap
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
