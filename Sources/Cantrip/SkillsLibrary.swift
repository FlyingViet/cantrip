import Foundation

/// Cantrip's skills library: one folder of skills (`~/Library/Application Support/Cantrip/skills`,
/// a local git repository for history, never pushed) that every backend reads through links:
/// `~/.agents/skills/<name>` for Copilot, Codex and Antigravity, `~/.claude/skills/<name>` for
/// Claude Code. A manifest records the links Cantrip made; anything else in those folders (a
/// CLI's or an installer's own skills) is never changed, and a name clash is reported.
struct SkillsLibrary {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    var folder: URL { home.appendingPathComponent("Library/Application Support/Cantrip/skills", isDirectory: true) }
    var manifestFile: URL { home.appendingPathComponent("Library/Application Support/Cantrip/skills-manifest.json") }

    /// Where each backend family looks for personal skills.
    struct Target: Equatable {
        let id: String
        let folder: URL
        let backends: [String]
    }

    var targets: [Target] {
        [Target(id: "agents", folder: home.appendingPathComponent(".agents/skills", isDirectory: true),
                backends: ["Copilot", "Codex", "Antigravity"]),
         Target(id: "claude", folder: home.appendingPathComponent(".claude/skills", isDirectory: true),
                backends: ["Claude Code"])]
    }

    /// Other personal skill folders a CLI reads; a same-named skill there competes with the library's.
    var shadowFolders: [URL] {
        [".copilot/skills", ".codex/skills", ".gemini/config/skills"].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// BackendKind raw values (kept as text so the CLI and its tests don't need the app's settings).
    static let allBackends = ["Claude Code", "Copilot", "Codex", "Antigravity"]

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Manifest

    struct Manifest: Codable, Equatable {
        var version = 1
        var skills: [String: Entry] = [:]

        struct Entry: Codable, Equatable {
            var enabled: Bool
            /// Links Cantrip made for this skill (absolute paths).
            var links: [String] = []
        }
    }

    func loadManifest() -> Manifest {
        (try? PrivateFile.read(Manifest.self, from: manifestFile)) ?? Manifest()
    }

    func saveManifest(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFile.write(manifest, to: manifestFile, encoder: encoder)
    }

    // MARK: - Listing

    struct Status: Equatable {
        let name: String
        let description: String
        let enabled: Bool
        /// Backends that see this library copy now.
        let backends: [String]
        /// What needs attention: clashes, missing or foreign links, secret-looking values.
        let problems: [String]

        var json: [String: Any] {
            ["name": name, "description": description, "enabled": enabled, "backends": backends, "problems": problems]
        }
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix(".") && !name.hasPrefix("-")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    /// Skill folders in the library (each has a SKILL.md).
    func names() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return entries.filter { name in
            Self.isValidName(name) && fm.fileExists(atPath: folder.appendingPathComponent("\(name)/SKILL.md").path)
        }.sorted()
    }

    func skillFolder(_ name: String) -> URL { folder.appendingPathComponent(name, isDirectory: true) }

    /// The `description:` from SKILL.md's front matter.
    static func description(ofSkillAt folder: URL) -> String {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return "" }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return "" }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if line.hasPrefix("description:") {
                return line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return ""
    }

