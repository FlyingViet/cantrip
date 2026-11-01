import Foundation

/// `cantrip env …`: per-project environment profiles (Xcode, Node, PATH, variables) that every
/// process Cantrip starts in a project uses.
enum EnvironmentCLI {
    static let usage = """
    Usage:
      cantrip env [list]              Profiles, their folders, and what they resolve to on this Mac
      cantrip env show [FOLDER] [--json]
                                      The profile processes in FOLDER (default: here) get, and its Xcode, Node and PATH
      cantrip env run [--dir FOLDER | --profile NAME] -- COMMAND [ARGS...]
                                      Run COMMAND with a profile applied, as Cantrip's backends would
      cantrip env set NAME [--folder F]... [--xcode PATH] [--node VERSION] [--path FOLDER]...
                      [--env KEY=VALUE]... [--unset KEY]... [--secret NAME]... [--clear]
                                      Create or change a profile (--clear drops its folders, PATH and variables first;
                                      --xcode "" or --node "" removes that choice). A profile named Default with no
                                      folders applies where no other profile does. Variables are plain values; give
                                      secrets as broker names (cantrip secret list)
      cantrip env remove NAME
      cantrip env hook [status|install|remove]
                                      Shells re-apply a tab's profile after their startup files (which reorder PATH).
                                      install adds two guarded lines to .zshrc, .zlogin and bash's startup files,
                                      backing each up first; they do nothing outside Cantrip's processes
    """

    struct Failure: LocalizedError {
        let message: String
        var code: Int32 = 1
        var errorDescription: String? { message }
    }

    static func main(_ arguments: [String]) -> Int32 {
        do {
            return try run(arguments)
        } catch {
            FileHandle.standardError.write(Data(("cantrip env: " + error.localizedDescription + "\n").utf8))
            return (error as? Failure)?.code ?? 1
        }
    }

    static func run(_ arguments: [String]) throws -> Int32 {
        let rest = Array(arguments.dropFirst())
        switch arguments.first {
        case nil, "list": list()
        case "show": try show(rest)
        case "run": return try runCommand(rest)
        case "set": try set(rest)
        case "remove", "rm": try remove(rest)
        case "hook": try hook(rest)
        case "help", "-h", "--help": print(usage)
        default: throw Failure(message: usage, code: 2)
        }
        return 0
    }

    static func describe(_ resolved: ResolvedEnvironment) -> [String] {
        var lines: [String] = []
        let profile = resolved.profile
        lines.append("\(profile.name): \(resolved.label)")
        if !profile.folders.isEmpty { lines.append("  folders: \(profile.folders.joined(separator: ", "))") }
        if let developer = resolved.developerDir { lines.append("  DEVELOPER_DIR=\(developer)") }
        if !resolved.pathPrefix.isEmpty { lines.append("  PATH first: \(resolved.pathPrefix.joined(separator: ":"))") }
        if !profile.env.isEmpty { lines.append("  variables: \(profile.env.keys.sorted().joined(separator: " "))") }
        if !profile.secrets.isEmpty { lines.append("  secrets (cantrip secret run): \(profile.secrets.joined(separator: " "))") }
        for problem in resolved.problems { lines.append("  ⚠︎ \(problem)") }
        return lines
    }

    static func list() {
        let profiles = EnvironmentProfiles.load().profiles
        if profiles.isEmpty {
            print("No environment profiles yet. Add one with `cantrip env set NAME --folder ~/path --xcode /Applications/Xcode.app --node 22`.")
        }
        for profile in profiles { print(describe(EnvironmentProfiles.resolve(profile)).joined(separator: "\n")) }
        let hooks = EnvironmentProfiles.hookInstalled()
        if hooks.values.contains(false) {
            let missing = hooks.filter { !$0.value }.keys.map { ($0 as NSString).lastPathComponent }.sorted()
            print("\nShell hook missing from \(missing.joined(separator: ", ")): login and interactive shells may reorder PATH. See `cantrip env hook install`.")
        }
    }

