import Foundation

/// The skills library and folder rules as Settings and the Remote clients see them: which backend
/// sees each skill, problems, and drift in the repositories' rule files.
@MainActor
final class SkillsHub: ObservableObject {
    static let shared = SkillsHub()

    @Published private(set) var skills: [SkillsLibrary.Status] = []
    @Published private(set) var rules: [FolderInstructions.Rule] = []
    @Published private(set) var drift: [FolderInstructions.Finding] = []
    @Published private(set) var driftCheckedAt: Date?
    @Published private(set) var checking = false
    @Published private(set) var messages: [String] = []

    /// How old a drift check may be before a Remote client's visit starts another one.
    static let driftMaxAge: TimeInterval = 600

    func refresh() {
        skills = SkillsLibrary().list()
        rules = FolderInstructions().rules()
    }

    func setEnabled(_ name: String, _ enabled: Bool) throws {
        messages = try SkillsLibrary().setEnabled(name, enabled).lines
        refresh()
    }

    func sync() throws {
        messages = try SkillsLibrary().sync().lines
        if messages.isEmpty { messages = ["Every skill is linked as it should be."] }
        refresh()
    }

    /// Runs the drift check off the main thread (it asks git, and GitHub for public repositories).
    func checkDrift() {
        guard !checking else { return }
        checking = true
        Task.detached(priority: .utility) {
            let findings = FolderInstructions().check()
            await MainActor.run {
                self.drift = findings
                self.driftCheckedAt = Date()
                self.checking = false
            }
        }
    }

    func checkDriftIfStale() {
        if driftCheckedAt.map({ Date().timeIntervalSince($0) > Self.driftMaxAge }) ?? true { checkDrift() }
    }

    func remotePayload() -> [String: Any] {
        let library = SkillsLibrary()
        let instructions = FolderInstructions()
        var payload: [String: Any] = [
            "library": SkillsLibrary.tilde(library.folder.path, home: library.home),
            "backends": SkillsLibrary.allBackends,
            "skills": skills.map(\.json),
            "rules": rules.map { rule -> [String: Any] in
                var item: [String: Any] = ["folder": instructions.tilde(rule.folder),
                                           "lines": rule.body.isEmpty ? 0 : rule.body.components(separatedBy: "\n").count]
                if let mirror = rule.mirror { item["mirror"] = instructions.tilde(mirror) }
                return item
            },
            "drift": drift.map { ["path": $0.path, "problem": $0.problem] },
            "checking": checking,
        ]
        if let driftCheckedAt { payload["driftCheckedAt"] = ISO8601DateFormatter().string(from: driftCheckedAt) }
        if !messages.isEmpty { payload["messages"] = messages }
        return payload
    }
}
