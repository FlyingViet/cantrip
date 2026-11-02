import Darwin
import Foundation

/// Keeps agent leftovers from filling the disk: Copilot CLI session folders nothing uses anymore,
/// agent git worktrees whose work is saved elsewhere, and build caches (`BuildCaches`). The host runs it daily and
/// `cantrip cleanup` on demand. It never touches project checkouts, uncommitted files, commits
/// that exist nowhere else, or anything a running process, a Cantrip tab or a memory note uses.
enum StorageUpkeep {
    static let defaultSessionRetentionDays = 14
    static let sessionRetentionDays = 3...365
    static let worktreeIdleDays = 3
    /// A clean worktree whose commits (and its submodules') are all on a remote goes after a day.
    static let pushedWorktreeIdle: TimeInterval = 86_400
    /// Build output inside an agent worktree nobody touched for this long goes, whatever its commits.
    static let worktreeOutputIdle: TimeInterval = 12 * 3_600

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
        var pushedWorktreeIdle: TimeInterval = StorageUpkeep.pushedWorktreeIdle
        var worktreeOutputIdle: TimeInterval = StorageUpkeep.worktreeOutputIdle
        /// Open tabs' working folders and the worktrees of child tabs still in progress: a worktree
        /// holding one is never touched.
        var protectedPaths: [String] = []
        var now = Date()
        var git = "/usr/bin/git"
        /// A fresh look at running processes; called again right before each removal.
        var processes: () -> ProcessSnapshot = ProcessSnapshot.current
        /// Simulator cleanup (`SimulatorPool.sweep`); nil skips it (no Xcode, or tests).
        var simulators: SimulatorPool.SweepOptions?
        var simulatorPool = SimulatorPool.Context()
        /// Build and package caches (`BuildCaches.sweep`); nil skips them (tests).
        var caches: BuildCaches.SweepOptions?

        static func standard(defaults: UserDefaults = .standard, now: Date = Date()) -> Configuration {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let cache = CantripPaths.cache
            let sessions = home.appendingPathComponent(".copilot/session-state", isDirectory: true)
            let temporary = [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                             URL(fileURLWithPath: "/private/tmp", isDirectory: true)]
            let vaultPath = defaults.string(forKey: "memoryPath").flatMap { $0.isEmpty ? nil : $0 }
                ?? home.appendingPathComponent("Cantrip Memory").path
            let vault = URL(fileURLWithPath: (vaultPath as NSString).expandingTildeInPath, isDirectory: true)
            let memoryOn = defaults.object(forKey: "memoryEnabled") == nil || defaults.bool(forKey: "memoryEnabled")
            // With memory on, a vault that can't be read stops the session sweep (`noteTokens`).
            let checkedVault = memoryOn || FileManager.default.fileExists(atPath: vault.path) ? vault : nil
            let hasSimulators = (try? ProcessRunner.run("/usr/bin/xcrun", ["--find", "simctl"], errorOutput: .discard,
                                                        timeout: 20))?.succeeded == true
            var simulators = SimulatorPool.SweepOptions.pool(SimulatorPool.Policy.standard(defaults))
            simulators.includeUnmanaged = defaults.bool(forKey: "storageSimulatorCleanup")
            return Configuration(
                sessionRoot: sessions,
                outputFolders: cache.appendingPathComponent("session-output-folders.json"),
                transcriptFolders: [cache.appendingPathComponent("chats"), cache.appendingPathComponent("home")],
                memoryVault: checkedVault,
                repositoryParents: [home.appendingPathComponent("Coding"), home.appendingPathComponent("Projects"), home],
                // Child tabs and agents keep worktrees in ~/.cache/Cantrip/worktrees, including ones
                // of a submodule's own repository (<repo>/.git/modules/<name>).
                worktreeSearchRoots: [cache, cache.appendingPathComponent("worktrees")] + temporary,
                agentRoots: [sessions, cache, URL(fileURLWithPath: "/private/var/folders")] + temporary,
                stateDirectory: cache,
                sessionRetention: TimeInterval(retentionDays(defaults)) * 86_400,
                protectedPaths: protectedPaths(defaults: defaults, childTabs: cache.appendingPathComponent("child-tabs.json")),
                now: now,
                simulators: hasSimulators ? simulators : nil,
                caches: .standard(home: home, now: now)
            )
        }

