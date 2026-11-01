import Foundation

// Focused tests for environment profiles, in a temporary home with fake Xcode and Node installs
// and real zsh/bash shells. See the Makefile's test-environments.

@main
enum EnvironmentProfileTests {
    static func main() throws {
        requireTemporaryHome()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("env-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = try Fixture(root: root)
        try testMatching(fake)
        try testResolving(fake)
        try testApplying(fake)
        try testShells(fake)
        try testCLI(fake)
        print("Environment profiles: matching, worktrees, Xcode/Node resolution, PATH order in zsh and bash, the hook and the CLI passed")
    }

    static func requireTemporaryHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let real = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)).standardizedFileURL.path }
        guard let testHome = ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"],
              URL(fileURLWithPath: testHome).standardizedFileURL.path == home, home != real else {
            fatalError("Environment tests write shell startup files in the home folder; run them with `make test-environments`")
        }
    }

    /// Fake Xcodes, Homebrew Node installs and a git repository with a linked worktree.
    struct Fixture {
        let root: URL
        let home: String
        let brew: String
        let repo: String
        let worktree: String
        let xcode: String
        let beta: String

        init(root: URL) throws {
            self.root = root
            home = NSHomeDirectory()
            let fm = FileManager.default
            brew = root.appendingPathComponent("brew").path
            for (formula, version, node) in [("node@22", "22.23.3_3", "22"), ("node@20", "20.20.2", "20"), ("node", "26.12.0", "26")] {
                let cellar = "\(brew)/Cellar/\(formula)/\(version)/bin"
                try fm.createDirectory(atPath: cellar, withIntermediateDirectories: true)
                try "#!/bin/sh\necho v\(node)\n".write(toFile: cellar + "/node", atomically: true, encoding: .utf8)
                chmod(cellar + "/node", 0o755)
                try fm.createDirectory(atPath: "\(brew)/opt", withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: "\(brew)/opt/\(formula)", withDestinationPath: "../Cellar/\(formula)/\(version)")
            }
            func makeXcode(_ name: String, _ version: String) throws -> String {
                let app = root.appendingPathComponent("\(name).app").path
                try fm.createDirectory(atPath: app + "/Contents/Developer/usr/bin", withIntermediateDirectories: true)
                let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
                try plist.write(to: URL(fileURLWithPath: app + "/Contents/version.plist"))
                return app
            }
            xcode = try makeXcode("Xcode", "27.1")
            beta = try makeXcode("Xcode-27.2-beta", "27.2")
            repo = root.appendingPathComponent("projects/app").path
            worktree = root.appendingPathComponent("worktrees/child").path
            try fm.createDirectory(atPath: repo + "/tools", withIntermediateDirectories: true)
            for arguments in [["init", "-q", "-b", "main"], ["-c", "user.email=t@example.invalid", "-c", "user.name=T", "commit", "-q", "--allow-empty", "-m", "x"],
                              ["worktree", "add", "-q", "-b", "child", worktree]] {
                let result = try ProcessRunner.run("/usr/bin/git", ["-C", repo] + arguments)
                precondition(result.succeeded, "git \(arguments): \(result.errorText)")
            }
            try fm.createDirectory(atPath: worktree + "/tools", withIntermediateDirectories: true)
        }
    }

    static func testMatching(_ fake: Fixture) throws {
        let snapshot = EnvironmentProfiles.Snapshot(profiles: [
            EnvironmentProfile(name: "Default", node: "26"),
            EnvironmentProfile(name: "App", folders: [fake.repo], node: "22"),
            EnvironmentProfile(name: "Tools", folders: [fake.repo + "/tools"], node: "20"),
            EnvironmentProfile(name: "Elsewhere", folders: ["~/elsewhere"]),
        ])
        func name(_ folder: String?) -> String? { EnvironmentProfiles.profile(for: folder, in: snapshot)?.name }
        precondition(name(fake.repo) == "App" && name(fake.repo + "/src/deep") == "App")
        precondition(name(fake.repo + "/tools") == "Tools", "The deepest folder wins")
        precondition(EnvironmentProfiles.mainCheckout(of: fake.worktree)?.hasSuffix("/projects/app") == true,
                     "\(String(describing: EnvironmentProfiles.mainCheckout(of: fake.worktree)))")
        precondition(name(fake.worktree) == "App", "A worktree (a child tab) shares its checkout's profile")
        precondition(name(fake.worktree + "/tools") == "Tools", "…including a subfolder's")
        precondition(EnvironmentProfiles.mainCheckout(of: fake.repo) == nil, "A main checkout isn't a worktree")
        precondition(name(fake.home + "/elsewhere/x") == "Elsewhere", "~ expands")
        precondition(name(fake.repo + "-other") == "Default", "A sibling with the same prefix doesn't match")
        precondition(name(nil) == "Default" && name("/") == "Default", "No project gets Default")
        precondition(name("/private" + fake.repo) == "App" || !fake.repo.hasPrefix("/var/"), "/private/var and /var are the same folder")
        precondition(EnvironmentProfiles.canonical("/private/var/x/../y") == "/var/y" && EnvironmentProfiles.canonical("/privatefoo") == "/privatefoo")
        precondition(EnvironmentProfiles.profile(for: "/", in: .init(profiles: [snapshot.profiles[1]])) == nil)
    }

    static func testResolving(_ fake: Fixture) throws {
        let resolved = EnvironmentProfiles.resolve(EnvironmentProfile(name: "App", developerDir: fake.xcode, node: "22",
                                                                      path: ["~/bin", "~/bin"], env: ["MODE": "debug"]),
                                                   nodeRoots: [fake.brew])
        precondition(resolved.developerDir == fake.xcode + "/Contents/Developer" && resolved.xcodeVersion == "27.1")
        precondition(resolved.nodeVersion == "22.23.3", "Homebrew's revision suffix is dropped: \(resolved.nodeVersion ?? "nil")")
        precondition(resolved.pathPrefix == ["\(fake.brew)/opt/node@22/bin", fake.home + "/bin"], "\(resolved.pathPrefix)")
        precondition(resolved.label == "Xcode 27.1 · Node 22.23.3 · 1 var" && resolved.problems.isEmpty, resolved.label)
        precondition(EnvironmentProfiles.resolve(EnvironmentProfile(name: "B", developerDir: fake.beta + "/Contents/Developer"),
                                                 nodeRoots: [fake.brew]).xcodeVersion == "27.2 beta")
        precondition(EnvironmentProfiles.resolve(EnvironmentProfile(name: "N", node: "26.12"), nodeRoots: [fake.brew]).nodeVersion == "26.12.0",
                     "The unversioned formula serves its own version")
        let missing = EnvironmentProfiles.resolve(EnvironmentProfile(name: "M", developerDir: "/nowhere/Xcode.app", node: "18"),
                                                  nodeRoots: [fake.brew])
        precondition(missing.problems.count == 2 && missing.developerDir == nil && missing.pathPrefix.isEmpty && missing.label.contains("⚠︎"))
        let nvm = fake.home + "/.nvm/versions/node/v18.20.1/bin"
        try FileManager.default.createDirectory(atPath: nvm, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: nvm + "/node", contents: Data(), attributes: [.posixPermissions: 0o755])
        precondition(EnvironmentProfiles.nodeInstall("18", roots: [fake.brew])?.bin == nvm, "nvm installs are found too")
        let a = resolved.fingerprint
        var changed = resolved
        changed.profile.env["MODE"] = "release"
        precondition(a != changed.fingerprint && a == resolved.fingerprint, "The fingerprint follows what processes see")
    }

    static func profile(_ fake: Fixture) -> ResolvedEnvironment {
        EnvironmentProfiles.resolve(EnvironmentProfile(name: "App", folders: [fake.repo], developerDir: fake.xcode, node: "22",
                                                       env: ["QUOTED": "it's \"x\" $HOME"], secrets: ["example"]),
                                    nodeRoots: [fake.brew])
    }

    static func testApplying(_ fake: Fixture) throws {
        let resolved = profile(fake)
        var environment = ["PATH": "/usr/bin:\(fake.brew)/opt/node@22/bin:/bin", "KEEP": "1"]
        EnvironmentProfiles.apply(resolved, to: &environment)
        precondition(environment["PATH"] == "\(fake.brew)/opt/node@22/bin:/usr/bin:/bin", environment["PATH"]!)
        precondition(environment["DEVELOPER_DIR"] == fake.xcode + "/Contents/Developer" && environment["KEEP"] == "1")
        precondition(environment[EnvironmentProfiles.profileVariable] == "App" && environment[EnvironmentProfiles.secretsVariable] == "example",
                     "Secrets are named, never given")
        let script = environment[EnvironmentProfiles.fileVariable]!
        precondition(environment["BASH_ENV"] == script && FileManager.default.fileExists(atPath: script))
        let mode = (try FileManager.default.attributesOfItem(atPath: script)[.posixPermissions] as? NSNumber)?.intValue
        precondition(mode == 0o600)
        var own = ["BASH_ENV": "/somewhere/mine.sh"]
        EnvironmentProfiles.apply(resolved, to: &own)
        precondition(own["BASH_ENV"] == "/somewhere/mine.sh", "A BASH_ENV the user set is kept")
        var later = ["PATH": "/usr/bin"]
        EnvironmentProfiles.applyAfterLogin(to: &later, workdir: nil)
        precondition(later["PATH"] == "/usr/bin", "Nothing applies without a profile file")
    }

    static func shell(_ executable: String, _ arguments: [String], _ environment: [String: String]) throws -> String {
        let result = try ProcessRunner.run(executable, arguments, environment: environment, timeout: 20)
        precondition(result.succeeded, "\(executable) \(arguments): \(result.errorText)")
        return result.text
    }

    static func testShells(_ fake: Fixture) throws {
        let resolved = profile(fake)
        let script = try EnvironmentProfiles.writeScript(resolved)
        let node22 = "\(fake.brew)/opt/node@22/bin", node26 = "\(fake.brew)/opt/node/bin", node20 = "\(fake.brew)/opt/node@20/bin"
        // Startup files that pick other Nodes, as a .zprofile's brew shellenv and a .zshrc's node@20 do.
        try "export PATH=\"\(node26):$PATH\"\n".write(toFile: fake.home + "/.zprofile", atomically: true, encoding: .utf8)
        try "export PATH=\"\(node20):$PATH\"\n".write(toFile: fake.home + "/.zshrc", atomically: true, encoding: .utf8)
        try "export PATH=\"\(node20):$PATH\"\n".write(toFile: fake.home + "/.bash_profile", atomically: true, encoding: .utf8)
        let check = "printf '%s|%s|%s' \"$(node)\" \"$DEVELOPER_DIR\" \"$QUOTED\""
        var base = ["HOME": fake.home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        EnvironmentProfiles.apply(resolved, to: &base)
        let expected = "v22|\(fake.xcode)/Contents/Developer|it's \"x\" $HOME"

        // Without the hook, login and interactive shells lose the profile's Node.
        let loginBefore = try shell("/bin/zsh", ["-l", "-c", check], base)
        let interactiveBefore = try shell("/bin/zsh", ["-i", "-c", check], base)
        precondition(loginBefore.hasPrefix("v26"), "zsh -l reorders PATH: \(loginBefore)")
        precondition(interactiveBefore.hasPrefix("v20"), "zsh -i reorders PATH: \(interactiveBefore)")
        let installed = try EnvironmentProfiles.installHook(home: fake.home)
        precondition(installed.count == 4, "\(installed)")
        let again = try EnvironmentProfiles.installHook(home: fake.home)
        precondition(again.isEmpty, "Installing twice changes nothing")
        let backups = try FileManager.default.contentsOfDirectory(atPath: fake.home).filter { $0.contains(".cantrip-backup-") }
        precondition(backups.count == 2, "Existing startup files are backed up first: \(backups)")
        precondition(!FileManager.default.fileExists(atPath: fake.home + "/.profile"), "bash's .profile isn't created next to .bash_profile")

        for (executable, arguments) in [("/bin/zsh", ["-l", "-c", check]), ("/bin/zsh", ["-i", "-c", check]), ("/bin/zsh", ["-c", check]),
                                        ("/bin/bash", ["-l", "-c", check]), ("/bin/bash", ["-c", check]), ("/bin/sh", ["-c", check]),
                                        ("/bin/zsh", ["-l", "-i", "-c", check])] {
            let output = try shell(executable, arguments, base)
            precondition(output == expected, "\(executable) \(arguments): \(output)")
        }
        let path = try shell("/bin/zsh", ["-l", "-c", "printf %s \"$PATH\""], base)
        precondition(path.hasPrefix(node22 + ":") && !path.contains("::") && !path.hasSuffix(":"), path)
        precondition(path.components(separatedBy: ":").filter { $0 == node22 }.count == 1, "Re-applying doesn't stack entries")

        // Terminals (no profile) are untouched by the hook.
        let plain = try shell("/bin/zsh", ["-l", "-i", "-c", "printf %s \"$(node)\""], ["HOME": fake.home, "PATH": "/usr/bin:/bin"])
        precondition(plain == "v20", plain)

        // Copilot's launcher: the runtime keeps the login shell's Node; what it starts gets the profile's.
        var copilot = ["HOME": fake.home, "PATH": "/usr/bin:/bin"]
        precondition(EnvironmentProfiles.applyAfterLogin(to: &copilot, workdir: fake.worktree) == nil, "No saved profiles yet")
        copilot[EnvironmentProfiles.fileVariable] = script.path
        copilot[EnvironmentProfiles.holdVariable] = "1"
        let launched = try shell("/bin/zsh", ["-l", "-c", EnvironmentProfiles.afterLogin("printf '%s|%s' \"$__cantrip_node\" \"$(node)\""), "x"], copilot)
        precondition(launched == "\(node26)/node|v22", "The runtime's own Node comes from the login shell: \(launched)")

        let removed = try EnvironmentProfiles.removeHook(home: fake.home)
        precondition(removed.count == 4 && EnvironmentProfiles.hookInstalled(home: fake.home).values.allSatisfy { !$0 })
        let zshrc = try String(contentsOfFile: fake.home + "/.zshrc", encoding: .utf8)
        precondition(zshrc == "export PATH=\"\(node20):$PATH\"\n", "Removing restores the file: \(zshrc.debugDescription)")
    }

    static func testCLI(_ fake: Fixture) throws {
        let file = fake.root.appendingPathComponent("state/environments.json")
        setenv("CANTRIP_ENVIRONMENTS", file.path, 1)
        defer { unsetenv("CANTRIP_ENVIRONMENTS") }
        try EnvironmentCLI.set(["App", "--folder", fake.repo, "--xcode", fake.xcode, "--node", "22", "--env", "MODE=debug",
                                "--secret", "example", "--path", "~/bin"])
        try EnvironmentCLI.set(["App", "--env", "OTHER=1", "--unset", "MODE"])
        var saved = EnvironmentProfiles.load(from: file).profiles
        precondition(saved.count == 1 && saved[0].env == ["OTHER": "1"] && saved[0].node == "22" && saved[0].folders == [fake.repo])
        try EnvironmentCLI.set(["App", "--node", "", "--clear", "--folder", fake.worktree])
        saved = EnvironmentProfiles.load(from: file).profiles
        precondition(saved[0].node == nil && saved[0].folders == [fake.worktree] && saved[0].env.isEmpty && saved[0].developerDir == fake.xcode)
        for bad in [["App", "--env", "1BAD=x"], ["App", "--secret", "has space"], ["App", "--bogus"], ["--node"]] {
            do { try EnvironmentCLI.set(bad); fatalError("\(bad) should fail") } catch is EnvironmentCLI.Failure {}
        }
        try EnvironmentCLI.remove(["App"])
        precondition(EnvironmentProfiles.load(from: file).profiles.isEmpty)

        // Relative folders are saved, and looked up, as absolute ones.
        let previous = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        FileManager.default.changeCurrentDirectoryPath(fake.repo)
        try EnvironmentCLI.set(["Here", "--folder", ".", "--path", "bin"])
        let here = EnvironmentProfiles.load(from: file).profiles[0]
        let cwd = EnvironmentProfiles.canonical(FileManager.default.currentDirectoryPath)
        precondition(here.folders == [cwd] && here.path == [cwd + "/bin"], "\(here.folders) \(here.path)")
        precondition(EnvironmentCLI.absolute("tools/../tools") == cwd + "/tools" && EnvironmentCLI.absolute("~/x") == fake.home + "/x")
        precondition(EnvironmentProfiles.resolved(for: EnvironmentCLI.absolute("."))?.profile.name == "Here")
        try EnvironmentCLI.remove(["Here"])
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        precondition(mode == 0o600, "Profiles are private to the user")
    }
}
