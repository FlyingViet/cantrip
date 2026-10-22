import Foundation

/// `Cantrip --headless`: sessions, Remote, Cantrip Home and the CLI socket with no window, menu
/// bar item or hotkey, for remote desktops, cloud Macs and SSH-only Macs. Set up and pair it with
/// `cantrip daemon` / `cantrip pair`.
enum HeadlessHost {
    /// Runs until SIGTERM/SIGINT/SIGHUP. The caller has taken the host lock.
    @MainActor
    static func run(recoveryReport: CrashRecovery.Report?) -> Never {
        let services = HostServices(manager: SessionManager())
        current = services
        services.start(recoveryReport: recoveryReport)
        services.continueRestoredWork()
        let stop = { (signal: Int32) in
            Log.write("headless: stopping on signal \(signal)")
            services.stop()
            exit(0)
        }
        for code in [SIGTERM, SIGINT, SIGHUP] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { stop(code) } }
            source.resume()
            signalSources.append(source)
        }
        // SIGUSR1 restarts in place (`cantrip daemon restart` for a host started with `daemon run`).
        signal(SIGUSR1, SIG_IGN)
        let restart = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        restart.setEventHandler { MainActor.assumeIsolated { restartInPlace() } }
        restart.resume()
        signalSources.append(restart)
        Log.write("headless: started pid=\(getpid())")
        while true { RunLoop.main.run() }
    }

    @MainActor private static var signalSources: [DispatchSourceSignal] = []
    @MainActor private static var current: HostServices?

    /// Restarts with the same arguments (Remote maintenance "restart"): a staged update installs on
    /// the way, and a supervisor keeps watching the same process.
    @MainActor
    static func restartInPlace() -> Never {
        Log.write("headless: restarting in place")
        current?.stop()
        HostLock.release()
        Log.flush()
        // Listening sockets and journals must not leak into the new image (they'd keep port 8765 bound).
        for descriptor in 3..<min(getdtablesize(), 65_536) {
            let flags = fcntl(descriptor, F_GETFD)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) }
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        execv(executable, CommandLine.unsafeArgv)
        Log.write("headless: restart failed (\(String(cString: strerror(errno)))); exiting for the supervisor")
        Log.flush()
        exit(1) // non-zero, so launchd's KeepAlive starts it again
    }
}
