import Foundation

/// The skills library, folder rules and their checks, in a temporary home: fake skills, fake
/// repositories, no network (repository visibility is answered by the test).
@main
struct SkillsTests {
    static func main() throws {
        guard let home = ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"] else {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-skills-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            var environment = ProcessInfo.processInfo.environment
            for key in ["CFFIXED_USER_HOME", "HOME", "CANTRIP_TAB_TEST_HOME"] { environment[key] = home.path }
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        }
        precondition(FileManager.default.homeDirectoryForCurrentUser.path == home, "Runs only in a temporary home")
        precondition(home.hasPrefix(FileManager.default.temporaryDirectory.path) || home.hasPrefix("/private/var/") || home.hasPrefix("/var/")
                     || home.hasPrefix("/tmp/") || home.hasPrefix("/private/tmp/"), "The test home is a temporary folder")
        let root = URL(fileURLWithPath: home)
        testSecretScan()
        try testSkillsLibrary(home: root)
        try testFolderRules(home: root)
        try testRulesCheck(home: root)
        print("Skills and folder rules: secret scan, library links, manifest, history, rules, worktrees, mirrors and drift checks passed")
    }

    // MARK: - Helpers

    static func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func skill(_ name: String, extra: String = "") -> String {
        "---\nname: \(name)\ndescription: Does \(name) things.\n---\n# \(name)\n\nRun `scripts/run.sh`.\n\(extra)"
    }

    static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    static func link(_ url: URL) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) }

    static func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

    @discardableResult
    static func git(_ directory: URL, _ arguments: [String]) -> String {
        let result = try? ProcessRunner.run("/usr/bin/git", ["-C", directory.path] + arguments, errorOutput: .discard, timeout: 30)
        return result?.text ?? ""
    }

    // Built at run time so this file never holds a token-shaped literal.
    static let fakeToken = "gh" + "p_" + String(repeating: "A1b2C3d4", count: 5)
    static let fakeHex = String(repeating: "9f8e7d6c5b4a", count: 3)

    // MARK: - Secret scan

    static func testSecretScan() {
        let flagged = [
            "TOKEN=\(fakeToken)",
            "export HA_TOKEN=\(fakeHex)",
            "curl https://admin:Hunter22pass@nas.example/api",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "\"password\": \"Zq8\(fakeHex)\"",
            "Authorization: Bearer \(fakeHex)",
        ]
        for line in flagged {
            let findings = SecretScan.scan(text: "intro\n\(line)\n", file: "x.sh")
            precondition(findings.first?.line == 2, "Flagged: \(line.prefix(12))…")
            precondition(!findings.map(\.description).joined().contains(fakeHex) && !findings.map(\.description).joined().contains(fakeToken),
                         "A finding never shows the value")
        }
        let clean = [
            "TOKEN=\"$HA_TOKEN\"",
            "export API_KEY=${API_KEY:-}",
            "curl -H \"Authorization: Bearer $TOKEN\" \"$HA_URL/api/states\"",
            "source ~/.hermes/secrets/homeassistant.env",
            "API_KEY=your-api-key-here",
            "The token is stored in the keychain; never print the password.",
            "token = os.environ[\"HA_TOKEN\"]",
            "password: <from Bitwarden>",
            "AUTH_TOKEN=$(security find-generic-password -s x -w)",
            "secret_name=homeassistant-long-lived-access",
            "cantrip secret run homeassistant -- ./scripts/ha.sh states",
        ]
        for line in clean {
            precondition(SecretScan.scan(text: line, file: "x").isEmpty, "Not a credential: \(line)")
        }
    }

    // MARK: - Library

    static func testSkillsLibrary(home: URL) throws {
        let fm = FileManager.default
        let library = SkillsLibrary(home: home)
        let claude = home.appendingPathComponent(".claude/skills"), agents = home.appendingPathComponent(".agents/skills")
        let hermes = home.appendingPathComponent(".hermes/skills/cat")
        // A skill linked from another tool's folder, a real one, one shared file by file, Claude's
        // own synced set and an installer's skill (both must stay untouched), and a dead link.
        try write(skill("arr"), hermes.appendingPathComponent("arr/SKILL.md"))
        try write("#!/bin/sh\necho arr\n", hermes.appendingPathComponent("arr/scripts/run.sh"))
        try fm.createDirectory(at: claude, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: claude.appendingPathComponent("arr"), withDestinationURL: hermes.appendingPathComponent("arr"))
        try write(skill("fire"), claude.appendingPathComponent("fire/SKILL.md"))
        try write(skill("port"), hermes.appendingPathComponent("port/SKILL.md"))
        try fm.createDirectory(at: claude.appendingPathComponent("port"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: claude.appendingPathComponent("port/SKILL.md"), withDestinationURL: hermes.appendingPathComponent("port/SKILL.md"))
        try write("synced", claude.appendingPathComponent("synced/docs/SKILL.md"))
        try write(skill("installer"), agents.appendingPathComponent("installer/SKILL.md"))
        try fm.createSymbolicLink(at: claude.appendingPathComponent("gone"), withDestinationURL: hermes.appendingPathComponent("gone"))
        let untouched = { (try? fm.contentsOfDirectory(atPath: claude.appendingPathComponent("synced").path)) ?? [] }
        let before = untouched()

        // A linked skill moves in; the old place links to it, and both backend folders link to it.
        var report = try library.add(source: claude.appendingPathComponent("arr"), move: true)
        let arr = library.skillFolder("arr")
        precondition(fm.fileExists(atPath: arr.appendingPathComponent("scripts/run.sh").path), "The whole skill moves")
        precondition(link(hermes.appendingPathComponent("arr")) == arr.path, "Its old place still works")
        precondition(link(claude.appendingPathComponent("arr")) == arr.path && link(agents.appendingPathComponent("arr")) == arr.path,
                     "Claude's link switches to the library, and the other backends get one")
        precondition(report.linked.count == 2 && report.problems.isEmpty, "\(report)")
        let manifest = library.loadManifest()
        precondition(manifest.skills["arr"]?.enabled == true && manifest.skills["arr"]?.links.count == 2, "The manifest records Cantrip's links")
        precondition(fm.fileExists(atPath: library.folder.appendingPathComponent("README.md").path)
                     && read(library.folder.appendingPathComponent("README.md")).contains("Edit skills here"),
                     "The library says to edit there")
        precondition(git(library.folder, ["log", "--format=%s"]).contains("Add arr"), "The library keeps history")

        // A real folder in Claude's folder moves; a folder of links is switched to the library copy.
        try library.add(source: claude.appendingPathComponent("fire"), move: true)
        precondition(link(claude.appendingPathComponent("fire")) == library.skillFolder("fire").path, "A real folder becomes a link")
        try library.add(source: hermes.appendingPathComponent("port"), move: true)
        precondition(link(claude.appendingPathComponent("port")) == library.skillFolder("port").path, "A folder of links to the skill is switched")
        precondition(read(library.skillFolder("port").appendingPathComponent("SKILL.md")).contains("name: port"),
                     "Links are followed when copying")

        // A credential keeps a skill out; the message names the place, never the value.
        try write(skill("leaky", extra: "export TOKEN=\(fakeToken)\n"), home.appendingPathComponent("drafts/leaky/SKILL.md"))
        do {
            try library.add(source: home.appendingPathComponent("drafts/leaky"))
            preconditionFailure("A skill with a credential is refused")
        } catch {
            let message = error.localizedDescription
            precondition(message.contains("leaky/SKILL.md:8") && !message.contains(fakeToken), message)
        }
        precondition(!fm.fileExists(atPath: library.skillFolder("leaky").path), "Nothing was copied")

        // A name clash with something Cantrip didn't make is reported and left alone.
        try write("mine", agents.appendingPathComponent("clash/notes.txt"))
        try write(skill("clash"), home.appendingPathComponent("drafts/clash/SKILL.md"))
        report = try library.add(source: home.appendingPathComponent("drafts/clash"))
        precondition(report.problems.contains { $0.contains("clash") } && link(claude.appendingPathComponent("clash")) != nil, "\(report)")
        precondition(read(agents.appendingPathComponent("clash/notes.txt")) == "mine", "The other folder is untouched")
        let clash = library.list().first { $0.name == "clash" }!
        precondition(clash.backends == ["Claude Code"] && clash.problems.contains { $0.hasPrefix("Name clash") }, "\(clash)")

        // Off removes only Cantrip's links; on puts them back.
        report = try library.setEnabled("arr", false)
        precondition(!exists(claude.appendingPathComponent("arr")) && !exists(agents.appendingPathComponent("arr")) && report.unlinked.count == 2)
        precondition(link(hermes.appendingPathComponent("arr")) == arr.path, "The old place keeps its link")
        precondition(library.list().first { $0.name == "arr" }?.backends == [], "Nobody sees a skill that's off")
        try library.setEnabled("arr", true)
        let arrStatus = library.list().first { $0.name == "arr" }!
        precondition(arrStatus.backends == SkillsLibrary.allBackends && arrStatus.problems.isEmpty && arrStatus.description == "Does arr things.", "\(arrStatus)")

        // A credential added later unlinks the skill at the next sync and stays out of history.
        try write(skill("fire", extra: "API_KEY=\(fakeHex)\n"), library.skillFolder("fire").appendingPathComponent("SKILL.md"))
        report = try library.sync()
        precondition(report.problems.contains { $0.contains("Not linked: fire") } && !exists(claude.appendingPathComponent("fire")), "\(report)")
        precondition(!git(library.folder, ["log", "-p"]).contains(fakeHex), "A credential is never committed")
        precondition(library.check().contains { $0.hasPrefix("fire: Looks like a credential") }, "check reports it")
        try write(skill("fire", extra: "Read the key with `cantrip secret run fire -- cmd`.\n"), library.skillFolder("fire").appendingPathComponent("SKILL.md"))
        try library.sync()
        precondition(link(claude.appendingPathComponent("fire")) != nil && git(library.folder, ["log", "--format=%s"]).contains("Sync"),
                     "Fixed, it's linked again and committed")

        // An edit in the library is what every backend reads (links, not copies).
        try write(skill("arr", extra: "Edited.\n"), arr.appendingPathComponent("SKILL.md"))
        for folder in [claude, agents] {
            precondition(read(folder.appendingPathComponent("arr/SKILL.md")).contains("Edited."))
        }

        // A skill deleted from the library loses its links; a same-named skill elsewhere is flagged.
        try fm.removeItem(at: library.skillFolder("port"))
        report = try library.sync()
        precondition(!exists(claude.appendingPathComponent("port")) && library.loadManifest().skills["port"] == nil, "\(report)")
        try write(skill("arr"), home.appendingPathComponent(".codex/skills/arr/SKILL.md"))
        precondition(library.check("arr").contains { $0.contains("~/.codex/skills") }, "A competing copy is flagged")

        // Other tools' entries were never changed.
        precondition(untouched() == before && fm.fileExists(atPath: agents.appendingPathComponent("installer/SKILL.md").path)
                     && link(claude.appendingPathComponent("gone")) != nil, "Unmanaged entries stay as they were")
        let mode = (try fm.attributesOfItem(atPath: library.manifestFile.path)[.posixPermissions] as? NSNumber)?.intValue
        precondition(mode == 0o600, "The manifest is private")
        precondition(!SkillsLibrary.isValidName("../x") && !SkillsLibrary.isValidName(".git") && SkillsLibrary.isValidName("unifi-direct"))
    }

    // MARK: - Folder rules

    static func testFolderRules(home: URL) throws {
        let fm = FileManager.default
        let store = FolderInstructions(home: home)
        let coding = home.appendingPathComponent("Coding")
        try write("# Old\nRouting table\n", coding.appendingPathComponent("CLAUDE.md"))
        let body = "- Search the notes before non-trivial work.\n- Never commit the notes."
        let rule = try store.save(folder: "~/Coding", body: body, mirror: "~/Coding/CLAUDE.md")
        precondition(rule.folder == coding.path && rule.mirror == coding.appendingPathComponent("CLAUDE.md").path)
        let saved = try String(contentsOf: rule.file, encoding: .utf8)
        precondition(saved.hasPrefix("---\nfolder: ~/Coding\nmirror: ~/Coding/CLAUDE.md\n---\n"), saved)
        let mirror = try String(contentsOf: coding.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        precondition(mirror.hasPrefix("Managed by Cantrip; edit with `cantrip instructions edit ~/Coding`") && mirror.contains(body), mirror)
        precondition(read(store.mirrorBackup(for: rule)).contains("Routing table")
                     && !FileManager.default.fileExists(atPath: coding.appendingPathComponent("CLAUDE.md.before-cantrip").path),
                     "What was there first is kept")

        // Applies to everything under the folder, not to a sibling with the same prefix.
        try fm.createDirectory(at: coding.appendingPathComponent("app/src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("CodingOld"), withIntermediateDirectories: true)
        precondition(store.rules(for: coding.appendingPathComponent("app/src").path).count == 1)
        precondition(store.rules(for: coding.path).count == 1)
        precondition(store.rules(for: home.appendingPathComponent("CodingOld").path).isEmpty)
        precondition(store.rules(for: home.path).isEmpty && store.guidance(for: "") == nil)

        // A child tab's worktree counts as its main checkout's folder.
        let main = coding.appendingPathComponent("app")
        try fm.createDirectory(at: main.appendingPathComponent(".git/worktrees/child"), withIntermediateDirectories: true)
        try write("../..\n", main.appendingPathComponent(".git/worktrees/child/commondir"))
        let worktree = home.appendingPathComponent(".cache/Cantrip/worktrees/child")
        try write("gitdir: \(main.path)/.git/worktrees/child\n", worktree.appendingPathComponent(".git"))
        try fm.createDirectory(at: worktree.appendingPathComponent("src"), withIntermediateDirectories: true)
        precondition(FolderInstructions.effectivePaths(for: worktree.appendingPathComponent("src").path).contains(main.appendingPathComponent("src").path))
        precondition(store.rules(for: worktree.appendingPathComponent("src").path).count == 1, "Worktrees get their checkout's rules")

        // Nested rules come outermost first; each backend's text holds them.
        try store.save(folder: main.path, body: "Use the app's own build script.", mirror: nil)
        let guidance = store.guidance(for: main.appendingPathComponent("src").path)!
        precondition(guidance.contains("Rules for work under ~/Coding (kept in Cantrip)") && guidance.contains(body)
                     && guidance.range(of: "~/Coding/app")!.lowerBound > guidance.range(of: body)!.lowerBound, guidance)
        // Copilot already read a mirror in its working folder; Claude skips the mirror and gets the text.
        precondition(store.guidance(for: coding.path, readsClaudeMdHere: true) == nil, "No second copy for Copilot in the mirror's own folder")
        precondition(store.guidance(for: main.path, readsClaudeMdHere: true)?.contains(body) == true)
        precondition(store.claudeSettings(for: main.path) == "{\"claudeMdExcludes\":[\"\(coding.path)/CLAUDE.md\"]}", store.claudeSettings(for: main.path) ?? "")
        precondition(store.claudeSettings(for: home.path) == nil)

        do {
            try store.save(folder: "~/Coding", body: "token=\(fakeHex)", mirror: nil)
            preconditionFailure("A rule with a credential is refused")
        } catch {
            precondition(!error.localizedDescription.contains(fakeHex))
        }
        precondition(store.rules(for: coding.path).first?.body == body, "The refused edit changed nothing")
        try fm.removeItem(at: store.rule(forFolder: main.path)!.file)
        try fm.removeItem(at: main.appendingPathComponent(".git"))
    }

    // MARK: - Drift check

    static func testRulesCheck(home: URL) throws {
        let store = FolderInstructions(home: home)
        let coding = home.appendingPathComponent("Coding")
        func repo(_ name: String, _ files: [String: String]) throws -> URL {
            let url = coding.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            git(url, ["init", "-q"])
            for (file, text) in files { try write(text, url.appendingPathComponent(file)) }
            git(url, ["add", "-A"])
            return url
        }
        precondition(FolderInstructions.isPointer(FolderInstructions.pointerText))
        precondition(FolderInstructions.isPointer("Gemini CLI reads this file. The guide is AGENTS.md, imported below.\n\n@AGENTS.md\n"))
        precondition(!FolderInstructions.isPointer("@AGENTS.md\n\n## Also\n- build with make\n"))
        precondition(!FolderInstructions.isPointer("# Rules\n- build with make\n"))

        let converted = try repo("converted", ["AGENTS.md": "# Agents\nBuild with make.\n", "CLAUDE.md": FolderInstructions.pointerText])
        let legacy = try repo("legacy", ["CLAUDE.md": "# Rules\nBuild with make.\n"])
        let grew = try repo("grew", ["AGENTS.md": "# Agents\n", "CLAUDE.md": FolderInstructions.pointerText + "\n- Also run lint\n",
                                     "tools/CLAUDE.md": "# Tools only\n"])
        let leakyPublic = try repo("public", ["AGENTS.md": "# Agents\nThe NAS is at 10.20.30.40; mail me at someone@mail.invalid.\nAsk Zorblax first.\n",
                                              "CLAUDE.md": FolderInstructions.pointerText])
        let privateRepo = try repo("private", ["AGENTS.md": "# Agents\nThe NAS is at 10.20.30.40.\n", "CLAUDE.md": FolderInstructions.pointerText])
        try write("# Private words\nZorblax\n", store.privateTermsFile)
        let findings = store.check { path in path == leakyPublic.path ? true : path == privateRepo.path ? false : nil }
        let text = findings.map(\.description)
        func has(_ repo: URL, _ file: String, _ fragment: String) -> Bool {
            findings.contains { $0.path.hasSuffix("/\(repo.lastPathComponent)/\(file)") && $0.problem.contains(fragment) }
        }
        precondition(!findings.contains { $0.path.contains("/converted/") }, "A converted repo is clean: \(text)")
        precondition(has(legacy, "CLAUDE.md", "no AGENTS.md"), "\(text)")
        precondition(has(grew, "CLAUDE.md", "its own rules") && has(grew, "tools/CLAUDE.md", "no AGENTS.md"), "\(text)")
        precondition(has(leakyPublic, "AGENTS.md", "local network address") && has(leakyPublic, "AGENTS.md", "email address")
                     && has(leakyPublic, "AGENTS.md", "private name"), "\(text)")
        precondition(!findings.contains { $0.path.contains("/private/") }, "Private repos may name their own hosts: \(text)")
        precondition(!text.joined().contains("192.168") && !text.joined().contains("Zorblax"), "Findings never repeat the content")
        precondition(!findings.contains { $0.path.hasSuffix("Coding/CLAUDE.md") }, "The mirror is up to date: \(text)")

        // A hand edit to the mirror is drift.
        try write("Managed by Cantrip\n\nsomething else\n", coding.appendingPathComponent("CLAUDE.md"))
        precondition(store.check { _ in nil }.contains { $0.path == "~/Coding/CLAUDE.md" && $0.problem.contains("differs") })
        precondition(converted.path.hasPrefix(coding.path))

        precondition(PersonalScan.scan(text: "Commits use 1+name@users.noreply.github.com and test@example.com", terms: []).isEmpty)
        precondition(PersonalScan.scan(text: "call 415-555-0134", terms: []).first?.kind == "phone number")
        precondition(PersonalScan.scan(text: "open https://mini.tail1234.ts.net:443", terms: []).first?.kind == "tailnet or local host name")
        precondition(PersonalScan.scan(text: "version 1.2.3.4 and port 8443", terms: []).isEmpty)
        precondition(PersonalScan.scan(text: "Trusts private ranges and Tailscale's 100.64.0.0/10", terms: []).isEmpty, "A range isn't a host")
        precondition(PersonalScan.scan(text: "Use `<tv ip>` or `192.168.0.50` in docs.", terms: []).isEmpty, "An example address is documentation")
        precondition(PersonalScan.scan(text: "The NAS is at 10.20.30.40.", terms: []).count == 1)

        try write("[remote \"origin\"]\n\turl = git@github.com:Owner/Repo.git\n", coding.appendingPathComponent("slug/.git/config"))
        precondition(RepoVisibility.githubSlug(coding.appendingPathComponent("slug").path) == "Owner/Repo")
    }
}