    static func show(_ arguments: [String]) throws {
        let folder = arguments.first { !$0.hasPrefix("-") }.map { EnvironmentProfiles.expand($0) }
            ?? FileManager.default.currentDirectoryPath
        guard let resolved = EnvironmentProfiles.resolved(for: folder) else {
            if arguments.contains("--json") { print("{}") } else { print("No profile applies to \(folder).") }
            return
        }
        if arguments.contains("--json") {
            let data = try JSONSerialization.data(withJSONObject: resolved.payload, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            if let main = EnvironmentProfiles.mainCheckout(of: folder) { print("(a worktree of \(main))") }
            print(describe(resolved).joined(separator: "\n"))
        }
    }

    /// Replaces this process with COMMAND under the profile, so its exit status and terminal are its own.
    static func runCommand(_ arguments: [String]) throws -> Int32 {
        guard let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count else {
            throw Failure(message: "Usage: cantrip env run [--dir FOLDER | --profile NAME] -- COMMAND", code: 2)
        }
        let options = Array(arguments[..<separator]), command = Array(arguments[(separator + 1)...])
        var resolved: ResolvedEnvironment?
        if let index = options.firstIndex(of: "--profile"), index + 1 < options.count {
            guard let profile = EnvironmentProfiles.load().profiles.first(where: { $0.name == options[index + 1] }) else {
                throw Failure(message: "No profile named \(options[index + 1]).")
            }
            resolved = EnvironmentProfiles.resolve(profile)
        } else {
            let folder = options.firstIndex(of: "--dir").flatMap { $0 + 1 < options.count ? options[$0 + 1] : nil }
                .map { EnvironmentProfiles.expand($0) } ?? FileManager.default.currentDirectoryPath
            resolved = EnvironmentProfiles.resolved(for: folder)
        }
        var environment = ToolPath.environment()
        if let resolved { EnvironmentProfiles.apply(resolved, to: &environment) }
        guard let executable = SecretRunner.resolve(command[0], path: environment["PATH"]) else {
            throw Failure(message: "\(command[0]): command not found.", code: 127)
        }
        let argv = command.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(executable, argv, envp)
        throw Failure(message: "\(command[0]): \(String(cString: strerror(errno)))", code: 126)
    }

    static func set(_ arguments: [String]) throws {
        guard let name = arguments.first, !name.hasPrefix("-") else { throw Failure(message: usage, code: 2) }
        var snapshot = EnvironmentProfiles.load()
        var profile = snapshot.profiles.first { $0.name == name } ?? EnvironmentProfile(name: name)
        var index = 1
        func value(_ option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw Failure(message: "\(option) needs a value.", code: 2) }
            return arguments[index]
        }
        if arguments.contains("--clear") { profile.folders = []; profile.path = []; profile.env = [:]; profile.secrets = [] }
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--clear": break
            case "--folder":
                let folder = try value(option)
                if !profile.folders.contains(folder) { profile.folders.append(folder) }
            case "--xcode": let xcode = try value(option); profile.developerDir = xcode.isEmpty ? nil : xcode
            case "--node": let node = try value(option); profile.node = node.isEmpty ? nil : node
            case "--path":
                let folder = try value(option)
                if !profile.path.contains(folder) { profile.path.append(folder) }
            case "--env":
                let pair = try value(option)
                guard let equals = pair.firstIndex(of: "="), SecretNames.isVariableName(String(pair[..<equals])) else {
                    throw Failure(message: "--env needs KEY=VALUE.", code: 2)
                }
                profile.env[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            case "--unset": profile.env.removeValue(forKey: try value(option))
            case "--secret":
                let secret = try value(option)
                guard SecretNames.isItemName(secret) else { throw Failure(message: "“\(secret)” isn't a secret name.", code: 2) }
                if !profile.secrets.contains(secret) { profile.secrets.append(secret) }
            default:
                throw Failure(message: "Unknown option \(option). \(usage)", code: 2)
            }
            index += 1
        }
        if let existing = snapshot.profiles.firstIndex(where: { $0.name == name }) {
            snapshot.profiles[existing] = profile
        } else {
            snapshot.profiles.append(profile)
        }
        try EnvironmentProfiles.save(snapshot)
        print(describe(EnvironmentProfiles.resolve(profile)).joined(separator: "\n"))
        print("Tabs in these folders restart their CLI with it at their next message (conversations continue).")
    }

    static func remove(_ arguments: [String]) throws {
        guard let name = arguments.first else { throw Failure(message: usage, code: 2) }
        var snapshot = EnvironmentProfiles.load()
        guard snapshot.profiles.contains(where: { $0.name == name }) else { throw Failure(message: "No profile named \(name).") }
        snapshot.profiles.removeAll { $0.name == name }
        try EnvironmentProfiles.save(snapshot)
        print("Removed \(name).")
    }

    static func hook(_ arguments: [String]) throws {
        switch arguments.first ?? "status" {
        case "status":
            for (file, installed) in EnvironmentProfiles.hookInstalled().sorted(by: { $0.key < $1.key }) {
                print("\(installed ? "✓" : "–") \(file)")
            }
        case "install":
            let changed = try EnvironmentProfiles.installHook()
            print(changed.isEmpty ? "The hook is already in every startup file."
                  : "Added the hook to \(changed.joined(separator: ", ")) (each backed up next to it as .cantrip-backup-…).")
        case "remove":
            let changed = try EnvironmentProfiles.removeHook()
            print(changed.isEmpty ? "No startup file has the hook." : "Removed the hook from \(changed.joined(separator: ", ")).")
        default:
            throw Failure(message: usage, code: 2)
        }
    }
}
