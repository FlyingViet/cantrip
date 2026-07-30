import AppKit

if let watcherFlag = CommandLine.arguments.firstIndex(of: "--cantrip-crash-watcher"),
   CommandLine.arguments.indices.contains(watcherFlag + 1) {
    CrashRecovery.runWatcher(markerPath: CommandLine.arguments[watcherFlag + 1])
    exit(EXIT_SUCCESS)
}

let recoveryReport = CrashRecovery.start()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(recoveryReport: recoveryReport)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
