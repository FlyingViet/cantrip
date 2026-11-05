import Foundation

/// How this process runs: the menu bar app, or `--headless` (sessions and Remote only, no windows).
/// The background engine (`--headless --engine`, `BackgroundEngine`) is headless too, started by
/// Cantrip.app's login agent; the app is then its client.
enum HostMode {
    nonisolated(unsafe) static var isHeadless = false
    nonisolated(unsafe) static var isEngine = false
}

/// One Cantrip host per user: the menu bar app and `--headless` share sessions, ports and the
/// CLI socket, so whichever starts second steps aside. The lock lives as long as the process.
enum HostLock {
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    static var url: URL {
        CantripPaths.cache("host.lock")
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
        let mode = HostMode.isEngine ? "engine" : HostMode.isHeadless ? "headless" : "app"
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
        let what = switch holder?.mode {
        case "headless": "as a background service"
        case "engine": "in the background for Cantrip.app"
        default: "as the menu bar app"
        }
        return "Cantrip is already running \(what)\(holder.map { " (pid \($0.pid))" } ?? ""). "
            + "Stop it first (`cantrip daemon stop`, or quit the app).\n"
    }

    /// "<pid> <headless|engine|app>" of the host holding the lock, if any. The file outlives its host, so
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

/// One window app for the background engine. An update's reopen and a second launch (`open -n`, a
/// copy of Cantrip.app from another folder) could otherwise both become its window; the second
/// finds the lock held, brings the first forward and exits. Held for the process's lifetime.
enum WindowLock {
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    static var url: URL {
        CantripPaths.cache("window.lock")
    }

    /// False when another window app still holds the lock after `wait` seconds (a window quitting
    /// to reopen into an update can overlap its successor briefly).
    static func acquire(wait: TimeInterval = 3) -> Bool {
        guard descriptor < 0 else { return true }
        guard let fd = lock(url, wait: wait) else { return false }
        descriptor = fd
        return true
    }

    /// Takes an exclusive lock on `url` and writes this pid into it, returning the descriptor; nil
    /// while another open file still holds it after `wait`. An unwritable cache returns -1 (no
    /// lock), so it never keeps the window from opening.
    static func lock(_ url: URL, wait: TimeInterval) -> Int32? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return -1 }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                close(fd)
                return nil
            }
            usleep(100_000)
        }
        ftruncate(fd, 0)
        _ = "\(getpid())\n".withCString { pwrite(fd, $0, strlen($0), 0) }
        return fd
    }

    /// The window app holding `url`, if one does. The file outlives its holder, so its pid only
    /// counts while the lock is really held.
    static func holder(of url: URL = url) -> Int32? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 else { return nil }
        return pid
    }
}
