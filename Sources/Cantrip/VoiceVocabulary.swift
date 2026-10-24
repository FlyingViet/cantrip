import Foundation

/// Names and phrases Cantrip Agent's dictation should spell the way the user does
/// (`GET /api/v1/voice/vocabulary`). Pure logic only, so tests compile it on its own:
/// VoiceVocabularySources.swift reads the Mac's data and hands candidates to these functions.
enum VoiceVocabulary {
    static let version = 1
    static let maximumTerms = 300
    static let maximumPeople = 100
    static let maximumHandlesPerPerson = 4

    enum Kind: String, Codable {
        case project, note, task, company, person, place, other
    }

    struct Term: Codable, Equatable {
        var text: String
        var kind: Kind
        var weight: Double
        var sources: [String]
        var aliases: [String]
    }

    struct Person: Codable, Equatable {
        /// Omitted from the JSON when unknown.
        var name: String?
        var handles: [String]
        var count: Int
        var sources: [String]
    }

    struct Response: Codable, Equatable {
        var version: Int
        var generatedAt: Double
        var terms: [Term]
        var people: [Person]
        var unavailable: [String]
    }

    struct TermCandidate: Equatable {
        var text: String
        var kind: Kind
        var weight: Double
        var sources: [String]

        init(_ text: String, _ kind: Kind, _ weight: Double, sources: [String]) {
            self.text = text
            self.kind = kind
            self.weight = weight
            self.sources = sources
        }
    }

    struct PersonCandidate: Equatable {
        var name: String?
        var handles: [String]
        var count: Int
        var source: String
    }

    /// A name NLTagger (or a test double) found in free text.
    struct NameEntity: Equatable {
        var text: String
        var kind: Kind
    }

    typealias NameTagger = (String) -> [NameEntity]

    // MARK: - Assembly

    static func response(terms: [TermCandidate], people: [PersonCandidate],
                         unavailable: [String], generatedAt: Date) -> Response {
        let merged = mergePeople(people)
        return Response(version: version, generatedAt: generatedAt.timeIntervalSince1970,
                        terms: mergeTerms(terms + personTerms(merged)), people: merged,
                        unavailable: unavailable)
    }

    // MARK: - Proper-noun phrases

    /// Generic English and platform words that are never vocabulary on their own; they are
    /// also trimmed from the ends of a run ("Daily Orbitly briefing" -> "Orbitly").
    static let genericWords: Set<String> = [
        "a", "an", "the", "i", "my", "our", "your", "this", "that", "these", "those", "it", "its",
        "and", "of", "for", "with", "to", "in", "on", "at", "by", "from", "about", "into", "via",
        "is", "are", "was", "be", "how", "what", "why", "when", "where", "who", "which",
        "daily", "weekly", "monthly", "yearly", "morning", "evening", "night", "today", "tomorrow",
        "yesterday", "week", "month", "year",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december",
        "home", "task", "tasks", "tracker", "trackers", "monitor", "monitoring", "briefing",
        "briefings", "note", "notes", "native", "release", "releases", "build", "builds",
        "development", "dev", "workflow", "workflows", "feasibility", "reading", "sending",
        "health", "check", "checks", "private", "public", "new", "old", "project", "projects",
        "plan", "plans", "planning", "status", "summary", "report", "reports", "review", "reviews",
        "update", "updates", "fix", "fixes", "bug", "bugs", "issue", "issues", "follow", "ups",
        "follow-ups", "followups", "bill", "bills", "interview", "interviews", "idea", "ideas",
        "todo", "todos", "inbox", "app", "apps", "tab", "tabs", "chat", "chats", "session",
        "sessions", "local", "remote", "test", "tests", "testing", "setup", "research", "draft",
        "drafts", "list", "lists", "log", "logs", "misc", "general", "untitled", "other",
        "overview", "guide", "procedure", "procedures", "checklist", "reference", "memory",
        "add", "find", "get", "make", "run", "send", "track", "watch", "write", "read", "prepare",
        "set", "use", "try", "move", "clean", "ship", "debug", "improve", "investigate", "explore",
        "learn", "migrate", "port", "design", "create", "remove", "sync", "deploy", "refactor",
        "rewrite", "support", "handle", "help", "organize", "schedule", "book", "call", "email",
        "text", "pay", "buy", "order", "cancel", "renew", "compare", "summarize",
        "ios", "ipados", "macos", "watchos", "tvos", "visionos", "iphone", "ipad", "mac",
        "macbook", "apple", "android", "windows", "linux", "web", "ai", "api", "ui", "ux",
    ]
    private static let connectorWords: Set<String> = ["of", "&", "and", "de"]
    private static let phraseSeparators = [" - ", "—", "–", "→", ":", "(", ")", ";", ",", "/", "|",
                                           "[", "]", "{", "}"]
    private static let tokenTrimSet = CharacterSet.punctuationCharacters.union(.symbols)
        .union(.whitespacesAndNewlines)

