import Foundation

/// Rules Cantrip keeps for a folder reach every backend through its own guidance channel:
/// Copilot's system message, Codex's developer instructions and Antigravity's first message
/// (Claude Code's appended system prompt is covered with its launch fixture).
extension SessionTabTests {
    @MainActor
    static func testFolderRulesReachEveryBackend() throws {
        requireTemporaryHome()
        let fm = FileManager.default
        let project = fm.homeDirectoryForCurrentUser.appendingPathComponent("rules-\(UUID().uuidString.prefix(8))")
        let app = project.appendingPathComponent("app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let store = FolderInstructions()
        let rule = try store.save(folder: project.path, body: "FOLDER-RULE-MARKER: log changes in the notes.",
                                  mirror: project.appendingPathComponent("CLAUDE.md").path)
        defer {
            try? fm.removeItem(at: rule.file)
            try? fm.removeItem(at: project)
        }

        let copilot = CopilotBackend()
        let guidance = { (dir: URL) in copilot.configuration(workdir: dir.path).json["systemGuidance"] as? String ?? "" }
        precondition(guidance(app).contains("FOLDER-RULE-MARKER") && guidance(app).contains("Rules for work under"),
                     "Copilot's system message carries the folder's rules")
        precondition(!guidance(project).contains("FOLDER-RULE-MARKER"),
                     "Where Copilot reads the CLAUDE.md mirror itself, it isn't sent twice")
        precondition(copilot.configuration(workdir: app.path) != copilot.configuration(workdir: fm.temporaryDirectory.path),
                     "Rules are part of the runtime configuration, so an edit restarts it")

        let codex = CodexBackend(persistKey: "folder-rules-\(UUID())")
        precondition(codex.developerInstructions(workdir: app.path).contains("FOLDER-RULE-MARKER")
                     && !codex.developerInstructions(workdir: fm.temporaryDirectory.path).contains("FOLDER-RULE-MARKER"),
                     "Codex's developer instructions carry the rules for its folder only")

        let rules = store.guidance(for: app.path)
        var (first, digest) = AntigravityBackend.withFolderRules("hello", rules: rules, newConversation: true, delivered: nil)
        precondition(first.hasPrefix(rules!) && first.hasSuffix("hello") && !digest.isEmpty, "Antigravity's first message carries them")
        let (next, same) = AntigravityBackend.withFolderRules("again", rules: rules, newConversation: false, delivered: digest)
        precondition(next == "again" && same == digest, "Later messages don't repeat them")
        (first, digest) = AntigravityBackend.withFolderRules("later", rules: rules! + " Edited.", newConversation: false, delivered: digest)
        precondition(first.contains("changed") && first.contains("Edited.") && digest != same, "An edit is sent once more")
        let (older, _) = AntigravityBackend.withFolderRules("resumed", rules: rules, newConversation: false, delivered: nil)
        precondition(older.contains("FOLDER-RULE-MARKER"), "A conversation from before the rules existed gets them once")
        let (none, empty) = AntigravityBackend.withFolderRules("plain", rules: nil, newConversation: true, delivered: nil)
        precondition(none == "plain" && empty.isEmpty, "No rules, no change")
        print("Folder rules: Copilot, Codex and Antigravity get the folder's rules once, without the mirror twice")
    }
}
