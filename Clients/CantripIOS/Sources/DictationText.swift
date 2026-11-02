import Foundation

/// Word-level rules for dictated text: deterministic cleanup, guarded number
/// formatting, guardrails for model edits and the diffs used to learn from
/// corrections. Foundation-only so every rule is unit tested and shared with
/// the offline evaluation harness.
enum DictationText {
    struct Word: Equatable, Sendable {
        var leading: String
        var core: String
        var trailing: String

        var text: String { leading + core + trailing }
        var key: String { DictationText.key(core) }
        var endsSentence: Bool { trailing.contains { ".?!".contains($0) } }
    }

    /// A casing or spelling fix applied wherever its word keys appear.
    struct Rule: Equatable, Sendable {
        let keys: [String]
        let replacement: [String]
        /// Also matches two or three words that spell the key when joined ("tail scale").
        var joinsWords = false
    }

    struct Hunk: Equatable {
        let old: Range<Int>
        let new: Range<Int>
        let isEqual: Bool
    }

    // MARK: Tokens

    private static let leadingPunctuation = Set("\"'“‘([{¿¡*")
    private static let trailingPunctuation = Set(".,!?;:\"'”’)]}…*")

    static func words(_ text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).map { piece in
            var core = Substring(piece)
            var leading = ""
            var trailing = ""
            while let first = core.first, leadingPunctuation.contains(first) {
                leading.append(first)
                core = core.dropFirst()
            }
            while let last = core.last, trailingPunctuation.contains(last) {
                trailing.insert(last, at: trailing.startIndex)
                core = core.dropLast()
            }
            return Word(leading: leading, core: String(core), trailing: trailing)
        }
    }

    static func join(_ words: [Word]) -> String {
        words.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func key(_ text: String) -> String {
        String(String.UnicodeScalarView(
            text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        ))
    }

    static func wordCount(_ text: String) -> Int {
        words(text).filter { !$0.key.isEmpty }.count
    }

    // MARK: Diff

    /// Longest-common-subsequence alignment grouped into equal and changed runs.
    static func diff(_ old: [String], _ new: [String]) -> [Hunk] {
        let n = old.count, m = new.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = old[i] == new[j]
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        var changeStart: (Int, Int)?
        var equalStart: (Int, Int)?
        func closeChange() {
            if let (a, b) = changeStart, a < i || b < j {
                hunks.append(Hunk(old: a..<i, new: b..<j, isEqual: false))
            }
            changeStart = nil
        }
        func closeEqual() {
            if let (a, b) = equalStart, a < i {
                hunks.append(Hunk(old: a..<i, new: b..<j, isEqual: true))
            }
            equalStart = nil
        }
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                closeChange()
                if equalStart == nil { equalStart = (i, j) }
                i += 1; j += 1
            } else {
                closeEqual()
                if changeStart == nil { changeStart = (i, j) }
                if j >= m || (i < n && table[i + 1][j] >= table[i][j + 1]) {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        closeChange()
        closeEqual()
        return hunks
    }

    /// Alignment where near-miss words substitute cheaply, so a misheard name
    /// lines up with its replacement even when other words repeat.
    static func alignSimilar(_ old: [String], _ new: [String]) -> [Hunk] {
        let n = old.count, m = new.count
        var cost = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        func pair(_ i: Int, _ j: Int) -> Double {
            old[i] == new[j] ? 0 : 1 - similarity(old[i], new[j]) * 0.9
        }
        for i in 0...n { cost[i][m] = Double(n - i) }
        for j in 0...m { cost[n][j] = Double(m - j) }
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    cost[i][j] = min(cost[i + 1][j + 1] + pair(i, j), cost[i + 1][j] + 1, cost[i][j + 1] + 1)
                }
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        var start: (Int, Int)?
        func flush() {
            if let (a, b) = start { hunks.append(Hunk(old: a..<i, new: b..<j, isEqual: false)) }
            start = nil
        }
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j], cost[i][j] == cost[i + 1][j + 1] {
                flush()
                hunks.append(Hunk(old: i..<(i + 1), new: j..<(j + 1), isEqual: true))
                i += 1; j += 1
                continue
            }
            if start == nil { start = (i, j) }
            if i < n, j < m, cost[i][j] == cost[i + 1][j + 1] + pair(i, j) {
                i += 1; j += 1
            } else if i < n, cost[i][j] == cost[i + 1][j] + 1 {
                i += 1
            } else {
                j += 1
            }
        }
        flush()
        return hunks
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    // MARK: Word lists

    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "hm", "mm", "mhm"]
    private static let stutters: Set<String> = [
        "i", "the", "a", "an", "to", "and", "of", "in", "on", "for", "we", "it", "is", "my",
        "you", "so", "but", "with", "at", "this", "he", "she", "they"
    ]
    static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "to", "of", "in", "on", "at", "for", "with",
        "from", "by", "about", "as", "is", "are", "was", "were", "be", "been", "it", "its", "that",
        "this", "these", "those", "i", "im", "you", "we", "they", "he", "she", "me", "us", "them",
        "my", "our", "your", "their", "his", "her", "if", "then", "than", "not", "do", "does",
        "did", "will", "would", "can", "could", "should", "have", "has", "had", "also", "just",
        "please", "when", "which", "who", "what", "where", "how", "up", "out", "into", "over"
    ]
    /// Words a vocabulary replacement may swallow by accident and that should
    /// be restored when the term matches better without them.
    private static let restorableWords: Set<String> = [
        "at", "to", "the", "with", "for", "and", "or", "of", "in", "on", "about", "from", "by",
        "text", "call", "email", "ask", "tell", "send", "message", "ping", "meet", "me", "my",
        "our", "your", "is", "was"
    ]
    private static let numberWords: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100,
        "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
        "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
        "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20,
        "thirtieth": 30
    ]
    private static let numberUnits: Set<String> = [
        "dollar", "dollars", "cent", "cents", "percent", "am", "pm", "oclock", "bucks"
    ]
    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december"
    ]
    private static let ordinals: [String: Int] = [
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3,
        "fourth": 4, "fourthly": 4, "fifth": 5, "fifthly": 5, "sixth": 6, "seventh": 7
    ]

    // MARK: Pipeline

    /// The deterministic cleanup that runs on every final transcript.
    static func finalize(
        _ text: String,
        rules: [Rule],
        normalizeNumbers: ((String) -> String)? = nil
    ) -> String {
        var result = removeDisfluencies(text)
        result = applySelfCorrections(result)
        if let normalizeNumbers {
            result = guardedNumbers(result, normalize: normalizeNumbers)
        }
        result = fixNumberFormats(result)
        result = applyRules(rules, to: result)
        result = fixCapitalization(result)
        result = formatLists(result)
        return result
    }

    /// Joins segment transcripts, lowercasing a segment's capitalized function
    /// word when the previous segment did not end a sentence.
    static func joinSegments(_ parts: [String]) -> String {
        var output: [Word] = []
        for part in parts {
            var words = words(part)
            guard !words.isEmpty else { continue }
            if let last = output.last, !last.endsSentence, functionWords.contains(words[0].key),
               words[0].key != "i", words[0].key != "im" {
                words[0].core = words[0].core.lowercased()
            }
            output.append(contentsOf: words)
        }
        return join(output)
    }

    static func removeDisfluencies(_ text: String) -> String {
        var words = words(text)
        var index = 0
        while index < words.count {
            let word = words[index]
            if fillers.contains(word.key), word.core.allSatisfy(\.isLetter),
               !(word.core.count >= 2 && word.core == word.core.uppercased()) {
                let closing = word.trailing.filter { ".?!".contains($0) }
                if !closing.isEmpty, index > 0, !words[index - 1].endsSentence {
                    words[index - 1].trailing = words[index - 1].trailing.filter { !",;".contains($0) } + closing
                }
                words.remove(at: index)
                continue
            }
            if index + 1 < words.count, word.trailing.isEmpty, word.leading.isEmpty,
               stutters.contains(word.key), word.key == words[index + 1].key {
                words.remove(at: index)
                continue
            }
            index += 1
        }
        return join(words)
    }

    // MARK: Self-corrections

    private static let correctionCues: [[String]] = [["actually"], ["no"], ["sorry"], ["i", "mean"], ["or", "rather"], ["make", "that"]]
    private static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    private enum Slot { case quantity, weekday, month }

    private static func slot(_ word: Word) -> Slot? {
        let key = word.key
        if weekdays.contains(key) { return .weekday }
        if months.contains(key) { return .month }
        if numberWords[key] != nil || (key.first?.isNumber == true && key.count <= 6) { return .quantity }
        return nil
    }

    /// "at 2, actually 3" → "at 3", "Tuesday, no, Wednesday" → "Wednesday":
    /// a corrected time, number, weekday or month keeps only the correction.
    static func applySelfCorrections(_ text: String) -> String {
        var words = words(text)
        var index = 0
        while index + 2 < words.count {
            guard let kind = slot(words[index]) else { index += 1; continue }
            var cueEnd: Int?
            for cue in correctionCues where index + cue.count + 1 < words.count {
                let span = words[(index + 1)...(index + cue.count)].map(\.key)
                if span == cue { cueEnd = index + cue.count + 1; break }
            }
            guard var replacement = cueEnd else { index += 1; continue }
            let cue = words[(index + 1)..<replacement].map(\.key)
            if cue == ["no"] || cue == ["sorry"] {
                // A bare "no" needs a pause around it: "no one showed up" is not a correction.
                let paused = words[index].trailing.contains(",") || words[replacement - 1].trailing.contains(",")
                if !paused || words[replacement].key == "one" { index += 1; continue }
            }
            if index > 0, replacement + 1 < words.count, words[replacement].key == words[index - 1].key {
                replacement += 1
            }
            guard slot(words[replacement]) == kind, words[replacement].key != words[index].key else {
                index += 1
                continue
            }
            words[replacement].leading = words[index].leading
            words.removeSubrange(index..<replacement)
            index += 1
        }
        return join(words)
    }

    // MARK: Numbers

    /// Applies inverse text normalization only where a spoken number clearly
    /// becomes clearer as digits; keeps "another one", list ordinals and any
    /// change that swallows ordinary words.
    static func guardedNumbers(_ text: String, normalize: (String) -> String) -> String {
        let normalized = normalize(text)
        guard normalized != text, !normalized.isEmpty else { return text }
        let old = words(text), new = words(normalized)
        var output: [Word] = []
        for hunk in diff(old.map(\.key), new.map(\.key)) {
            let oldWords = Array(old[hunk.old])
            if hunk.isEqual {
                output.append(contentsOf: oldWords)
                continue
            }
            var newWords = Array(new[hunk.new])
            let previous = hunk.old.lowerBound > 0 ? old[hunk.old.lowerBound - 1].key : nil
            let next = hunk.old.upperBound < old.count ? old[hunk.old.upperBound].key : nil
            if acceptsNumberChange(from: oldWords, to: newWords, previous: previous, next: next) {
                if let lastOld = oldWords.last, let lastNew = newWords.last,
                   lastNew.trailing.isEmpty, !lastOld.trailing.isEmpty {
                    newWords[newWords.count - 1].trailing = lastOld.trailing
                }
                if let firstOld = oldWords.first, !newWords.isEmpty, newWords[0].leading.isEmpty {
                    newWords[0].leading = firstOld.leading
                }
                output.append(contentsOf: newWords)
            } else {
                output.append(contentsOf: oldWords)
            }
        }
        return join(output)
    }

    private static func acceptsNumberChange(
        from old: [Word], to new: [Word], previous: String?, next: String?
    ) -> Bool {
        guard !old.isEmpty, !new.isEmpty else { return false }
        let produced = new.map(\.text).joined()
        guard produced.contains(where: { $0.isNumber || "$%@".contains($0) }) else { return false }
        if produced.contains("@") {
            let keys = old.map(\.key)
            return keys.contains("at") && keys.contains("dot") && old.count <= 10
                && new.filter({ $0.core.contains("@") }).count == 1
        }
        var numbers = 0
        var units = 0
        var value = 0
        for (index, word) in old.enumerated() {
            let key = word.key
            if let number = numberWords[key] {
                numbers += 1
                value = max(value, number)
            } else if numberUnits.contains(key) || key == "point" {
                units += 1
            } else if key == "and", index > 0, index + 1 < old.count,
                      numberWords[old[index - 1].key] != nil, numberWords[old[index + 1].key] != nil {
                continue
            } else if key == "a", index + 1 < old.count,
                      ["hundred", "thousand", "million", "billion"].contains(old[index + 1].key) {
                continue
            } else {
                return false
            }
        }
        if numbers >= 2 { return true }
        guard numbers == 1 else { return false }
        if units > 0 { return true }
        if let previous, months.contains(previous) { return true }
        if let next, numberUnits.contains(next) { return true }
        return value >= 10
    }

    /// "at 9.30" → "at 9:30", "04:15" → "4:15", "$1200" → "$1,200".
    static func fixNumberFormats(_ text: String) -> String {
        var result = text
        result = replacing(
            #"\b(at|around|until|till|before|after)\s+(1[0-2]|[1-9])\.([0-5]\d)\b(?!\s*(?:dollars|percent|%|million|billion|thousand|miles|kilometers|km|gb|mb|tb))"#,
            in: result, with: "$1 $2:$3", options: [.caseInsensitive]
        )
        result = replacing(#"(?<![\d:])0(\d):([0-5]\d)\b"#, in: result, with: "$1:$2")
        let pattern = try? NSRegularExpression(pattern: #"\$(\d{4,})(\.\d{2})?\b"#)
        if let pattern {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US")
            for match in pattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let digitsRange = Range(match.range(at: 1), in: result),
                      let value = Int(result[digitsRange]),
                      let grouped = formatter.string(from: NSNumber(value: value)) else { continue }
                result.replaceSubrange(digitsRange, with: grouped)
            }
        }
        return result
    }

    private static func replacing(
        _ pattern: String, in text: String, with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }

    // MARK: Vocabulary

    static func applyRules(_ rules: [Rule], to text: String) -> String {
        guard !rules.isEmpty else { return text }
        let longest = rules.map(\.keys.count).max() ?? 1
        var byFirstKey: [String: [Rule]] = [:]
        var joined: [String: Rule] = [:]
        for rule in rules where !rule.keys.isEmpty && !rule.replacement.isEmpty {
            byFirstKey[rule.keys[0], default: []].append(rule)
            if rule.joinsWords, rule.keys.count == 1 { joined[rule.keys[0]] = rule }
        }
        let words = words(text)
        var output: [Word] = []
        var index = 0
        func spanIsPhrase(_ length: Int) -> Bool {
            // Punctuation inside a span means the words belong to different phrases.
            !words[index..<(index + length - 1)].contains { !$0.trailing.isEmpty }
                && !words[(index + 1)..<(index + length)].contains { !$0.leading.isEmpty }
        }
        func replace(_ length: Int, with rule: Rule) {
            var replacement = rule.replacement.map { Word(leading: "", core: $0, trailing: "") }
            replacement[0].leading = words[index].leading
            replacement[replacement.count - 1].trailing = words[index + length - 1].trailing
            output.append(contentsOf: replacement)
            index += length
        }
        outer: while index < words.count {
            if !joined.isEmpty {
                for length in stride(from: min(3, words.count - index), through: 2, by: -1) where spanIsPhrase(length) {
                    let key = words[index..<(index + length)].map(\.key).joined()
                    if let rule = joined[key] {
                        replace(length, with: rule)
                        continue outer
                    }
                }
            }
            if let candidates = byFirstKey[words[index].key] {
                for length in stride(from: min(longest, words.count - index), through: 1, by: -1) where spanIsPhrase(length) {
                    let keys = words[index..<(index + length)].map(\.key)
                    guard let rule = candidates.first(where: { $0.keys == keys }) else { continue }
                    replace(length, with: rule)
                    continue outer
                }
            }
            output.append(words[index])
            index += 1
        }
        return join(output)
    }

    /// Restores words and punctuation that CTC vocabulary boosting dropped
    /// next to a replaced term, and reverts replacements that do not sound
    /// like the words they replaced. `terms` (word keys per vocabulary term)
    /// lets neighbouring replacements be judged one by one.
    static func repairBoost(original: String, boosted: String, terms: [[String]] = []) -> String {
        let old = words(original), new = words(boosted)
        var output: [Word] = []
        for hunk in mergeTermSpans(alignSimilar(old.map(\.key), new.map(\.key)), new: new, terms: terms) {
            let oldWords = Array(old[hunk.old])
            if hunk.isEqual {
                for (offset, var word) in new[hunk.new].enumerated() {
                    let source = oldWords[offset]
                    if word.trailing.isEmpty { word.trailing = source.trailing }
                    if word.leading.isEmpty { word.leading = source.leading }
                    output.append(word)
                }
                continue
            }
            let newWords = Array(new[hunk.new])
            if newWords.isEmpty || oldWords.isEmpty {
                // Boosting replaces spans; a bare deletion or insertion is an artifact.
                output.append(contentsOf: oldWords)
                continue
            }
            let units = termUnits(newWords, terms: terms)
            for (unit, span) in zip(units, assign(units, to: oldWords)) {
                let replaced = Array(oldWords[span])
                guard !replaced.isEmpty else { continue }
                output.append(contentsOf: repairReplacement(
                    old: replaced, new: unit, oldStart: hunk.old.lowerBound + span.lowerBound, context: old
                ))
            }
        }
        return join(output)
    }

    /// A multi-word term that only partly differs ("orbit lean" → "Orbit Lane")
    /// is judged as a whole, not word by word.
    private static func mergeTermSpans(_ hunks: [Hunk], new: [Word], terms: [[String]]) -> [Hunk] {
        let keys = new.map(\.key)
        var spans: [Range<Int>] = []
        for term in terms where term.count > 1 && term.count <= keys.count {
            for start in 0...(keys.count - term.count) where Array(keys[start..<(start + term.count)]) == term {
                spans.append(start..<(start + term.count))
            }
        }
        guard !spans.isEmpty else { return hunks }
        var result = hunks
        for span in spans {
            let touching = result.indices.filter { index in
                let range = result[index].new
                return range.isEmpty
                    ? range.lowerBound > span.lowerBound && range.lowerBound < span.upperBound
                    : range.overlaps(span)
            }
            guard let first = touching.first, let last = touching.last,
                  touching.contains(where: { !result[$0].isEqual }) else { continue }
            let merged = Hunk(
                old: result[first].old.lowerBound..<result[last].old.upperBound,
                new: result[first].new.lowerBound..<result[last].new.upperBound,
                isEqual: false
            )
            result.replaceSubrange(first...last, with: [merged])
        }
        return result
    }

    /// Splits replacement words into vocabulary terms (longest match) and single words.
    private static func termUnits(_ words: [Word], terms: [[String]]) -> [[Word]] {
        var units: [[Word]] = []
        var index = 0
        while index < words.count {
            let keys = words[index...].map(\.key)
            let match = terms.filter { !$0.isEmpty && $0.count <= keys.count && Array(keys.prefix($0.count)) == $0 }
                .map(\.count).max() ?? 1
            units.append(Array(words[index..<(index + match)]))
            index += match
        }
        // Without term boundaries, treat the whole replacement as one unit.
        return terms.isEmpty ? [words] : units
    }

    /// Monotone alignment of units to contiguous old spans maximizing similarity.
    private static func assign(_ units: [[Word]], to old: [Word]) -> [Range<Int>] {
        guard units.count > 1 else { return [0..<old.count] }
        let n = old.count, u = units.count
        var best = Array(repeating: Array(repeating: -Double.infinity, count: n + 1), count: u + 1)
        var choice = Array(repeating: Array(repeating: 0, count: n + 1), count: u + 1)
        best[0][0] = 0
        for i in 0..<u {
            let target = units[i].map(\.key).joined()
            for j in 0...n where best[i][j] > -Double.infinity {
                let last = i == u - 1
                for k in (last ? n : j)...(last ? n : min(n, j + 6)) {
                    let score = best[i][j] + (k > j ? similarity(old[j..<k].map(\.key).joined(), target) : 0)
                    if score > best[i + 1][k] { best[i + 1][k] = score; choice[i + 1][k] = j }
                }
            }
        }
        var spans: [Range<Int>] = []
        var end = n
        for i in stride(from: u, to: 0, by: -1) {
            let start = choice[i][end]
            spans.insert(start..<end, at: 0)
            end = start
        }
        return spans
    }

    private static func repairReplacement(old oldWords: [Word], new: [Word], oldStart: Int, context: [Word]) -> [Word] {
        var newWords = new
        let target = newWords.map(\.key).joined()
        var best = (start: 0, end: oldWords.count)
        var bestScore = similarity(oldWords.map(\.key).joined(), target)
        for start in 0..<oldWords.count {
            for end in (start + 1)...oldWords.count where end - start < oldWords.count {
                let score = similarity(oldWords[start..<end].map(\.key).joined(), target)
                if score > bestScore + 0.05 { best = (start, end); bestScore = score }
            }
        }
        // TDT capitalizes words it hears as names; replacing ordinary words
        // with a term that does not resemble them is a false hit.
        let nameLike = (best.start..<best.end).contains { offset in
            let index = oldStart + offset
            let word = context[index]
            let startsSentence = index == 0 || context[index - 1].endsSentence
            return word.core.first?.isUppercase == true && word.key != "i" && !startsSentence
        }
        if bestScore < (nameLike ? 0.35 : 0.6) { return oldWords }
        var prefix = Array(oldWords[..<best.start])
        var suffix = Array(oldWords[best.end...])
        if !prefix.allSatisfy({ restorableWords.contains($0.key) }) { prefix = [] }
        if !suffix.allSatisfy({ restorableWords.contains($0.key) }) { suffix = [] }
        let replacedEnd = suffix.isEmpty ? oldWords.count : best.end
        let replacedStart = prefix.isEmpty ? 0 : best.start
        if newWords[newWords.count - 1].trailing.isEmpty {
            newWords[newWords.count - 1].trailing = oldWords[replacedEnd - 1].trailing
        }
        if newWords[0].leading.isEmpty { newWords[0].leading = oldWords[replacedStart].leading }
        return prefix + newWords + suffix
    }

    // MARK: Capitalization

    private static let abbreviations: Set<String> = ["eg", "ie", "etc", "vs", "mr", "mrs", "ms", "dr", "st"]

    static func fixCapitalization(_ text: String) -> String {
        guard !text.contains("\n") else {
            return text.components(separatedBy: "\n").map(fixCapitalization).joined(separator: "\n")
        }
        var words = words(text)
        guard !words.isEmpty else { return text }
        for index in words.indices {
            let core = words[index].core
            let lower = core.lowercased()
            if lower == "i" || ["i'm", "i'll", "i've", "i'd", "i’m", "i’ll", "i’ve", "i’d"].contains(lower) {
                words[index].core = "I" + core.dropFirst()
                continue
            }
            let startsSentence = index == 0
                || (words[index - 1].endsSentence && !abbreviations.contains(words[index - 1].key))
            if startsSentence, let first = core.first, first.isLowercase,
               core.dropFirst().allSatisfy({ !$0.isUppercase }) {
                words[index].core = first.uppercased() + core.dropFirst()
            }
        }
        let spoken = words.filter { !$0.key.isEmpty }
        if spoken.count >= 4, var last = words.last,
           !last.trailing.contains(where: { ".?!:".contains($0) }),
           last.core.last.map({ $0.isLetter || $0.isNumber }) == true {
            last.trailing = "." + last.trailing.filter { !",;".contains($0) }
            words[words.count - 1] = last
        }
        return join(words)
    }

    // MARK: Lists

    /// "First, A. Second, B. Third, C." → a numbered list (three or more items).
    static func formatLists(_ text: String) -> String {
        let words = words(text)
        var markers: [Int] = []
        var expected = 1
        for (index, word) in words.enumerated() {
            let boundary = index == 0 || words[index - 1].trailing.contains { ".,;:?!".contains($0) }
            guard boundary, index + 1 < words.count else { continue }
            if ordinals[word.key] == expected {
                markers.append(index)
                expected += 1
            } else if markers.count >= 2, ["finally", "lastly"].contains(word.key) {
                markers.append(index)
                expected += 1
                break
            }
        }
        guard markers.count >= 3 else { return text }
        var lines: [String] = []
        var preface = Array(words[..<markers[0]])
        if !preface.isEmpty {
            var last = preface.removeLast()
            last.trailing = last.trailing.contains { ".?!".contains($0) } ? last.trailing : ":"
            preface.append(last)
            lines.append(join(preface))
        }
        var tail: [Word] = []
        for (number, start) in markers.enumerated() {
            var end = number + 1 < markers.count ? markers[number + 1] : words.count
            if number + 1 == markers.count,
               let stop = words[start..<end].firstIndex(where: \.endsSentence), stop + 1 < end {
                tail = Array(words[(stop + 1)..<end])
                end = stop + 1
            }
            var item = Array(words[(start + 1)..<end])
            guard !item.isEmpty else { return text }
            if let first = item[0].core.first, first.isLowercase,
               item[0].core.dropFirst().allSatisfy({ !$0.isUppercase }) {
                item[0].core = first.uppercased() + item[0].core.dropFirst()
            }
            item[0].leading = ""
            item[item.count - 1].trailing = item[item.count - 1].trailing.filter { !",;".contains($0) }
            lines.append("\(number + 1). " + join(item))
        }
        if !tail.isEmpty { lines.append(join(tail)) }
        return lines.joined(separator: "\n")
    }

    // MARK: Model edits

    struct Edit: Equatable, Sendable {
        let find: String
        let replace: String
    }

    static func applyEdits(_ edits: [Edit], to text: String) -> String {
        var result = text
        for edit in edits.prefix(12) where edit.find != edit.replace
            && (key(edit.find).count >= 3 || edit.find.split(separator: " ").count >= 2) {
            let range = result.range(of: edit.find)
                ?? result.range(of: edit.find, options: [.caseInsensitive, .diacriticInsensitive])
            guard let range else { continue }
            result.replaceSubrange(range, with: edit.replace)
        }
        return result
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .trimmingCharacters(in: .whitespaces)
    }

    enum Verdict: Equatable {
        case accepted
        case rejected(String)
    }

    /// Accepts a cleaned-up candidate only when it changes few words and adds
    /// nothing beyond the dictation, known vocabulary and small function words.
    static func evaluate(original: String, candidate: String, allowedKeys: Set<String>) -> Verdict {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("empty") }
        let old = words(original).filter { !$0.key.isEmpty && !fillers.contains($0.key) }
        let new = words(trimmed).filter { !$0.key.isEmpty }
        guard !old.isEmpty else { return .rejected("nothing dictated") }
        let oldKeys = Set(old.map(\.key))
        let joinedOld = old.map(\.key).joined()
        let hasNumbers = old.contains { numberWords[$0.key] != nil || $0.key.contains(where: \.isNumber) }
        var edits = 0
        for hunk in diff(old.map(\.key), new.map(\.key)) where !hunk.isEqual {
            let introduced = new[hunk.new].filter { !oldKeys.contains($0.key) && allowedKeys.contains($0.key) }
            if !introduced.isEmpty {
                // A name may only replace words that sound like it.
                let before = old[hunk.old].map(\.key).joined(), after = new[hunk.new].map(\.key).joined()
                if similarity(before, after) < 0.45 { return .rejected("swapped in “\(introduced[0].core)”") }
            }
            for word in new[hunk.new] {
                let key = word.key
                let allowed = oldKeys.contains(key) || allowedKeys.contains(key)
                    || functionWords.contains(key)
                    || (hasNumbers && key.contains(where: \.isNumber))
                    || (key.count >= 4 && joinedOld.contains(key))
                if !allowed { return .rejected("added “\(word.core)”") }
            }
            edits += max(hunk.old.count, hunk.new.count)
        }
        var oldCounts: [String: Int] = [:], newCounts: [String: Int] = [:]
        for word in old { oldCounts[word.key, default: 0] += 1 }
        for word in new { newCounts[word.key, default: 0] += 1 }
        for (key, count) in newCounts where !functionWords.contains(key) && !allowedKeys.contains(key) {
            if let before = oldCounts[key], count > before { return .rejected("repeated “\(key)”") }
        }
        let hasCue = old.contains { ["actually", "no", "sorry", "mean", "rather", "scratch", "wait"].contains($0.key) }
        if !hasCue {
            let cueless: Set<String> = ["like", "know", "you", "mean", "basically", "literally"]
            for (key, count) in oldCounts where !functionWords.contains(key) && !cueless.contains(key) {
                let kept = newCounts[key] ?? 0
                if kept < count, !new.contains(where: { similarity($0.key, key) >= 0.5 }) {
                    return .rejected("removed “\(key)”")
                }
            }
        }
        let ratio = Double(edits) / Double(old.count)
        let limit = old.count >= 8 ? 0.35 : 0.5
        if ratio > limit { return .rejected(String(format: "changed %.0f%% of words", ratio * 100)) }
        let oldLength = old.map(\.core.count).reduce(0, +)
        let newLength = new.map(\.core.count).reduce(0, +)
        if Double(newLength) < Double(oldLength) * 0.5 { return .rejected("dropped too much") }
        return .accepted
    }

    // MARK: Learning

    struct Substitution: Equatable, Sendable {
        let heard: String
        let corrected: String
    }

    /// Word swaps between what was dictated and what was finally sent that
    /// look like fixed names or terms (not rewrites).
    static func substitutions(dictated: String, final: String) -> [Substitution] {
        let old = words(dictated), new = words(final)
        var found: [Substitution] = []
        for hunk in diff(old.map(\.key), new.map(\.key)) {
            if hunk.isEqual {
                for offset in 0..<hunk.old.count {
                    let before = old[hunk.old.lowerBound + offset], after = new[hunk.new.lowerBound + offset]
                    guard before.core != after.core, after.core.contains(where: \.isUppercase) else { continue }
                    let position = hunk.new.lowerBound + offset
                    let startsSentence = position == 0 || new[position - 1].endsSentence
                    let onlyCapitalized = after.core == before.core.prefix(1).uppercased() + before.core.dropFirst()
                    if startsSentence && onlyCapitalized { continue }
                    found.append(Substitution(heard: before.core, corrected: after.core))
                }
                continue
            }
            guard (1...3).contains(hunk.old.count), (1...3).contains(hunk.new.count) else { continue }
            let heardWords = old[hunk.old], correctedWords = new[hunk.new]
            let looksLikeTerm = correctedWords.contains { word in
                word.core.dropFirst().contains(where: \.isUppercase)
                    || (word.core.first?.isUppercase == true && !functionWords.contains(word.key))
            }
            guard looksLikeTerm else { continue }
            let heardKey = heardWords.map(\.key).joined(), correctedKey = correctedWords.map(\.key).joined()
            guard heardKey != correctedKey, similarity(heardKey, correctedKey) >= 0.45 else { continue }
            found.append(Substitution(
                heard: heardWords.map(\.core).joined(separator: " "),
                corrected: correctedWords.map(\.core).joined(separator: " ")
            ))
        }
        return found
    }
}