    /// Proper-noun phrases in a title: "Kestrel Labs development workflow" -> ["Kestrel Labs"].
    static func properNounPhrases(in title: String) -> [String] {
        var text = title
        for separator in phraseSeparators {
            text = text.replacingOccurrences(of: separator, with: "\n")
        }
        var phrases: [String] = []
        var seen = Set<String>()
        for part in text.split(separator: "\n") {
            for phrase in nameRuns(in: part) where seen.insert(phrase.lowercased()).inserted {
                phrases.append(phrase)
            }
        }
        return phrases
    }

    /// Starts with an uppercase letter, or has one inside ("iOS", "QuillKit", "2FA").
    static func isNameLike(_ token: String) -> Bool {
        guard let first = token.first, token.contains(where: \.isLetter) else { return false }
        return first.isUppercase || token.dropFirst().contains(where: \.isUppercase)
    }

    static func isGeneric(_ word: String) -> Bool {
        genericWords.contains(word.lowercased())
    }

    private static func nameRuns(in part: Substring) -> [String] {
        var runs: [[String]] = []
        var current: [String] = []
        var pendingConnector: String?
        func flush() {
            if !current.isEmpty { runs.append(current) }
            current = []
            pendingConnector = nil
        }
        for raw in part.split(whereSeparator: \.isWhitespace) {
            let endsSentence = raw.last.map { ".!?".contains($0) } ?? false
            let token = cleanedToken(raw)
            if token.isEmpty {
                flush()
            } else if isNameLike(token) {
                if let connector = pendingConnector { current.append(connector) }
                pendingConnector = nil
                current.append(token)
                if endsSentence { flush() }
            } else if !current.isEmpty, pendingConnector == nil, !endsSentence,
                      connectorWords.contains(token.lowercased()) {
                // Kept only if another name-like token follows ("Bank of Orbitly").
                pendingConnector = token
            } else {
                flush()
            }
        }
        flush()
        return runs.compactMap { run in
            var tokens = run[...]
            while let first = tokens.first, isGeneric(first) || connectorWords.contains(first.lowercased()) {
                tokens.removeFirst()
            }
            while let last = tokens.last, isGeneric(last) || connectorWords.contains(last.lowercased()) {
                tokens.removeLast()
            }
            guard (1...4).contains(tokens.count) else { return nil }
            let phrase = tokens.joined(separator: " ")
            return phrase.count >= 3 ? phrase : nil
        }
    }

    private static func cleanedToken(_ raw: Substring) -> String {
        if raw == "&" { return "&" }
        var token = raw.trimmingCharacters(in: tokenTrimSet)
        for suffix in ["'s", "’s"] where token.count > suffix.count + 1 && token.lowercased().hasSuffix(suffix) {
            token = String(token.dropLast(suffix.count))
        }
        return token
    }

    // MARK: - Tabs

    static let genericTabTitles: Set<String> = [
        "new tab", "tab", "new chat", "chat", "untitled", "private local", "cantrip home",
        "cantrip home background", "home",
    ]

