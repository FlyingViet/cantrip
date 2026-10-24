import Foundation

/// One slash command, custom command or skill that a Cantrip tab's agent backend exposes
/// (`GET /api/v1/sessions/{id}/commands`). Decoding is lenient: a row without a `name` or
/// `insert` is dropped, every other field falls back to its contract default.
struct BackendCommand: Codable, Equatable, Sendable {
    /// What the user types after "/", without the slash.
    let name: String
    var description: String = ""
    /// "builtin", "custom", "skill" or "cantrip".
    var kind: String = "builtin"
    /// Short display label, e.g. "Copilot", "Project", "Personal".
    var source: String = ""
    var inputHint: String? = nil
    var requiresInput: Bool = false
    var aliases: [String] = []
    /// The exact composer text when chosen. Never built by the client ("$skill " for Codex skills).
    let insert: String
    /// "runs", "cantrip" or "unavailable".
    var availability: String = "runs"
    var note: String? = nil
    /// A client action for "cantrip" rows; only "modelSettings" is known.
    var action: String? = nil

    init(name: String, description: String = "", kind: String = "builtin", source: String = "",
         inputHint: String? = nil, requiresInput: Bool = false, aliases: [String] = [],
         insert: String, availability: String = "runs", note: String? = nil, action: String? = nil) {
        self.name = name
        self.description = description
        self.kind = kind
        self.source = source
        self.inputHint = inputHint
        self.requiresInput = requiresInput
        self.aliases = aliases
        self.insert = insert
        self.availability = availability
        self.note = note
        self.action = action
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let insert = try container.decode(String.self, forKey: .insert)
        guard !name.isEmpty, !insert.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: container,
                                                   debugDescription: "A command needs a name and insert text.")
        }
        self.name = name
        self.insert = insert
        description = (try? container.decodeIfPresent(String.self, forKey: .description)) ?? ""
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? "builtin"
        source = (try? container.decodeIfPresent(String.self, forKey: .source)) ?? ""
        inputHint = try? container.decodeIfPresent(String.self, forKey: .inputHint)
        requiresInput = (try? container.decodeIfPresent(Bool.self, forKey: .requiresInput)) ?? false
        aliases = (try? container.decodeIfPresent([String].self, forKey: .aliases)) ?? []
        availability = (try? container.decodeIfPresent(String.self, forKey: .availability)) ?? "runs"
        note = try? container.decodeIfPresent(String.self, forKey: .note)
        action = try? container.decodeIfPresent(String.self, forKey: .action)
    }

    var isUnavailable: Bool { availability == "unavailable" }
    var opensModelSettings: Bool { action == "modelSettings" }
    /// The row's title: exactly what choosing it inserts, without the argument space
    /// ("/plan", or "$imagegen" for a Codex skill).
    var title: String {
        insert.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "/" + name
    }
    var trimmedInputHint: String? {
        guard let hint = inputHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty else { return nil }
        return hint
    }
    /// Return, a click or a tap sends it at once; anything taking an argument is inserted instead.
    var sendsWhenChosen: Bool { !requiresInput && trimmedInputHint == nil }
    var trimmedNote: String? {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
        return note
    }
}

/// The host's command list for one session.
struct BackendCommandsResponse: Codable, Equatable, Sendable {
    var backend: String? = nil
    var workdir: String? = nil
    var revision: String? = nil
    /// One line explaining an empty or partial list; shown as an informational row.
    var status: String? = nil
    var commands: [BackendCommand] = []

    init(backend: String? = nil, workdir: String? = nil, revision: String? = nil, status: String? = nil,
         commands: [BackendCommand] = []) {
        self.backend = backend
        self.workdir = workdir
        self.revision = revision
        self.status = status
        self.commands = commands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backend = try? container.decodeIfPresent(String.self, forKey: .backend)
        workdir = try? container.decodeIfPresent(String.self, forKey: .workdir)
        revision = try? container.decodeIfPresent(String.self, forKey: .revision)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        // One malformed row must not hide the others.
        commands = (try container.decode([Lossy].self, forKey: .commands)).compactMap(\.command)
    }

    var trimmedStatus: String? {
        guard let status = status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty else { return nil }
        return status
    }

    private struct Lossy: Decodable {
        let command: BackendCommand?
        init(from decoder: Decoder) throws { command = try? BackendCommand(from: decoder) }
    }
}

/// A command that matches the typed token, with its rank.
struct BackendCommandMatch: Equatable, Identifiable {
    let command: BackendCommand
    /// 0 exact name, 1 name prefix, 2 alias prefix, 3 name contains, 4 description word prefix.
    let score: Int
    /// The host's position; equal scores keep host order.
    let index: Int

    var id: Int { index }
}

/// How a row was chosen: Tab inserts; Return, a click or a tap may also send.
enum BackendCommandTrigger: Equatable {
    case tab
    case activate
}

