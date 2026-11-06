import Foundation

/// PATH for the CLIs and shells Cantrip starts.
///
/// An app opened from Finder or launchd inherits only the system folders, so Cantrip adds the
/// folders installers use (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) ahead of them.
/// Folders the inherited PATH already has keep their place, so a host started from a terminal
/// (`cantrip daemon run`) keeps that terminal's order, and nested launches don't stack duplicates.
enum ToolPath {
    static let systemFolders: Set<String> = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    /// Folders that go first, ahead of everything inherited: the build queue's shims while it's on
    /// (`BuildQueue.apply`).
    nonisolated(unsafe) static var leadingFolders: [String] = []

    /// In the order Cantrip prefers them.
    static func toolFolders(home: String) -> [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    static func value(inherited: String?, home: String = NSHomeDirectory(), leading: [String] = leadingFolders) -> String {
        let base = inherited.flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin"
        var entries: [String] = []
        for entry in base.split(separator: ":").map(String.init) where !entries.contains(entry) {
            entries.append(entry)
        }
        for folder in leading.reversed() where !entries.contains(folder) { entries.insert(folder, at: 0) }
        let tools = toolFolders(home: home)
        for (rank, folder) in tools.enumerated() where !entries.contains(folder) {
            // A missing folder goes before the system folders and before Cantrip's lower-ranked folders.
            let later = systemFolders.union(tools[(rank + 1)...])
            entries.insert(folder, at: entries.firstIndex(where: later.contains) ?? entries.endIndex)
        }
        return entries.joined(separator: ":")
    }

    static func environment(
        _ base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = value(inherited: base["PATH"], home: home)
        return environment
    }
}