    /// Custom tab names exactly as written, plus any shorter proper-noun phrases inside them.
    static func tabTerms(_ titles: [String]) -> [TermCandidate] {
        var terms: [TermCandidate] = []
        for raw in titles {
            let title = collapsed(raw)
            let lower = title.lowercased()
            guard title.count >= 2, title.contains(where: \.isLetter), !genericTabTitles.contains(lower),
                  lower.range(of: #"^(new )?tab \d+$"#, options: .regularExpression) == nil else { continue }
            terms.append(TermCandidate(title, .project, 0.9, sources: ["tabs"]))
            for phrase in properNounPhrases(in: title) where phrase.lowercased() != lower {
                terms.append(TermCandidate(phrase, .project, 0.9, sources: ["tabs"]))
            }
        }
        return terms
    }

    // MARK: - Memory notes

    static let excludedNoteNames: Set<String> = ["memory.md", "user.md"]

    /// The first `# ` heading outside fenced code blocks.
    static func firstHeading(in text: String) -> String? {
        var inFence = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, trimmed.hasPrefix("# ") else { continue }
            let heading = trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
            return heading.isEmpty ? nil : heading
        }
        return nil
    }

    /// "orbitly-launch.md" -> "Orbitly Launch"; nil for dates and all-generic names.
    static func prettifiedNoteName(_ fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        let words = base.split(whereSeparator: { "-_ .".contains($0) }).map(String.init)
        guard (1...4).contains(words.count),
              !words.allSatisfy({ isGeneric($0) || !$0.contains(where: \.isLetter) }) else { return nil }
        let pretty = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return pretty.count >= 3 ? pretty : nil
    }

    static func noteTerms(fileName: String, heading: String?) -> [TermCandidate] {
        var texts = heading.map(properNounPhrases(in:)) ?? []
        if texts.isEmpty, let pretty = prettifiedNoteName(fileName) { texts = [pretty] }
        return texts.map { TermCandidate($0, .note, 0.7, sources: ["memory"]) }
    }

    // MARK: - Cantrip Home tasks

    struct WorkspaceField: Codable, Equatable {
        var key: String
        var kind: String
        var label: String
    }

    struct WorkspaceRecord: Codable, Equatable {
        var values: [String: String]
    }

    /// The subset of a Home task workspace this reads; decodes tasks.json directly.
    struct Workspace: Codable, Equatable {
        var fields: [WorkspaceField]
        var records: [WorkspaceRecord]
    }

    struct HomeTask: Codable, Equatable {
        var title: String
        var workspace: Workspace?
    }

    static let entityFieldPattern =
        "company|contact|vendor|provider|organization|organisation|person|interviewer|recruiter|festival|venue|airline|service"
    static let personFieldPattern = "person|interviewer|recruiter|contact"
    private static let placeholderValues: Set<String> = [
        "n/a", "na", "n.a.", "none", "tbd", "tba", "unknown", "null", "nil", "pending", "other",
        "various", "multiple", "self", "me", "yes", "no", "true", "false", "not yet", "-", "?",
    ]

    /// Text fields that name a company, contact, vendor, venue, and so on.
    static func entityFields(of workspace: Workspace) -> [WorkspaceField] {
        workspace.fields.filter {
            $0.kind == "text" && (matches($0.key, entityFieldPattern) || matches($0.label, entityFieldPattern))
        }
    }

    /// A short name-like value, or nil for URLs, emails, numbers, dates and placeholders.
    static func usableWorkspaceValue(_ raw: String) -> String? {
        let value = collapsed(raw)
        guard (2...60).contains(value.count) else { return nil }
        let lower = value.lowercased()
        let letters = value.filter(\.isLetter).count
        let digits = value.filter(\.isNumber).count
        guard letters >= 2, digits <= letters, !placeholderValues.contains(lower),
              !lower.contains("://"), !lower.hasPrefix("www."), !lower.contains("@"),
              lower.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+(/\S*)?$"#, options: .regularExpression) == nil,
              !looksLikeDate(lower) else { return nil }
        return value
    }

    private static func looksLikeDate(_ lower: String) -> Bool {
        let month = "(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\.?"
        let weekday = "((mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\\s+)?"
        return lower.range(of: "^\(weekday)\(month)\\s+\\d{1,2}(st|nd|rd|th)?(,?\\s+\\d{4})?$",
                           options: .regularExpression) != nil
            || lower.range(of: "^\(weekday)\\d{1,2}(st|nd|rd|th)?\\s+\(month)(,?\\s+\\d{4})?$",
                           options: .regularExpression) != nil
    }

