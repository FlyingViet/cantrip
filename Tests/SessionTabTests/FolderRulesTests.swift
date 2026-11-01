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

    /// Paired clients list the skills library, turn a skill off and on, relink and start a drift
    /// check through /api/v1/skills.
    @MainActor
    static func testSkillsAPI() async throws {
        requireTemporaryHome()
        let fm = FileManager.default
        let library = SkillsLibrary()
        let draft = fm.homeDirectoryForCurrentUser.appendingPathComponent("drafts-\(UUID().uuidString.prefix(8))/weather-lookup")
        try fm.createDirectory(at: draft, withIntermediateDirectories: true)
        try "---\nname: weather-lookup\ndescription: Looks up the weather.\n---\nSay it's sunny.\n"
            .write(to: draft.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        // Leave the home as found: other tests run agents there and check it has no .agents folder.
        let made = [library.home.appendingPathComponent(".agents"), library.home.appendingPathComponent(".claude/skills"),
                    library.folder.deletingLastPathComponent()].filter { !fm.fileExists(atPath: $0.path) }
        try library.add(source: draft)
        defer {
            try? fm.removeItem(at: library.skillFolder("weather-lookup"))
            _ = try? library.sync()
            try? fm.removeItem(at: draft.deletingLastPathComponent())
            for folder in made { try? fm.removeItem(at: folder) }
        }

        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager)
        defer { withExtendedLifetime(manager) {} }
        let port = Int.random(in: 20_000...45_000), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ method: String = "GET", _ body: [String: Any]? = nil, authorized: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/skills")!)
            request.httpMethod = method
            if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
        }
        func skill(_ payload: [String: Any]) -> [String: Any]? {
            (payload["skills"] as? [[String: Any]])?.first { $0["name"] as? String == "weather-lookup" }
        }

        let anonymous = try await call(authorized: false)
        precondition(anonymous.0 == 401, "Pairing is required")
        let listed = try await call()
        precondition(listed.0 == 200 && skill(listed.1)?["enabled"] as? Bool == true
                     && skill(listed.1)?["backends"] as? [String] == SkillsLibrary.allBackends
                     && skill(listed.1)?["description"] as? String == "Looks up the weather."
                     && listed.1["backends"] as? [String] == SkillsLibrary.allBackends && listed.1["rules"] is [Any],
                     "GET lists each skill and which backends see it: \(listed)")
        let rendered = String(decoding: try JSONSerialization.data(withJSONObject: listed.1), as: UTF8.self)
        precondition(!rendered.contains("sunny"),
                     "Never a skill's contents")
        let off = try await call("POST", ["action": "setEnabled", "name": "weather-lookup", "enabled": false])
        precondition(off.0 == 200 && skill(off.1)?["enabled"] as? Bool == false && (skill(off.1)?["backends"] as? [String])?.isEmpty == true
                     && !fm.fileExists(atPath: library.targets[0].folder.appendingPathComponent("weather-lookup").path),
                     "Turning a skill off unlinks it for every backend: \(off)")
        let on = try await call("POST", ["action": "setEnabled", "name": "weather-lookup", "enabled": true])
        precondition(on.0 == 200 && skill(on.1)?["backends"] as? [String] == SkillsLibrary.allBackends, "And on again: \(on)")
        let sync = try await call("POST", ["action": "sync"])
        precondition(sync.0 == 200 && (sync.1["messages"] as? [String])?.isEmpty == false, "Relink reports what it did: \(sync)")
        let check = try await call("POST", ["action": "check"])
        precondition(check.0 == 200 && check.1["drift"] is [Any], "A drift check starts: \(check)")
        let unknown = try await call("POST", ["action": "nope"])
        let missing = try await call("POST", ["action": "setEnabled", "name": "not-a-skill", "enabled": true])
        precondition(unknown.0 == 400 && missing.0 == 400 && (missing.1["error"] as? String)?.contains("no skill named") == true,
                     "Bad requests are refused with a reason: \(unknown) \(missing)")
        print("Skills API: list, on/off, relink, drift check and errors passed")
    }
}
