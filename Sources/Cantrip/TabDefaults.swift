import Foundation

/// The UserDefaults keys Cantrip keeps for each tab. Removing a tab goes through `removeAll`,
/// so a key added here can't be left behind.
enum TabDefaults {
    static func workdir(_ id: UUID) -> String { "workdir-\(id.uuidString)" }
    static func claudeSession(_ id: UUID) -> String { "claudeSessionID-\(id.uuidString)" }
    static func codexSession(_ id: UUID) -> String { "codexSessionID-\(id.uuidString)" }
    static func lastRunOutcome(_ id: UUID) -> String { "lastRunOutcome-\(id.uuidString)" }

    /// A council seat's native session, by seat and model so replacing a seat never resumes a
    /// different model's session.
    static func councilClaude(_ id: UUID, seat: Int, model: String) -> String {
        "\(councilClaudePrefix(id))-\(seat)-\(model)"
    }

    static func councilCodex(_ id: UUID, seat: Int, model: String) -> String {
        "\(councilCodexPrefix(id))-\(seat)-\(model)"
    }

    private static func councilClaudePrefix(_ id: UUID) -> String { "councilClaude-\(id.uuidString)" }
    private static func councilCodexPrefix(_ id: UUID) -> String { "councilCodex-\(id.uuidString)" }

    /// Every key above for `id`. Council seats are found by prefix, whatever their count or models.
    static func removeAll(for id: UUID, in defaults: UserDefaults = .standard) {
        for key in [workdir(id), claudeSession(id), codexSession(id), lastRunOutcome(id)] {
            defaults.removeObject(forKey: key)
        }
        removeCouncilSeats(for: id, in: defaults)
    }

    /// Council seats' saved sessions for `id`, so a new conversation doesn't resume them.
    static func removeCouncilSeats(for id: UUID, in defaults: UserDefaults = .standard) {
        let council = [councilClaudePrefix(id), councilCodexPrefix(id)]
        for key in defaults.dictionaryRepresentation().keys where council.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
