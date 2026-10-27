import Foundation

/// Finds the CLIs Cantrip runs (copilot, claude, gh, tailscale) the same way everywhere.
///
/// A configured path wins when it's executable; a configured bare name is looked up instead of the
/// default name. Otherwise: the PATH Cantrip gives the tools it starts (ToolPath), then the tool's
/// own install folders, then the login shell's PATH. Found paths are remembered while they stay
/// executable; a miss isn't, so a CLI installed later is found on the next lookup.
final class ToolLocator: @unchecked Sendable {
    static let shared = ToolLocator()

    private let home: String
    private let inheritedPATH: String?
    private let loginShell: (String) -> String?
    private let lock = NSLock()
    private var found: [String: String] = [:]

    init(home: String = NSHomeDirectory(),
         inheritedPATH: String? = ProcessInfo.processInfo.environment["PATH"],
         loginShell: @escaping (String) -> String? = ToolLocator.loginShellPath) {
        self.home = home
        self.inheritedPATH = inheritedPATH
        self.loginShell = loginShell
    }

    static let copilotFolders = ["~/.npm-global/bin"]
    static let claudeFolders = ["~/.claude/local"]

    var copilot: String? { copilot(configured: "") }
    func copilot(configured: String, askLoginShell: Bool = true) -> String? {
        path(for: "copilot", configured: configured, extraFolders: Self.copilotFolders, askLoginShell: askLoginShell)
    }

    /// What to run for Copilot without blocking on a login shell: the located path, or the configured
    /// value (`copilot` when blank) for the CLI's own lookup to resolve or report missing.
    func copilotCommand(configured: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        return copilot(configured: trimmed, askLoginShell: false) ?? (trimmed.isEmpty ? "copilot" : trimmed)
    }

    var claude: String? { claude(configured: "") }
    func claude(configured: String) -> String? {
        path(for: "claude", configured: configured, extraFolders: Self.claudeFolders)
    }

    var gh: String? { path(for: "gh") }

    var tailscale: String? {
        let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        return Self.isExecutable(app) ? app : path(for: "tailscale")
    }

    /// `extraFolders` may start with `~/` for the home folder.
    func path(for name: String, configured: String = "", extraFolders: [String] = [],
              askLoginShell: Bool = true) -> String? {
        let configured = configured.trimmingCharacters(in: .whitespaces)
        if configured.contains("/") { return Self.isExecutable(configured) ? configured : nil }
        let name = configured.isEmpty ? name : configured
        guard !name.isEmpty, !name.hasPrefix("-") else { return nil }
        if let cached = lock.withLock({ found[name] }), Self.isExecutable(cached) { return cached }

        let folders = ToolPath.value(inherited: inheritedPATH, home: home).split(separator: ":").map(String.init)
            + extraFolders.map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
        var path = folders.lazy.map { "\($0)/\(name)" }.first(where: Self.isExecutable)
        if path == nil, askLoginShell {
            path = loginShell(name).flatMap { $0.hasPrefix("/") && Self.isExecutable($0) ? $0 : nil }
        }
        if let path { lock.withLock { found[name] = path } }
        return path
    }

    /// `command -v` in a login shell. A shell profile can print a banner, so the answer is the last line.
    static func loginShellPath(_ name: String) -> String? {
        guard let output = ProcessRunner.output("/bin/zsh", ["-l", "-c", "command -v \"$1\"", "cantrip", name],
                                                timeout: 10),
              let line = output.split(whereSeparator: \.isNewline).last.map(String.init),
              line.hasPrefix("/") else { return nil }
        return line
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