    /// Task-title phrases (weight 0.6) and company/contact field values (0.8).
    static func homeTaskTerms(_ tasks: [HomeTask], isPersonalName: (String) -> Bool) -> [TermCandidate] {
        var terms: [TermCandidate] = []
        for task in tasks {
            terms += properNounPhrases(in: task.title).map { TermCandidate($0, .task, 0.6, sources: ["home"]) }
            if let workspace = task.workspace {
                terms += workspaceFieldTerms(workspace, isPersonalName: isPersonalName)
            }
        }
        return terms
    }

    static func workspaceFieldTerms(_ workspace: Workspace, isPersonalName: (String) -> Bool) -> [TermCandidate] {
        let fields = entityFields(of: workspace)
        guard !fields.isEmpty else { return [] }
        var personNames: [String: Bool] = [:]
        var terms: [TermCandidate] = []
        for record in workspace.records {
            for field in fields {
                guard let raw = record.values[field.key], let value = usableWorkspaceValue(raw) else { continue }
                var kind = Kind.company
                if matches(field.key, personFieldPattern) || matches(field.label, personFieldPattern) {
                    let isName = personNames[value] ?? isPersonalName(value)
                    personNames[value] = isName
                    if isName { kind = .person }
                }
                terms.append(TermCandidate(value, kind, 0.8, sources: ["home"]))
            }
        }
        return terms
    }

    /// People (0.5) and organizations (0.4) named in the text of records in workspaces that
    /// track companies or contacts. Reads at most `recordLimit` records in all.
    static func workspaceEntityTerms(_ tasks: [HomeTask], recordLimit: Int = 200, valueLimit: Int = 2_000,
                                     tagger: NameTagger) -> [TermCandidate] {
        var remaining = recordLimit
        var terms: [TermCandidate] = []
        for task in tasks {
            guard let workspace = task.workspace, !entityFields(of: workspace).isEmpty else { continue }
            let keys = workspace.fields.filter { $0.kind == "text" || $0.kind == "longText" }.map(\.key)
            for record in workspace.records {
                guard remaining > 0 else { return terms }
                remaining -= 1
                for key in keys {
                    guard let value = record.values[key], value.contains(where: \.isLetter) else { continue }
                    for entity in tagger(String(value.prefix(valueLimit))) {
                        guard let text = plausibleEntity(entity.text) else { continue }
                        switch entity.kind {
                        case .person: terms.append(TermCandidate(text, .person, 0.5, sources: ["home"]))
                        case .company: terms.append(TermCandidate(text, .company, 0.4, sources: ["home"]))
                        default: break
                        }
                    }
                }
            }
        }
        return terms
    }

    /// True when the tagger reads (most of) the value as one personal name.
    static func isPersonalName(_ value: String, tagger: NameTagger) -> Bool {
        tagger(value).contains { $0.kind == .person && $0.text.count * 2 >= value.count }
    }

    private static func plausibleEntity(_ raw: String) -> String? {
        let text = collapsed(raw.trimmingCharacters(in: tokenTrimSet))
        let words = text.split(separator: " ")
        guard (3...60).contains(text.count), (1...4).contains(words.count), !text.contains("@"),
              let first = words.first, isNameLike(String(first)),
              !words.allSatisfy({ isGeneric(String($0)) }) else { return nil }
        return text
    }

    // MARK: - People

    /// Emails lowercased; phone numbers as "+" and digits (a bare 10-digit number is US +1).
    /// Short codes (fewer than 7 digits) are businesses, not people, and return nil.
    static func normalizedHandle(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["mailto:", "tel:", "sms:"] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if value.contains("@") {
            let email = value.lowercased()
            let parts = email.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."),
                  !parts[1].hasSuffix("."), !email.contains(where: \.isWhitespace) else { return nil }
            return email
        }
        guard !value.contains(where: \.isLetter) else { return nil }
        let digits = String(value.filter { $0.isASCII && $0.isNumber })
        guard (7...15).contains(digits.count) else { return nil }
        if value.hasPrefix("+") { return "+" + digits }
        if digits.count == 10 { return "+1" + digits }
        return "+" + digits
    }

    /// The last 10 digits of a phone handle, to match numbers saved without a country code.
    static func phoneSuffix(_ handle: String) -> String? {
        guard handle.hasPrefix("+") else { return nil }
        let digits = handle.dropFirst()
        return digits.count >= 10 ? String(digits.suffix(10)) : nil
    }

