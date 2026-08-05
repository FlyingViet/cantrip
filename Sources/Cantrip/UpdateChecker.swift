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
    private var lastCheck = Date.distantPast
    private var checking = false
    private init() {}

    /// The repo is wherever the .app lives.
    private var repoPath: String {
        (Bundle.main.bundlePath as NSString).deletingLastPathComponent
    }

    /// Checks on every panel show (lightly debounced so rapid
    /// summon/dismiss cycles don't spam git fetch).
    func checkIfDue() {
        guard Date().timeIntervalSince(lastCheck) > 30, !checking else { return }
        guard FileManager.default.fileExists(atPath: repoPath + "/.git") else { return }
        lastCheck = Date()
        checking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer { self.checking = false }

            // Local staleness first — needs no network: does the source
            // checkout describe differently than the build we're running?
            let buildIdentity = CrashRecovery.buildIdentity
            if buildIdentity != "development",
               let sourceIdentity = Self.sourceIdentity(in: self.repoPath) {
                let stale = sourceIdentity != buildIdentity
                DispatchQueue.main.async {
                    guard self.staleBuild != stale else { return }
                    if stale {
                        Log.write("update: running build \(buildIdentity) is stale — source is at \(sourceIdentity)")
                    }
                    self.staleBuild = stale
                }
            }

            guard Self.git(["fetch", "--quiet", "origin"], in: self.repoPath) != nil,
                  let countText = Self.git(["rev-list", "--count", "HEAD..origin/main"],
                                           in: self.repoPath),
                  let count = Int(countText) else { return }
            DispatchQueue.main.async {
                self.commitsBehind = count
                if count > 0 { Log.write("update: \(count) commit(s) behind origin/main") }
            }
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
