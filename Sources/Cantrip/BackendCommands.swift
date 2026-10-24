import Foundation
import CryptoKit

/// A slash command, custom command or skill that a tab's agent backend exposes, as served by
/// `GET /api/v1/sessions/{id}/commands`. Free of app types so tests compile it alone.
struct BackendCommand: Codable, Equatable {
    enum Kind: String, Codable { case builtin, custom, skill, cantrip }
    /// `runs`: the backend runs it. `cantrip`: Cantrip handles it with its own equivalent.
    /// `unavailable`: it can't run from Cantrip; `note` says why.
    enum Availability: String, Codable { case runs, cantrip, unavailable }

    var name: String
    var description: String
    var kind: Kind
    var source: String
    var inputHint: String?
    var requiresInput = false
    var aliases: [String] = []
    /// Exact composer text when chosen ("/plan ", or "$imagegen " for a Codex skill).
    var insert: String
    var availability: Availability = .runs
    var note: String?
    /// Client action for `cantrip` rows: "modelSettings" or "startFresh".
    var action: String?

    private enum CodingKeys: String, CodingKey {
        case name, description, kind, source, inputHint, requiresInput, aliases, insert,
             availability, note, action
    }

    init(name: String, description: String, kind: Kind, source: String, inputHint: String? = nil,
         requiresInput: Bool = false, aliases: [String] = [], insert: String? = nil,
         availability: Availability = .runs, note: String? = nil, action: String? = nil) {
        self.name = name
        self.description = description
        self.kind = kind
        self.source = source
        self.inputHint = inputHint
        self.requiresInput = requiresInput
        self.aliases = aliases
        self.insert = insert ?? "/\(name) "
        self.availability = availability
        self.note = note
        self.action = action
    }

    /// What a row shows: the token the composer gets ("/plan", or "$imagegen" for Codex).
    var title: String {
        insert.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "/\(name)"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .builtin
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        inputHint = try c.decodeIfPresent(String.self, forKey: .inputHint)
        requiresInput = try c.decodeIfPresent(Bool.self, forKey: .requiresInput) ?? false
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        insert = try c.decodeIfPresent(String.self, forKey: .insert) ?? "/\(name) "
        availability = try c.decodeIfPresent(Availability.self, forKey: .availability) ?? .runs
        note = try c.decodeIfPresent(String.self, forKey: .note)
        action = try c.decodeIfPresent(String.self, forKey: .action)
    }

    /// Optional fields are written as JSON null so every client sees the same keys.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(kind, forKey: .kind)
        try c.encode(source, forKey: .source)
        try c.encode(inputHint, forKey: .inputHint)
        try c.encode(requiresInput, forKey: .requiresInput)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(insert, forKey: .insert)
        try c.encode(availability, forKey: .availability)
        try c.encode(note, forKey: .note)
        try c.encode(action, forKey: .action)
    }
}

struct BackendCommandList: Codable, Equatable {
    var backend: String
    var workdir: String
    var revision: String
    var status: String?
    var commands: [BackendCommand]

    private enum CodingKeys: String, CodingKey { case backend, workdir, revision, status, commands }

    init(backend: String, workdir: String, status: String?, commands: [BackendCommand]) {
        self.backend = backend
        self.workdir = workdir
        self.status = status
        self.commands = commands
        revision = Self.revision(status: status, commands: commands)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = try c.decode(String.self, forKey: .backend)
        workdir = try c.decode(String.self, forKey: .workdir)
        revision = try c.decode(String.self, forKey: .revision)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        commands = try c.decode([BackendCommand].self, forKey: .commands)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backend, forKey: .backend)
        try c.encode(workdir, forKey: .workdir)
        try c.encode(revision, forKey: .revision)
        try c.encode(status, forKey: .status)
        try c.encode(commands, forKey: .commands)
    }

    static func revision(status: String?, commands: [BackendCommand]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = (try? encoder.encode(commands)) ?? Data()
        data.append(Data((status ?? "").utf8))
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func command(named name: String) -> BackendCommand? {
        let lower = name.lowercased()
        return commands.first { $0.name.lowercased() == lower }
            ?? commands.first { $0.aliases.contains { $0.lowercased() == lower } }
    }
}

// MARK: - Typing "/": when to suggest, matching, choosing

