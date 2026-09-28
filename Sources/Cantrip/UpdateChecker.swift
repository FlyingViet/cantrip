import Foundation

/// Checks whether the GitHub remote has commits we don't (the app runs
/// out of its own git checkout — Cantrip.app's parent directory).
/// Clicking the toolbar status pulls, rebuilds, and relaunches.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    @Published private(set) var commitsBehind = 0
    /// The RUNNING app was built from an older commit than the local
    /// source checkout (git pull without rebuild, crash mid-update, or
    /// agent-made commits). Relaunching would keep starting the old
    /// build forever — surface the same rebuild chip.
    @Published private(set) var staleBuild = false
    /// Anything that the update/rebuild chip should appear for.
    var updateAvailable: Bool { commitsBehind > 0 || staleBuild }
    /// Running, staged, and latest GitHub versions for Settings.
    @Published private(set) var versionReport: CantripVersionReport
    @Published private(set) var isChecking = false
    private var lastCheck = Date.distantPast
    private init() {
        versionReport = Self.localReport(repositoryAvailable: true)
    }

    /// The repo is wherever the .app lives.
    private var repoPath: String {
        (Bundle.main.bundlePath as NSString).deletingLastPathComponent
    }

    /// Checks on every panel show (lightly debounced so rapid
    /// summon/dismiss cycles don't spam git fetch).
    func checkIfDue() { check(force: false) }

    /// Checks right away, e.g. from the Settings refresh button.
    func checkNow() { check(force: true) }

    private func check(force: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.check(force: force) }
            return
        }
        guard !isChecking, force || Date().timeIntervalSince(lastCheck) > 30 else { return }
        guard FileManager.default.fileExists(atPath: repoPath + "/.git") else {
            versionReport = Self.localReport(repositoryAvailable: false)
            return
        }
        lastCheck = Date()
        isChecking = true
        let repoPath = repoPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var report = Self.localReport(repositoryAvailable: true)
            defer {
                report.checkedAt = Date()
                let finished = report
                DispatchQueue.main.async {
                    self.versionReport = finished
                    self.isChecking = false
                }
            }

            // Local staleness first — needs no network: does the source
            // checkout describe differently than the build we're running?
            let buildIdentity = CrashRecovery.buildIdentity
            let sourceIdentity = Self.sourceIdentity(in: repoPath)
            report.source = sourceIdentity.map(CantripBuildVersion.init(identity:))
            if buildIdentity != "development", let sourceIdentity {
                let stale = sourceIdentity != buildIdentity
                DispatchQueue.main.async {
                    guard self.staleBuild != stale else { return }
                    if stale {
                        Log.write("update: running build \(buildIdentity) is stale — source is at \(sourceIdentity)")
                    }
                    self.staleBuild = stale
                }
            }

            let fetched = Self.git(["fetch", "--quiet", "origin"], in: repoPath) != nil
            report.fetchFailed = !fetched
            // After a failed fetch the last fetched origin/main still says
            // what was latest then; Settings labels it as such.
            Self.addLatest(to: &report, in: repoPath)

            guard fetched,
                  let countText = Self.git(["rev-list", "--count", "HEAD..origin/main"], in: repoPath),
                  let count = Int(countText) else { return }
            DispatchQueue.main.async {
                self.commitsBehind = count
                if count > 0 { Log.write("update: \(count) commit(s) behind origin/main") }
            }
        }
    }

    private static func localReport(repositoryAvailable: Bool) -> CantripVersionReport {
        var report = CantripVersionReport(runningIdentity: CrashRecovery.buildIdentity,
                                          runningDate: CrashRecovery.buildDate)
        report.repositoryAvailable = repositoryAvailable
        if let staged = PendingUpdate.stagedBuild(for: Bundle.main.bundleURL) {
            report.staged = CantripBuildVersion(identity: staged.identity)
            report.stagedDate = staged.date.flatMap(CantripVersionReport.parseDate)
        }
        return report
    }

    private static func addLatest(to report: inout CantripVersionReport, in dir: String) {
        let latest = "origin/main"
        guard let identity = git(["describe", "--always", latest], in: dir), !identity.isEmpty else { return }
        report.latest = CantripBuildVersion(identity: identity)
        if let log = git(["log", "-1", "--format=%s%x1f%cI", latest], in: dir) {
            let fields = log.components(separatedBy: "\u{1f}")
            report.latestSubject = fields.first.flatMap { $0.isEmpty ? nil : $0 }
            report.latestDate = fields.count > 1 ? CantripVersionReport.parseDate(fields[1]) : nil
        }
        func count(_ range: String) -> Int? {
            git(["rev-list", "--count", range], in: dir).flatMap { Int($0) }
        }
        if let running = report.running.gitRevision {
            report.runningBehind = count("\(running)..\(latest)")
            report.runningAhead = count("\(latest)..\(running)")
        }
        if let staged = report.staged?.gitRevision {
            report.stagedBehind = count("\(staged)..\(latest)")
        }
    }

    /// Shell command for the self-update script — run through the panel's
    /// `!` streaming path so pull/build progress shows in the transcript.
    /// The script relaunches the app detached after the output completes.
    var updateCommand: String {
        "sh " + (repoPath + "/Scripts/self-update.sh").shellQuoted
    }

    /// Identity of the source checkout, format-matched to the Makefile's
    /// CantripBuildIdentity. A bare `git describe --dirty` can't tell two
    /// DIFFERENT dirty states apart (both say "<sha>-dirty"), so when the
    /// tree is dirty a checksum of the diff is appended — the Makefile
    /// stamps builds the same way.
    static func sourceIdentity(in dir: String) -> String? {
        guard var identity = git(["describe", "--always", "--dirty"], in: dir),
              !identity.isEmpty else { return nil }
        if identity.hasSuffix("-dirty"),
           let digest = shell("git -C \(dir.shellQuoted) diff HEAD | cksum | cut -d' ' -f1"),
           !digest.isEmpty {
            identity += "-" + digest
        }
        return identity
    }

    private static func shell(_ command: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func git(_ args: [String], in dir: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(20)
        while p.isRunning && Date() < deadline { usleep(100_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
