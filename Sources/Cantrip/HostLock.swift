import Foundation

/// How this process runs: the menu bar app, or `--headless` (sessions and Remote only, no windows).
enum HostMode {
    nonisolated(unsafe) static var isHeadless = false
}

/// One Cantrip host per user: the menu bar app and `--headless` share sessions, ports and the
/// CLI socket, so whichever starts second steps aside. The lock lives as long as the process.
enum HostLock {
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/Cantrip/host.lock")
    }

    /// False when another Cantrip host still holds the lock after `wait` seconds (a quitting
    /// host, or an update handing off to its new build, can overlap the next launch briefly).
    static func acquire(wait: TimeInterval = 5) -> Bool {
        guard descriptor < 0 else { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true } // an unwritable cache must not keep Cantrip from starting
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                close(fd)
                return false
            }
            usleep(100_000)
        }
        ftruncate(fd, 0)
        let mode = HostMode.isHeadless ? "headless" : "app"
        _ = "\(getpid()) \(mode)\n".withCString { write(fd, $0, strlen($0)) }
        descriptor = fd
        return true
    }

    /// Lets a new build take over (an update handing off before this process exits).
    static func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    /// Why this process can't start, for the terminal.
    static var busyMessage: String {
        let holder = holder()
        let what = holder?.mode == "headless" ? "as a background service" : "as the menu bar app"
        return "Cantrip is already running \(what)\(holder.map { " (pid \($0.pid))" } ?? ""). "
            + "Stop it first (`cantrip daemon stop`, or quit the app).\n"
    }

    /// "<pid> <headless|app>" of the host holding the lock, if any. The file outlives its host, so
    /// the pid in it only counts while the lock is really held.
    static func holder() -> (pid: Int32, mode: String)? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let pid = Int32(parts[0]), kill(pid, 0) == 0 else { return nil }
        return (pid, String(parts[1]))
    }
}
