import Foundation

/// Checks whether the GitHub remote has commits we don't (a source install runs
/// out of its own git checkout — Cantrip.app's parent directory) or, for a release
/// install, whether a newer release is out. Clicking the toolbar status pulls,
/// rebuilds and relaunches, or downloads the release and restarts.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    @Published private(set) var commitsBehind = 0
    /// The RUNNING app was built from an older commit than the local
    /// source checkout (git pull without rebuild, crash mid-update, or
    /// agent-made commits). Relaunching would keep starting the old
    /// build forever — surface the same rebuild chip.
    @Published private(set) var staleBuild = false
    /// Anything that the update/rebuild chip should appear for.
    var updateAvailable: Bool { commitsBehind > 0 || staleBuild || releaseUpdateAvailable }
    /// A release install can download a newer release.
    var releaseUpdateAvailable: Bool {
        if case .releaseAvailable = versionReport.state(checking: false) { return true }
        return false
    }
    /// A release download in progress, what it's doing, and why the last one failed.
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadStatus: String?
    @Published private(set) var downloadError: String?
    private var latestRelease: ReleaseUpdater.Release?
    /// Running, staged, and latest GitHub versions for Settings.
    @Published private(set) var versionReport: CantripVersionReport
    @Published private(set) var isChecking = false
    private var lastCheck = Date.distantPast
    private init() {
        versionReport = Self.localReport(repositoryAvailable: true)
        versionReport.releaseInstall = CantripInstall.isRelease()
    }

    /// The repo is wherever the .app lives.
    private var repoPath: String {
        (Bundle.main.bundlePath as NSString).deletingLastPathComponent
    }

    /// GitHub allows 60 unauthenticated API calls an hour, so release installs check hourly.
    private static let releaseCheckInterval: TimeInterval = 3600

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
        let release = CantripInstall.isRelease()
        guard !isChecking,
              force || Date().timeIntervalSince(lastCheck) > (release ? Self.releaseCheckInterval : 30) else { return }
        if release { checkRelease(); return }
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

            // Forced tags: a rewritten history moves release tags, which a plain fetch refuses to clobber.
            let fetched = Self.git(["fetch", "--quiet", "--force", "--tags", "origin"], in: repoPath) != nil
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

    private func checkRelease() {
        lastCheck = Date()
        isChecking = true
        let previous = latestRelease
        Task { [weak self] in
            var report = Self.localReport(repositoryAvailable: false)
            report.releaseInstall = true
            var release = previous
            do {
                release = try await ReleaseUpdater.latest()
            } catch {
                report.fetchFailed = true
                Log.write("update: couldn't check GitHub's releases: \(error.localizedDescription)")
            }
            if let release { Self.add(release, to: &report) }
            report.checkedAt = Date()
            let finished = report
            DispatchQueue.main.async {
                guard let self else { return }
                self.latestRelease = release
                self.versionReport = finished
                self.isChecking = false
                if self.releaseUpdateAvailable, let release { Log.write("update: \(release.tag) is available") }
            }
        }
    }

    private static func add(_ release: ReleaseUpdater.Release, to report: inout CantripVersionReport) {
        report.latest = CantripBuildVersion(identity: release.tag)
        report.latestSubject = release.name
        report.latestDate = release.publishedAt
        report.latestDownloadable = release.diskImage != nil && release.checksum != nil
    }

    /// The panel's update action. A source install pulls, rebuilds and relaunches through a `!`
    /// command; a release install downloads the newest release and restarts if `idle()` says no tab is
    /// busy (otherwise it stays staged for Restart to Install).
    func update(submit: (String) -> Void, idle: @escaping () -> Bool) {
        if CantripInstall.isRelease() {
            downloadRelease(restartIf: idle)
        } else {
            submit("!" + updateCommand)
        }
    }

    /// Downloads and stages the newest release for the next launch.
    func downloadRelease(restartIf idle: (() -> Bool)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.downloadRelease(restartIf: idle) }
            return
        }
        guard !isDownloading, let release = latestRelease else { return }
        isDownloading = true
        downloadError = nil
        downloadStatus = "Downloading \(release.name)…"
        Task { [weak self] in
            do {
                _ = try await ReleaseUpdater.stage(release) { status in
                    DispatchQueue.main.async { self?.downloadStatus = status }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.finishDownload(error: nil)
                    guard let idle, idle() else { return }
                    do { try RemoteMaintenance.relaunch(Bundle.main.bundleURL) }
                    catch { self.downloadError = error.localizedDescription }
                }
            } catch {
                Log.write("update: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.finishDownload(error: error.localizedDescription) }
            }
        }
    }

    private func finishDownload(error: String?) {
        isDownloading = false
        downloadStatus = nil
        downloadError = error
        var report = versionReport
        let local = Self.localReport(repositoryAvailable: report.repositoryAvailable)
        report.staged = local.staged
        report.stagedDate = local.stagedDate
        versionReport = report
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
        guard let identity = git(["describe", "--always", "--match", "v[0-9]*", latest], in: dir),
              !identity.isEmpty else { return }
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
    /// stamps builds the same way. Only host tags (`v1.1.1`) count, not `windows-v*`.
    static func sourceIdentity(in dir: String) -> String? {
        guard var identity = git(["describe", "--always", "--dirty", "--match", "v[0-9]*"], in: dir),
              !identity.isEmpty else { return nil }
        if identity.hasSuffix("-dirty"),
           let digest = shell("git -C \(dir.shellQuoted) diff HEAD | cksum | cut -d' ' -f1"),
           !digest.isEmpty {
            identity += "-" + digest
        }
        return identity
    }

    private static func shell(_ command: String) -> String? {
        ProcessRunner.output("/bin/zsh", ["-c", command], timeout: 20)
    }

    private static func git(_ args: [String], in dir: String) -> String? {
        ProcessRunner.output("/usr/bin/git", ["-C", dir] + args, timeout: 20)
    }
}