/// What choosing a row does to the composer.
struct BackendCommandChoice: Equatable {
    /// The composer's new text: the command's `insert`, or empty when model settings open instead.
    let text: String
    /// Send now (the sender trims, so "/usage " goes out as "/usage").
    let sendsImmediately: Bool
    /// Open this tab's model settings instead of inserting.
    let opensModelSettings: Bool
}

/// What the suggestion list shows under the composer.
enum BackendSlashPresentation: Equatable {
    /// The first fetch for this session is still running.
    case loading
    case rows([BackendCommandMatch], status: String?)

    var matches: [BackendCommandMatch] {
        if case .rows(let matches, _) = self { return matches }
        return []
    }
}

/// Keys the desktop composer routes to the list while it is visible.
enum BackendSlashKey: Equatable {
    case up
    case down
    case tab
    case `return`
    case escape
}

enum BackendSlashKeyResult: Equatable {
    /// Not for the list: the text field handles it as today.
    case ignore
    case highlight(Int)
    case choose(BackendCommandMatch, BackendCommandTrigger)
    case dismiss
}

/// Backend slash-command suggestions, identical on every Cantrip client (see the host contract).
enum BackendSlashCommands {
    static let maximumRows = 50

    /// The lowercased command token while the composer holds only "/token"; nil otherwise
    /// (leading whitespace, any whitespace or newline, or a path such as "/Users/x").
    static func slashToken(_ text: String) -> String? {
        guard text.first == "/", !text.contains(where: \.isWhitespace) else { return nil }
        let token = text.dropFirst()
        guard !token.contains("/") else { return nil }
        return token.lowercased()
    }

    /// The lowest matching rule for a lowercased token, or nil when the command doesn't match.
    static func score(_ command: BackendCommand, token: String) -> Int? {
        if token.isEmpty { return 1 }
        let name = command.name.lowercased()
        if name == token { return 0 }
        if name.hasPrefix(token) { return 1 }
        if command.aliases.contains(where: { $0.lowercased().hasPrefix(token) }) { return 2 }
        let compactToken = withoutSeparators(token)
        if name.contains(token) || compactToken.isEmpty || withoutSeparators(name).contains(compactToken) {
            return 3
        }
        if token.count >= 2,
           command.description.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains(where: { $0.hasPrefix(token) }) {
            return 4
        }
        return nil
    }

    /// Matching commands: available before unavailable, then by score, then in host order; at most 50.
    static func matches(token: String, commands: [BackendCommand]) -> [BackendCommandMatch] {
        let token = token.lowercased()
        let ranked = commands.enumerated().compactMap { index, command in
            score(command, token: token).map { BackendCommandMatch(command: command, score: $0, index: index) }
        }
        return Array(ranked.sorted {
            ($0.command.isUnavailable ? 1 : 0, $0.score, $0.index) < ($1.command.isUnavailable ? 1 : 0, $1.score, $1.index)
        }.prefix(maximumRows))
    }

    /// The row Return chooses before any arrow key: the first row only for a typed, strong, runnable
    /// match. Otherwise nothing, so Return sends the text unchanged.
    static func defaultHighlight(token: String, matches: [BackendCommandMatch]) -> Int? {
        guard !token.isEmpty, let first = matches.first, first.score <= 2, !first.command.isUnavailable else {
            return nil
        }
        return 0
    }

    /// Up/Down: moves to the next choosable row, wrapping and skipping unavailable rows.
    static func moveHighlight(from current: Int?, by step: Int, in matches: [BackendCommandMatch]) -> Int? {
        let choosable = matches.indices.filter { !matches[$0].command.isUnavailable }
        guard !choosable.isEmpty, step != 0 else { return current }
        guard let current, let position = choosable.firstIndex(of: current) else {
            return step > 0 ? choosable.first : choosable.last
        }
        let count = choosable.count
        return choosable[((position + step) % count + count) % count]
    }

    /// What choosing a row does; nil for unavailable rows, which can't be chosen.
    static func choose(_ command: BackendCommand, via trigger: BackendCommandTrigger,
                       canOpenModelSettings: Bool) -> BackendCommandChoice? {
        guard !command.isUnavailable else { return nil }
        if command.opensModelSettings, canOpenModelSettings {
            return BackendCommandChoice(text: "", sendsImmediately: false, opensModelSettings: true)
        }
        return BackendCommandChoice(
            text: command.insert,
            sendsImmediately: trigger == .activate && command.sendsWhenChosen,
            opensModelSettings: false
        )
    }

    /// The list for the composer's text, or nil when nothing should show. `response` is the cached
    /// list (nil before the first fetch succeeds); `isLoading` says whether a fetch is running.
    static func presentation(token: String?, response: BackendCommandsResponse?,
                             isLoading: Bool) -> BackendSlashPresentation? {
        guard let token else { return nil }
        guard let response else { return isLoading ? .loading : nil }
        let matches = matches(token: token, commands: response.commands)
        let status = response.trimmedStatus
        guard !matches.isEmpty || status != nil else { return nil }
        return .rows(matches, status: status)
    }

