import Foundation

/// `cantrip skills …` and `cantrip instructions …`: the shared skills library and folder rules.
/// Both work on files directly, so they run without the app.
extension CantripCLI {
    static let skillsUsage = """
    Usage:
      cantrip skills [list] [--json]   Skills in Cantrip's library, which backends see each one, and problems
      cantrip skills add PATH [--name NAME] [--move] [--disabled]
                                  Copy a skill folder into the library (--move: move it, leaving a link behind) and link it
                                  for every backend. Refused when it holds a value that looks like a credential
      cantrip skills edit NAME    Open its SKILL.md in $EDITOR, then check and sync it
      cantrip skills enable|disable NAME
      cantrip skills sync [--dry-run]  Link enabled skills, unlink turned-off ones, record the library's changes
      cantrip skills check [NAME] Name clashes, missing links, front matter and credential-looking values (exit 1 on any)
    """

    static let instructionsUsage = """
    Usage:
      cantrip instructions [list] [DIR] [--json]
                                  Folder rules Cantrip gives every backend; with DIR, the ones that apply there and their text
      cantrip instructions edit FOLDER [--mirror PATH | --no-mirror] [--from FILE|-]
                                  Edit (or create) the rules for everything under FOLDER in $EDITOR, or set them from a file.
                                  A mirror is a CLAUDE.md rewritten from them for Claude Code run in a terminal
      cantrip instructions check [--json]
                                  Out-of-date mirrors, CLAUDE.md without AGENTS.md, pointer files with their own rules,
                                  credentials, and personal details in a public repository's rules (exit 1 on any)
    """

    // MARK: - skills

