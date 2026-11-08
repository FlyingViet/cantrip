import Foundation

/// What the memory search looks for: the new message, plus the exchange before it, so a follow-up
/// that doesn't name its subject ("will that make it faster?") still finds it. The message's own
/// words count fully. The previous exchange adds only its most frequent words, at a lower weight,
/// so a message that changes the subject still finds its own topic first.
struct MemoryQuery: Equatable {
    struct Term: Equatable {
        let word: String
        let weight: Double
    }

    static let previousWeight = 0.5
    static let previousTermLimit = 12
    /// How much of the previous exchange is read: the user's message, and the end of the reply,
    /// where its answer is (status lines come earlier, before the tool calls).
    static let previousUserLimit = 1_200
    static let previousReplyLimit = 1_500

    /// The message's words, then up to `previousTermLimit` from the previous exchange.
    let terms: [Term]

    init(message: String, previous: ConversationTurn? = nil) {
        let current = ConversationContextBuilder.terms(from: Self.withoutInjectedContext(message))
        let seen = Set(current)
        let earlier = previous.map {
            Self.topicWords(user: $0.user, reply: $0.assistant).map(\.word).filter { !seen.contains($0) }
        } ?? []
        terms = current.map { Term(word: $0, weight: 1) }
            + earlier.prefix(Self.previousTermLimit).map { Term(word: $0, weight: Self.previousWeight) }
    }

    var words: [String] { terms.map(\.word) }

    // MARK: - Previous exchange

    /// The previous exchange's most frequent words (the user's count double), first-seen order
    /// on ties. Stopwords and the narration verbs replies use between tool calls are left out.
    static func topicWords(user: String, reply: String) -> [(word: String, count: Double)] {
        let asked = withoutInjectedContext(String(user.prefix(previousUserLimit)))
        let answered = String(conversationText(reply).suffix(previousReplyLimit))
        var counts: [String: Double] = [:]
        var order: [String: Int] = [:]
        for (text, weight) in [(asked, 2.0), (answered, 1.0)] {
            for word in ConversationContextBuilder.words(in: text)
            where !narration.contains(word) && !word.allSatisfy(\.isNumber) {
                counts[word, default: 0] += weight
                if order[word] == nil { order[word] = order.count }
            }
        }
        return counts.keys.sorted {
            counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : order[$0]! < order[$1]!
        }.map { ($0, counts[$0]!) }
    }

    private static let narration: Set<String> = [
        "checking", "reading", "running", "looking", "writing", "adding", "making", "starting",
        "trying", "using", "building", "updating", "now", "next", "first", "also", "here", "there",
        "which", "these", "those", "they", "their", "been", "being", "doing", "done", "yes", "sure",
        "okay", "want", "need", "one", "two", "new", "way", "thing", "things", "something", "really",
        "very", "much", "more", "most", "still", "only", "even", "each", "every", "after", "before",
        "again", "back", "over", "since", "while", "because", "found", "let", "don", "isn", "won",
    ]

    // MARK: - Cleaning

    /// A reply as conversation: without fenced blocks (cards, Home blocks, code, logs), links,
    /// file paths, or anything Cantrip injected.
    static func conversationText(_ text: String) -> String {
        var kept: [Substring] = []
        var fence: Substring?
        for line in withoutInjectedContext(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix(3)
                continue
            }
            kept.append(line)
        }
        let joined = kept.joined(separator: "\n")
        let range = NSRange(joined.startIndex..., in: joined)
        return linksAndPaths.stringByReplacingMatches(in: joined, range: range, withTemplate: " ")
    }

    private static let linksAndPaths = try! NSRegularExpression(
        pattern: #"\]\([^)\s]*\)|https?://\S+|(?<![\w.])[~/][\w.~@+-]*/\S*"#
    )

    /// Text without the blocks Cantrip adds around a message: the memory protocol and its
    /// RETRIEVED snippets, the earlier-turns digest, and a paired device's location note.
    static func withoutInjectedContext(_ text: String) -> String {
        var text = text
        for marker in ["(Persistent memory — ", "(Memory from previous sessions:", "RETRIEVED — memory snippets",
                       "(RETRIEVED — memory snippets"] {
            if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
        }
        if text.hasPrefix("Context - selected earlier turns only"),
           let range = text.range(of: "\nNew message:\n") {
            text = String(text[range.upperBound...])
        }
        let paragraphs = text.components(separatedBy: "\n\n").filter {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !(trimmed.hasPrefix("(Context: this message comes from") && trimmed.hasSuffix(")"))
        }
        return paragraphs.joined(separator: "\n\n")
    }
}