enum BackendCommandFilter {
    /// The command name being typed, lowercased, or nil when the text isn't a command in progress:
    /// it must start with "/", have no whitespace yet, and not be a path ("/Users/x").
    static func slashToken(_ text: String) -> String? {
        guard text.hasPrefix("/"), !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        let token = text.dropFirst()
        guard !token.contains("/") else { return nil }
        return token.lowercased()
    }

    struct Match: Equatable {
        let command: BackendCommand
        let score: Int
    }

    /// Ranked matches: lowest rule score wins; unavailable rows sort last; host order breaks ties.
    static func matches(token: String, in commands: [BackendCommand], limit: Int = 50) -> [Match] {
        let t = token.lowercased()
        var scored: [(match: Match, index: Int)] = []
        for (index, command) in commands.enumerated() {
            guard let score = score(command, token: t) else { continue }
            scored.append((Match(command: command, score: score), index))
        }
        scored.sort { a, b in
            let ua = a.match.command.availability == .unavailable ? 1 : 0
            let ub = b.match.command.availability == .unavailable ? 1 : 0
            if ua != ub { return ua < ub }
            if a.match.score != b.match.score { return a.match.score < b.match.score }
            return a.index < b.index
        }
        return scored.prefix(limit).map(\.match)
    }

    static func score(_ command: BackendCommand, token t: String) -> Int? {
        let name = command.name.lowercased()
        if t.isEmpty { return 1 }
        if name == t { return 0 }
        if name.hasPrefix(t) { return 1 }
        if command.aliases.contains(where: { $0.lowercased().hasPrefix(t) }) { return 2 }
        let squash: (String) -> String = { $0.filter { !"-_:".contains($0) } }
        if name.contains(t) || (!squash(t).isEmpty && squash(name).contains(squash(t))) { return 3 }
        if t.count >= 2 {
            let words = command.description.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if words.contains(where: { $0.hasPrefix(t) }) { return 4 }
        }
        return nil
    }

    /// Index of the row Return would choose, if any: only a close name match is preselected,
    /// so a path-like or prose "/word" still sends as typed.
    static func defaultHighlight(token: String, matches: [Match]) -> Int? {
        guard !token.isEmpty, let first = matches.first, first.score <= 2,
              first.command.availability != .unavailable else { return nil }
        return 0
    }

    enum Choice: Equatable {
        /// Replace the composer text; send it now when `send` is true.
        case insert(text: String, send: Bool)
        /// Open the tab's model settings instead of inserting.
        case openModelSettings
        /// The row can't be chosen.
        case none
    }

    /// What choosing a row does. `viaTab` only inserts; Return/click/tap may also send.
    static func choose(_ command: BackendCommand, viaTab: Bool = false,
                       canOpenModelSettings: Bool = false) -> Choice {
        guard command.availability != .unavailable else { return .none }
        if command.action == "modelSettings", canOpenModelSettings { return .openModelSettings }
        let needsInput = command.requiresInput
            || !(command.inputHint?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        return .insert(text: command.insert, send: !viaTab && !needsInput)
    }
}

// MARK: - Parsing a prompt that names a command

struct SlashInvocation: Equatable {
    let name: String
    let input: String

    /// Characters a command name may contain; anything else ends the name.
    static func isNameCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." || c == ":"
    }

    /// "/name rest": the name is the run of name characters after "/", so a zero-width or other
    /// separator can't hide a name from Cantrip. A path ("/Users/x") is never a command.
    init?(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: Self.separators)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let nameEnd = body.firstIndex(where: { !Self.isNameCharacter($0) }) ?? body.endIndex
        let name = String(body[..<nameEnd])
        guard !name.isEmpty, nameEnd == body.endIndex || body[nameEnd] != "/" else { return nil }
        self.name = name
        input = String(body[nameEnd...]).trimmingCharacters(in: Self.separators)
    }

    /// Whitespace plus the invisible characters JavaScript's `\s` also treats as spaces.
    static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}\u{2060}"))
}

// MARK: - Cantrip's policy for commands that would bypass it or break remotely

enum BackendCommandFamily: String {
    case copilot, copilotRemote, claudeCode, codex
}

