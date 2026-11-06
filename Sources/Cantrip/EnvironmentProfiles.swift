import CryptoKit
import Foundation

/// A project's toolchain: the Xcode, Node and PATH every process Cantrip starts there uses, so
/// Claude Code, Copilot, Codex, Antigravity, child tabs, `!` commands and Home runs all build with
/// the same tools. Declared in Cantrip's own state (`~/.cache/Cantrip/environments.json`), never
/// in the project.
struct EnvironmentProfile: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    /// Project folders (`~` allowed). Git worktrees of a checkout inside one share its profile.
    var folders: [String] = []
    /// The Xcode to use: an `Xcode.app` or its `Contents/Developer` folder.
    var developerDir: String?
    /// A Node version such as "22" or "22.23.3", resolved to an installed copy (Homebrew or nvm).
    var node: String?
    /// Folders put first on PATH.
    var path: [String] = []
    /// Plain values only. Secrets stay in the broker.
    var env: [String: String] = [:]
    /// Broker secret names the project uses, for `cantrip secret run`. Their values are never put
    /// in an agent's environment, where a model could read them.
    var secrets: [String] = []

    init(name: String, folders: [String] = [], developerDir: String? = nil, node: String? = nil,
         path: [String] = [], env: [String: String] = [:], secrets: [String] = []) {
        self.name = name
        self.folders = folders
        self.developerDir = developerDir
        self.node = node
        self.path = path
        self.env = env
        self.secrets = secrets
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        folders = try values.decodeIfPresent([String].self, forKey: .folders) ?? []
        developerDir = try values.decodeIfPresent(String.self, forKey: .developerDir)
        node = try values.decodeIfPresent(String.self, forKey: .node)
        path = try values.decodeIfPresent([String].self, forKey: .path) ?? []
        env = try values.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        secrets = try values.decodeIfPresent([String].self, forKey: .secrets) ?? []
    }

    /// The fallback for folders no profile names (and for calls with no project, such as the
    /// OpenAI-compatible API): a profile named "Default" with no folders.
    var isDefault: Bool { folders.isEmpty && name.caseInsensitiveCompare("Default") == .orderedSame }
}

/// A profile with its Xcode and Node found on this Mac.
struct ResolvedEnvironment: Equatable {
    var profile: EnvironmentProfile
    /// `…/Contents/Developer`, for DEVELOPER_DIR.
    var developerDir: String?
    var xcodeVersion: String?
    var nodeVersion: String?
    /// Folders put first on PATH, in order (Node's first).
    var pathPrefix: [String] = []
    /// What can't be applied, such as an Xcode or Node that isn't installed.
    var problems: [String] = []

    /// "Xcode 27.1 · Node 22.23.3", for tab headers.
    var label: String {
        var parts: [String] = []
        if let xcodeVersion { parts.append("Xcode \(xcodeVersion)") }
        if let nodeVersion { parts.append("Node \(nodeVersion)") }
        if !profile.env.isEmpty { parts.append("\(profile.env.count) var\(profile.env.count == 1 ? "" : "s")") }
        if !problems.isEmpty { parts.append("⚠︎ \(problems.count) problem\(problems.count == 1 ? "" : "s")") }
        return parts.isEmpty ? profile.name : parts.joined(separator: " · ")
    }

