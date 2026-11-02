import Foundation

/// A tab picked from a composer's "@" suggestions. The composer shows "@label"; sending turns it
/// into a token carrying the tab's ID (`CantripTabMentions.encode`).
struct CantripTabMention: Codable, Equatable, Hashable {
    let id: String
    let label: String
}

/// @-mentions of tabs, identical on every Cantrip client (host contract, Mac `TabMentions`). A
/// picked mention travels inside the message text as `@[Label](cantrip-tab:<UUID>)`; transcripts
/// show it as "@Label". The Mac checks every ID and tells its model which tab is meant. Private
/// tabs, Private Local tabs and Home itself are never suggested (`mentionable`).
enum CantripTabMentions {
    struct Token: Equatable {
        let label: String
        let id: String
        let range: Range<String.Index>
    }

    static let scheme = "cantrip-tab"
    static let labelLimit = 60
    /// How far back from the caret an "@" can start a query.
    static let queryLimit = 48
    static let suggestionLimit = 8
    /// Characters before "@" that still start a word: "(@tv", "\"@tv".
    private static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘"]

    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"@\[([^\[\]\n]{1,120})\]\(cantrip-tab:([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)"#
    )

    // MARK: Tokens

    static func parse(_ text: String) -> [Token] {
        guard text.contains("](\(scheme):") else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return tokenRegex.matches(in: text, range: whole).compactMap { match in
            guard let range = Range(match.range, in: text),
                  let labelRange = Range(match.range(at: 1), in: text),
                  let idRange = Range(match.range(at: 2), in: text) else { return nil }
            return Token(label: String(text[labelRange]), id: String(text[idRange]).uppercased(), range: range)
        }
    }

    /// The text as people read it: each token becomes "@Label".
    static func plain(_ text: String) -> String {
        let tokens = parse(text)
        guard !tokens.isEmpty else { return text }
        var result = text
        for token in tokens.reversed() {
            result.replaceSubrange(token.range, with: "@" + token.label)
        }
        return result
    }

    /// A tab title as a mention label: one line, no brackets, at most 60 characters.
    static func label(for title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let label = String(cleaned.prefix(labelLimit)).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? "tab" : label
    }

    static func token(label: String, id: String) -> String {
        "@[\(Self.label(for: label))](\(scheme):\(id.uppercased()))"
    }

    /// The tab a rendered mention link opens (`cantrip-tab:<UUID>`).
    static func tabID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let id = url.absoluteString.dropFirst(scheme.count + 1)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: id).map { $0.uuidString }
    }

    // MARK: Composer

    /// The "@query" being typed just before `caret` (end of text when nil), or nil. An "@"
    /// inside a word (an email address, a handle) never starts one.
    static func query(in text: String, caret: String.Index? = nil) -> (at: String.Index, query: String)? {
        let caret = caret ?? text.endIndex
        guard caret <= text.endIndex else { return nil }
        let lowerBound = text.index(caret, offsetBy: -(queryLimit + 1), limitedBy: text.startIndex) ?? text.startIndex
        guard let at = text[lowerBound..<caret].lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let previous = text[text.index(before: at)]
            guard previous.isWhitespace || openers.contains(previous) else { return nil }
        }
        let query = String(text[text.index(after: at)..<caret])
        if query.contains(where: \.isNewline) || query.first?.isWhitespace == true { return nil }
        // Already a mention token.
        if query.hasPrefix("[") { return nil }
        return (at, query)
    }

    /// Whether the "@" at `at` starts a picked mention's "@Label": the list stays closed there, so
    /// Return sends and the next word isn't taken for a query ("@Sony TV " still matches Sony TV).
    static func isPicked(at: String.Index, in text: String, picks: [CantripTabMention]) -> Bool {
        let rest = text[at...]
        return picks.contains { pick in
            let needle = "@" + pick.label
            guard rest.hasPrefix(needle) else { return false }
            let end = text.index(at, offsetBy: needle.count)
            return end == text.endIndex || !(text[end].isLetter || text[end].isNumber || text[end] == "_")
        }
    }

    /// The label for picking `candidate`: its title, made unique when another picked tab has the
    /// same label (with its project, then a number), since a label stands for one ID. Picking the
    /// same tab again keeps its label.
    static func uniqueLabel(for candidate: Candidate, among picks: [CantripTabMention]) -> String {
        let base = label(for: candidate.title)
        let taken = Set(picks.filter { $0.id.uppercased() != candidate.id.uppercased() }.map(\.label))
        guard taken.contains(base) else { return base }
        // The title is shortened so the suffix always fits in the label (else a 60-character title
        // would lose every suffix and never become unique).
        func suffixed(_ suffix: String) -> String {
            let head = String(base.prefix(max(1, labelLimit - suffix.count))).trimmingCharacters(in: .whitespaces)
            return label(for: head + suffix)
        }
        if let project = candidate.project, project.count < labelLimit / 2 {
            let withProject = suffixed(" (\(project))")
            if !taken.contains(withProject) { return withProject }
        }
        var number = 2
        while taken.contains(suffixed(" \(number)")) { number += 1 }
        return suffixed(" \(number)")
    }

    struct Candidate: Equatable, Identifiable {
        let id: String
        let title: String
        var workdir = ""
        var parentTitle: String?
        var isStreaming = false
        var needsAnswer = false

        /// The folder's name, unless the tab works in a home folder (or nowhere in particular).
        var project: String? {
            let path = (workdir as NSString).standardizingPath
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !path.isEmpty, path != "/", path != "~", !parts.isEmpty else { return nil }
            if path.hasPrefix("/"), parts.count == 2, ["Users", "home"].contains(parts[0]) { return nil }
            if path == "/var/root" || path == "/root" { return nil }
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? nil : name
        }

        /// What helps tell tabs apart: whose child it is, its project and whether it's busy.
        var detail: String {
            var parts: [String] = []
            if let parentTitle { parts.append("Child of \(parentTitle)") }
            if let project, project.caseInsensitiveCompare(title) != .orderedSame { parts.append(project) }
            if needsAnswer { parts.append("Needs your answer") } else if isStreaming { parts.append("Working") }
            return parts.joined(separator: " · ")
        }

        var accessibilityLabel: String {
            var parts = [title]
            if let parentTitle { parts.append("child of \(parentTitle)") }
            if let project, project.caseInsensitiveCompare(title) != .orderedSame { parts.append("project \(project)") }
            if needsAnswer { parts.append("needs your answer") } else if isStreaming { parts.append("working") }
            return parts.joined(separator: ", ")
        }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Tabs matching `query`, best first, then in list order. An empty query lists them all.
    static func matches(_ query: String, in candidates: [Candidate], limit: Int = suggestionLimit) -> [Candidate] {
        let q = normalized(query)
        let words = q.split(separator: " ")
        let scored: [(Int, Int, Candidate)] = candidates.enumerated().compactMap { index, candidate in
            let title = normalized(candidate.title)
            let titleWords = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "/" || $0 == "." })
            let score: Int
            if q.isEmpty || title.hasPrefix(q) {
                score = 0
            } else if !words.isEmpty, words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) {
                score = 1
            } else if title.contains(q) {
                score = 2
            } else if let project = candidate.project, normalized(project).hasPrefix(q) {
                score = 3
            } else {
                return nil
            }
            return (score, index, candidate)
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(limit).map(\.2)
    }

    /// Picks `candidate` for the query at `at`: "@Label " replaces it (no second space when one
    /// already follows) and the caret goes after the space. `label` defaults to the tab's title
    /// (`uniqueLabel` when other tabs are picked).
    static func insert(_ candidate: Candidate, at: String.Index, caret: String.Index? = nil,
                       in text: String, label: String? = nil) -> (text: String, label: String, caret: String.Index) {
        let label = label ?? Self.label(for: candidate.title)
        let end = caret ?? text.endIndex
        let spaced = text[end...].first == " "
        let inserted = "@\(label)" + (spaced ? "" : " ")
        let result = String(text[..<at]) + inserted + String(text[end...])
        let offset = text.distance(from: text.startIndex, to: at) + inserted.count + (spaced ? 1 : 0)
        return (result, label, result.index(result.startIndex, offsetBy: offset))
    }

    /// Where "@label" counts as that mention: starting a word and ending at a word boundary.
    private static func occurrences(of label: String, in text: String) -> [Range<String.Index>] {
        let needle = "@" + label
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            searchStart = range.upperBound
            let startsWord = range.lowerBound == text.startIndex
                || { let c = text[text.index(before: range.lowerBound)]; return c.isWhitespace || openers.contains(c) }()
            let endsWord = range.upperBound == text.endIndex
                || { let c = text[range.upperBound]; return !(c.isLetter || c.isNumber || c == "_" || c == "[") }()
            if startsWord, endsWord { ranges.append(range) }
        }
        return ranges
    }

    /// The text to send: each picked mention whose "@Label" is still in the text becomes a token.
    static func encode(_ text: String, mentions: [CantripTabMention]) -> String {
        var result = text
        // Longest labels first, so "@TV" can't take the start of "@TV Remote".
        for mention in mentions.sorted(by: { $0.label.count > $1.label.count }) {
            let token = Self.token(label: mention.label, id: mention.id)
            for range in occurrences(of: mention.label, in: result).reversed() {
                result.replaceSubrange(range, with: token)
            }
        }
        return result
    }

    /// The picks whose "@Label" is still in `text` (the others' chips go away). All picks are
    /// matched together, so "@TV" doesn't count where the text says "@TV Remote" and that is
    /// picked too.
    static func remaining(_ mentions: [CantripTabMention], in text: String) -> [CantripTabMention] {
        let encoded = encode(text, mentions: mentions)
        return mentions.filter { encoded.contains(token(label: $0.label, id: $0.id)) }
    }

    /// `text` without `mention` (its chip's remove button): its "@Label" and the space after it
    /// go; the other picks' texts stay.
    static func removing(_ mention: CantripTabMention, from text: String, among mentions: [CantripTabMention]) -> String {
        let token = token(label: mention.label, id: mention.id)
        let encoded = encode(text, mentions: mentions.contains(mention) ? mentions : mentions + [mention])
        return plain(encoded
            .replacingOccurrences(of: token + " ", with: "")
            .replacingOccurrences(of: token, with: ""))
    }

    /// Adds a picked mention once (the same tab picked twice keeps one chip).
    static func adding(_ mention: CantripTabMention, to mentions: [CantripTabMention]) -> [CantripTabMention] {
        mentions.contains(mention) ? mentions : mentions + [mention]
    }

    // MARK: Sessions

    /// Whether the composer of `session` offers "@" (the Mac acts on mentions there).
    static func supportsMentions(_ session: CantripRemoteSession?) -> Bool {
        session?.supportsTabMentions == true
    }

    /// The tabs a composer in `composingID` may suggest, in tab-list order (sections as listed;
    /// child tabs follow their parent as the Mac lists them).
    static func candidates(sessions: [CantripRemoteSession], sections: [CantripTabSection],
                           composingID: String?) -> [Candidate] {
        let ordered = CantripTabGrouping.groups(sessions, sections: sections)?.flatMap(\.sessions) ?? sessions
        let titles = Dictionary(sessions.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return ordered.compactMap { session in
            guard session.mentionable == true, session.id != composingID,
                  session.isCantripHome != true, UUID(uuidString: session.id) != nil else { return nil }
            var parentTitle: String?
            if let parentID = session.parentID {
                parentTitle = titles[parentID] ?? session.child.map(\.parentTitle).flatMap { $0.isEmpty ? nil : $0 }
            }
            return Candidate(id: session.id, title: session.title, workdir: session.workdir,
                             parentTitle: parentTitle, isStreaming: session.isStreaming,
                             needsAnswer: (session.pendingInputCount ?? 0) > 0)
        }
    }

    // MARK: Pop-up

    struct Popup: Equatable {
        enum Content: Equatable {
            case rows([Candidate])
            /// Nothing matches; shown as one info row that can't be picked.
            case noMatch(String)
        }

        /// UTF-16 offset of the "@": a dismissed pop-up stays dismissed for that "@".
        let at: Int
        let query: String
        let content: Content

        var rows: [Candidate] {
            if case .rows(let rows) = content { return rows }
            return []
        }
    }

    /// The suggestions for the composer's text and caret, or nil when nothing should show (also
    /// right after a pick: its "@Label" isn't a query).
    static func popup(text: String, caret: String.Index?, candidates: [Candidate], dismissedAt: Int?,
                      picks: [CantripTabMention] = []) -> Popup? {
        guard let found = query(in: text, caret: caret), !isPicked(at: found.at, in: text, picks: picks) else {
            return nil
        }
        let at = text.utf16.distance(from: text.startIndex, to: found.at)
        guard at != dismissedAt else { return nil }
        let rows = matches(found.query, in: candidates)
        if !rows.isEmpty { return Popup(at: at, query: found.query, content: .rows(rows)) }
        // "@Sony TV" typed by hand with no tab of that name stays plain text.
        if found.query.contains(where: \.isWhitespace) { return nil }
        return Popup(at: at, query: found.query, content: .noMatch(found.query))
    }

    /// Escape hid the pop-up for the "@" at `dismissedAt`; it stays hidden until that "@" no
    /// longer starts the text being typed (deleted, or the caret moved to another "@").
    static func keepsDismissal(_ dismissedAt: Int?, text: String, caret: String.Index?) -> Int? {
        guard let dismissedAt, let found = query(in: text, caret: caret),
              text.utf16.distance(from: text.startIndex, to: found.at) == dismissedAt else { return nil }
        return dismissedAt
    }

    enum KeyResult: Equatable {
        /// Not for the list: the text field handles it as usual.
        case ignore
        case highlight(Int)
        case pick(Candidate)
        case dismiss
    }

    /// Hardware keys while the pop-up shows: Up/Down move (wrapping), Return or Tab picks the
    /// highlighted row, Escape dismisses. With only the "no match" row, Return keeps its meaning.
    static func handle(_ key: BackendSlashKey, popup: Popup, highlighted: Int) -> KeyResult {
        let rows = popup.rows
        switch key {
        case .escape:
            return .dismiss
        case .up, .down:
            guard !rows.isEmpty else { return .ignore }
            let step = key == .down ? 1 : -1
            let current = rows.indices.contains(highlighted) ? highlighted : 0
            return .highlight(((current + step) % rows.count + rows.count) % rows.count)
        case .return, .tab:
            guard !rows.isEmpty else { return .ignore }
            return .pick(rows[rows.indices.contains(highlighted) ? highlighted : 0])
        }
    }

    static func countAnnouncement(_ count: Int) -> String {
        count == 1 ? "1 tab" : "\(count) tabs"
    }

    static func noMatchText(_ query: String) -> String {
        query.isEmpty ? "No other open tabs to mention" : "No open tab matches “\(query)”"
    }

    // MARK: Rendering

    enum Segment: Equatable {
        case text(String)
        case mention(label: String, id: String)
    }

    /// The text split into plain runs and mentions.
    static func segments(_ text: String) -> [Segment] {
        let tokens = parse(text)
        guard !tokens.isEmpty else { return text.isEmpty ? [] : [.text(text)] }
        var segments: [Segment] = []
        var cursor = text.startIndex
        for token in tokens {
            if cursor < token.range.lowerBound { segments.append(.text(String(text[cursor..<token.range.lowerBound]))) }
            segments.append(.mention(label: token.label, id: token.id))
            cursor = token.range.upperBound
        }
        if cursor < text.endIndex { segments.append(.text(String(text[cursor...]))) }
        return segments
    }

    /// Markdown for a formatted reply: each token outside code blocks becomes a bold "@Label",
    /// linked to its tab when `linkable` says it can open; inside code it reads "@Label".
    static func markdown(_ text: String, linkable: (String) -> Bool = { _ in false }) -> String {
        guard !parse(text).isEmpty else { return text }
        var fence: (marker: Character, count: Int)?
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.drop { $0 == " " }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if count >= 3 {
                    if let open = fence {
                        if open.marker == marker, count >= open.count,
                           trimmed.dropFirst(count).allSatisfy(\.isWhitespace) { fence = nil }
                    } else {
                        fence = (marker, count)
                    }
                    lines.append(plain(line))
                    continue
                }
            }
            guard fence == nil else {
                lines.append(plain(line))
                continue
            }
            var result = line
            for token in parse(line).reversed() {
                let label = "**@\(escapedMarkdown(token.label))**"
                result.replaceSubrange(token.range, with: linkable(token.id)
                                       ? "[\(label)](\(scheme):\(token.id))" : label)
            }
            lines.append(result)
        }
        return lines.joined(separator: "\n")
    }

    private static func escapedMarkdown(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_~<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