enum BackendCommandPolicy {
    static let approvalsNote = "Cantrip's approval settings decide what Copilot may do in this tab."
    static let acpApprovalsNote = "Cantrip answers this Copilot server's approval requests."
    static let sandboxNote = "Changes sandboxing for every Copilot session. Use Copilot in a terminal for this."
    static let remoteNote = "Cantrip runs Copilot with remote control off; this tab is already remote through Cantrip."
    static let scheduleNote = "Scheduled prompts stop when Cantrip releases the idle Copilot runtime. Ask Cantrip Home to schedule a task instead."
    static let cwdNote = "This tab's folder is set in Cantrip on the Mac."
    static let modelNote = "Uses this tab's model settings in Cantrip."
    static let clearNote = "Same as Start Fresh: Cantrip keeps the transcript and Claude starts a new conversation."
    static let colorNote = "Colors the terminal prompt bar, which Cantrip doesn't have."
    static let automaticSkillNote = "Copilot uses this skill automatically when a request needs it. It has no command."

    /// How Cantrip treats a backend command by name. nil = the backend runs it as is.
    static func override(family: BackendCommandFamily, name: String)
        -> (availability: BackendCommand.Availability, note: String, action: String?)? {
        switch (family, name.lowercased()) {
        case (.copilot, "allow-all"), (.copilot, "yolo"), (.copilot, "permissions"):
            return (.unavailable, approvalsNote, nil)
        case (.copilotRemote, "allow-all"), (.copilotRemote, "yolo"), (.copilotRemote, "permissions"):
            return (.unavailable, acpApprovalsNote, nil)
        case (.copilot, "sandbox"), (.copilotRemote, "sandbox"):
            return (.unavailable, sandboxNote, nil)
        case (.copilot, "remote"), (.copilotRemote, "remote"):
            return (.unavailable, remoteNote, nil)
        case (.copilot, "every"), (.copilot, "after"), (.copilot, "loop"):
            return (.unavailable, scheduleNote, nil)
        case (.copilot, "cwd"), (.copilot, "cd"), (.copilotRemote, "cwd"), (.copilotRemote, "cd"):
            return (.unavailable, cwdNote, nil)
        case (.copilot, "model"), (.copilot, "models"):
            return (.cantrip, modelNote, "modelSettings")
        case (.claudeCode, "clear"), (.claudeCode, "reset"), (.claudeCode, "new"):
            return (.cantrip, clearNote, "startFresh")
        case (.claudeCode, "color"):
            return (.unavailable, colorNote, nil)
        default:
            return nil
        }
    }

    /// The rule for a sent `/name`: by the name, by the discovered command it is an alias of, or
    /// by that command's own availability (for example a skill Copilot only uses automatically).
    static func rule(family: BackendCommandFamily, name: String, discovered: BackendCommand?)
        -> (availability: BackendCommand.Availability, note: String, action: String?)? {
        if let rule = override(family: family, name: name) { return rule }
        guard let discovered else { return nil }
        for alias in [discovered.name] + discovered.aliases {
            if let rule = override(family: family, name: alias) { return rule }
        }
        if discovered.availability != .runs, discovered.kind != .cantrip {
            return (discovered.availability, discovered.note ?? "", discovered.action)
        }
        return nil
    }

    /// Names (with known aliases) the Copilot bridge refuses itself, after resolving aliases.
    static func blockedNames(family: BackendCommandFamily) -> [String: String] {
        var blocked: [String: String] = [:]
        for name in ["allow-all", "yolo", "permissions", "sandbox", "remote", "every", "after", "loop",
                     "cwd", "cd", "model", "models", "clear", "reset", "new", "color"] {
            if let rule = override(family: family, name: name) {
                blocked[name] = rule.availability == .unavailable ? rule.note
                    : "Change this tab's model in its model settings, or send `/model <model>`."
            }
        }
        return blocked
    }

    static func apply(_ command: BackendCommand, family: BackendCommandFamily) -> BackendCommand {
        var command = command
        let names = [command.name] + command.aliases
        if let rule = names.lazy.compactMap({ override(family: family, name: $0) }).first {
            command.availability = rule.availability
            command.note = rule.note
            command.action = rule.action
        }
        return command
    }

