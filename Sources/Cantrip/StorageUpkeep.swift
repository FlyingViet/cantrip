import Darwin
import Foundation

/// Keeps agent leftovers from filling the disk: Copilot CLI session folders nothing uses anymore,
/// and agent git worktrees whose work is saved elsewhere. The host runs it daily and
/// `cantrip cleanup` on demand. It never touches project checkouts, uncommitted files, commits
/// that exist nowhere else, or anything a running process, a Cantrip tab or a memory note uses.
enum StorageUpkeep {
    static let defaultSessionRetentionDays = 14
    static let sessionRetentionDays = 3...365
    static let worktreeIdleDays = 3

    struct Configuration {
        /// `~/.copilot/session-state`: one folder per Copilot CLI session (Cantrip tabs, Home runs,
        /// the Hermes gateway's calls, Terminal sessions).
        var sessionRoot: URL
        /// Cantrip's record of the CLI sessions each tab and Home run used.
        var outputFolders: URL
        /// Folders of Cantrip JSON (tab transcripts, Home's store) whose links to a session's
        /// files keep that session, for tabs older than `outputFolders`.
        var transcriptFolders: [URL] = []
        /// Sessions a note names (by their first 8 characters) are kept.
        var memoryVault: URL?
        /// Main checkouts are found directly inside these folders.
        var repositoryParents: [URL]
        /// Folders searched one level deep for agent worktrees, so their repositories are found too.
        var worktreeSearchRoots: [URL]
        /// Only worktrees inside these are ever removed.
        var agentRoots: [URL]
        /// The last report, the removal log and the lock.
        var stateDirectory: URL
        var sessionRetention: TimeInterval
        var worktreeIdle: TimeInterval = TimeInterval(StorageUpkeep.worktreeIdleDays) * 86_400
        var now = Date()
        var git = "/usr/bin/git"
        var processes: () -> ProcessSnapshot = ProcessSnapshot.current

        static func standard(defaults: UserDefaults = .standard, now: Date = Date()) -> Configuration {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let cache = home.appendingPathComponent(".cache/Cantrip", isDirectory: true)
            let sessions = home.appendingPathComponent(".copilot/session-state", isDirectory: true)
            let temporary = [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                             URL(fileURLWithPath: "/private/tmp", isDirectory: true)]
            let vaultPath = defaults.string(forKey: "memoryPath").flatMap { $0.isEmpty ? nil : $0 }
                ?? home.appendingPathComponent("Cantrip Memory").path
            let vault = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath, isDirectory: true)
            let memoryOn = defaults.object(forKey: "memoryEnabled") == nil || defaults.bool(forKey: "memoryEnabled")
            // With memory on, a vault that can't be read stops the session sweep (`noteTokens`).
            let checkedVault = memoryOn || FileManager.default.fileExists(atPath: vault.path) ? vault : nil
            return Configuration(
                sessionRoot: sessions,
                outputFolders: cache.appendingPathComponent("session-output-folders.json"),
                transcriptFolders: [cache.appendingPathComponent("chats"), cache.appendingPathComponent("home")],
                memoryVault: checkedVault,
                repositoryParents: [home.appendingPathComponent("Coding"), home.appendingPathComponent("Projects"), home],
                worktreeSearchRoots: [cache] + temporary,
                agentRoots: [sessions, cache, URL(fileURLWithPath: "/private/var/folders")] + temporary,
                stateDirectory: cache,
                sessionRetention: TimeInterval(retentionDays(defaults)) * 86_400,
                now: now
            )
        }