    static func skills(_ arguments: [String]) throws -> Int32 {
        var words: [String] = [], json = false, dryRun = false, move = false, disabled = false, name: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json": json = true
            case "--dry-run": dryRun = true
            case "--move": move = true
            case "--disabled": disabled = true
            case "--name":
                index += 1
                guard index < arguments.count else { throw Failure(message: "--name needs a value.", code: 2) }
                name = arguments[index]
            case "-h", "--help", "help": print(skillsUsage); return 0
            default: words.append(arguments[index])
            }
            index += 1
        }
        let library = SkillsLibrary()
        let action = words.first ?? "list"
        func needName() throws -> String {
            guard words.count == 2 else { throw Failure(message: "Usage: cantrip skills \(action) NAME", code: 2) }
            return words[1]
        }
        switch action {
        case "list":
            let skills = library.list()
            if json {
                printJSON(["library": library.folder.path, "skills": skills.map(\.json)])
                return 0
            }
            print("Library: \(SkillsLibrary.tilde(library.folder.path, home: library.home))")
            if skills.isEmpty { print("No skills yet. Add one with `cantrip skills add PATH`.") }
            for skill in skills {
                let seen = skill.backends.isEmpty ? "no backend" : skill.backends.joined(separator: ", ")
                print("\(skill.enabled ? "on " : "off") \(skill.name) — \(seen)")
                for problem in skill.problems { print("      ! \(problem)") }
            }
            return 0
        case "add":
            guard words.count == 2 else { throw Failure(message: "Usage: cantrip skills add PATH [--name NAME] [--move] [--disabled]", code: 2) }
            let source = URL(fileURLWithPath: (words[1] as NSString).expandingTildeInPath)
            let report = try wrap { try library.add(source: source, name: name, move: move, enabled: !disabled) }
            print("Added \(name ?? source.lastPathComponent) to \(SkillsLibrary.tilde(library.folder.path, home: library.home)).")
            report.lines.forEach { print($0) }
            return report.problems.isEmpty ? 0 : 1
        case "enable", "disable":
            let report = try wrap { try library.setEnabled(try needName(), action == "enable") }
            print(report.lines.isEmpty ? "Nothing to change." : report.lines.joined(separator: "\n"))
            return report.problems.isEmpty ? 0 : 1
        case "sync":
            let report = try wrap { try library.sync(dryRun: dryRun) }
            print(report.lines.isEmpty ? "Every skill is linked as it should be." : report.lines.map { dryRun ? "Would: \($0)" : $0 }.joined(separator: "\n"))
            return report.problems.isEmpty ? 0 : 1
        case "check":
            let problems = library.check(words.count > 1 ? words[1] : nil)
            print(problems.isEmpty ? "No problems." : problems.joined(separator: "\n"))
            return problems.isEmpty ? 0 : 1
        case "edit":
            let skill = try needName()
            guard library.names().contains(skill) else { throw Failure(message: "The library has no skill named \(skill).") }
            let file = library.skillFolder(skill).appendingPathComponent("SKILL.md")
            guard try openEditor(file) else {
                print("Edit \(file.path), then run `cantrip skills sync`.")
                return 0
            }
            let report = try wrap { try library.sync(only: [skill]) }
            report.lines.forEach { print($0) }
            let problems = library.check(skill)
            problems.forEach { print($0) }
            return problems.isEmpty ? 0 : 1
        default:
            throw Failure(message: skillsUsage, code: 2)
        }
    }

    private static func wrap<Value>(_ body: () throws -> Value) throws -> Value {
        do { return try body() } catch let failure as Failure { throw failure } catch {
            throw Failure(message: error.localizedDescription)
        }
    }

    /// Opens `file` in $VISUAL or $EDITOR and waits. False when there's no terminal or editor.
    static func openEditor(_ file: URL) throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
              let editor = [environment["VISUAL"], environment["EDITOR"], "vi"].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", editor + " \"$1\"", "sh", file.path]
        try process.run()
        process.waitUntilExit()
        return true
    }

    // MARK: - instructions

    static func instructions(_ arguments: [String]) throws -> Int32 {
        var words: [String] = [], json = false, mirror: String?, noMirror = false, from: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json": json = true
            case "--no-mirror": noMirror = true
            case "--mirror", "--from":
                let flag = arguments[index]
                index += 1
                guard index < arguments.count else { throw Failure(message: "\(flag) needs a value.", code: 2) }
                if flag == "--mirror" { mirror = arguments[index] } else { from = arguments[index] }
            case "-h", "--help", "help": print(instructionsUsage); return 0
            default: words.append(arguments[index])
            }
            index += 1
        }
        let store = FolderInstructions()
        let action = words.first ?? "list"
        switch action {
        case "list":
            let directory = words.count > 1 ? store.expand((words[1] as NSString).expandingTildeInPath) : nil
            let rules = directory.map(store.rules(for:)) ?? store.rules()
            if json {
                var object: [String: Any] = ["folder": store.folder.path, "rules": rules.map { rule -> [String: Any] in
                    var item: [String: Any] = ["folder": rule.folder, "file": rule.file.path, "lines": rule.body.components(separatedBy: "\n").count]
                    if let mirror = rule.mirror { item["mirror"] = mirror }
                    if directory != nil { item["text"] = rule.body }
                    return item
                }]
                if let directory { object["guidance"] = store.guidance(for: directory) ?? "" }
                printJSON(object)
                return 0
            }
            if rules.isEmpty {
                print(directory == nil ? "No folder rules yet. Add some with `cantrip instructions edit FOLDER`." : "No folder rule applies in \(store.tilde(directory!)).")
                return 0
            }
            for rule in rules {
                let lines = rule.body.components(separatedBy: "\n").count
                print("\(store.tilde(rule.folder)) — \(lines) line\(lines == 1 ? "" : "s")\(rule.mirror.map { ", mirrored to \(store.tilde($0))" } ?? "") (\(store.tilde(rule.file.path)))")
                if directory != nil { print("\n\(rule.body)\n") }
            }
            return 0
        case "edit":
            guard words.count == 2 else { throw Failure(message: "Usage: cantrip instructions edit FOLDER [--mirror PATH | --no-mirror] [--from FILE|-]", code: 2) }
            let target = store.expand((words[1] as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Failure(message: "\(words[1]) isn't a folder.")
            }
            let existing = store.rule(forFolder: target)
            let mirrorPath = noMirror ? nil : mirror.map { ($0 as NSString).expandingTildeInPath } ?? existing?.mirror
            var body = existing?.body ?? ""
            if let from {
                let data = from == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: (from as NSString).expandingTildeInPath))
                body = String(decoding: data, as: UTF8.self)
            } else {
                let draft = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-rules-\(UUID().uuidString).md")
                try PrivateFile.write(Data((body.isEmpty ? "" : body + "\n").utf8), to: draft)
                defer { try? FileManager.default.removeItem(at: draft) }
                guard try openEditor(draft) else {
                    print("No terminal editor here. Pass the rules with --from FILE (or --from - on standard input).")
                    return 2
                }
                body = (try? String(contentsOf: draft, encoding: .utf8)) ?? body
            }
            let rule = try wrap { try store.save(folder: target, body: body, mirror: mirrorPath) }
            print("Saved the rules for \(store.tilde(rule.folder)) in \(store.tilde(rule.file.path)).")
            if let mirror = rule.mirror { print("Rewrote \(store.tilde(mirror)) for Claude Code in a terminal.") }
            print("New sessions under \(store.tilde(rule.folder)) get them on every backend.")
            return 0
        case "check":
            let findings = store.check()
            if json {
                printJSON(["findings": findings.map { ["path": $0.path, "problem": $0.problem] }])
            } else {
                print(findings.isEmpty ? "No problems." : findings.map(\.description).joined(separator: "\n"))
            }
            return findings.isEmpty ? 0 : 1
        default:
            throw Failure(message: instructionsUsage, code: 2)
        }
    }
}