    /// Display order: your own commands and skills first, then built-ins, then Cantrip scripts.
    static func ordered(_ commands: [BackendCommand]) -> [BackendCommand] {
        let rank: [BackendCommand.Kind: Int] = [.custom: 0, .skill: 1, .builtin: 2, .cantrip: 3]
        var seen = Set<String>()
        return commands.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.kind] ?? 9, rb = rank[b.element.kind] ?? 9
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
            .filter { seen.insert($0.name.lowercased()).inserted }
    }
}

// MARK: - Normalizing each backend's own discovery output

enum BackendCommandParsers {
    /// Copilot SDK: `session.rpc.commands.list({includeBuiltins, includeSkills})` and
    /// `session.rpc.skills.list()` from a session in the tab's folder.
    static func copilot(commands: [[String: Any]], skills: [[String: Any]],
                        family: BackendCommandFamily = .copilot) -> [BackendCommand] {
        var skillInfo: [String: [String: Any]] = [:]
        for skill in skills {
            if let name = (skill["commandName"] as? String) ?? (skill["name"] as? String) {
                skillInfo[name.lowercased()] = skill
            }
        }
        var result: [BackendCommand] = []
        var listed = Set<String>()
        for entry in commands {
            guard let name = (entry["name"] as? String).map(clean), !name.isEmpty else { continue }
            let kindValue = entry["kind"] as? String ?? "builtin"
            if kindValue == "client" { continue }
            let input = entry["input"] as? [String: Any]
            let info = skillInfo[name.lowercased()]
            let isSkill = kindValue == "skill"
            let path = info?["path"] as? String ?? ""
            let kind: BackendCommand.Kind = !isSkill ? .builtin
                : path.contains("/commands/") ? .custom : .skill
            listed.insert(name.lowercased())
            result.append(BackendCommandPolicy.apply(BackendCommand(
                name: name,
                description: oneLine(entry["description"] as? String ?? info?["description"] as? String ?? ""),
                kind: kind,
                source: isSkill ? copilotSource(info?["source"] as? String) : "Copilot",
                inputHint: (input?["hint"] as? String).flatMap(nonEmpty),
                requiresInput: input?["required"] as? Bool ?? false,
                aliases: (entry["aliases"] as? [String] ?? []).map(clean).filter { !$0.isEmpty }
            ), family: family))
        }
        // Skills the model uses on its own: listed so you know they exist, but not runnable.
        for skill in skills where skill["userInvocable"] as? Bool == false && skill["enabled"] as? Bool != false {
            guard let name = (skill["name"] as? String).map(clean), !name.isEmpty,
                  !listed.contains(name.lowercased()) else { continue }
            result.append(BackendCommand(
                name: name, description: oneLine(skill["description"] as? String ?? ""), kind: .skill,
                source: copilotSource(skill["source"] as? String),
                availability: .unavailable, note: BackendCommandPolicy.automaticSkillNote))
        }
        return result
    }

    static func copilotSource(_ raw: String?) -> String {
        guard let raw = raw?.lowercased() else { return "Copilot" }
        if raw == "project" || raw.hasPrefix("project") || raw.hasPrefix("repo") { return "Project" }
        if raw.hasPrefix("personal") || raw == "user" { return "Personal" }
        if raw.contains("plugin") { return "Plugin" }
        return "Copilot"
    }

    /// ACP `available_commands_update` entries: {name, description, input: {hint}}.
    static func acp(_ commands: [[String: Any]]) -> [BackendCommand] {
        commands.compactMap { entry in
            guard let name = (entry["name"] as? String).map(clean), !name.isEmpty else { return nil }
            let hint = ((entry["input"] as? [String: Any])?["hint"] as? String).flatMap(nonEmpty)
            let isSkill = hint == "instructions for the skill"
            return BackendCommandPolicy.apply(BackendCommand(
                name: name, description: oneLine(entry["description"] as? String ?? ""),
                kind: isSkill ? .skill : .builtin, source: "Copilot", inputHint: hint
            ), family: .copilotRemote)
        }
    }

    struct ClaudeInitialize {
        let commands: [BackendCommand]
        let signedIn: Bool?
    }