        static func retentionDays(_ defaults: UserDefaults) -> Int {
            let stored = defaults.integer(forKey: "storageSessionRetentionDays")
            return stored == 0 ? StorageUpkeep.defaultSessionRetentionDays
                : min(max(stored, sessionRetentionDays.lowerBound), sessionRetentionDays.upperBound)
        }
    }

    /// Why a session folder stayed.
    enum SessionKeep: String, Codable, CaseIterable {
        case recent, tab, note, inUse, unsavedWork

        func describe(_ count: Int, retentionDays: Int) -> String {
            let sessions = count == 1 ? "1 session" : "\(count.formatted()) sessions"
            switch self {
            case .recent: return "\(sessions) used in the last \(retentionDays) days"
            case .tab: return "\(sessions) of open or closed tabs and Home runs"
            case .note: return "\(sessions) named in memory notes"
            case .inUse: return "\(sessions) in use by a running process"
            case .unsavedWork: return "\(sessions) holding uncommitted or unpushed git work"
            }
        }
    }

    struct Worktree: Codable, Equatable {
        var path: String
        var repository: String
        var bytes: Int64 = 0
        /// Why it was kept; nil when removed.
        var reason: String?
    }

    struct Report: Codable {
        var startedAt: Date
        var finishedAt: Date
        var dryRun: Bool
        var sessionRetentionDays: Int
        var sessionsRemoved = 0
        var sessionBytesRemoved: Int64 = 0
        var sessionsKept: [String: Int] = [:]
        var worktreesRemoved: [Worktree] = []
        var worktreesKept: [Worktree] = []
        var prunedRepositories: [String] = []
        var errors: [String] = []
        var freeBytesBefore: Int64?
        var freeBytesAfter: Int64?

        var worktreeBytesRemoved: Int64 { worktreesRemoved.reduce(0) { $0 + $1.bytes } }
        var bytesRemoved: Int64 { sessionBytesRemoved + worktreeBytesRemoved }

        /// One sentence for Settings, the log and the terminal.
        var summary: String {
            let sessions = sessionsRemoved == 1 ? "1 unused session" : "\(sessionsRemoved.formatted()) unused sessions"
            let worktrees = worktreesRemoved.count == 1 ? "1 worktree" : "\(worktreesRemoved.count) worktrees"
            var parts: [String] = []
            if sessionsRemoved > 0 { parts.append("\(sessions) (\(StorageUpkeep.format(sessionBytesRemoved)))") }
            if !worktreesRemoved.isEmpty { parts.append("\(worktrees) (\(StorageUpkeep.format(worktreeBytesRemoved)))") }
            var text = parts.isEmpty
                ? (dryRun ? "Nothing to clean up right now." : "Nothing needed cleaning up.")
                : (dryRun ? "Would remove " : "Removed ") + parts.joined(separator: " and ") + "."
            if !errors.isEmpty { text += " \(errors.count) could not be removed." }
            return text
        }

        var keptSummary: [String] {
            SessionKeep.allCases.compactMap { reason in
                sessionsKept[reason.rawValue].map { reason.describe($0, retentionDays: sessionRetentionDays) }
            }
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Running

    /// Runs one cleanup unless another (the host's or `cantrip cleanup`) holds the lock. Real runs
    /// save their report and log each removal; `log` also receives every removal.
    static func perform(_ configuration: Configuration, dryRun: Bool,
                        log: (String) -> Void = { _ in }) -> Report? {
        let fm = FileManager.default
        try? fm.createDirectory(at: configuration.stateDirectory, withIntermediateDirectories: true)
        let lockPath = configuration.stateDirectory.appendingPathComponent("storage-upkeep.lock").path
        let lock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock) }
            return nil
        }
        defer { flock(lock, LOCK_UN); close(lock) }

        let logFile = configuration.stateDirectory.appendingPathComponent("storage-upkeep.log")
        let report = run(configuration, dryRun: dryRun) { line in
            log(line)
            if !dryRun { appendLog(line, to: logFile) }
        }
        if !dryRun {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(report).write(to: reportURL(in: configuration.stateDirectory), options: .atomic)
        }
        return report
    }

    static func reportURL(in directory: URL) -> URL {
        directory.appendingPathComponent("storage-upkeep.json")
    }

    static func lastReport(in directory: URL) -> Report? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: reportURL(in: directory))).flatMap { try? decoder.decode(Report.self, from: $0) }
    }

    /// Worktrees first, so a session folder only holds worktrees the sweep had a reason to keep.
    static func run(_ c: Configuration, dryRun: Bool, log: (String) -> Void = { _ in }) -> Report {
        var report = Report(startedAt: Date(), finishedAt: Date(), dryRun: dryRun,
                            sessionRetentionDays: Int((c.sessionRetention / 86_400).rounded()))
        report.freeBytesBefore = freeBytes(c.sessionRoot)
        let processes = c.processes()
        let protections: Protections
        do {
            protections = try Protections(c)
        } catch {
            // Without them a kept session can't be told apart; skip everything rather than guess.
            report.errors.append(error.localizedDescription)
            report.finishedAt = Date()
            return report
        }
        sweepWorktrees(c, processes: processes, protections: protections, dryRun: dryRun, report: &report, log: log)
        sweepSessions(c, processes: processes, protections: protections, dryRun: dryRun, report: &report, log: log)
        report.freeBytesAfter = freeBytes(c.sessionRoot)
        report.finishedAt = Date()
        return report
    }

    // MARK: - Sessions

    struct ProtectionError: LocalizedError {
        let errorDescription: String?
    }

    /// Sessions kept whatever their age: used by a tab or Home run, or named in a note.
    struct Protections {
        var referenced: Set<String>
        var noted: Set<String>

        init(referenced: Set<String> = [], noted: Set<String> = []) {
            self.referenced = referenced
            self.noted = noted
        }

        init(_ c: Configuration) throws {
            guard let recorded = referencedSessions(c.outputFolders) else {
                throw ProtectionError(errorDescription: "Skipped: \(c.outputFolders.path) couldn't be read, so tabs' sessions can't be told apart.")
            }
            guard let noted = noteTokens(c.memoryVault) else {
                throw ProtectionError(errorDescription: "Skipped: the memory folder \(c.memoryVault?.path ?? "") couldn't be read, so sessions named in notes can't be told apart.")
            }
            self.init(referenced: recorded.union(linkedSessions(c.transcriptFolders)), noted: noted)
        }

        func reason(for id: String) -> SessionKeep? {
            if referenced.contains(id) { return .tab }
            if noted.contains(String(id.prefix(8))) { return .note }
            return nil
        }
    }

    static func sweepSessions(_ c: Configuration, processes: ProcessSnapshot, protections: Protections, dryRun: Bool,
                              report: inout Report, log: (String) -> Void) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: c.sessionRoot.path) else { return }
        let cutoff = c.now.addingTimeInterval(-c.sessionRetention)
        let verb = dryRun ? "would remove" : "removed"
        // In a dry run these are still on disk; they don't hold their sessions back.
        let removedWorktrees = Set(report.worktreesRemoved.map { resolved($0.path) })
        for name in names.sorted() {
            // Session folders are named by lowercase UUID; anything else isn't a session.
            guard UUID(uuidString: name)?.uuidString.lowercased() == name else { continue }
            let folder = c.sessionRoot.appendingPathComponent(name, isDirectory: true)
            guard isRealDirectory(folder) else { continue }
            func keep(_ reason: SessionKeep) { report.sessionsKept[reason.rawValue, default: 0] += 1 }
            if let reason = protections.reason(for: name) { keep(reason); continue }
            guard let scan = scanSession(folder, cutoff: cutoff, removedWorktrees: removedWorktrees) else {
                keep(.recent); continue
            }
            if lockOwners(folder).contains(where: processes.isAlive) || processes.uses(folder.path) {
                keep(.inUse); continue
            }
            if scan.worktrees > 0 || scan.repositories.contains(where: { hasUnsavedWork($0.url, bare: $0.bare, git: c.git) }) {
                keep(.unsavedWork); continue
            }
            let idle = Int(c.now.timeIntervalSince(scan.newest) / 86_400)
            let line = "session \(name) \(verb): \(format(scan.bytes)), idle \(idle) days, "
                + "\(sessionLabel(folder))"
            if !dryRun {
                do { try removeTree(folder) } catch {
                    report.errors.append("Session \(name): \(error.localizedDescription)")
                    continue
                }
            }
            report.sessionsRemoved += 1
            report.sessionBytesRemoved += scan.bytes
            log(line)
        }
    }

    /// What started a session, for the removal log: its producer and the start of its name.
    static func sessionLabel(_ folder: URL) -> String {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("workspace.yaml"), encoding: .utf8) else {
            return "no workspace file"
        }
        func value(_ key: String) -> String? {
            text.split(separator: "\n").first { $0.hasPrefix(key + ":") }
                .map { $0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) }
        }
        let client = value("client_name") ?? "?"
        let cwd = value("cwd") ?? "?"
        var name = value("name") ?? ""
        if name.hasPrefix("|") {
            // A block scalar: the first indented line holds the text.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if let index = lines.firstIndex(where: { $0.hasPrefix("name:") }), lines.indices.contains(index + 1) {
                name = lines[index + 1].trimmingCharacters(in: .whitespaces)
            }
        }
        return "\(client) in \(cwd): \(name.prefix(80))"
    }

    struct SessionScan {
        var newest: Date
        var bytes: Int64
        var repositories: [(url: URL, bare: Bool)]
        var worktrees: Int
    }

    /// Size, newest change and git checkouts of an idle session; nil as soon as anything in it
    /// changed after `cutoff`.
    static func scanSession(_ folder: URL, cutoff: Date, removedWorktrees: Set<String> = []) -> SessionScan? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
                                      .totalFileAllocatedSizeKey]
        guard let own = try? folder.resourceValues(forKeys: Set(keys)),
              let ownDate = own.contentModificationDate, ownDate < cutoff else { return nil }
        var scan = SessionScan(newest: ownDate, bytes: 0, repositories: [], worktrees: 0)
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true }) else { return nil }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if let date = values.contentModificationDate {
                if date >= cutoff { return nil }
                scan.newest = max(scan.newest, date)
            }
            scan.bytes += Int64(values.totalFileAllocatedSize ?? 0)
            let isFolder = values.isDirectory == true && values.isSymbolicLink != true
            if isFolder, url.lastPathComponent != ".git", !url.path.contains("/.git/"),
               isBareRepository(url), !isGenerated(url, below: folder) {
                scan.repositories.append((url, true))
                continue
            }
            guard url.lastPathComponent == ".git", !isGenerated(url.deletingLastPathComponent(), below: folder) else {
                continue
            }
            if isFolder {
                scan.repositories.append((url.deletingLastPathComponent(), false))
            } else if !removedWorktrees.contains(resolved(url.deletingLastPathComponent().path)) {
                scan.worktrees += 1
            }
        }
        return scan
    }

    /// Package and build folders hold checkouts that are copies, not work.
    private static let generatedFolders: Set<String> = ["node_modules", "DerivedData", ".build", "Pods", ".gradle",
                                                        "SourcePackages"]

    /// A bare repository (a local remote, for example): HEAD, objects and refs, no work tree.
    static func isBareRepository(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.appendingPathComponent("HEAD").path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fm.fileExists(atPath: url.appendingPathComponent("objects").path)
            && fm.fileExists(atPath: url.appendingPathComponent("refs").path)
    }

    static func isGenerated(_ url: URL, below root: URL) -> Bool {
        let relative = url.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count)
        return relative.contains { generatedFolders.contains($0) }
    }

    /// A standalone repository holds work only it has: uncommitted changes, a stash, or commits on
    /// HEAD or a local branch that no remote has. Anything git can't answer counts as work.
    static func hasUnsavedWork(_ repository: URL, bare: Bool = false, git: String) -> Bool {
        let path = repository.path
        if !bare {
            guard let status = Git.run(git, ["-C", path, "status", "--porcelain"]), status.succeeded else { return true }
            if !status.output.isEmpty { return true }
        }
        // `--verify -q` exits 1 for a missing ref; anything else is an error.
        guard let head = Git.run(git, ["-C", path, "rev-parse", "--verify", "-q", "HEAD"]),
              head.status == 0 || head.status == 1,
              let stash = Git.run(git, ["-C", path, "rev-parse", "--verify", "-q", "refs/stash"]),
              stash.status == 0 || stash.status == 1 else { return true }
        if stash.succeeded { return true }
        // Deleting a repository would break worktrees that still live elsewhere.
        guard let worktrees = Git.run(git, ["-C", path, "worktree", "list", "--porcelain"]), worktrees.succeeded,
              !parseWorktrees(worktrees.output).dropFirst().contains(where: { !$0.prunable }) else { return true }
        // An unborn HEAD (a new orphan branch) still leaves other branches to check.
        let tips = head.succeeded ? ["HEAD", "--branches"] : ["--branches"]
        guard let unpushed = Git.run(git, ["-C", path, "rev-list", "--count"] + tips + ["--not", "--remotes"]),
              unpushed.succeeded else { return true }
        return unpushed.output != "0"
    }

    /// CLI session IDs Cantrip recorded for its tabs, closed (reopenable) tabs and Home runs.
    /// nil when the record exists but can't be read (a fresh install has none).
    static func referencedSessions(_ file: URL) -> Set<String>? {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = object["sessions"] as? [String: [String]] else { return nil }
        return Set(sessions.values.joined().map { $0.lowercased() })
    }

    /// Sessions whose folders Cantrip's own JSON links to (`…/session-state/<id>/…`, with JSON's
    /// escaped slashes too): images and files shown in tab transcripts and Home's records.
    static func linkedSessions(_ folders: [URL]) -> Set<String> {
        let pattern = try! NSRegularExpression(
            pattern: #"session-state\\?/([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"#
        )
        var linked: Set<String> = []
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasSuffix(".json") {
                let url = folder.appendingPathComponent(name)
                guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 <= 64 << 20,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let string = text as NSString
                for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                    linked.insert(string.substring(with: match.range(at: 1)).lowercased())
                }
            }
        }
        return linked
    }

    /// Every 8-hex-digit word in the vault's notes: notes name sessions by their first 8
    /// characters ("session 9fd0ee72 files/qa"). A commit hash that matches only keeps more.
    /// nil when the vault can't be read (missing, unmounted, no permission), so nothing is
    /// removed on the assumption that no note names it. A symlinked vault is followed.
    static func noteTokens(_ vault: URL?) -> Set<String>? {
        guard let vault else { return [] }
        let root = URL(fileURLWithPath: resolved(vault.path), isDirectory: true)
        guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil,
              let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsPackageDescendants]
              ) else { return nil }
        let pattern = try! NSRegularExpression(pattern: "(?<![0-9A-Za-z])[0-9A-Fa-f]{8}(?![0-9A-Za-z])")
        var tokens: Set<String> = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 <= 8 << 20,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let string = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                tokens.insert(string.substring(with: match.range).lowercased())
            }
        }
        return tokens
    }

    /// PIDs of the Copilot CLIs holding a session (`inuse.<pid>.lock`).
    static func lockOwners(_ folder: URL) -> [pid_t] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { name in
            guard name.hasPrefix("inuse."), name.hasSuffix(".lock") else { return nil }
            return pid_t(name.dropFirst("inuse.".count).dropLast(".lock".count))
        }
    }

    // MARK: - Worktrees

    struct WorktreeEntry: Equatable {
        var path: String
        var head: String?
        var branch: String?
        var locked = false
        var prunable = false
        var bare = false
    }

    static func parseWorktrees(_ porcelain: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current { entries.append(current) }
                current = WorktreeEntry(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                current?.branch = String(line.dropFirst("branch ".count))
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.prunable = true
            } else if line == "bare" {
                current?.bare = true
            }
        }
        if let current { entries.append(current) }
        return entries
    }

    /// Git arguments that address a repository by its common dir: from the main checkout when it
    /// has one, else (a bare repository) by `--git-dir`.
    static func repositoryArguments(_ common: String) -> [String] {
        let url = URL(fileURLWithPath: common)
        return url.lastPathComponent == ".git" ? ["-C", url.deletingLastPathComponent().path] : ["--git-dir=\(common)"]
    }

    static func sweepWorktrees(_ c: Configuration, processes: ProcessSnapshot, protections: Protections = .init(),
                               dryRun: Bool, report: inout Report, log: (String) -> Void) {
        let cutoff = c.now.addingTimeInterval(-c.worktreeIdle)
        let sessionRoot = resolved(c.sessionRoot.path) + "/"
        for common in repositories(c) {
            let repository = repositoryArguments(common)
            guard let listed = Git.run(c.git, repository + ["worktree", "list", "--porcelain"]),
                  listed.succeeded else { continue }
            let entries = parseWorktrees(listed.output)
            var stale: [String] = []
            for entry in entries.dropFirst() where !entry.bare {
                if entry.prunable { stale.append(entry.path); continue }
                guard isUnder(entry.path, c.agentRoots) else { continue }
                var result = Worktree(path: entry.path, repository: common)
                // A worktree in a kept session (a tab's, a note's, a live CLI's) stays with it.
                let target = resolved(entry.path)
                if target.hasPrefix(sessionRoot) {
                    let id = String(target.dropFirst(sessionRoot.count).prefix { $0 != "/" })
                    let folder = c.sessionRoot.appendingPathComponent(id)
                    if let reason = protections.reason(for: id) {
                        result.reason = reason == .tab ? "its session belongs to a tab or Home run" : "its session is named in a memory note"
                    } else if lockOwners(folder).contains(where: processes.isAlive) {
                        result.reason = "its session is in use"
                    }
                    if result.reason != nil {
                        report.worktreesKept.append(result)
                        continue
                    }
                }
                if let reason = keepReason(entry, common: common, configuration: c,
                                           processes: processes, cutoff: cutoff) {
                    result.reason = reason
                    report.worktreesKept.append(result)
                    continue
                }
                result.bytes = allocatedSize(URL(fileURLWithPath: entry.path))
                if !dryRun {
                    // Removing it would make its parent (a session's files/) look recently used.
                    let parent = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
                    let parentDate = try? parent.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    let removed = Git.run(c.git, repository + ["worktree", "remove", entry.path])
                    if let parentDate {
                        try? FileManager.default.setAttributes([.modificationDate: parentDate], ofItemAtPath: parent.path)
                    }
                    guard removed?.succeeded == true, !FileManager.default.fileExists(atPath: entry.path) else {
                        result.reason = "git worktree remove failed: \(removed?.error ?? "no output")"
                        report.worktreesKept.append(result)
                        report.errors.append("Worktree \(entry.path): \(result.reason!)")
                        continue
                    }
                }
                report.worktreesRemoved.append(result)
                log("worktree \(entry.path) \(dryRun ? "would remove" : "removed"): \(format(result.bytes)), "
                    + "\(entry.branch.map { "branch \($0.replacingOccurrences(of: "refs/heads/", with: ""))" } ?? "detached") "
                    + "of \(common)")
            }
            guard !stale.isEmpty else { continue }
            // `git worktree prune` drops every missing worktree's record; only do it when all are agents'.
            guard stale.allSatisfy({ isUnder($0, c.agentRoots) }) else {
                log("worktree records left in \(common): \(stale.filter { !isUnder($0, c.agentRoots) }.joined(separator: ", ")) are missing outside agent folders")
                continue
            }
            if !dryRun {
                guard Git.run(c.git, repository + ["worktree", "prune"])?.succeeded == true else {
                    report.errors.append("git worktree prune failed in \(common)")
                    continue
                }
            }
            report.prunedRepositories.append(common)
            log("worktree records \(dryRun ? "would prune" : "pruned") in \(common): \(stale.joined(separator: ", "))")
        }
    }

    /// Why a worktree stays, or nil when removing it loses nothing: it is unlocked, unused,
    /// unchanged for `worktreeIdle`, clean, and its commits are on a branch (which removal keeps)
    /// or, when detached, on some other branch, tag or remote.
    static func keepReason(_ entry: WorktreeEntry, common: String, configuration c: Configuration,
                           processes: ProcessSnapshot, cutoff: Date) -> String? {
        let path = entry.path
        guard FileManager.default.fileExists(atPath: path) else { return "missing" }
        if entry.locked { return "locked" }
        if processes.uses(path) { return "in use by a running process" }
        let idleDays = Int(c.worktreeIdle / 86_400)
        if let newest = newestChange(URL(fileURLWithPath: path), cutoff: cutoff), newest >= cutoff {
            return "changed in the last \(idleDays) days"
        }
        if let committed = Git.run(c.git, ["-C", path, "log", "-1", "--format=%ct"]),
           committed.succeeded, let seconds = TimeInterval(committed.output),
           Date(timeIntervalSince1970: seconds) >= cutoff {
            return "committed to in the last \(idleDays) days"
        }
        guard let status = Git.run(c.git, ["-C", path, "status", "--porcelain"]), status.succeeded else {
            return "git status failed"
        }
        if !status.output.isEmpty {
            let count = status.output.split(separator: "\n").count
            return count == 1 ? "1 uncommitted file" : "\(count) uncommitted files"
        }
        if entry.branch == nil {
            guard let head = entry.head,
                  let refs = Git.run(c.git, repositoryArguments(common) + ["for-each-ref", "--contains", head,
                                             "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"]),
                  refs.succeeded else { return "git could not check its commits" }
            if refs.output.isEmpty { return "detached commits on no branch" }
        }
        return nil
    }

    /// Repositories (by git common dir) that may have agent worktrees: main checkouts directly in
    /// `repositoryParents`, plus the repositories of linked worktrees found one level inside
    /// `worktreeSearchRoots` and in session `files/` folders.
    static func repositories(_ c: Configuration) -> [String] {
        let fm = FileManager.default
        var candidates: [URL] = []
        for parent in c.repositoryParents {
            for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] {
                let child = parent.appendingPathComponent(name)
                if fm.fileExists(atPath: child.appendingPathComponent(".git").path) { candidates.append(child) }
            }
        }
        var searchRoots = c.worktreeSearchRoots
        for name in (try? fm.contentsOfDirectory(atPath: c.sessionRoot.path)) ?? [] {
            searchRoots.append(c.sessionRoot.appendingPathComponent(name).appendingPathComponent("files"))
        }
        for root in searchRoots {
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
                let child = root.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                // A `.git` file marks a linked worktree.
                if fm.fileExists(atPath: child.appendingPathComponent(".git").path, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    candidates.append(child)
                }
            }
        }
        var commons: Set<String> = []
        for candidate in candidates {
            guard let result = Git.run(c.git, ["-C", candidate.path, "rev-parse", "--path-format=absolute",
                                               "--git-common-dir"]), result.succeeded, !result.output.isEmpty else { continue }
            commons.insert(resolved(result.output))
        }
        return commons.sorted()
    }

    // MARK: - Files

    static func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// The newest change outside git's own data and generated folders; stops once past `cutoff`.
    static func newestChange(_ root: URL, cutoff: Date) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in true }) else { return nil }
        var newest: Date?
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".git" || generatedFolders.contains(name) || name == "build" {
                walker.skipDescendants()
                continue
            }
            guard let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
            if date >= cutoff { break }
        }
        return newest
    }

    static func allocatedSize(_ root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Removes a folder; read-only folders (Go's module cache, for example) are made writable first.
    static func removeTree(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            chmod(url.path, 0o700)
            if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [], errorHandler: { _, _ in true }) {
                for case let item as URL in walker
                where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    chmod(item.path, 0o700)
                }
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(real) }
        return String(cString: real)
    }

    static func isUnder(_ path: String, _ roots: [URL]) -> Bool {
        let targets = forms(path)
        return roots.contains { root in
            forms(root.path).contains { base in
                let prefix = base.hasSuffix("/") ? base : base + "/"
                return targets.contains { $0.hasPrefix(prefix) }
            }
        }
    }

    /// A path as written, resolved, and with macOS's /tmp and /var symlinks spelled out, so a
    /// missing worktree recorded under /tmp still matches /private/tmp.
    static func forms(_ path: String) -> Set<String> {
        var forms: Set<String> = [(path as NSString).standardizingPath, resolved(path)]
        for form in Array(forms) where form.hasPrefix("/tmp/") || form.hasPrefix("/var/") {
            forms.insert("/private" + form)
        }
        return forms
    }

    static func freeBytes(_ url: URL) -> Int64? {
        var stats = statfs()
        guard statfs(url.path, &stats) == 0 else { return nil }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }

    static func appendLog(_ line: String, to file: URL) {
        let stamp = ISODate.string(from: Date())
        let data = Data("[\(stamp)] \(line)\n".utf8)
        if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 4 << 20 {
            let previous = file.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: file, to: previous)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    // MARK: - Git

    enum Git {
        struct Result {
            var status: Int32
            var output: String
            var error: String
            var succeeded: Bool { status == 0 }
        }

        /// Runs git without prompts or optional locks; nil when it can't start or exceeds `timeout`.
        static func run(_ git: String, _ arguments: [String], timeout: TimeInterval = 120) -> Result? {
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["LC_ALL"] = "C"
            guard let result = try? ProcessRunner.run(git, arguments, environment: environment, timeout: timeout),
                  !result.timedOut else { return nil }
            return Result(status: result.status, output: result.text, error: result.errorText)
        }
    }

    // MARK: - Processes

    /// What running processes point at: working folders and command lines.
    struct ProcessSnapshot {
        var workingDirectories: [String]
        var commandLines: [String]
        var isAlive: (pid_t) -> Bool = { pid in kill(pid, 0) == 0 || errno == EPERM }

        func uses(_ path: String) -> Bool {
            let variants = Set([path, StorageUpkeep.resolved(path)])
            return variants.contains { candidate in
                workingDirectories.contains { $0 == candidate || $0.hasPrefix(candidate + "/") }
                    || commandLines.contains { $0.contains(candidate) }
            }
        }

        static func current() -> ProcessSnapshot {
            var snapshot = ProcessSnapshot(workingDirectories: [], commandLines: [])
            let capacity = max(Int(proc_listallpids(nil, 0)), 0) + 256
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes {
                Int(proc_listallpids($0.baseAddress, Int32($0.count)))
            }
            for pid in pids.prefix(min(max(count, 0), capacity)) where pid > 0 && pid != getpid() {
                var info = proc_vnodepathinfo()
                let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
                if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size {
                    let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { buffer in
                        String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
                    }
                    if !cwd.isEmpty { snapshot.workingDirectories.append(cwd) }
                }
                if let arguments = commandLine(of: pid), !arguments.isEmpty {
                    snapshot.commandLines.append(arguments.joined(separator: " "))
                }
            }
            return snapshot
        }

        private static func commandLine(of pid: pid_t) -> [String]? {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
            let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            var index = MemoryLayout<Int32>.size
            while index < size, buffer[index] != 0 { index += 1 }
            while index < size, buffer[index] == 0 { index += 1 }
            var arguments: [String] = []
            while arguments.count < Int(argc), index < size {
                let start = index
                while index < size, buffer[index] != 0 { index += 1 }
                arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                index += 1
            }
            return arguments
        }
    }
}