        /// The working folders of the tabs open in Cantrip, and the worktrees of child tabs that
        /// aren't settled (merged, discarded, or with nothing to merge).
        static func protectedPaths(defaults: UserDefaults, childTabs: URL) -> [String] {
            var paths: [String] = []
            for id in defaults.stringArray(forKey: "openSessionIDs") ?? [] {
                if let workdir = defaults.string(forKey: "workdir-\(id)"), !workdir.isEmpty { paths.append(workdir) }
            }
            if let data = try? Data(contentsOf: childTabs),
               let records = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                let settled: Set<String> = ["merged", "noChanges", "discarded", "requeued"]
                for record in records {
                    guard let worktree = record["worktree"] as? String, !worktree.isEmpty,
                          !settled.contains(record["state"] as? String ?? "") else { continue }
                    paths.append(worktree)
                }
            }
            return paths
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
        var simulators: SimulatorPool.SweepReport?
        var caches: BuildCaches.Report?
        /// Build output removed from worktrees that stay (their source and git state are kept).
        /// Optional, like the fields below, so reports from older versions still read.
        var worktreeOutputRemoved: [BuildCaches.Removal]?
        /// Bytes freed per kind of thing removed (`Category`), filled in when the run ends.
        var bytesByCategory: [String: Int64]?
        /// Free space fell under the low-disk threshold and started this run.
        var lowDisk: Bool?

        enum Category: String, CaseIterable {
            case sessions, worktrees, worktreeBuildOutput, agentBuildFolders, checkoutBuildOutput,
                 orphanedBuildFolders, packageCaches, simulators

            var label: String {
                switch self {
                case .sessions: return "unused sessions"
                case .worktrees: return "worktrees"
                case .worktreeBuildOutput: return "build output in worktrees"
                case .agentBuildFolders: return "agents' DerivedData and package clones"
                case .checkoutBuildOutput: return "build output in checkouts"
                case .orphanedBuildFolders: return "DerivedData of deleted projects"
                case .packageCaches: return "package caches"
                case .simulators: return "simulators"
                }
            }
        }

        var worktreeBytesRemoved: Int64 { worktreesRemoved.reduce(0) { $0 + $1.bytes } }
        var worktreeOutputBytesRemoved: Int64 { (worktreeOutputRemoved ?? []).reduce(0) { $0 + $1.bytes } }
        var bytesRemoved: Int64 {
            sessionBytesRemoved + worktreeBytesRemoved + worktreeOutputBytesRemoved + (simulators?.bytesRemoved ?? 0)
                + (caches?.bytesRemoved ?? 0)
        }

        func categoryBytes() -> [String: Int64] {
            var bytes: [Category: Int64] = [.sessions: sessionBytesRemoved, .worktrees: worktreeBytesRemoved,
                                            .worktreeBuildOutput: worktreeOutputBytesRemoved,
                                            .simulators: simulators?.bytesRemoved ?? 0]
            for removal in caches?.removed ?? [] {
                let category = removal.category.flatMap(Category.init(rawValue:)) ?? .agentBuildFolders
                bytes[category, default: 0] += removal.bytes
            }
            bytes[.packageCaches, default: 0] += (caches?.caches ?? []).reduce(0) { $0 + max($1.bytes - $1.bytesAfter, 0) }
            return Dictionary(uniqueKeysWithValues: bytes.filter { $0.value > 0 }.map { ($0.key.rawValue, $0.value) })
        }

        /// "worktrees 4.1 GB, build output in worktrees 2 GB", largest first.
        var categoryLines: [String] {
            (bytesByCategory ?? categoryBytes()).sorted { $0.value > $1.value }.compactMap { key, value in
                Category(rawValue: key).map { "\($0.label) \(StorageUpkeep.format(value))" }
            }
        }

