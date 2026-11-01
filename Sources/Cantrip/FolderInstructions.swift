import Foundation

/// Private and folder rules: agent rules that apply to everything under a folder, kept in
/// Cantrip (`~/Library/Application Support/Cantrip/instructions/*.md`) instead of a repository.
/// Each new session gets the rules for its folder through Cantrip's guidance channel (Copilot's
/// system message, Claude Code's appended system prompt, Codex's developer instructions,
/// Antigravity's first message). A rule may name a `mirror`: a CLAUDE.md regenerated from it for
/// Claude Code run in a terminal, which Cantrip's own Claude sessions skip (claudeMdExcludes) so
/// nothing loads twice.
///
/// A rule file:
///
///     ---
///     folder: ~/Coding
///     mirror: ~/Coding/CLAUDE.md
///     ---
///     The rules, in Markdown.
struct FolderInstructions {
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    var folder: URL { home.appendingPathComponent("Library/Application Support/Cantrip/instructions", isDirectory: true) }
    /// Words that must never appear in a public repository's rules (names, places, hosts); one per
    /// line, kept only here.
    var privateTermsFile: URL { folder.appendingPathComponent("private-terms.txt") }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Rule: Equatable {
        let file: URL
        /// Absolute path the rule applies under.
        let folder: String
        /// Absolute path of the CLAUDE.md regenerated from this rule, if any.
        let mirror: String?
        let body: String
    }

    // MARK: - Reading

