import Darwin
import Foundation
import Security

/// macOS checks privacy grants such as Screen Recording and Accessibility
/// against the running app's files, so replacing the bundle under a live
/// Cantrip makes those checks fail until it is reopened. While Cantrip is
/// running, `make app` therefore stages the signed build beside it
/// (`.Cantrip.app.pending`), and the next launch installs it before anything
/// else starts.
enum PendingUpdate {
    enum Outcome: Equatable {
        case none
        case installed
        case discarded(String)
        case deferred(String)
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static var launchedExecutable: FileIdentity?

    static func pendingURL(for app: URL) -> URL {
        app.deletingLastPathComponent()
            .appendingPathComponent(".\(app.lastPathComponent).pending", isDirectory: true)
    }

    static func previousURL(for app: URL) -> URL {
        app.deletingLastPathComponent()
            .appendingPathComponent(".\(app.lastPathComponent).previous", isDirectory: true)
    }

    /// The bundle that the next launch will run.
    static func nextLaunchBundle(for app: URL) -> URL {
        let pending = pendingURL(for: app)
        return isDirectory(pending) ? pending : app
    }

    /// Runs first at launch. When a staged build is installed, this process
    /// hands off to a fresh launch of the updated app before the app starts.
    static func installIfReady() {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return }
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let outcome = install(
            app: app,
            validate: { signatureProblem(in: $0, bundleIdentifier: bundleIdentifier) },
            otherInstanceRunning: { CrashRecovery.hasRunningInstance(from: app.path) }
        )
        switch outcome {
        case .none:
            return
        case .discarded(let reason), .deferred(let reason):
            Log.write("update: \(reason)")
        case .installed:
            Log.write("update: installed staged build \(buildIdentity(of: app) ?? "unknown"); starting it")
            Log.flush()
            // Relaunch through Launch Services: macOS hides the menu bar icon of
            // a process that exec'd a new image after launch.
            if open(app) {
                exit(EXIT_SUCCESS)
            }
            Log.write("update: could not open the installed build; starting it in this process")
            Log.flush()
            let executable = app.appendingPathComponent("Contents/MacOS")
                .appendingPathComponent(Bundle.main.executableURL?.lastPathComponent ?? "Cantrip").path
            execv(executable, CommandLine.unsafeArgv)
            Log.write("update: could not start the installed build (\(String(cString: strerror(errno)))); continuing with the previous process")
        }
    }

    static func install(app: URL,
                        validate: (URL) -> String?,
                        otherInstanceRunning: () -> Bool,
                        waitTimeout: TimeInterval = 15,
                        pollInterval: TimeInterval = 0.25) -> Outcome {
        let fileManager = FileManager.default
        let pending = pendingURL(for: app)
        guard isDirectory(pending) else { return .none }

        if let problem = validate(pending) ?? notNewerProblem(pending: pending, installed: app) {
            try? fileManager.removeItem(at: pending)
            return .discarded("discarded staged build: \(problem)")
        }

        // Quit and reopen can overlap briefly; never swap files under a live instance.
        let deadline = Date().addingTimeInterval(waitTimeout)
        while otherInstanceRunning() {
            guard Date() < deadline else {
                return .deferred("kept staged build because another Cantrip from \(app.path) is still running")
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        let previous = previousURL(for: app)
        try? fileManager.removeItem(at: previous)
        if isDirectory(app) {
            guard renamex_np(pending.path, app.path, UInt32(RENAME_SWAP)) == 0 else {
                return .deferred("could not install staged build: \(String(cString: strerror(errno)))")
            }
            // The old bundle now sits at the pending path. Move it away first so
            // a failed deletion can never be mistaken for a newer staged build.
            if rename(pending.path, previous.path) == 0 {
                try? fileManager.removeItem(at: previous)
            } else {
                try? fileManager.removeItem(at: pending)
            }
        } else {
            guard rename(pending.path, app.path) == 0 else {
                return .deferred("could not install staged build: \(String(cString: strerror(errno)))")
            }
        }
        return .installed
    }

    static func signatureProblem(in bundle: URL, bundleIdentifier: String?) -> String? {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let identifier = info["CFBundleIdentifier"] as? String else {
            return "missing app metadata"
        }
        if let bundleIdentifier, identifier != bundleIdentifier {
            return "bundle identifier \(identifier) does not match \(bundleIdentifier)"
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            return "unreadable code signature"
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures)
            | UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode))
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        guard status == errSecSuccess else { return "invalid code signature (\(status))" }
        return nil
    }

    /// Records the executable this process started from.
    static func recordLaunchedExecutable(_ path: String? = Bundle.main.executablePath) {
        launchedExecutable = identity(of: path)
    }

    /// True when this process's executable was replaced or removed after
    /// launch. macOS privacy checks are then unreliable until Cantrip reopens.
    static func launchedExecutableReplaced(_ path: String? = Bundle.main.executablePath) -> Bool {
        guard let launchedExecutable else { return false }
        return identity(of: path) != launchedExecutable
    }

    private static func notNewerProblem(pending: URL, installed: URL) -> String? {
        guard let pendingDate = buildDate(of: pending),
              let installedDate = buildDate(of: installed),
              pendingDate <= installedDate else { return nil }
        return "build \(pendingDate) is not newer than installed build \(installedDate)"
    }

    private static func buildDate(of bundle: URL) -> String? {
        info(of: bundle)?["CantripBuildDate"] as? String
    }

    private static func buildIdentity(of bundle: URL) -> String? {
        info(of: bundle)?["CantripBuildIdentity"] as? String
    }

    private static func info(of bundle: URL) -> NSDictionary? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private static func identity(of path: String?) -> FileIdentity? {
        guard let path else { return nil }
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func open(_ app: URL) -> Bool {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-n", app.path]
        opener.standardInput = FileHandle.nullDevice
        opener.standardOutput = FileHandle.nullDevice
        opener.standardError = FileHandle.nullDevice
        do {
            try opener.run()
            opener.waitUntilExit()
            return opener.terminationStatus == 0
        } catch {
            return false
        }
    }
}