    /// Changes whenever anything a process would see changes, so tabs restart their CLI.
    var fingerprint: String {
        let parts = [profile.name, developerDir ?? "", pathPrefix.joined(separator: ":"),
                     profile.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"),
                     profile.secrets.joined(separator: " ")]
        return SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The variables a process gets (PATH is handled separately: prepended, not replaced).
    var variables: [String: String] {
        var variables = profile.env
        if let developerDir { variables["DEVELOPER_DIR"] = developerDir }
        variables[EnvironmentProfiles.profileVariable] = profile.name
        if !profile.secrets.isEmpty { variables[EnvironmentProfiles.secretsVariable] = profile.secrets.joined(separator: " ") }
        return variables
    }

    var payload: [String: Any] {
        var payload: [String: Any] = ["name": profile.name, "label": label, "path": pathPrefix,
                                      "variables": profile.env.keys.sorted(), "secrets": profile.secrets]
        if let xcodeVersion { payload["xcode"] = xcodeVersion }
        if let developerDir { payload["developerDir"] = developerDir }
        if let nodeVersion { payload["node"] = nodeVersion }
        if !problems.isEmpty { payload["problems"] = problems }
        return payload
    }

    /// A script shells source after their own startup files, which reorder PATH (macOS's
    /// path_helper, Homebrew's shellenv, a `.zshrc` that picks a Node).
    var shellScript: String {
        var lines = ["# Cantrip environment profile “\(profile.name)”. Written by Cantrip: change the profile, not this file."]
        for (name, value) in variables.sorted(by: { $0.key < $1.key }) where SecretNames.isVariableName(name) {
            lines.append("export \(name)=\(value.shellQuoted)")
        }
        // The build queue's shims go first again too: startup files may have moved them back.
        let pathPrefix = ToolPath.leadingFolders + pathPrefix
        if !pathPrefix.isEmpty {
            lines.append("for __cantrip_dir in \(pathPrefix.reversed().map(\.shellQuoted).joined(separator: " ")); do")
            lines.append("  __cantrip_path=\":$PATH:\"; __cantrip_path=\"${__cantrip_path//:\"$__cantrip_dir\":/:}\"")
            lines.append("  __cantrip_path=\"${__cantrip_path#:}\"; __cantrip_path=\"${__cantrip_path%:}\"")
            lines.append("  PATH=\"$__cantrip_dir${__cantrip_path:+:$__cantrip_path}\"")
            lines.append("done")
            lines.append("export PATH; unset __cantrip_dir __cantrip_path")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum EnvironmentProfiles {
    static let profileVariable = "CANTRIP_ENV_PROFILE"
    static let fileVariable = "CANTRIP_ENV_FILE"
    static let secretsVariable = "CANTRIP_PROJECT_SECRETS"
    /// Set while a launcher must find its own tools before the profile applies (the shell hook skips).
    static let holdVariable = "CANTRIP_ENV_HOLD"

    struct Snapshot: Codable, Equatable {
        var profiles: [EnvironmentProfile] = []
    }

    static var file: URL {
        ProcessInfo.processInfo.environment["CANTRIP_ENVIRONMENTS"].map { URL(fileURLWithPath: $0) }
            ?? CantripPaths.cache("environments.json")
    }

    static var scriptsFolder: URL { file.deletingLastPathComponent().appendingPathComponent("environments", isDirectory: true) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (url: URL, modified: Date?, snapshot: Snapshot)?
    nonisolated(unsafe) private static var checkouts: [String: String?] = [:]

    /// The saved profiles, re-read only when the file changes.
    static func load(from url: URL = file) -> Snapshot {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = lock.withLock({ cached }), cached.url == url, cached.modified == modified { return cached.snapshot }
        let snapshot = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
        lock.withLock { cached = (url, modified, snapshot) }
        return snapshot
    }

    static func save(_ snapshot: Snapshot, to url: URL = file) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try PrivateFile.write(try encoder.encode(snapshot), to: url)
        lock.withLock { cached = nil }
    }

    static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        return canonical(expanded)
    }

    /// One spelling per folder: standardized, without macOS's `/private` alias for /var, /tmp
    /// and /etc (which `standardizingPath` drops only for paths that exist).
    static func canonical(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        for alias in ["/private/var", "/private/tmp", "/private/etc"]
        where standard == alias || standard.hasPrefix(alias + "/") {
            return String(standard.dropFirst("/private".count))
        }
        return standard
    }

    /// The main checkout of the git worktree `folder` is in (with the same subfolder), or nil when
    /// it isn't a linked worktree.
    static func mainCheckout(of folder: String) -> String? {
        let start = canonical(folder)
        if let known = lock.withLock({ checkouts[start] }) { return known }
        var found: String?
        var current = start
        var relative: [String] = []
        let manager = FileManager.default
        while current != "/" && !current.isEmpty {
            let dotGit = current + "/.git"
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if !isDirectory.boolValue,
                   let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                   let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) {
                    var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    if !gitdir.hasPrefix("/") { gitdir = (current as NSString).appendingPathComponent(gitdir) }
                    if let range = canonical(gitdir).range(of: "/.git/worktrees/") {
                        let main = String(canonical(gitdir)[..<range.lowerBound])
                        found = ([main] + relative.reversed()).joined(separator: "/")
                    }
                }
                break
            }
            relative.append((current as NSString).lastPathComponent)
            current = (current as NSString).deletingLastPathComponent
        }
        lock.withLock { checkouts[start] = .some(found) }
        return found
    }

    /// The profile for processes in `workdir`: the one with the deepest folder containing it (or
    /// its main checkout, for a worktree), else Default. Nil when neither exists.
    static func profile(for workdir: String?, in snapshot: Snapshot? = nil, home: String = NSHomeDirectory()) -> EnvironmentProfile? {
        let profiles = (snapshot ?? load()).profiles
        if let workdir, !workdir.isEmpty {
            let places = [canonical(workdir)] + [mainCheckout(of: workdir)].compactMap { $0 }
            var best: (profile: EnvironmentProfile, depth: Int)?
            for profile in profiles {
                for folder in profile.folders.map({ expand($0, home: home) }) {
                    guard places.contains(where: { $0 == folder || $0.hasPrefix(folder + "/") }) else { continue }
                    if folder.count > best?.depth ?? -1 { best = (profile, folder.count) }
                }
            }
            if let best { return best.profile }
        }
        return profiles.first(where: \.isDefault)
    }

    /// Finds the profile's Xcode and Node.
    static func resolve(_ profile: EnvironmentProfile, home: String = NSHomeDirectory(),
                        nodeRoots: [String]? = nil) -> ResolvedEnvironment {
        var resolved = ResolvedEnvironment(profile: profile)
        if let requested = profile.developerDir, !requested.isEmpty {
            var developer = expand(requested, home: home)
            if developer.hasSuffix(".app") { developer += "/Contents/Developer" }
            if FileManager.default.fileExists(atPath: developer + "/usr/bin") {
                resolved.developerDir = developer
                resolved.xcodeVersion = xcodeVersion(developerDir: developer)
            } else {
                resolved.problems.append("No Xcode at \(requested)")
            }
        }
        if let requested = profile.node, !requested.isEmpty {
            if let install = nodeInstall(requested, home: home, roots: nodeRoots) {
                resolved.nodeVersion = install.version
                resolved.pathPrefix.append(install.bin)
            } else {
                resolved.problems.append("Node \(requested) isn't installed (brew install node@\(requested.split(separator: ".").first ?? ""))")
            }
        }
        for folder in profile.path.map({ expand($0, home: home) }) where !resolved.pathPrefix.contains(folder) {
            resolved.pathPrefix.append(folder)
        }
        return resolved
    }

    /// "27.1" (or "27.1 beta") from the Xcode that holds `developerDir`.
    static func xcodeVersion(developerDir: String) -> String? {
        let contents = (developerDir as NSString).deletingLastPathComponent
        let plist = (contents as NSString).appendingPathComponent("version.plist")
        guard let data = FileManager.default.contents(atPath: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = object["CFBundleShortVersionString"] as? String else { return nil }
        let app = ((contents as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return app.localizedCaseInsensitiveContains("beta") ? "\(version) beta" : version
    }

    /// The bin folder and version of an installed Node matching `requested` ("22" or "22.23"):
    /// Homebrew's `node@N` and `node`, then nvm's.
    static func nodeInstall(_ requested: String, home: String = NSHomeDirectory(), roots: [String]? = nil) -> (bin: String, version: String)? {
        let wanted = requested.hasPrefix("v") ? String(requested.dropFirst()) : requested
        let major = wanted.split(separator: ".").first.map(String.init) ?? wanted
        func matches(_ version: String) -> Bool { version == wanted || version.hasPrefix(wanted + ".") }
        var candidates: [String] = []
        for prefix in roots ?? ["/opt/homebrew", "/usr/local"] {
            candidates += ["\(prefix)/opt/node@\(major)", "\(prefix)/opt/node"]
        }
        for candidate in candidates {
            let real = (candidate as NSString).resolvingSymlinksInPath
            guard FileManager.default.isExecutableFile(atPath: real + "/bin/node") else { continue }
            // Homebrew keeps each version in Cellar/<formula>/<version>[_revision].
            let folder = (real as NSString).lastPathComponent
            let version = String(folder.split(separator: "_").first ?? Substring(folder))
            if matches(version) { return (candidate + "/bin", version) }
        }
        let nvm = home + "/.nvm/versions/node"
        let installed = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
            .map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
            .filter(matches)
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        if let version = installed.first, FileManager.default.isExecutableFile(atPath: "\(nvm)/v\(version)/bin/node") {
            return ("\(nvm)/v\(version)/bin", version)
        }
        return nil
    }

    nonisolated(unsafe) private static var resolvedCache: [String: (snapshot: Snapshot, at: Date, value: ResolvedEnvironment?)] = [:]

    /// The resolved profile for `workdir`, if any. Tab headers ask on every render, so answers are
    /// reused for a few seconds unless the profiles change.
    static func resolved(for workdir: String?) -> ResolvedEnvironment? {
        let snapshot = load()
        let key = workdir ?? ""
        if let hit = lock.withLock({ resolvedCache[key] }), hit.snapshot == snapshot, Date().timeIntervalSince(hit.at) < 5 {
            return hit.value
        }
        let value = profile(for: workdir, in: snapshot).map { resolve($0) }
        lock.withLock {
            if resolvedCache.count > 200 { resolvedCache.removeAll() }
            resolvedCache[key] = (snapshot, Date(), value)
        }
        return value
    }

    /// Applies `workdir`'s profile to a process environment: PATH folders first, the variables,
    /// and the script shells re-source (`CANTRIP_ENV_FILE`, and `BASH_ENV` for scripts).
    /// Returns the profile applied, if any.
    @discardableResult
    static func apply(to environment: inout [String: String], workdir: String?) -> ResolvedEnvironment? {
        guard let resolved = resolved(for: workdir) else { return nil }
        apply(resolved, to: &environment)
        return resolved
    }

    static func apply(_ resolved: ResolvedEnvironment, to environment: inout [String: String]) {
        for (name, value) in resolved.variables { environment[name] = value }
        // The build queue's shims stay ahead of the profile's folders (`BuildQueue`).
        environment["PATH"] = prepend(ToolPath.leadingFolders + resolved.pathPrefix, to: environment["PATH"])
        if let script = try? writeScript(resolved) {
            environment[fileVariable] = script.path
            // Non-interactive bash reads BASH_ENV; keep one the user set.
            if environment["BASH_ENV"] == nil || environment["BASH_ENV"]?.hasPrefix(scriptsFolder.path) == true {
                environment["BASH_ENV"] = script.path
            }
        }
    }

    /// For a launcher that runs a login shell first and sources the profile itself afterwards:
    /// only the script's path, with the shell hook held off until then.
    @discardableResult
    static func applyAfterLogin(to environment: inout [String: String], workdir: String?) -> ResolvedEnvironment? {
        guard let resolved = resolved(for: workdir), let script = try? writeScript(resolved) else { return nil }
        environment[fileVariable] = script.path
        environment[holdVariable] = "1"
        if environment["BASH_ENV"] == nil || environment["BASH_ENV"]?.hasPrefix(scriptsFolder.path) == true {
            environment["BASH_ENV"] = script.path
        }
        return resolved
    }

    /// A `zsh -l -c` command that notes the login shell's `node` (as `$__cantrip_node`), then
    /// applies the profile from `applyAfterLogin` and runs `command`.
    static func afterLogin(_ command: String) -> String {
        "__cantrip_node=$(command -v node); unset \(holdVariable); "
            + "if [ -n \"$\(fileVariable)\" ] && [ -r \"$\(fileVariable)\" ]; then . \"$\(fileVariable)\"; fi; " + command
    }

    static func prepend(_ folders: [String], to path: String?) -> String {
        let existing = (path ?? "").split(separator: ":").map(String.init).filter { !folders.contains($0) }
        return (folders + existing).joined(separator: ":")
    }

    /// Writes the profile's shell script (only when it changed) and returns where it is.
    static func writeScript(_ resolved: ResolvedEnvironment) throws -> URL {
        let slug = resolved.profile.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let url = scriptsFolder.appendingPathComponent(String(slug) + ".sh")
        let text = resolved.shellScript
        if (try? String(contentsOf: url, encoding: .utf8)) != text {
            try PrivateFile.write(Data(text.utf8), to: url)
        }
        return url
    }

    // MARK: - Shell startup hook

    /// Shells re-apply the profile after their own startup files: macOS's path_helper (login
    /// shells), Homebrew's shellenv or a `.zshrc` that picks a Node would otherwise reorder PATH.
    static let hookMarker = "# Cantrip environment profiles"
    static let hookLine = "\(hookMarker): re-apply a Cantrip tab's profile (does nothing elsewhere).\n"
        + "[ -n \"$\(fileVariable)\" ] && [ -z \"$\(holdVariable)\" ] && [ -r \"$\(fileVariable)\" ] && . \"$\(fileVariable)\"\n"

    /// The startup files that run last for each kind of shell: zsh login (`.zlogin`), zsh
    /// interactive (`.zshrc`), bash login and interactive. Non-interactive bash uses BASH_ENV.
    static func hookFiles(home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        // bash reads the first of these that exists; adding .bash_profile would hide .profile.
        let bashLogin = [".bash_profile", ".bash_login", ".profile"].first { fm.fileExists(atPath: "\(home)/\($0)") } ?? ".bash_profile"
        return [".zshrc", ".zlogin", bashLogin, ".bashrc"].map { "\(home)/\($0)" }
    }

    static func hookInstalled(home: String = NSHomeDirectory()) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: hookFiles(home: home).map { file in
            (file, ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").contains(hookMarker))
        })
    }

    /// Appends the hook to each startup file that lacks it, keeping a backup of the file first.
    /// Returns the files changed.
    static func installHook(home: String = NSHomeDirectory(), now: Date = Date()) throws -> [String] {
        var changed: [String] = []
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        for file in hookFiles(home: home) {
            let existing = (try? String(contentsOfFile: file, encoding: .utf8))
            if existing?.contains(hookMarker) == true { continue }
            if let existing {
                try existing.write(toFile: "\(file).cantrip-backup-\(stamp)", atomically: true, encoding: .utf8)
            }
            let separator = existing.map { $0.isEmpty || $0.hasSuffix("\n") ? "\n" : "\n\n" } ?? ""
            try ((existing ?? "") + separator + hookLine).write(toFile: file, atomically: true, encoding: .utf8)
            changed.append(file)
        }
        return changed
    }

    static func removeHook(home: String = NSHomeDirectory()) throws -> [String] {
        var changed: [String] = []
        for file in hookFiles(home: home) {
            guard let existing = try? String(contentsOfFile: file, encoding: .utf8), existing.contains(hookMarker) else { continue }
            var lines = existing.components(separatedBy: "\n")
            if let start = lines.firstIndex(where: { $0.hasPrefix(hookMarker) }) {
                lines.removeSubrange(start...min(start + 1, lines.count - 1))
                if start > 0, start - 1 < lines.count, lines[start - 1].isEmpty { lines.remove(at: start - 1) }
            }
            try lines.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
            changed.append(file)
        }
        return changed
    }
}
