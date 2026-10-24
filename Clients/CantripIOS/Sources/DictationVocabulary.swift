import Foundation

/// A word or phrase dictation should spell exactly: a project, company,
/// person, or a term learned from your own corrections.
struct DictationTerm: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case person, project, company, task, note, place, learned, other

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }

        var priority: Int {
            switch self {
            case .learned: 0
            case .person: 1
            case .project: 2
            case .company: 3
            case .task, .note: 4
            case .place: 5
            case .other: 6
            }
        }
    }

    var text: String
    var kind: Kind
    var weight: Double
    var aliases: [String] = []
    var sources: [String] = []
    /// The lowercase spelling is not an ordinary word, so casing can be restored anywhere.
    var exactCase = false

    var key: String { DictationText.key(text) }
}

/// Spelling dictionary used to tell names apart from ordinary words.
protocol DictationLexicon {
    func isWord(_ word: String) -> Bool
}

/// One fix you made to dictated text before sending it.
struct DictationCorrection: Codable, Hashable, Sendable {
    var heard: String
    var corrected: String
    var count: Int
    var lastUsed: Date
    /// The misheard form is an ordinary word, so it is only boosted, never auto-replaced.
    var heardIsWord: Bool
}

enum DictationVocabulary {
    static let maximumTerms = 200
    static let maximumCorrections = 300

    // MARK: Assembly

    /// Cleans, merges and ranks terms from every source, keeping the most
    /// useful `cap` (CTC boosting is tuned for a few hundred terms).
    static func assemble(
        _ inputs: [DictationTerm], lexicon: DictationLexicon?, cap: Int = maximumTerms
    ) -> [DictationTerm] {
        var merged: [String: DictationTerm] = [:]
        var order: [String] = []
        for input in inputs {
            guard let text = sanitize(input.text) else { continue }
            let key = DictationText.key(text)
            var aliases = input.aliases.compactMap(sanitize)
            if let alias = camelCaseAlias(text) { aliases.append(alias) }
            if var existing = merged[key] {
                if input.weight > existing.weight
                    || (input.weight == existing.weight && uppercaseCount(text) > uppercaseCount(existing.text)) {
                    existing.text = text
                }
                if existing.kind == .other || input.kind.priority < existing.kind.priority {
                    existing.kind = input.kind
                }
                existing.weight = min(1, max(existing.weight, input.weight) + 0.05)
                existing.aliases += aliases
                existing.sources += input.sources
                merged[key] = existing
            } else {
                var term = input
                term.text = text
                term.aliases = aliases
                term.weight = min(1, max(0, input.weight))
                merged[key] = term
                order.append(key)
            }
        }
        var terms = order.compactMap { merged[$0] }.map { term -> DictationTerm in
            var term = term
            var seen: Set<String> = [term.text.lowercased()]
            term.aliases = term.aliases.filter { seen.insert($0.lowercased()).inserted }
            var sources: Set<String> = []
            term.sources = term.sources.filter { sources.insert($0).inserted }
            term.exactCase = isExactCase(term.text, lexicon: lexicon)
            return term
        }
        terms.sort {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            if $0.kind.priority != $1.kind.priority { return $0.kind.priority < $1.kind.priority }
            return $0.text < $1.text
        }
        return Array(terms.prefix(cap))
    }

    static func sanitize(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: #"\.md$"#, with: "", options: .regularExpression)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard (3...40).contains(text.count),
              text.split(separator: " ").count <= 4,
              text.filter(\.isLetter).count >= 2,
              !text.contains(where: { "/\\@_<>{}[]|#=".contains($0) }),
              !text.lowercased().hasPrefix("http") else { return nil }
        return text
    }

    /// "QuillPad" → "Quill Pad", so the spaced form ASR tends to produce maps back.
    static func camelCaseAlias(_ text: String) -> String? {
        guard !text.contains(" ") else { return nil }
        var parts: [String] = []
        var current = ""
        for character in text {
            if character.isUppercase, let last = current.last, last.isLowercase {
                parts.append(current)
                current = ""
            }
            current.append(character)
        }
        parts.append(current)
        return parts.count > 1 ? parts.joined(separator: " ") : nil
    }

    static func isExactCase(_ text: String, lexicon: DictationLexicon?) -> Bool {
        let words = text.split(separator: " ")
        if words.count > 1 { return words.contains { $0.first?.isUppercase == true } }
        guard let first = text.first, first.isUppercase || text.dropFirst().contains(where: \.isUppercase) else {
            return false
        }
        if text.dropFirst().contains(where: \.isUppercase) { return true }
        guard let lexicon else { return false }
        return !lexicon.isWord(text.lowercased())
    }

    private static func uppercaseCount(_ text: String) -> Int {
        text.filter(\.isUppercase).count
    }

    // MARK: Titles

