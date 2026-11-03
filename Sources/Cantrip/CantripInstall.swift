import Foundation

/// How this Cantrip was installed. A source install is Cantrip.app beside its repository
/// (`./install.sh`; updates pull and rebuild). A release install is the notarized app from a release's
/// disk image, usually in /Applications, with no repository; it updates from GitHub releases.
/// The helper scripts ship inside the app either way.
enum CantripInstall {
    /// Scripts copied into `Contents/Resources/bin` (Scripts/assemble-app.sh).
    static let bundledScripts = ["cantrip", "cantrip-mcp", "mcp-on-demand", "messages-send", "mail-refresh"]

    /// The repository the running app sits in, if any.
    static var checkout: URL? { checkout(for: Bundle.main.bundleURL) }

    static func checkout(for app: URL) -> URL? {
        guard app.pathExtension == "app" else { return nil }
        let folder = app.deletingLastPathComponent()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: folder.appendingPathComponent(".git").path),
              fileManager.fileExists(atPath: folder.appendingPathComponent("Makefile").path) else { return nil }
        return folder
    }

    /// A Cantrip.app without a repository beside it.
    static func isRelease(_ app: URL = Bundle.main.bundleURL) -> Bool {
        app.pathExtension == "app" && checkout(for: app) == nil
    }

    /// A helper script's path: the checkout's copy in a source install (so edits apply without a rebuild),
    /// otherwise the app's own copy.
    static func script(_ name: String, app: URL = Bundle.main.bundleURL,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let fileManager = FileManager.default
        if let checkout = checkout(for: app) {
            let path = checkout.appendingPathComponent("Scripts").appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        let bundled = app.appendingPathComponent("Contents/Resources/bin").appendingPathComponent(name).path
        if fileManager.isExecutableFile(atPath: bundled) { return bundled }
        // A bare binary (tests, `swift run`): the usual checkout.
        return home.appendingPathComponent("Coding/Cantrip/Scripts").appendingPathComponent(name).path
    }

    /// `script` with the home folder written as `~`, for text that agents read.
    static func displayScript(_ name: String) -> String {
        tilde(script(name), home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private static func tilde(_ path: String, home: URL) -> String {
        path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }

    // MARK: - Command-line tool

    /// What `~/.local/bin/cantrip` (the link `./install.sh` makes) is.
    enum CommandLineTool: Equatable {
        /// A link to this app's CLI.
        case installed
        case missing
        /// A link to another Cantrip's CLI, or to nothing; installing replaces it.
        case otherCantrip(String)
        /// Something that isn't Cantrip's; installing leaves it alone.
        case blocked
    }

    static func commandLineLink(home: URL) -> URL {
        home.appendingPathComponent(".local/bin/cantrip")
    }

    static func commandLineTool(app: URL = Bundle.main.bundleURL,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CommandLineTool {
        let link = commandLineLink(home: home)
        let fileManager = FileManager.default
        guard let type = (try? fileManager.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType else {
            return .missing
        }
        guard type == .typeSymbolicLink, let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else {
            return .blocked
        }
        let target = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.path
        if target == URL(fileURLWithPath: script("cantrip", app: app, home: home)).standardizedFileURL.path { return .installed }
        let ours = target.hasSuffix("/Scripts/cantrip") || target.hasSuffix("/Contents/Resources/bin/cantrip")
        return ours || !fileManager.fileExists(atPath: target) ? .otherCantrip(tilde(target, home: home)) : .blocked
    }

    static func commandLineToolStatus(app: URL = Bundle.main.bundleURL,
                                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        switch commandLineTool(app: app, home: home) {
        case .installed: return "Installed as ~/.local/bin/cantrip"
        case .missing: return "Not installed"
        case .otherCantrip(let target): return "~/.local/bin/cantrip runs another Cantrip (\(target))"
        case .blocked: return "~/.local/bin/cantrip is another program, so Cantrip leaves it alone"
        }
    }

    struct InstallError: LocalizedError {
        let errorDescription: String?
    }

    /// Links `~/.local/bin/cantrip` to this app's CLI and, when no shell startup file mentions
    /// `.local/bin`, adds it to PATH in `~/.zshrc`, as `./install.sh` does. Returns what changed.
    @discardableResult
    static func installCommandLineTool(app: URL = Bundle.main.bundleURL,
                                       home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        let fileManager = FileManager.default
        let target = script("cantrip", app: app, home: home)
        guard fileManager.isExecutableFile(atPath: target) else {
            throw InstallError(errorDescription: "This Cantrip doesn't include the cantrip command.")
        }
        let link = commandLineLink(home: home)
        switch commandLineTool(app: app, home: home) {
        case .blocked:
            throw InstallError(errorDescription: "~/.local/bin/cantrip is another program. Move it away, then install again.")
        case .installed, .otherCantrip:
            try fileManager.removeItem(at: link)
        case .missing:
            break
        }
        try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target)

        let startupFiles = [".zshrc", ".zprofile", ".zshenv", ".bash_profile", ".bashrc", ".profile"]
            .map { home.appendingPathComponent($0) }
        let onPath = startupFiles.contains { (try? String(contentsOf: $0, encoding: .utf8))?.contains(".local/bin") == true }
        guard !onPath else { return "Installed. Open a new Terminal window to use cantrip." }
        let zshrc = home.appendingPathComponent(".zshrc")
        let line = "\n# Added by Cantrip for the cantrip command\nexport PATH=\"$HOME/.local/bin:$PATH\"\n"
        if let handle = try? FileHandle(forWritingTo: zshrc) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try Data(line.dropFirst().utf8).write(to: zshrc)
        }
        return "Installed, and ~/.local/bin was added to PATH in ~/.zshrc. Open a new Terminal window to use cantrip."
    }
}
