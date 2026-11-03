import AppKit
import ServiceManagement

/// "Keep agents running when Cantrip quits": the engine (this app's own binary with `--headless
/// --engine`) runs as a login agent registered from Cantrip.app (`Contents/Library/LaunchAgents`,
/// written by Scripts/assemble-app.sh), and the app becomes its client (`ClientAppDelegate`): the
/// Home and Settings windows on loopback, ⌥Space and the menu bar. Quitting or updating the app
/// leaves tabs running; the engine restarts into a new build once its tabs are idle (`HeadlessHost`).
enum BackgroundEngine {
    /// UserDefaults keys, in the domain the app and the engine share.
    static let defaultsKey = "backgroundEngine"
    static let errorKey = "backgroundEngineError"
    /// Relaunch arguments: the window to open once the app is back.
    static let openHomeArgument = "--open-home-window"
    static let openSettingsArgument = "--open-settings-window"

    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "com.cantrip" }
    static var label: String { bundleIdentifier + ".engine" }
    static var plistName: String { label + ".plist" }
    static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    /// Whether this Mac runs its agents in the background engine instead of the app.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Why the app couldn't start the engine last time, for Settings.
    static var lastError: String? {
        get { UserDefaults.standard.string(forKey: errorKey) }
        set {
            guard newValue != lastError else { return }
            if let newValue { UserDefaults.standard.set(newValue, forKey: errorKey) }
            else { UserDefaults.standard.removeObject(forKey: errorKey) }
        }
    }

    /// The host app switches when the setting changes (`AppDelegate`); the engine's app polls it.
    @MainActor static var onSettingChange: (() -> Void)?

    /// Settings › About & Updates.
    @MainActor
    static func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        lastError = nil
        Log.write("engine: background agents turned \(on ? "on" : "off")")
        onSettingChange?()
    }

    /// Why background mode can't be used on this Mac, or nil when it can.
    @MainActor
    static var unavailableReason: String? {
        unavailableReason(homeWindow: HomeWindow.unavailableReason,
                          agentBundled: FileManager.default.fileExists(atPath: Bundle.main.bundleURL
                              .appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)").path),
                          daemonInstalled: Daemon.isInstalled)
    }

    static func unavailableReason(homeWindow: String?, agentBundled: Bool, daemonInstalled: Bool) -> String? {
        if let homeWindow { return "Background agents use the Home window. \(homeWindow)" }
        guard agentBundled else { return "This Cantrip build doesn't include the background agent. Rebuild it (make app) or update." }
        if daemonInstalled {
            return "Cantrip already runs as a background service (cantrip daemon). Stop it with `cantrip daemon stop` first."
        }
        return nil
    }

    /// The app starts as the engine's client: background mode is on, or the engine still runs
    /// (it was turned off while the app was closed; the app hands its tabs back once idle).
    @MainActor
    static var appRunsAsClient: Bool {
        unavailableReason == nil && (isEnabled || runningPID != nil)
    }

    /// The engine holding the host lock, if it's running.
    static var runningPID: Int32? {
        guard let holder = HostLock.holder(), holder.mode == "engine" else { return nil }
        return holder.pid
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let approvalMessage = "Allow Cantrip in System Settings › General › Login Items & Extensions."

    /// Registers the login agent (launchd starts it right away, and at every login).
    static func register() throws {
        let service = service
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            throw Failure("macOS is holding Cantrip's background agent for approval. \(approvalMessage)")
        default:
            do { try service.register() } catch {
                if service.status == .requiresApproval {
                    throw Failure("macOS is holding Cantrip's background agent for approval. \(approvalMessage)")
                }
                throw Failure("macOS didn't register Cantrip's background agent: \(error.localizedDescription)")
            }
            Log.write("engine: registered the background agent \(label)")
        }
    }

    /// Registers the login agent if needed and starts the engine if it isn't running.
    static func start() throws {
        try register()
        guard runningPID == nil else { return }
        // Registered earlier and exited since (a clean stop, or the app still held the host lock).
        let result = try? ProcessRunner.run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(label)"],
                                            errorOutput: .merge, timeout: 15)
        guard result?.succeeded != true else { return }
        Log.write("engine: kickstart \(label): \(result?.text ?? "failed")")
        // macOS still lists the agent as registered, but launchd no longer has it (removed with
        // `launchctl bootout`, say): registering it again loads and starts it.
        if result?.text.contains("Could not find service") == true, service.status == .enabled {
            try? service.unregister()
            Log.write("engine: launchd had lost \(label); registering it again")
            try register()
        }
    }

    /// Stops the engine and keeps it from starting at login.
    static func stop() {
        do {
            try service.unregister()
            Log.write("engine: unregistered the background agent \(label)")
        } catch {
            Log.write("engine: couldn't unregister \(label): \(error.localizedDescription)")
        }
        if let pid = runningPID { kill(pid, SIGTERM) }
    }

    /// Quits this app and opens it again (the host and client roles are picked at launch),
    /// optionally with a window open.
    @MainActor
    static func relaunchApp(opening argument: String? = nil) {
        var open = ["-n"]
        // A test home (CFFIXED_USER_HOME, which `cantrip daemon start` keeps too) survives it.
        let environment = ProcessInfo.processInfo.environment
        if let fixed = environment["CFFIXED_USER_HOME"] {
            open += ["--env", "CFFIXED_USER_HOME=\(fixed)", "--env", "HOME=\(environment["HOME"] ?? fixed)"]
        }
        open.append(Bundle.main.bundlePath)
        if let argument { open += ["--args", argument] }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for this exact process to exit; never touches another Cantrip.
        helper.arguments = ["-c", """
            pid="$1"; shift
            for attempt in $(/usr/bin/seq 1 120); do
                if ! /bin/kill -0 "$pid" 2>/dev/null; then exec /usr/bin/open "$@"; fi
                /bin/sleep 0.5
            done
            """, "cantrip-relaunch", String(getpid())] + open
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run() } catch {
            Log.write("engine: couldn't reopen Cantrip: \(error.localizedDescription)")
            return
        }
        Log.write("engine: reopening Cantrip\(argument.map { " (\($0))" } ?? "")")
        NSApplication.shared.terminate(nil)
    }

    /// What the app needs to reach the engine like Cantrip's own window: its loopback port, the
    /// pairing token and the engine's local key. Only this user can use the socket it comes over.
    struct Connection: Equatable {
        let port: Int
        let token: String
        let localKey: String
        let pid: Int32
        let build: String
    }

    /// One `app-connection` answer: how to connect, the setting as the engine sees it, the work a
    /// switch would interrupt and notifications after `after` in outbox `outbox`.
    struct Sync {
        let connection: Connection
        let enabled: Bool
        let busy: Int
        let outbox: String
        let seq: Int
        let notices: [(seq: Int, entry: MacNoticeOutbox.Entry)]
    }

    static func sync(after cursor: Int?, outbox: String?, timeout: Int = 3) throws -> Sync {
        var request: [String: Any] = ["command": "app-connection"]
        if let cursor, let outbox {
            request["after"] = cursor
            request["outbox"] = outbox
        }
        let reply = try CantripCLI.request(request, timeout: timeout)
        guard let port = reply["port"] as? Int, let token = reply["token"] as? String, !token.isEmpty,
              let localKey = reply["localKey"] as? String, !localKey.isEmpty else {
            throw Failure((reply["error"] as? String) ?? "The background agents didn't say how to connect.")
        }
        return Sync(connection: Connection(port: port, token: token, localKey: localKey,
                                           pid: Int32((reply["pid"] as? Int) ?? 0), build: (reply["build"] as? String) ?? ""),
                    enabled: (reply["enabled"] as? Bool) ?? true, busy: (reply["busy"] as? Int) ?? 0,
                    outbox: (reply["outbox"] as? String) ?? "", seq: (reply["seq"] as? Int) ?? 0,
                    notices: MacNoticeOutbox.parse((reply["notices"] as? [[String: Any]]) ?? []))
    }

    /// Settings' line under the toggle: a switch waiting for tabs, or what went wrong.
    @MainActor
    static func status(busy: Int) -> (text: String, tone: String?)? {
        if let lastError { return (lastError, "error") }
        let working = busy == 1 ? "1 tab or task is working" : "\(busy) tabs or tasks are working"
        if HostMode.isEngine, !isEnabled {
            return (busy > 0 ? "Turns off when nothing is working (\(working))." : "Turning off…", nil)
        }
        if !HostMode.isHeadless, isEnabled {
            if let reason = unavailableReason { return (reason, "warning") }
            return (busy > 0 ? "Turns on when nothing is working (\(working))." : "Turning on…", nil)
        }
        return nil
    }
}