    func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return home.path }
        if trimmed.hasPrefix("~/") { return home.appendingPathComponent(String(trimmed.dropFirst(2))).path }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    func tilde(_ path: String) -> String { SkillsLibrary.tilde(path, home: home) }

    func parse(_ text: String, file: URL) -> Rule? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let folder = fields["folder"], !folder.isEmpty else { return nil }
        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Rule(file: file, folder: expand(folder), mirror: fields["mirror"].flatMap { $0.isEmpty ? nil : expand($0) }, body: body)
    }

    func rules() -> [Rule] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
            let file = folder.appendingPathComponent(name)
            return (try? String(contentsOf: file, encoding: .utf8)).flatMap { parse($0, file: file) }
        }
    }

    func rule(forFolder path: String) -> Rule? {
        let target = expand(path)
        return rules().first { $0.folder == target }
    }

    /// The paths a working folder stands for: itself and, for a linked git worktree (a child
    /// tab's checkout), the same place in its main checkout.
    static func effectivePaths(for workdir: String) -> [String] {
        let fm = FileManager.default
        let start = URL(fileURLWithPath: workdir).standardizedFileURL
        var paths = [start.path, start.resolvingSymlinksInPath().path]
        var directory = start
        var relative: [String] = []
        for _ in 0..<32 {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue, let text = try? String(contentsOf: dotGit, encoding: .utf8),
                   let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let gitdir = URL(fileURLWithPath: line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces),
                                     relativeTo: directory).standardizedFileURL
                    if let common = try? String(contentsOf: gitdir.appendingPathComponent("commondir"), encoding: .utf8) {
                        let commonDir = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines),
                                            relativeTo: gitdir.appendingPathComponent("x")).standardizedFileURL
                        if commonDir.lastPathComponent == ".git" {
                            var main = commonDir.deletingLastPathComponent()
                            for part in relative.reversed() { main.appendPathComponent(part) }
                            paths.append(main.standardizedFileURL.path)
                        }
                    }
                }
                break
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            relative.append(directory.lastPathComponent)
            directory = parent
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Rules that apply in `workdir`, outermost folder first.
    func rules(for workdir: String) -> [Rule] {
        guard !workdir.isEmpty else { return [] }
        let paths = Self.effectivePaths(for: workdir)
        return rules().filter { rule in
            let folders = [rule.folder, URL(fileURLWithPath: rule.folder).resolvingSymlinksInPath().path]
            return paths.contains { path in folders.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") } }
        }.sorted { $0.folder.count < $1.folder.count }
    }

    /// The text a new session in `workdir` gets, or nil when no rule applies. Copilot reads the
    /// CLAUDE.md in the working folder and the git root itself (`readsClaudeMdHere`), so a mirror
    /// there already reached it.
    func guidance(for workdir: String, readsClaudeMdHere: Bool = false) -> String? {
        var rules = rules(for: workdir)
        if readsClaudeMdHere {
            let read = Set([workdir, Self.gitRoot(of: workdir)].compactMap { $0 }.map { URL(fileURLWithPath: $0).appendingPathComponent("CLAUDE.md").standardizedFileURL.path })
            rules.removeAll { $0.mirror.map(read.contains) == true }
        }
        let blocks = rules.filter { !$0.body.isEmpty }.map { "Rules for work under \(tilde($0.folder)) (kept in Cantrip):\n\n\($0.body)" }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// CLAUDE.md mirrors of the rules that apply, which Cantrip's Claude sessions skip.
    func claudeExcludes(for workdir: String) -> [String] {
        rules(for: workdir).compactMap(\.mirror)
    }

    /// Claude Code `--settings` JSON that skips the mirrors, or nil when there are none.
    func claudeSettings(for workdir: String) -> String? {
        let excludes = claudeExcludes(for: workdir)
        guard !excludes.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["claudeMdExcludes": excludes], options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func gitRoot(of workdir: String) -> String? {
        var directory = URL(fileURLWithPath: workdir).standardizedFileURL
        for _ in 0..<32 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return directory.path }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    // MARK: - Writing

    func fileName(forFolder path: String) -> String {
        let relative = tilde(expand(path))
        let slug = relative.replacingOccurrences(of: "~", with: "home")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }).joined(separator: "-")
        return (slug.isEmpty ? "root" : slug) + ".md"
    }

    func text(of rule: Rule) -> String {
        var header = "---\nfolder: \(tilde(rule.folder))\n"
        if let mirror = rule.mirror { header += "mirror: \(tilde(mirror))\n" }
        return header + "---\n" + rule.body + "\n"
    }

    @discardableResult
    func save(folder path: String, body: String, mirror: String?) throws -> Rule {
        let existing = rule(forFolder: path)
        let file = existing?.file ?? folder.appendingPathComponent(fileName(forFolder: path))
        let rule = Rule(file: file, folder: expand(path), mirror: mirror.map(expand), body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        let findings = SecretScan.scan(text: rule.body, file: tilde(file.path))
        guard findings.isEmpty else {
            throw Failure(message: "Not saved: the rules have values that look like credentials:\n" + findings.map { "  \($0)" }.joined(separator: "\n"))
        }
        try PrivateFile.write(Data(text(of: rule).utf8), to: file)
        try writeMirror(rule)
        return rule
    }

    static func mirrorHeader(folder: String) -> String {
        "Managed by Cantrip; edit with `cantrip instructions edit \(folder)`. Changes made here are replaced."
    }

    func mirrorText(_ rule: Rule) -> String {
        Self.mirrorHeader(folder: tilde(rule.folder)) + "\n\n" + rule.body + "\n"
    }

    /// Where a mirror's earlier, hand-written content is kept.
    func mirrorBackup(for rule: Rule) -> URL {
        folder.appendingPathComponent("before-cantrip", isDirectory: true)
            .appendingPathComponent(fileName(forFolder: rule.folder).replacingOccurrences(of: ".md", with: "") + "-" + URL(fileURLWithPath: rule.mirror ?? "").lastPathComponent)
    }

    func writeMirror(_ rule: Rule) throws {
        guard let mirror = rule.mirror else { return }
        let url = URL(fileURLWithPath: mirror)
        let current = try? String(contentsOf: url, encoding: .utf8)
        if current == mirrorText(rule) { return }
        if let current, !current.hasPrefix("Managed by Cantrip") {
            // The first time, keep what was there (in Cantrip's folder, not beside the mirror).
            let backup = mirrorBackup(for: rule)
            if !FileManager.default.fileExists(atPath: backup.path) { try PrivateFile.write(Data(current.utf8), to: backup) }
        }
        try mirrorText(rule).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Drift

    /// Repositories a check looks at: each rule's folder and the git repositories directly in it.
    func repositories() -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        for rule in rules() {
            if fm.fileExists(atPath: rule.folder + "/.git") { found.append(rule.folder) }
            for name in ((try? fm.contentsOfDirectory(atPath: rule.folder)) ?? []).sorted() where !name.hasPrefix(".") {
                let path = rule.folder + "/" + name
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                let hasRules = ["CLAUDE.md", "AGENTS.md", "GEMINI.md"].contains { fm.fileExists(atPath: path + "/" + $0) }
                if fm.fileExists(atPath: path + "/.git") || hasRules { found.append(path) }
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    static let pointerFiles = ["CLAUDE.md", "GEMINI.md"]

    /// A CLAUDE.md or GEMINI.md that only points at AGENTS.md: an `@AGENTS.md` line and at most one
    /// sentence about it.
    static func isPointer(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.contains("@AGENTS.md") else { return false }
        let other = lines.filter { $0 != "@AGENTS.md" }
        return other.count <= 1 && other.allSatisfy { $0.contains("AGENTS.md") }
    }

    static let pointerText = """
    Claude Code reads this file. The rules for every coding agent are in AGENTS.md; edit that.

    @AGENTS.md
    """

    /// Rule files in a repository (tracked ones, or just the top folder's outside git).
    static func ruleFiles(in repository: String) -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        if fm.fileExists(atPath: repository + "/.git"), let git = ["/usr/bin/git", "/opt/homebrew/bin/git"].first(where: fm.isExecutableFile(atPath:)),
           let result = try? ProcessRunner.run(git, ["-C", repository, "ls-files", "-z", "--", ":(glob)**/CLAUDE.md", ":(glob)**/AGENTS.md", ":(glob)**/GEMINI.md"],
                                               errorOutput: .discard, timeout: 20), result.succeeded {
            files = String(decoding: result.output, as: UTF8.self).split(separator: "\0").map(String.init)
        }
        for name in ["CLAUDE.md", "AGENTS.md", "GEMINI.md"] where fm.fileExists(atPath: repository + "/" + name) && !files.contains(name) {
            files.append(name)
        }
        return files.sorted()
    }

    struct Finding: Equatable, CustomStringConvertible {
        let path: String
        let problem: String
        var description: String { "\(path): \(problem)" }
    }

    /// Rule mirrors out of date, CLAUDE.md files without an AGENTS.md, pointer files that grew their
    /// own rules, and personal details or credentials in a public repository's rule files.
    /// `isPublic` answers for a repository path (nil = unknown).
    func check(isPublic: (String) -> Bool? = RepoVisibility.isPublic) -> [Finding] {
        var findings: [Finding] = []
        let fm = FileManager.default
        for rule in rules() {
            if !fm.fileExists(atPath: rule.folder) { findings.append(Finding(path: tilde(rule.file.path), problem: "its folder \(tilde(rule.folder)) doesn't exist")) }
            for secret in SecretScan.scan(text: rule.body, file: tilde(rule.file.path)) {
                findings.append(Finding(path: secret.file, problem: "line \(secret.line) looks like a credential (\(secret.kind))"))
            }
            if let mirror = rule.mirror {
                let current = try? String(contentsOf: URL(fileURLWithPath: mirror), encoding: .utf8)
                if current != mirrorText(rule) {
                    findings.append(Finding(path: tilde(mirror), problem: current == nil ? "missing; run `cantrip instructions edit \(tilde(rule.folder))` and save"
                        : "differs from the rule it mirrors; edit the rule with `cantrip instructions edit \(tilde(rule.folder))` (saving rewrites this file)"))
                }
            }
        }
        let mirrors = Set(rules().compactMap(\.mirror))
        let terms = privateTerms()
        for repository in repositories() {
            let files = Self.ruleFiles(in: repository)
            let visibility = isPublic(repository)
            for file in files {
                let path = repository + "/" + file
                guard !mirrors.contains(path), let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else { continue }
                let directory = (file as NSString).deletingLastPathComponent
                let name = (file as NSString).lastPathComponent
                let agents = directory.isEmpty ? "AGENTS.md" : directory + "/AGENTS.md"
                if Self.pointerFiles.contains(name) {
                    if !fm.fileExists(atPath: repository + "/" + agents) {
                        if name == "CLAUDE.md" { findings.append(Finding(path: tilde(path), problem: "holds the rules but there's no AGENTS.md beside it, so other agents don't see them; move them to AGENTS.md and leave a pointer")) }
                    } else if !Self.isPointer(text) {
                        findings.append(Finding(path: tilde(path), problem: "has its own rules besides AGENTS.md; move them into AGENTS.md so every agent gets them"))
                    }
                }
                for secret in SecretScan.scan(text: text, file: tilde(path)) {
                    findings.append(Finding(path: tilde(path), problem: "line \(secret.line) looks like a credential (\(secret.kind))"))
                }
                if visibility == true {
                    for personal in PersonalScan.scan(text: text, terms: terms) {
                        findings.append(Finding(path: tilde(path), problem: "line \(personal.line) has personal content in a public repository (\(personal.kind))"))
                    }
                }
            }
        }
        return findings
    }

    func privateTerms() -> [String] {
        var terms = ((try? String(contentsOf: privateTermsFile, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        terms += PersonalScan.accountTerms()
        return terms
    }
}

/// Personal details that don't belong in a public repository.
enum PersonalScan {
    struct Finding: Equatable {
        let line: Int
        let kind: String
    }

    private static let patterns: [(String, NSRegularExpression)] = [
        ("email address", #"\b[A-Za-z0-9._%+-]+@(?!users\.noreply\.github\.com\b|example\.(?:com|org|net)\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#),
        ("phone number", #"(?<![\w.])(?:\+?1[ .-]?)?\(?[2-9]\d{2}\)?[ .-]\d{3}[ .-]\d{4}(?![\w.])"#),
        // A range (`100.64.0.0/10`) describes networks, not someone's host.
        ("local network address", #"\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01])|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))\.\d{1,3}\.\d{1,3}\b(?!/\d)"#),
        ("tailnet or local host name", #"\b[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:ts\.net|local|lan|home\.arpa)\b"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// This account's short and full name, and its home folder: never committed, read at run time.
    static func accountTerms() -> [String] {
        var terms = [NSUserName()]
        terms += NSFullUserName().split(separator: " ").map(String.init).filter { $0.count >= 3 }
        return terms.filter { !$0.isEmpty }
    }

    static func scan(text: String, terms: [String]) -> [Finding] {
        let termPatterns = terms.compactMap { term -> NSRegularExpression? in
            try? NSRegularExpression(pattern: "(?i)(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: term) + "(?![A-Za-z0-9])")
        }
        var findings: [Finding] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            // Addresses and names a line offers as an example are documentation.
            let example = ["example", "e.g.", "for instance", "placeholder", "in docs"].contains { line.lowercased().contains($0) }
            for (kind, regex) in patterns where regex.firstMatch(in: line, range: range) != nil {
                if example, kind != "email address" { continue }
                findings.append(Finding(line: index + 1, kind: kind))
            }
            if termPatterns.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                findings.append(Finding(line: index + 1, kind: "a private name or word"))
            }
        }
        return findings
    }
}

/// Whether a repository is public on GitHub, asked with `gh` and remembered for a day.
enum RepoVisibility {
    static var cacheFile: URL { CantripPaths.cache("instructions/repo-visibility.json") }

    struct Entry: Codable { var isPublic: Bool; var checked: Date }

    static func isPublic(_ repository: String) -> Bool? {
        guard let slug = githubSlug(repository) else { return nil }
        var cache = (try? PrivateFile.read([String: Entry].self, from: cacheFile)) ?? [:]
        if let entry = cache[slug], Date().timeIntervalSince(entry.checked) < 86_400 { return entry.isPublic }
        let searchPath = ToolPath.value(inherited: ProcessInfo.processInfo.environment["PATH"]).split(separator: ":")
        guard let gh = searchPath.map({ "\($0)/gh" }).first(where: FileManager.default.isExecutableFile(atPath:)),
              let result = try? ProcessRunner.run(gh, ["api", "repos/\(slug)", "--jq", ".private"], errorOutput: .discard, timeout: 20),
              result.succeeded, ["true", "false"].contains(result.text) else { return cache[slug]?.isPublic }
        cache[slug] = Entry(isPublic: result.text == "false", checked: Date())
        try? PrivateFile.write(cache, to: cacheFile)
        return result.text == "false"
    }

    /// `owner/name` from the `origin` remote's GitHub URL.
    static func githubSlug(_ repository: String) -> String? {
        guard let config = (try? String(contentsOfFile: repository + "/.git/config", encoding: .utf8)) ?? gitdirConfig(repository) else { return nil }
        var inOrigin = false
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inOrigin = trimmed == "[remote \"origin\"]"; continue }
            guard inOrigin, trimmed.hasPrefix("url") , let equals = trimmed.firstIndex(of: "=") else { continue }
            var url = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let range = url.range(of: "github.com") else { return nil }
            url = String(url[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
            if url.hasSuffix(".git") { url.removeLast(4) }
            let parts = url.split(separator: "/")
            return parts.count == 2 ? parts.joined(separator: "/") : nil
        }
        return nil
    }

    private static func gitdirConfig(_ repository: String) -> String? {
        guard let text = try? String(contentsOfFile: repository + "/.git", encoding: .utf8),
              let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let gitdir = URL(fileURLWithPath: line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces),
                         relativeTo: URL(fileURLWithPath: repository + "/")).standardizedFileURL
        let common = (try? String(contentsOf: gitdir.appendingPathComponent("commondir"), encoding: .utf8))
            .map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitdir.appendingPathComponent("x")).standardizedFileURL }
        return try? String(contentsOf: (common ?? gitdir).appendingPathComponent("config"), encoding: .utf8)
    }
}