    private static let nonPersonNames: Set<String> = [
        "unknown", "unknown caller", "no caller id", "spam risk", "potential spam", "scam likely",
        "private number", "blocked", "voicemail",
    ]

    /// A trimmed person name, or nil for emails, numbers, rooms and other non-person labels.
    static func plausiblePersonName(_ raw: String) -> String? {
        let name = collapsed(raw)
        guard (2...60).contains(name.count), name.filter(\.isLetter).count >= 2,
              !name.contains("@"), !name.contains(where: \.isNumber),
              name.split(separator: " ").count <= 5,
              !nonPersonNames.contains(name.lowercased()),
              name.range(of: #"\b(room|conference|resource|meeting|zoom|calendar|holidays?|birthdays?)\b"#,
                         options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return name
    }

    /// The `limit` busiest handles from (handle, name, count) rows, merged after normalizing.
    static func topHandles(_ rows: [(handle: String, name: String?, count: Int)], limit: Int = 60,
                           source: String) -> [PersonCandidate] {
        var merged: [(handle: String, name: String?, count: Int)] = []
        var index: [String: Int] = [:]
        for row in rows {
            guard row.count > 0, let handle = normalizedHandle(row.handle) else { continue }
            let name = row.name.flatMap(plausiblePersonName)
            if let position = index[handle] {
                merged[position].count += row.count
                if merged[position].name == nil { merged[position].name = name }
            } else {
                index[handle] = merged.count
                merged.append((handle, name, row.count))
            }
        }
        return merged.enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .prefix(limit)
            .map { PersonCandidate(name: $0.element.name, handles: [$0.element.handle], count: $0.element.count, source: source) }
    }

    /// Names people by their handles using a directory keyed by normalized handle (from
    /// Contacts). Numbers saved without a country code match on their last 10 digits.
    static func resolvingNames(_ candidates: [PersonCandidate], directory: [String: String]) -> [PersonCandidate] {
        guard !directory.isEmpty else { return candidates }
        var bySuffix: [String: String] = [:]
        for (handle, name) in directory.sorted(by: { $0.key < $1.key }) {
            if let suffix = phoneSuffix(handle), bySuffix[suffix] == nil { bySuffix[suffix] = name }
        }
        return candidates.map { candidate in
            var candidate = candidate
            for raw in candidate.handles {
                guard let handle = normalizedHandle(raw) else { continue }
                if let name = directory[handle] ?? phoneSuffix(handle).flatMap({ bySuffix[$0] }) {
                    candidate.name = name
                    break
                }
            }
            return candidate
        }
    }

    /// Merges people who share a handle or a name (transitively): counts add up, sources
    /// and handles are combined (busiest 4 handles kept). Busiest first, at most `limit`.
    static func mergePeople(_ candidates: [PersonCandidate], limit: Int = maximumPeople) -> [Person] {
        struct Clean { var name: String?; var handles: [String]; var count: Int; var source: String }
        let cleaned: [Clean] = candidates.compactMap { candidate in
            let name = candidate.name.flatMap(plausiblePersonName)
            var handles: [String] = []
            for raw in candidate.handles {
                if let handle = normalizedHandle(raw), !handles.contains(handle) { handles.append(handle) }
            }
            guard name != nil || !handles.isEmpty else { return nil }
            return Clean(name: name, handles: handles, count: max(candidate.count, 0), source: candidate.source)
        }
        var parent = Array(cleaned.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        var owner: [String: Int] = [:]
        for (index, person) in cleaned.enumerated() {
            var keys = person.handles.map { "handle:" + $0 }
            if let name = person.name { keys.append("name:" + name.lowercased()) }
            for key in keys {
                if let other = owner[key] {
                    let (a, b) = (root(index), root(other))
                    if a != b { parent[max(a, b)] = min(a, b) }
                } else {
                    owner[key] = index
                }
            }
        }
        var groups: [Int: [Clean]] = [:]
        for index in cleaned.indices { groups[root(index), default: []].append(cleaned[index]) }
        var people: [Person] = groups.keys.sorted().map { key in
            let members = groups[key]!
            var sources: [String] = []
            var handleCounts: [(handle: String, count: Int)] = []
            var nameCounts: [(name: String, count: Int)] = []
            for member in members {
                if !sources.contains(member.source) { sources.append(member.source) }
                for handle in member.handles {
                    if let position = handleCounts.firstIndex(where: { $0.handle == handle }) {
                        handleCounts[position].count += member.count
                    } else {
                        handleCounts.append((handle, member.count))
                    }
                }
                if let name = member.name {
                    if let position = nameCounts.firstIndex(where: { $0.name == name }) {
                        nameCounts[position].count += member.count
                    } else {
                        nameCounts.append((name, member.count))
                    }
                }
            }
            let handles = handleCounts.enumerated()
                .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
                .prefix(maximumHandlesPerPerson).map(\.element.handle)
            let name = nameCounts.enumerated().max { a, b in
                (a.element.count, a.element.name.count, -a.offset) < (b.element.count, b.element.name.count, -b.offset)
            }?.element.name
            return Person(name: name, handles: Array(handles), count: members.reduce(0) { $0 + $1.count },
                          sources: sources)
        }
        people.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            return ($0.name ?? $0.handles.first ?? "") < ($1.name ?? $1.handles.first ?? "")
        }
        return Array(people.prefix(limit))
    }

    /// Named people as person terms, weighted 0.85 (busiest) down to 0.5.
    static func personTerms(_ people: [Person]) -> [TermCandidate] {
        let named = people.compactMap { person in person.name.map { (name: $0, sources: person.sources) } }
        return named.enumerated().map { rank, person in
            let weight = named.count > 1 ? 0.85 - 0.35 * Double(rank) / Double(named.count - 1) : 0.85
            return TermCandidate(person.name, .person, weight, sources: person.sources)
        }
    }

    // MARK: - Terms

    /// Case-insensitive dedupe: sources merge, the highest weight (and its kind) wins, and the
    /// spelling with internal capitals ("QuillKit" over "Quillkit") is kept. Sorted by weight,
    /// then text; at most `limit`.
    static func mergeTerms(_ candidates: [TermCandidate], limit: Int = maximumTerms) -> [Term] {
        struct Group {
            var spellings: [(text: String, weight: Double, order: Int)]
            var kind: Kind
            var weight: Double
            var sources: [String]
        }
        var groups: [String: Group] = [:]
        var order: [String] = []
        for (index, candidate) in candidates.enumerated() {
            let text = collapsed(candidate.text)
            guard (2...80).contains(text.count), text.contains(where: \.isLetter), candidate.weight.isFinite else { continue }
            let weight = min(max(candidate.weight, 0), 1)
            let key = text.lowercased()
            if var group = groups[key] {
                group.spellings.append((text, weight, index))
                if weight > group.weight {
                    group.weight = weight
                    group.kind = candidate.kind
                }
                for source in candidate.sources where !group.sources.contains(source) { group.sources.append(source) }
                groups[key] = group
            } else {
                var sources: [String] = []
                for source in candidate.sources where !sources.contains(source) { sources.append(source) }
                groups[key] = Group(spellings: [(text, weight, index)], kind: candidate.kind, weight: weight, sources: sources)
                order.append(key)
            }
        }
        var terms = order.map { key -> Term in
            let group = groups[key]!
            let text = group.spellings.max { a, b in
                (internalCapitals(a.text), capitalizedWords(a.text), a.weight, -a.order)
                    < (internalCapitals(b.text), capitalizedWords(b.text), b.weight, -b.order)
            }!.text
            let folded = text.folding(options: .diacriticInsensitive, locale: nil)
            return Term(text: text, kind: group.kind, weight: (group.weight * 1000).rounded() / 1000,
                        sources: group.sources, aliases: folded == text ? [] : [folded])
        }
        terms.sort {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            let (a, b) = ($0.text.lowercased(), $1.text.lowercased())
            return a != b ? a < b : $0.text < $1.text
        }
        return Array(terms.prefix(limit))
    }

    /// Words with a capital after their first letter and some lowercase: "QuillKit", "iOS".
    static func internalCapitals(_ text: String) -> Int {
        text.split(separator: " ").filter {
            $0.dropFirst().contains(where: \.isUppercase) && $0.contains(where: \.isLowercase)
        }.count
    }

    private static func capitalizedWords(_ text: String) -> Int {
        text.split(separator: " ").filter { $0.first?.isUppercase == true }.count
    }

    // MARK: - Helpers

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