        /// One sentence for Settings, the log and the terminal.
        var summary: String {
            let sessions = sessionsRemoved == 1 ? "1 unused session" : "\(sessionsRemoved.formatted()) unused sessions"
            let worktrees = worktreesRemoved.count == 1 ? "1 worktree" : "\(worktreesRemoved.count) worktrees"
            var parts: [String] = []
            if sessionsRemoved > 0 { parts.append("\(sessions) (\(StorageUpkeep.format(sessionBytesRemoved)))") }
            if !worktreesRemoved.isEmpty { parts.append("\(worktrees) (\(StorageUpkeep.format(worktreeBytesRemoved)))") }
            if let output = worktreeOutputRemoved, !output.isEmpty {
                let folders = output.count == 1 ? "1 build output folder" : "\(output.count) build output folders"
                parts.append("\(folders) in kept worktrees (\(StorageUpkeep.format(worktreeOutputBytesRemoved)))")
            }
            if let simulators, simulators.removedCount > 0 {
                let count = simulators.removedCount == 1 ? "1 simulator's data" : "\(simulators.removedCount) simulators' data"
                parts.append("\(count) (\(StorageUpkeep.format(simulators.bytesRemoved)))")
            }
            if let caches, caches.count > 0 {
                let count = caches.count == 1 ? "1 build cache" : "\(caches.count) build caches"
                parts.append("\(count) (\(StorageUpkeep.format(caches.bytesRemoved)))")
            }
            var text = parts.isEmpty
                ? (dryRun ? "Nothing to clean up right now." : "Nothing needed cleaning up.")
                : (dryRun ? "Would remove " : "Removed ") + parts.joined(separator: " and ") + "."
            let failed = errors.count + (simulators?.errors.count ?? 0) + (caches?.errors.count ?? 0)
            if failed > 0 { text += " \(failed) could not be removed." }
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
    static func perform(_ configuration: Configuration, dryRun: Bool, lowDisk: Bool = false,
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
        var report = run(configuration, dryRun: dryRun) { line in
            log(line)
            if !dryRun { appendLog(line, to: logFile) }
        }
        if lowDisk { report.lowDisk = true }
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

    // MARK: - Low disk

    /// When free space starts a cleanup, and when what's left after it is worth one alert. Saved
    /// between launches, so a restart doesn't alert again.
    struct LowDiskGuard: Codable, Equatable {
        static let gigabyte: Int64 = 1 << 30
        var runBelow: Int64 = 20 * gigabyte
        var alertBelow: Int64 = 15 * gigabyte
        /// A low-disk cleanup runs at most this often while space stays low.
        var retry: TimeInterval = 60 * 60
        var lastRunAt: Date?
        /// The alert went out; it goes again only after free space recovers past `runBelow`.
        var alerted = false

        /// Whether free space calls for a cleanup now (and notes that one is starting).
        mutating func shouldRun(free: Int64, now: Date) -> Bool {
            guard free < runBelow else {
                alerted = false
                return false
            }
            if let lastRunAt, now.timeIntervalSince(lastRunAt) < retry { return false }
            lastRunAt = now
            return true
        }

        /// After a low-disk cleanup: whether to send the one alert.
        mutating func shouldAlert(freeAfter: Int64) -> Bool {
            guard freeAfter < alertBelow, !alerted else { return false }
            alerted = true
            return true
        }
    }

    /// The largest things still on disk that Cantrip's agents made: each folder in
    /// `~/.cache/Cantrip` (each worktree in its worktrees folder), Copilot's sessions, simulators
    /// and package caches, largest first.
    static func biggestItems(_ c: Configuration, report: Report?, limit: Int = 5) -> [(name: String, bytes: Int64)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        func name(_ url: URL) -> String {
            url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
        }
        var items: [(String, Int64)] = []
        let cache = c.stateDirectory
        for entry in (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        where isRealDirectory(entry) {
            if entry.lastPathComponent == "worktrees" {
                for worktree in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                where isRealDirectory(worktree) {
                    items.append((name(worktree), allocatedSize(worktree)))
                }
            } else {
                items.append((name(entry), allocatedSize(entry)))
            }
        }
        items.append(("Copilot sessions (\(name(c.sessionRoot)))", allocatedSize(c.sessionRoot)))
        if let simulators = report?.simulators { items.append(("Simulators", simulators.totalBytes)) }
        for cache in report?.caches?.caches ?? [] { items.append(("\(cache.name) cache", cache.bytesAfter)) }
        return Array(items.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    /// Runs a cleanup when free space is under the guard's threshold, then sends `alert` once if
    /// space is still under its alert threshold. nil when no cleanup ran (or another one held the lock).
    static func lowDiskRun(_ c: Configuration, guard state: inout LowDiskGuard, free: () -> Int64?,
                           alert: (_ title: String, _ body: String) -> Void,
                           log: (String) -> Void = { _ in }) -> Report? {
        guard let before = free(), state.shouldRun(free: before, now: c.now) else { return nil }
        log("free space \(format(before)) is under \(format(state.runBelow)): cleaning up")
        guard var report = perform(c, dryRun: false, lowDisk: true, log: log) else { return nil }
        report.lowDisk = true
        guard let after = free(), state.shouldAlert(freeAfter: after) else { return report }
        let biggest = biggestItems(c, report: report)
            .map { "\($0.name) \(format($0.bytes))" }.joined(separator: ", ")
        let freed = report.bytesRemoved > 0 ? "Cleanup freed \(format(report.bytesRemoved)). " : ""
        alert("Only \(format(after)) free on the Mac",
              freed + (biggest.isEmpty ? "Nothing else Cantrip made is large." : "Largest left: \(biggest)."))
        log("low disk alert sent: \(format(after)) free")
        return report
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
        if let options = c.simulators {
            var pool = c.simulatorPool
            pool.commandLines = { processes.commandLines }
            pool.now = { c.now }
            report.simulators = SimulatorPool.sweep(options, dryRun: dryRun, context: pool, log: log)
        }
        if var caches = c.caches {
            caches.git = c.git
            caches.currentProcesses = c.processes
            report.caches = BuildCaches.sweep(caches, processes: processes, dryRun: dryRun, log: log)
        }
        report.bytesByCategory = report.categoryBytes()
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
                // Build output may go from a worktree that stays, unless something is using it.
                var trimmable = true
                // A worktree in a kept session (a tab's, a note's, a live CLI's) stays with it.
                let target = resolved(entry.path)
                if target.hasPrefix(sessionRoot) {
                    let id = String(target.dropFirst(sessionRoot.count).prefix { $0 != "/" })
                    let folder = c.sessionRoot.appendingPathComponent(id)
                    if let reason = protections.reason(for: id) {
                        result.reason = reason == .tab ? "its session belongs to a tab or Home run" : "its session is named in a memory note"
                    } else if lockOwners(folder).contains(where: processes.isAlive) {
                        result.reason = "its session is in use"
                        trimmable = false
                    }
                    if entry.locked || processes.uses(entry.path) || isProtected(entry.path, by: c.protectedPaths) {
                        trimmable = false
                    }
                }
                var hasSubmodules = false
                if result.reason == nil {
                    switch keepDecision(entry, common: common, configuration: c, processes: processes) {
                    case .keep(let reason, let canTrim):
                        result.reason = reason
                        trimmable = canTrim
                    case .remove(let submodules):
                        hasSubmodules = submodules
                    }
                }
                if result.reason != nil {
                    if trimmable {
                        trimOutput(of: entry.path, c, dryRun: dryRun, report: &report, log: log)
                    }
                    report.worktreesKept.append(result)
                    continue
                }
                // A build may have started since the run began: look again right before removing.
                if c.processes().uses(entry.path) {
                    result.reason = "in use by a running process"
                    report.worktreesKept.append(result)
                    continue
                }
                result.bytes = allocatedSize(URL(fileURLWithPath: entry.path))
                if !dryRun {
                    // Removing it would make its parent (a session's files/) look recently used.
                    let parent = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
                    let parentDate = try? parent.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    defer {
                        if let parentDate {
                            try? FileManager.default.setAttributes([.modificationDate: parentDate], ofItemAtPath: parent.path)
                        }
                    }
                    if hasSubmodules {
                        // git refuses to remove a worktree holding submodules. The worktree and each
                        // submodule were checked clean and on their remotes, so the folder goes and
                        // `git worktree prune` drops the record (and the submodules' git data).
                        do { try removeTree(URL(fileURLWithPath: entry.path)) } catch {
                            result.reason = "could not delete it: \(error.localizedDescription)"
                            report.worktreesKept.append(result)
                            report.errors.append("Worktree \(entry.path): \(result.reason!)")
                            continue
                        }
                    } else {
                        let removed = Git.run(c.git, repository + ["worktree", "remove", entry.path])
                        guard removed?.succeeded == true, !FileManager.default.fileExists(atPath: entry.path) else {
                            result.reason = "git worktree remove failed: \(removed?.error ?? "no output")"
                            report.worktreesKept.append(result)
                            report.errors.append("Worktree \(entry.path): \(result.reason!)")
                            continue
                        }
                    }
                }
                if hasSubmodules { stale.append(entry.path) }
                report.worktreesRemoved.append(result)
                log("worktree \(entry.path) \(dryRun ? "would remove" : "removed"): \(format(result.bytes)), "
                    + "\(entry.branch.map { "branch \($0.replacingOccurrences(of: "refs/heads/", with: ""))" } ?? "detached") "
                    + "of \(common)" + (hasSubmodules ? " (with its submodules)" : ""))
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

    enum KeepDecision: Equatable {
        /// Stays; `trimmable`: its build output may still go.
        case keep(String, trimmable: Bool)
        /// Removing it loses nothing; `submodules`: it holds initialized submodules, so git won't remove it.
        case remove(submodules: Bool)
    }

    /// Whether a worktree stays. It goes when it is unlocked, unused, not an open tab's or a child
    /// tab's, clean, its submodules clean and on their remotes, and either its commits are on a
    /// remote and nothing changed for `pushedWorktreeIdle`, or nothing changed or was committed for
    /// `worktreeIdle` and its commits are on a branch (which removal keeps) or, when detached, on
    /// some other branch, tag or remote.
    static func keepDecision(_ entry: WorktreeEntry, common: String, configuration c: Configuration,
                             processes: ProcessSnapshot) -> KeepDecision {
        let path = entry.path
        guard FileManager.default.fileExists(atPath: path) else { return .keep("missing", trimmable: false) }
        if entry.locked { return .keep("locked", trimmable: false) }
        if processes.uses(path) { return .keep("in use by a running process", trimmable: false) }
        if isProtected(path, by: c.protectedPaths) {
            return .keep("an open tab or a child tab in progress works in it", trimmable: false)
        }
        let pushedCutoff = c.now.addingTimeInterval(-c.pushedWorktreeIdle)
        let cutoff = c.now.addingTimeInterval(-c.worktreeIdle)
        let newest = newestChange(URL(fileURLWithPath: path), cutoff: pushedCutoff)
        if let newest, newest >= pushedCutoff { return .keep("changed in the last day", trimmable: true) }
        guard let status = Git.run(c.git, ["-C", path, "status", "--porcelain"]), status.succeeded else {
            return .keep("git status failed", trimmable: true)
        }
        if !status.output.isEmpty {
            let count = status.output.split(separator: "\n").count
            return .keep(count == 1 ? "1 uncommitted file" : "\(count) uncommitted files", trimmable: true)
        }
        // Removing a worktree removes its submodules' git data too: each must hold nothing of its own.
        guard let submodules = initializedSubmodules(path, git: c.git) else {
            return .keep("git could not list its submodules", trimmable: true)
        }
        if let unsaved = submodules.first(where: { hasUnsavedWork(URL(fileURLWithPath: path).appendingPathComponent($0), git: c.git) }) {
            return .keep("submodule \(unsaved) has uncommitted or unpushed work", trimmable: true)
        }
        let hasSubmodules = !submodules.isEmpty
        if let unpushed = Git.run(c.git, ["-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes"]),
           unpushed.succeeded, unpushed.output == "0" {
            return .remove(submodules: hasSubmodules)
        }
        let idleDays = Int(c.worktreeIdle / 86_400)
        if let newest, newest >= cutoff { return .keep("changed in the last \(idleDays) days", trimmable: true) }
        if let committed = Git.run(c.git, ["-C", path, "log", "-1", "--format=%ct"]),
           committed.succeeded, let seconds = TimeInterval(committed.output),
           Date(timeIntervalSince1970: seconds) >= cutoff {
            return .keep("committed to in the last \(idleDays) days", trimmable: true)
        }
        if entry.branch == nil {
            guard let head = entry.head,
                  let refs = Git.run(c.git, repositoryArguments(common) + ["for-each-ref", "--contains", head,
                                             "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"]),
                  refs.succeeded else { return .keep("git could not check its commits", trimmable: true) }
            if refs.output.isEmpty { return .keep("detached commits on no branch", trimmable: true) }
        }
        return .remove(submodules: hasSubmodules)
    }

    /// The worktree's initialized submodules (recursively), relative to it; nil when git can't say.
    static func initializedSubmodules(_ path: String, git: String) -> [String]? {
        guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".gitmodules").path) else {
            return []
        }
        guard let listed = Git.run(git, ["-C", path, "submodule", "status", "--recursive"]), listed.succeeded else { return nil }
        // " <sha> path (describe)", "+<sha> path", "U<sha> path"; "-" marks one never initialized.
        return listed.output.split(separator: "\n").compactMap { line in
            guard let first = line.first, first != "-" else { return nil }
            let fields = line.dropFirst().split(separator: " ")
            return fields.count >= 2 ? String(fields[1]) : nil
        }
    }

    /// Whether `path` is one of `protected` or holds one.
    static func isProtected(_ path: String, by protected: [String]) -> Bool {
        let targets = forms(path)
        return protected.contains { candidate in
            forms(candidate).contains { form in targets.contains { form == $0 || form.hasPrefix($0 + "/") } }
        }
    }

    /// Removes the git-ignored build output (DerivedData, .build, build, .spm, node_modules, dist...)
    /// of a worktree that stays, once nothing in it changed for `worktreeOutputIdle`. Source, git
    /// state and anything git tracks stay. Each folder is checked against running processes right
    /// before it goes, and its parent keeps its date so the worktree doesn't look recently used.
    static func trimOutput(of path: String, _ c: Configuration, dryRun: Bool, report: inout Report,
                           log: (String) -> Void) {
        let root = URL(fileURLWithPath: path)
        let cutoff = c.now.addingTimeInterval(-c.worktreeOutputIdle)
        if let newest = newestChange(root, cutoff: cutoff), newest >= cutoff { return }
        let folders = BuildCaches.outputFolders(in: root, git: c.git)
        guard !folders.isEmpty, !c.processes().uses(path) else { return }
        for folder in folders {
            let idle = BuildCaches.idleSince(folder.url, shape: folder.shape)
            guard c.now.timeIntervalSince(idle) >= c.worktreeOutputIdle, !c.processes().uses(folder.url.path) else { continue }
            let bytes = allocatedSize(folder.url)
            if !dryRun {
                let parent = folder.url.deletingLastPathComponent()
                let parentDate = try? parent.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                do { try removeTree(folder.url) } catch {
                    report.errors.append("\(folder.url.path): \(error.localizedDescription)")
                    continue
                }
                if let parentDate {
                    try? FileManager.default.setAttributes([.modificationDate: parentDate], ofItemAtPath: parent.path)
                }
            }
            let hours = Int(c.now.timeIntervalSince(idle) / 3_600)
            let reason = "build output of a worktree that stays, unused for \(hours >= 48 ? "\(hours / 24) days" : "\(hours) hours")"
            report.worktreeOutputRemoved = (report.worktreeOutputRemoved ?? [])
                + [BuildCaches.Removal(path: folder.url.path, bytes: bytes, reason: reason,
                                       category: Report.Category.worktreeBuildOutput.rawValue)]
            log("build output \(folder.url.path) \(dryRun ? "would remove" : "removed"): \(format(bytes)), \(reason)")
        }
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