    /// Front-matter problems the CLIs would reject or skip.
    static func frontMatterProblems(ofSkillAt folder: URL, name: String) -> [String] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8) else {
            return ["SKILL.md is missing"]
        }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              lines.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ["SKILL.md has no front matter (name and description)"]
        }
        var problems: [String] = []
        let header = lines.dropFirst().prefix { $0.trimmingCharacters(in: .whitespaces) != "---" }
        if !header.contains(where: { $0.hasPrefix("name:") }) { problems.append("SKILL.md front matter has no name") }
        if description(ofSkillAt: folder).isEmpty { problems.append("SKILL.md front matter has no description") }
        return problems
    }

    enum LinkState: Equatable {
        case linked            // our link to this library copy
        case missing           // nothing there
        case clash(String)     // something Cantrip didn't make
    }

    func linkState(_ name: String, in target: Target) -> LinkState {
        let entry = target.folder.appendingPathComponent(name)
        let fm = FileManager.default
        if let destination = try? fm.destinationOfSymbolicLink(atPath: entry.path) {
            let resolved = URL(fileURLWithPath: destination, relativeTo: target.folder).standardizedFileURL.path
            return resolved == skillFolder(name).standardizedFileURL.path ? .linked
                : .clash("\(Self.tilde(entry.path, home: home)) links to \(Self.tilde(resolved, home: home))")
        }
        guard (try? fm.attributesOfItem(atPath: entry.path)) != nil else { return .missing }
        return .clash("\(Self.tilde(entry.path, home: home)) is a folder Cantrip doesn't manage")
    }

    func status(_ name: String, manifest: Manifest? = nil, findings: [SecretScan.Finding]? = nil) -> Status {
        let manifest = manifest ?? loadManifest()
        // A folder copied into the library by hand is enabled at the next sync.
        let enabled = manifest.skills[name]?.enabled ?? true
        let folder = skillFolder(name)
        var backends: [String] = []
        var problems = Self.frontMatterProblems(ofSkillAt: folder, name: name)
        for target in targets {
            switch linkState(name, in: target) {
            case .linked:
                backends += target.backends
                if !enabled { problems.append("Turned off, but \(Self.tilde(target.folder.appendingPathComponent(name).path, home: home)) still links here; run `cantrip skills sync`") }
            case .missing:
                if enabled { problems.append("Not linked for \(target.backends.joined(separator: ", ")); run `cantrip skills sync`") }
            case .clash(let detail):
                problems.append("Name clash: \(detail) (left as is; rename one of them)")
            }
        }
        for other in shadowFolders where (try? FileManager.default.attributesOfItem(atPath: other.appendingPathComponent(name).path)) != nil {
            problems.append("Another skill named \(name) in \(Self.tilde(other.path, home: home)) may be used instead")
        }
        for finding in findings ?? SecretScan.scan(folder: folder, relativeTo: self.folder) {
            problems.append("Looks like a credential: \(finding) — use `cantrip secret run NAME -- cmd` instead")
        }
        return Status(name: name, description: Self.description(ofSkillAt: folder), enabled: enabled,
                      backends: Self.allBackends.filter(backends.contains), problems: problems)
    }

    func list() -> [Status] {
        let manifest = loadManifest()
        return names().map { status($0, manifest: manifest) }
    }

    // MARK: - Changing the library

    struct Report: Equatable {
        var linked: [String] = []
        var unlinked: [String] = []
        var problems: [String] = []
        var lines: [String] { linked.map { "Linked \($0)" } + unlinked.map { "Removed link \($0)" } + problems }
    }

    /// Makes the library folder (git repository and README) when it isn't there yet.
    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let readme = folder.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            try Self.readme.write(to: readme, atomically: true, encoding: .utf8)
        }
        let ignore = folder.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: ignore.path) {
            try ".DS_Store\n*.env\nconfig.env\n__pycache__/\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: folder.appendingPathComponent(".git").path) {
            _ = git(["init", "-q"])
            commit("Start Cantrip's skills library", metadataOnly: true)
        }
    }

    static let readme = """
    # Cantrip skills library

    Edit skills here. Each folder is one skill: a SKILL.md (front matter with `name` and
    `description`, then the instructions) plus any scripts/ and references/ it uses.

    Cantrip links every enabled skill into ~/.agents/skills (Copilot, Codex, Antigravity) and
    ~/.claude/skills (Claude Code), so an edit here reaches every backend. This folder is a local
    git repository for history only: never push it, since skills hold personal details.

    Never put a credential in a skill. Scripts get them by name at run time:
    `cantrip secret run NAME -- command`.

    Commands: cantrip skills list | add PATH | edit NAME | enable NAME | disable NAME | sync | check
    """

    /// Copies (or, with `move`, moves) the skill at `source` into the library and links it.
    /// Refuses a skill with a value that looks like a credential. Entries in the backends'
    /// folders that already point at `source` are switched to the library copy.
    @discardableResult
    func add(source: URL, name: String? = nil, move: Bool = false, enabled: Bool = true) throws -> Report {
        let fm = FileManager.default
        let real = source.resolvingSymlinksInPath().standardizedFileURL
        let name = name ?? source.lastPathComponent
        guard Self.isValidName(name) else { throw Failure(message: "\(name) isn't a usable skill name (letters, digits, - _ .).") }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: real.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure(message: "\(source.path) isn't a folder.")
        }
        guard fm.fileExists(atPath: real.appendingPathComponent("SKILL.md").path) else {
            throw Failure(message: "\(source.path) has no SKILL.md.")
        }
        let destination = skillFolder(name)
        guard !real.path.hasPrefix(folder.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
            throw Failure(message: "\(name) is already in the library; use `cantrip skills enable \(name)`.")
        }
        guard !fm.fileExists(atPath: destination.path) else {
            throw Failure(message: "The library already has a skill named \(name).")
        }
        let findings = SecretScan.scan(folder: real, relativeTo: real.deletingLastPathComponent())
        guard findings.isEmpty else {
            throw Failure(message: "Not added: \(name) has values that look like credentials. Move them to the secrets broker and read them with `cantrip secret run NAME -- cmd`:\n"
                + findings.map { "  \($0)" }.joined(separator: "\n"))
        }
        try prepare()

        // Entries that already stand for this skill: links to it, or folders of links into it.
        var adopt: [URL] = []
        for target in targets {
            let entry = target.folder.appendingPathComponent(name)
            if entry.resolvingSymlinksInPath().standardizedFileURL.path == real.path, entry.standardizedFileURL.path != real.path {
                adopt.append(entry)
            } else if Self.isFolderOfLinks(entry, into: real) {
                adopt.append(entry)
            }
        }

        try Self.copyFollowingLinks(from: real, to: destination)
        if move {
            try fm.removeItem(at: real)
            let insideTarget = targets.contains {
                real.deletingLastPathComponent().standardizedFileURL.path == $0.folder.resolvingSymlinksInPath().standardizedFileURL.path
            }
            // The old place keeps working for anything that still names it.
            if !insideTarget { try fm.createSymbolicLink(at: real, withDestinationURL: destination) }
        }
        for entry in adopt where (try? fm.attributesOfItem(atPath: entry.path)) != nil {
            try fm.removeItem(at: entry)
        }
        var manifest = loadManifest()
        manifest.skills[name] = Manifest.Entry(enabled: enabled, links: manifest.skills[name]?.links ?? [])
        try saveManifest(manifest)
        commit("Add \(name)")
        return try sync(only: [name])
    }

    /// A real folder whose files are all links into `source` (a skill shared file by file).
    static func isFolderOfLinks(_ entry: URL, into source: URL) -> Bool {
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: entry.path)) == nil,
              let files = try? fm.contentsOfDirectory(atPath: entry.path), !files.isEmpty else { return false }
        return files.allSatisfy { file in
            let path = entry.appendingPathComponent(file)
            guard (try? fm.destinationOfSymbolicLink(atPath: path.path)) != nil else { return false }
            return path.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(source.path + "/")
        }
    }

    static func copyFollowingLinks(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) where name != ".git" && name != ".DS_Store" {
            let from = source.appendingPathComponent(name).resolvingSymlinksInPath()
            let to = destination.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard !source.resolvingSymlinksInPath().path.hasPrefix(from.path + "/") else { continue } // a loop
                try copyFollowingLinks(from: from, to: to)
            } else {
                try fm.copyItem(at: from, to: to)
            }
        }
    }

    @discardableResult
    func setEnabled(_ name: String, _ enabled: Bool) throws -> Report {
        guard names().contains(name) else { throw Failure(message: "The library has no skill named \(name).") }
        var manifest = loadManifest()
        manifest.skills[name, default: Manifest.Entry(enabled: enabled)].enabled = enabled
        try saveManifest(manifest)
        return try sync(only: [name])
    }

    /// Links every enabled skill for every backend and removes Cantrip's links for skills that
    /// were turned off or deleted. A skill with a secret-looking value is unlinked, not linked.
    /// Changed skill files are committed to the library's history.
    @discardableResult
    func sync(only: [String]? = nil, dryRun: Bool = false) throws -> Report {
        let fm = FileManager.default
        if !dryRun { try prepare() }
        var manifest = loadManifest()
        let present = Set(names())
        var report = Report()
        let candidates = only ?? Array(Set(manifest.skills.keys).union(present)).sorted()
        for name in candidates {
            // A folder that showed up in the library on its own (copied in by hand) starts enabled.
            if manifest.skills[name] == nil, present.contains(name) { manifest.skills[name] = Manifest.Entry(enabled: true) }
            guard var entry = manifest.skills[name] else { continue }
            let findings = present.contains(name) ? SecretScan.scan(folder: skillFolder(name), relativeTo: folder) : []
            if !findings.isEmpty {
                report.problems.append("Not linked: \(name) has values that look like credentials (\(findings.map(\.description).joined(separator: "; "))). Move them to the secrets broker.")
            }
            let wanted = present.contains(name) && entry.enabled && findings.isEmpty
            var links: [String] = []
            for target in targets {
                let link = target.folder.appendingPathComponent(name)
                switch linkState(name, in: target) {
                case .linked:
                    if wanted { links.append(link.path) }
                    else if entry.links.contains(link.path) {
                        if !dryRun { try fm.removeItem(at: link) }
                        report.unlinked.append(Self.tilde(link.path, home: home))
                    }
                case .missing:
                    guard wanted else { continue }
                    if !dryRun {
                        try fm.createDirectory(at: target.folder, withIntermediateDirectories: true)
                        try fm.createSymbolicLink(at: link, withDestinationURL: skillFolder(name))
                    }
                    links.append(link.path)
                    report.linked.append(Self.tilde(link.path, home: home))
                case .clash(let detail):
                    // A link we made that now points elsewhere, or a broken one, is ours to repair.
                    if entry.links.contains(link.path), (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                        if !dryRun { try fm.removeItem(at: link) }
                        if wanted {
                            if !dryRun { try fm.createSymbolicLink(at: link, withDestinationURL: skillFolder(name)) }
                            links.append(link.path)
                            report.linked.append(Self.tilde(link.path, home: home))
                        } else {
                            report.unlinked.append(Self.tilde(link.path, home: home))
                        }
                    } else if wanted {
                        report.problems.append("Name clash for \(name): \(detail). Left as is.")
                    }
                }
            }
            entry.links = links
            if present.contains(name) { manifest.skills[name] = entry } else { manifest.skills[name] = nil }
        }
        if !dryRun {
            try saveManifest(manifest)
            commit("Sync")
        }
        return report
    }

    /// Everything that needs attention across the library (empty = all good).
    func check(_ only: String? = nil) -> [String] {
        let manifest = loadManifest()
        var problems: [String] = []
        for name in names() where only == nil || only == name {
            for problem in status(name, manifest: manifest).problems { problems.append("\(name): \(problem)") }
        }
        if let only, !names().contains(only) { problems.append("The library has no skill named \(only).") }
        for (name, entry) in manifest.skills where !names().contains(name) && !entry.links.isEmpty && (only == nil || only == name) {
            problems.append("\(name): removed from the library but still linked; run `cantrip skills sync`")
        }
        return problems.sorted()
    }

    // MARK: - History

    @discardableResult
    private func git(_ arguments: [String]) -> Bool {
        guard let gitPath = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { return false }
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"] { environment[key] = "Cantrip" }
        for key in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"] { environment[key] = "cantrip@localhost" }
        let result = try? ProcessRunner.run(gitPath, ["-C", folder.path] + arguments, environment: environment,
                                            errorOutput: .discard, timeout: 30)
        return result?.succeeded == true
    }

    /// Commits the library's changes, leaving out any skill with a secret-looking value.
    func commit(_ message: String, metadataOnly: Bool = false) {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) else { return }
        if metadataOnly {
            guard git(["add", "--", "README.md", ".gitignore"]) else { return }
        } else {
            let flagged = names().filter { !SecretScan.scan(folder: skillFolder($0), relativeTo: folder).isEmpty }
            guard git(["add", "-A", "--", "."] + flagged.map { ":(exclude)\($0)" }) else { return }
            // A flagged skill's files never stay staged.
            for name in flagged { git(["reset", "-q", "--", name]) }
        }
        if !git(["diff", "--cached", "--quiet"]) { git(["commit", "-q", "-m", message]) }
    }

    static func tilde(_ path: String, home: URL) -> String {
        let prefix = home.standardizedFileURL.path
        return path == prefix ? "~" : path.hasPrefix(prefix + "/") ? "~" + path.dropFirst(prefix.count) : path
    }
}
