import Foundation
import NaturalLanguage

struct ConversationTurn: Equatable {
    let user: String
    let assistant: String
}

struct ConversationContextMessage: Equatable {
    let role: String
    let content: String
}

struct ConversationContextSelection: Equatable {
    let summary: String?
    let relatedTurns: [ConversationTurn]
    let recentTurns: [ConversationTurn]
    let fullHistoryTurns: [ConversationTurn]?
}

/// Builds a small, relevant conversation window without sending the full
/// transcript on every stateless-backend request.
enum ConversationContextBuilder {
    static let recentTurnCount = 3
    static let relatedTurnCount = 2

    private static let userSnippetLimit = 600
    private static let assistantSnippetLimit = 1_000
    private static let summaryLimit = 700
    private static let fullHistoryLimit = 80_000
    private static let semanticThreshold = 0.28
    private static let sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    private static let embeddingLock = NSLock()
    private static let stopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "what", "when", "where",
        "how", "can", "you", "your", "not", "are", "was", "were", "have",
        "has", "had", "from", "about", "into", "did", "does", "its", "get",
        "make", "just", "like", "them", "then", "than", "will", "would",
        "should", "could", "our", "out", "all", "any", "some", "please",
    ]

    private struct RankedTurn {
        let index: Int
        let score: Double
        let turn: ConversationTurn
    }

    static func terms(from query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
    }

    static func select(
        for query: String,
        from turns: [ConversationTurn]
    ) -> ConversationContextSelection {
        guard !turns.isEmpty else {
            return ConversationContextSelection(
                summary: nil,
                relatedTurns: [],
                recentTurns: [],
                fullHistoryTurns: nil
            )
        }

        if explicitlyRequestsFullHistory(query) {
            return ConversationContextSelection(
                summary: nil,
                relatedTurns: [],
                recentTurns: [],
                fullHistoryTurns: boundedFullHistory(turns)
            )
        }

        let recentCount = min(recentTurnCount, turns.count)
        let olderTurns = Array(turns.dropLast(recentCount))
        let recentTurns = Array(turns.suffix(recentCount))
        let queryTerms = Set(terms(from: query))
        let queryVector = sentenceVector(for: query, maxChars: 1_000)

        var ranked: [RankedTurn] = []
        for (index, turn) in olderTurns.enumerated() {
            let candidate = turn.user + "\n" + String(turn.assistant.prefix(1_200))
            let candidateTerms = Set(terms(from: candidate))
            let overlap = queryTerms.intersection(candidateTerms).count
            let lexical = queryTerms.isEmpty
                ? 0
                : Double(overlap) / Double(queryTerms.count)
            let semantic = semanticSimilarity(queryVector, candidate) ?? 0
            if overlap > 0 || semantic >= semanticThreshold {
                ranked.append(RankedTurn(
                    index: index,
                    score: lexical * 2 + semantic,
                    turn: turn
                ))
            }
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.index > $1.index
        }
        let relatedTurns = ranked.prefix(relatedTurnCount)
            .sorted { $0.index < $1.index }
            .map { $0.turn }

        return ConversationContextSelection(
            summary: compactSummary(of: olderTurns),
            relatedTurns: relatedTurns,
            recentTurns: recentTurns,
            fullHistoryTurns: nil
        )
    }

    static func composePrompt(
        currentPrompt: String,
        query: String,
        turns: [ConversationTurn]
    ) -> String {
        let selection = select(for: query, from: turns)
        if let fullHistory = selection.fullHistoryTurns {
            var lines = [
                "Context - full conversation history (explicitly requested; very long turns may be clipped):"
            ]
            for turn in fullHistory {
                lines.append(format(turn, userLimit: turn.user.count,
                                    assistantLimit: turn.assistant.count))
            }
            lines.append("")
            lines.append("New message: \(currentPrompt)")
            return lines.joined(separator: "\n")
        }

        guard selection.summary != nil
                || !selection.relatedTurns.isEmpty
                || !selection.recentTurns.isEmpty else {
            return currentPrompt
        }

        var sections = ["Context - selected earlier turns only (not the full transcript):"]
        if let summary = selection.summary {
            sections.append("Compact summary:\n\(summary)")
        }
        if !selection.relatedTurns.isEmpty {
            sections.append("Related older turns:\n" + selection.relatedTurns.map {
                format($0)
            }.joined(separator: "\n"))
        }
        if !selection.recentTurns.isEmpty {
            sections.append("Most recent turns:\n" + selection.recentTurns.map {
                format($0)
            }.joined(separator: "\n"))
        }
        sections.append("New message:\n\(currentPrompt)")
        return sections.joined(separator: "\n\n")
    }

    static func chatMessages(
        for query: String,
        turns: [ConversationTurn]
    ) -> [ConversationContextMessage] {
        let selection = select(for: query, from: turns)
        if let fullHistory = selection.fullHistoryTurns {
            var messages = [ConversationContextMessage(
                role: "system",
                content: "The user explicitly requested the full conversation history. Very long turns may be clipped."
            )]
            messages += messagesForTurns(fullHistory, clipped: false)
            return messages
        }

        var messages: [ConversationContextMessage] = []
        if let summary = selection.summary {
            messages.append(ConversationContextMessage(
                role: "system",
                content: "Compact summary of other earlier topics:\n\(summary)"
            ))
        }
        if !selection.relatedTurns.isEmpty {
            messages.append(ConversationContextMessage(
                role: "system",
                content: "The following are selected related older turns, not a complete transcript."
            ))
            messages += messagesForTurns(selection.relatedTurns, clipped: true)
        }
        if !selection.recentTurns.isEmpty {
            messages.append(ConversationContextMessage(
                role: "system",
                content: "The following are the most recent conversation turns."
            ))
            messages += messagesForTurns(selection.recentTurns, clipped: true)
        }
        return messages
    }

    static func explicitlyRequestsFullHistory(_ query: String) -> Bool {
        let normalized = query.lowercased()
        return [
            "full conversation", "entire conversation", "whole conversation",
            "full transcript", "entire transcript", "whole transcript",
            "everything we discussed", "everything we've discussed",
            "all previous messages", "all prior messages", "whole chat",
        ].contains { normalized.contains($0) }
    }

    private static func messagesForTurns(
        _ turns: [ConversationTurn],
        clipped: Bool
    ) -> [ConversationContextMessage] {
        turns.flatMap { turn in
            let user = clipped ? clip(turn.user, to: userSnippetLimit) : turn.user
            let assistant = clipped
                ? clip(turn.assistant, to: assistantSnippetLimit)
                : turn.assistant
            return [
                ConversationContextMessage(role: "user", content: user),
                ConversationContextMessage(role: "assistant", content: assistant),
            ]
        }
    }

    private static func format(
        _ turn: ConversationTurn,
        userLimit: Int = userSnippetLimit,
        assistantLimit: Int = assistantSnippetLimit
    ) -> String {
        "User: \(clip(turn.user, to: userLimit))\n" +
            "Assistant: \(clip(turn.assistant, to: assistantLimit))"
    }

    private static func compactSummary(of turns: [ConversationTurn]) -> String? {
        let entries = turns.suffix(4).compactMap { turn -> String? in
            let user = oneLine(turn.user, limit: 80)
            guard !user.isEmpty else { return nil }
            let assistant = oneLine(turn.assistant, limit: 90)
            return assistant.isEmpty ? user : "\(user) -> \(assistant)"
        }
        guard !entries.isEmpty else { return nil }
        return clip(entries.joined(separator: " | "), to: summaryLimit)
    }

    private static func semanticSimilarity(
        _ queryVector: [Double]?,
        _ candidate: String
    ) -> Double? {
        guard let queryVector, candidate.count >= 8,
              let candidateVector = sentenceVector(
                for: candidate,
                maxChars: 2_000
              ),
              queryVector.count == candidateVector.count else { return nil }
        let dot = zip(queryVector, candidateVector).reduce(0) {
            $0 + $1.0 * $1.1
        }
        let queryMagnitude = sqrt(queryVector.reduce(0) { $0 + $1 * $1 })
        let candidateMagnitude = sqrt(candidateVector.reduce(0) { $0 + $1 * $1 })
        guard queryMagnitude > 0, candidateMagnitude > 0 else { return nil }
        return dot / (queryMagnitude * candidateMagnitude)
    }

    private static func sentenceVector(
        for text: String,
        maxChars: Int
    ) -> [Double]? {
        guard text.count >= 8, let embedding = sentenceEmbedding else { return nil }
        return embeddingLock.withLock {
            embedding.vector(for: String(text.prefix(maxChars)))
        }
    }

    private static func boundedFullHistory(
        _ turns: [ConversationTurn]
    ) -> [ConversationTurn] {
        let total = turns.reduce(0) { $0 + $1.user.count + $1.assistant.count }
        guard total > fullHistoryLimit else { return turns }

        let perTurn = max(400, fullHistoryLimit / turns.count)
        let userLimit = max(160, perTurn / 3)
        let assistantLimit = max(240, perTurn - userLimit)
        return turns.map {
            ConversationTurn(
                user: clip($0.user, to: userLimit),
                assistant: clip($0.assistant, to: assistantLimit)
            )
        }
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return clip(normalized, to: limit)
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 12 else { return String(text.prefix(limit)) }
        return String(text.prefix(limit - 12)) + " ...[clipped]"
    }
}