    /// Claude Code `initialize` control response: `commands` [{name, description, argumentHint,
    /// aliases}], `account.tokenSource`, `fast_mode_disabled_reason`. `personal`/`project` hold
    /// skill and command folder names, used only to label where an entry comes from.
    static func claude(_ response: [String: Any], personalSkills: Set<String> = [],
                       personalCommands: Set<String> = [], projectSkills: Set<String> = [])
        -> ClaudeInitialize {
        let fastReason = response["fast_mode_disabled_reason"] as? String
        var result: [BackendCommand] = []
        for entry in response["commands"] as? [[String: Any]] ?? [] {
            guard let name = (entry["name"] as? String).map(clean), !name.isEmpty,
                  !name.hasPrefix("__") else { continue }
            var description = oneLine(entry["description"] as? String ?? "")
            if description.lowercased().hasPrefix("(removed)") { continue }
            var kind = BackendCommand.Kind.builtin
            var source = "Claude Code"
            if description.hasSuffix(" (project)") || description == "(project)" {
                description = String(description.dropLast("(project)".count))
                    .trimmingCharacters(in: .whitespaces)
                source = "Project"
                kind = projectSkills.contains(name) ? .skill : .custom
            } else if description.hasSuffix(" (user)") || description == "(user)" {
                description = String(description.dropLast("(user)".count))
                    .trimmingCharacters(in: .whitespaces)
                source = "Personal"
                kind = personalCommands.contains(name) && !personalSkills.contains(name) ? .custom : .skill
            } else if personalSkills.contains(name) {
                kind = .skill
                source = "Personal"
            } else if personalCommands.contains(name) {
                kind = .custom
                source = "Personal"
            }
            var command = BackendCommandPolicy.apply(BackendCommand(
                name: name, description: description, kind: kind, source: source,
                inputHint: (entry["argumentHint"] as? String).flatMap(nonEmpty),
                aliases: (entry["aliases"] as? [String] ?? []).map(clean).filter { !$0.isEmpty }
            ), family: .claudeCode)
            if name == "fast", let fastReason, command.availability == .runs {
                command.availability = .unavailable
                command.note = fastReason == "sdk_opt_in_required"
                    ? "Claude Code keeps fast mode off for SDK sessions like Cantrip's."
                    : "Claude Code reports fast mode isn't available here (\(fastReason))."
            }
            result.append(command)
        }
        let tokenSource = (response["account"] as? [String: Any])?["tokenSource"] as? String
        return ClaudeInitialize(commands: result, signedIn: tokenSource.map { $0 != "none" })
    }

    /// Codex app-server `skills/list` result: {data: [{cwd, skills: [SkillMetadata], errors}]}.
    /// Codex has no command list (its built-ins live in its terminal UI); skills run from a
    /// prompt that mentions them as `$name`.
    static func codex(_ result: [String: Any]) -> [BackendCommand] {
        var commands: [BackendCommand] = []
        var seen = Set<String>()
        for entry in result["data"] as? [[String: Any]] ?? [] {
            for skill in entry["skills"] as? [[String: Any]] ?? [] {
                guard let name = (skill["name"] as? String).map(clean), !name.isEmpty,
                      seen.insert(name.lowercased()).inserted else { continue }
                let interface = skill["interface"] as? [String: Any]
                let description = (interface?["shortDescription"] as? String).flatMap(nonEmpty)
                    ?? (skill["shortDescription"] as? String).flatMap(nonEmpty)
                    ?? skill["description"] as? String ?? ""
                let source: String
                switch skill["scope"] as? String {
                case "user": source = "Personal"
                case "repo": source = "Project"
                case "admin": source = "Admin"
                default: source = "Codex"
                }
                let enabled = skill["enabled"] as? Bool ?? true
                commands.append(BackendCommand(
                    name: name, description: oneLine(description), kind: .skill, source: source,
                    inputHint: "what to do", insert: "$\(name) ",
                    availability: enabled ? .runs : .unavailable,
                    note: enabled ? nil : "Turned off in Codex's skill settings."))
            }
        }
        return commands
    }

    static func cantripScripts(_ scripts: [(name: String, description: String)]) -> [BackendCommand] {
        scripts.map {
            BackendCommand(name: $0.name, description: oneLine($0.description), kind: .cantrip, source: "Cantrip")
        }
    }

    static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One line, at most 300 characters.
    static func oneLine(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return collapsed.count > 300 ? String(collapsed.prefix(299)) + "…" : collapsed
    }
}
