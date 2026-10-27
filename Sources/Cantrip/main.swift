import AppKit

if CommandLine.arguments.dropFirst().first == "--cantrip-askpass" {
    exit(RemoteAskpass.runHelper())
}

if CommandLine.arguments.dropFirst().first == AntigravityHook.helperArgument {
    exit(AntigravityHook.runHelper())
}

if let watcherFlag = CommandLine.arguments.firstIndex(of: "--cantrip-crash-watcher"),
   CommandLine.arguments.indices.contains(watcherFlag + 1) {
    CrashRecovery.runWatcher(markerPath: CommandLine.arguments[watcherFlag + 1])
    exit(EXIT_SUCCESS)
}

// `Cantrip daemon|pair|config|status|doctor …`: a terminal client of the running host.
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first, CantripCLI.commands.contains(command) {
    exit(CantripCLI.run(arguments))
}

HostMode.isHeadless = arguments.contains("--headless")
// Under launchd, "another Cantrip is already running" is a clean exit, so it isn't restarted.
let busyExit: Int32 = arguments.contains("--supervised") ? EXIT_SUCCESS : 75 // EX_TEMPFAIL
// Before installing an update or starting crash recovery: another host may be running.
guard HostLock.acquire() else {
    if HostMode.isHeadless {
        FileHandle.standardError.write(Data(HostLock.busyMessage.utf8))
        exit(busyExit)
    }
    MainActor.assumeIsolated {
        if HostLock.holder()?.mode == "headless" {
            NSApplication.shared.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "Cantrip is running in the background"
            alert.informativeText = "It was started headless (for example with \u{201C}cantrip daemon start\u{201D}). "
                + "Remote clients can use it now. To use the menu bar app instead, run "
                + "\u{201C}cantrip daemon stop\u{201D} in Terminal, then open Cantrip again."
            alert.runModal()
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