    /// Project-like names inside a free-form title: CamelCase or unknown
    /// words, and runs of capitalized words ("Fix Orbit Lane login" → "Orbit Lane").
    static func titleCandidates(_ title: String, lexicon: DictationLexicon?) -> [String] {
        let words = DictationText.words(title).map(\.core).filter { !$0.isEmpty }
        var found: [String] = []
        var run: [String] = []
        func closeRun() {
            defer { run = [] }
            var phrase = run
            if phrase.count >= 3, let first = phrase.first, lexicon?.isWord(first.lowercased()) == true,
               words.first == first {
                phrase.removeFirst()
            }
            guard (2...3).contains(phrase.count),
                  !phrase.allSatisfy({ DictationText.functionWords.contains($0.lowercased()) }) else { return }
            found.append(phrase.joined(separator: " "))
        }
        for word in words {
            let letters = word.filter(\.isLetter)
            guard letters.count == word.count else {
                closeRun()
                continue
            }
            if word.first?.isUppercase == true, word.count >= 2, !(word.count <= 3 && word == word.uppercased()) {
                run.append(word)
            } else {
                closeRun()
            }
            let camel = word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
            let unknown = word.count >= 4 && lexicon.map { !$0.isWord(word.lowercased()) } == true
            if camel || unknown { found.append(word) }
        }
        closeRun()
        var seen: Set<String> = []
        return found.filter { seen.insert(DictationText.key($0)).inserted }
    }

    // MARK: Use

    /// Casing and spelling rules: exact-case terms and their aliases, joined
    /// forms ("zephyr ly" → "Zephyrly") and confident learned fixes.
    static func rules(_ terms: [DictationTerm], corrections: [DictationCorrection]) -> [DictationText.Rule] {
        var rules: [DictationText.Rule] = []
        // Learned terms only feed boosting; their automatic replacement is the
        // guarded corrections loop below.
        for term in terms where term.kind != .learned {
            let replacement = term.text.split(separator: " ").map(String.init)
            if term.exactCase {
                let joins = replacement.count == 1 && term.key.count >= 6
                    && [.project, .company, .learned].contains(term.kind)
                rules.append(.init(
                    keys: replacement.map(DictationText.key), replacement: replacement, joinsWords: joins
                ))
            }
            for alias in term.aliases {
                let keys = alias.split(separator: " ").map { DictationText.key(String($0)) }
                if keys.count > 1 || term.exactCase {
                    rules.append(.init(keys: keys, replacement: replacement))
                }
            }
        }
        for correction in corrections where correction.count >= 2 && !correction.heardIsWord {
            let keys = correction.heard.split(separator: " ").map { DictationText.key(String($0)) }
            let replacement = correction.corrected.split(separator: " ").map(String.init)
            guard !keys.isEmpty, !replacement.isEmpty else { continue }
            rules.append(.init(keys: keys, replacement: replacement))
        }
        return rules
    }

    /// Up to `limit` terms that sound like something in the dictation, for
    /// the language-model prompt (the full list would crowd it out).
    static func relevant(_ terms: [DictationTerm], to text: String, limit: Int = 12) -> [DictationTerm] {
        let keys = DictationText.words(text).map(\.key).filter { !$0.isEmpty }
        guard !keys.isEmpty else { return [] }
        var windows: Set<String> = []
        for length in 1...3 {
            guard keys.count >= length else { break }
            for start in 0...(keys.count - length) {
                windows.insert(keys[start..<(start + length)].joined())
            }
        }
        var scored: [(DictationTerm, Double)] = []
        for term in terms {
            let candidates = [term.text] + term.aliases
            var best = 0.0
            for candidate in candidates {
                let key = DictationText.key(candidate)
                guard key.count >= 3 else { continue }
                if windows.contains(key) { best = 1; break }
                for window in windows where abs(window.count - key.count) <= max(2, key.count / 3) {
                    best = max(best, DictationText.similarity(window, key))
                }
            }
            if best >= 0.6 { scored.append((term, best + term.weight * 0.1)) }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Keys a model edit may introduce without counting as invented content.
    static func allowedKeys(_ terms: [DictationTerm]) -> Set<String> {
        var keys: Set<String> = []
        for term in terms {
            keys.insert(term.key)
            for word in term.text.split(separator: " ") { keys.insert(DictationText.key(String(word))) }
        }
        return keys
    }

    // MARK: Learning

    static func record(
        _ substitutions: [DictationText.Substitution],
        into corrections: [DictationCorrection],
        isWord: (String) -> Bool,
        now: Date = Date()
    ) -> [DictationCorrection] {
        var corrections = corrections
        for substitution in substitutions {
            let heardKey = DictationText.key(substitution.heard)
            // Recasing an ordinary word ("not" → "NOT") is emphasis, not a name.
            if heardKey == DictationText.key(substitution.corrected),
               substitution.heard.split(separator: " ").allSatisfy({ isWord(String($0).lowercased()) }) {
                continue
            }
            if let index = corrections.firstIndex(where: { DictationText.key($0.heard) == heardKey }) {
                if corrections[index].corrected == substitution.corrected {
                    corrections[index].count += 1
                } else {
                    corrections[index].corrected = substitution.corrected
                    corrections[index].count = 1
                }
                corrections[index].lastUsed = now
            } else {
                let heardIsWord = substitution.heard.split(separator: " ")
                    .allSatisfy { isWord(String($0).lowercased()) }
                corrections.append(DictationCorrection(
                    heard: substitution.heard, corrected: substitution.corrected,
                    count: 1, lastUsed: now, heardIsWord: heardIsWord
                ))
            }
        }
        if corrections.count > maximumCorrections {
            corrections.sort { $0.lastUsed > $1.lastUsed }
            corrections = Array(corrections.prefix(maximumCorrections))
        }
        return corrections
    }

    static func terms(from corrections: [DictationCorrection]) -> [DictationTerm] {
        corrections.map { correction in
            DictationTerm(
                text: correction.corrected, kind: .learned,
                weight: min(1, 0.55 + 0.1 * Double(correction.count)),
                aliases: correction.heardIsWord ? [] : [correction.heard], sources: ["learned"]
            )
        }
    }
}
