import AppKit

if CommandLine.arguments.dropFirst().first == "--cantrip-askpass" {
    exit(RemoteAskpass.runHelper())
}

if CommandLine.arguments.dropFirst().first == AntigravityHook.helperArgument {
    exit(AntigravityHook.runHelper())
}

if CommandLine.arguments.dropFirst().first == AgentPolicyBackstop.hookArgument {
    let client = CommandLine.arguments.dropFirst(2).first ?? "copilot"
    print(AgentPolicyBackstop.runHelper(client: client, input: FileHandle.standardInput.readDataToEndOfFile()))
    exit(0)
}

if let watcherFlag = CommandLine.arguments.firstIndex(of: "--cantrip-crash-watcher"),
   CommandLine.arguments.indices.contains(watcherFlag + 1) {
    CrashRecovery.runWatcher(markerPath: CommandLine.arguments[watcherFlag + 1])
    exit(EXIT_SUCCESS)
}

// Agents' builds (and `cantrip cleanup`) find the build disk in their environment.
BuildCaches.exportBuildRoot(UserDefaults.standard.string(forKey: "buildRoot"))
// Every CLI Cantrip starts keeps its own memory off; Cantrip Memory is the one store.
CLIMemory.exportEnvironment()

// `Cantrip daemon|pair|config|status|doctor …`: a terminal client of the running host.
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first, CantripCLI.commands.contains(command) {
    exit(CantripCLI.run(arguments))
}

HostMode.isHeadless = arguments.contains("--headless")
// The background engine: Cantrip.app's login agent (`BackgroundEngine`), headless with the app as its window.
HostMode.isEngine = HostMode.isHeadless && arguments.contains("--engine")

// "Keep agents running when Cantrip quits": the engine runs them and this app is its window. It
// takes no host lock and leaves staged updates to the engine, which installs them once idle.
if !HostMode.isHeadless, MainActor.assumeIsolated({ BackgroundEngine.appRunsAsClient }) {
    // One window app: a second launch (an update's reopen racing `open -n`, another copy of the
    // app) brings the first forward and exits instead of becoming a second window.
    guard WindowLock.acquire() else {
        let holder = WindowLock.holder()
        Log.write("client: Cantrip.app is already open\(holder.map { " (pid \($0))" } ?? ""); this copy (pid \(getpid())) exits")
        if let holder {
            MainActor.assumeIsolated { _ = NSRunningApplication(processIdentifier: holder)?.activate() }
        }
        exit(EXIT_SUCCESS)
    }
    PendingUpdate.recordLaunchedExecutable()
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = ClientAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
    exit(EXIT_SUCCESS)
}

// Under launchd, "another Cantrip is already running" is a clean exit, so it isn't restarted.
let busyExit: Int32 = arguments.contains("--supervised") ? EXIT_SUCCESS : 75 // EX_TEMPFAIL
// Before installing an update or starting crash recovery: another host may be running.
guard HostLock.acquire() else {
    if HostMode.isHeadless {
        FileHandle.standardError.write(Data(HostLock.busyMessage.utf8))
        exit(busyExit)
    }
    MainActor.assumeIsolated {
        switch HostLock.holder()?.mode {
        case "headless":
            NSApplication.shared.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "Cantrip is running in the background"
            alert.informativeText = "It was started headless (for example with \u{201C}cantrip daemon start\u{201D}). "
                + "Remote clients can use it now. To use the menu bar app instead, run "
                + "\u{201C}cantrip daemon stop\u{201D} in Terminal, then open Cantrip again."
            alert.runModal()
        case "engine":
            // Its own app opens as its window; this copy can't (`BackgroundEngine.unavailableReason`).
            NSApplication.shared.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "Cantrip's agents are running in the background"
            alert.informativeText = "This copy of Cantrip can't open their window. "
                + (BackgroundEngine.unavailableReason ?? "")
            alert.runModal()
        default:
            break
        }
    }
    exit(EXIT_SUCCESS)
}

if HostMode.isHeadless, let other = CrashRecovery.otherRunningHost() {
    FileHandle.standardError.write(Data("Cantrip is already running (pid \(other)). Quit it first.\n".utf8))
    exit(busyExit)
}

PendingUpdate.installIfReady()
PendingUpdate.recordLaunchedExecutable()

let recoveryReport = CrashRecovery.start()
try? RunJournal.prune()

MainActor.assumeIsolated {
    if HostMode.isHeadless { HeadlessHost.run(recoveryReport: recoveryReport) }
    let app = NSApplication.shared
    let delegate = AppDelegate(recoveryReport: recoveryReport)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