    /// Desktop keys while the list is visible. `highlighted` is the current highlight (or default).
    static func handle(_ key: BackendSlashKey, matches: [BackendCommandMatch],
                       highlighted: Int?) -> BackendSlashKeyResult {
        let current = highlighted.flatMap { matches.indices.contains($0) ? $0 : nil }
        switch key {
        case .up, .down:
            guard let next = moveHighlight(from: current, by: key == .down ? 1 : -1, in: matches) else {
                return .ignore
            }
            return .highlight(next)
        case .tab:
            // Like shell completion: with nothing highlighted, the first runnable row.
            let target = current ?? matches.firstIndex { !$0.command.isUnavailable }
            guard let target, !matches[target].command.isUnavailable else { return .ignore }
            return .choose(matches[target], .tab)
        case .return:
            guard let current, !matches[current].command.isUnavailable else { return .ignore }
            return .choose(matches[current], .activate)
        case .escape:
            return .dismiss
        }
    }

    // MARK: Accessibility

    /// "title, description, source[, note]" (and "unavailable" for rows that can't run).
    static func accessibilityLabel(for command: BackendCommand) -> String {
        var parts = [command.title]
        let description = command.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { parts.append(description) }
        if !command.source.isEmpty { parts.append(command.source) }
        if let note = command.trimmedNote { parts.append(note) }
        if command.isUnavailable { parts.append("unavailable") }
        return parts.joined(separator: ", ")
    }

    static func accessibilityHint(for command: BackendCommand, canOpenModelSettings: Bool) -> String {
        if command.isUnavailable { return "" }
        if command.opensModelSettings, canOpenModelSettings { return "Opens model settings" }
        return command.sendsWhenChosen ? "Runs the command" : "Inserts the command"
    }

    static func countAnnouncement(_ count: Int) -> String {
        count == 1 ? "1 command" : "\(count) commands"
    }

    private static func withoutSeparators(_ text: String) -> String {
        text.filter { $0 != "-" && $0 != "_" && $0 != ":" }
    }
}

/// The Skills section of iPhone Duo's sidebar layout: the open chat's commands grouped while the
/// composer is idle, or the live "/" matches (same ranking and default highlight as the pop-up).
enum BackendSkillsSidebar {
    enum Group: String, CaseIterable, Identifiable {
        /// Skills, custom commands and Cantrip's own commands.
        case yours
        /// The backend's built-in commands that run (or that Cantrip handles).
        case builtIn
        /// Listed for reference, dimmed with the reason.
        case unavailable

        var id: Self { self }
        var title: String {
            switch self {
            case .yours: "Your skills & commands"
            case .builtIn: "Built-in"
            case .unavailable: "Can't run here"
            }
        }
        var isCollapsedByDefault: Bool { self == .unavailable }
    }

    struct Section: Equatable, Identifiable {
        let group: Group
        let matches: [BackendCommandMatch]
        var id: Group { group }
    }

    enum Content: Equatable {
        /// The first fetch for this chat is still running.
        case loading
        case grouped([Section], status: String?)
        /// Typing "/token": ranked matches with the highlighted position.
        case filtered([BackendCommandMatch], highlighted: Int?, status: String?)
    }

    static func group(of command: BackendCommand) -> Group {
        if command.isUnavailable { return .unavailable }
        return command.kind == "builtin" ? .builtIn : .yours
    }

    /// Non-empty groups in display order; each keeps the host's order.
    static func sections(_ commands: [BackendCommand]) -> [Section] {
        let all = commands.enumerated().map { BackendCommandMatch(command: $1, score: 1, index: $0) }
        return Group.allCases.compactMap { group in
            let matches = all.filter { self.group(of: $0.command) == group }
            return matches.isEmpty ? nil : Section(group: group, matches: matches)
        }
    }

    /// Nil when nothing should show: an older Mac, or a failed first fetch.
    static func content(response: BackendCommandsResponse?, isLoading: Bool, token: String?,
                        highlighted: Int?) -> Content? {
        guard let response else { return isLoading ? .loading : nil }
        if let token {
            let matches = BackendSlashCommands.matches(token: token, commands: response.commands)
            return .filtered(matches, highlighted: highlighted.flatMap { matches.indices.contains($0) ? $0 : nil },
                             status: response.trimmedStatus)
        }
        return .grouped(sections(response.commands), status: response.trimmedStatus)
    }

    /// Filtering opens a collapsed section so the matches and the highlight are visible.
    static func isExpanded(stored: Bool, isFiltering: Bool) -> Bool { stored || isFiltering }
}
