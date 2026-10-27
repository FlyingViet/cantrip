import Foundation

/// Where Cantrip keeps its own state: `~/.cache/Cantrip`.
///
/// Built from the home folder on each use, so a process started with CFFIXED_USER_HOME
/// (the test suites) gets its own.
enum CantripPaths {
    static var cache: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/Cantrip", isDirectory: true)
    }

    /// `relativePath` inside the cache folder, such as "runs" or "notifications/state.json".
    static func cache(_ relativePath: String, isDirectory: Bool = false) -> URL {
        cache.appendingPathComponent(relativePath, isDirectory: isDirectory)
    }
}
