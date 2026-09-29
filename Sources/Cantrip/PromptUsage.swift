import Foundation

/// How much a prompt put in the model's context, and what its run used.
/// Shown as a line under the prompt; the same fields go to Remote clients.
struct PromptUsage: Codable, Equatable {
    /// Tokens in the root agent's context when the prompt was sent.
    var contextTokens: Int?
    var contextLimit: Int?
    /// Breakdown of `contextTokens`, when the backend reports it (Copilot).
    var systemTokens: Int?
    var toolTokens: Int?
    var conversationTokens: Int?
    /// Estimated tokens of the message as sent, and the part Cantrip added (memory, context, earlier turns).
    var messageTokens: Int?
    var addedTokens: Int?
    /// Context at the run's latest root model call.
    var latestContextTokens: Int?
    /// Every model call the run made, subagents included.
    var modelCalls = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0

    var isEmpty: Bool { contextTokens == nil && messageTokens == nil && modelCalls == 0 }

    /// Tokenizers vary; about four characters per token for English text and code.
    static func estimatedTokens(characters: Int) -> Int { (max(0, characters) + 3) / 4 }

    mutating func apply(_ context: BackendContextUsage, typedCharacters: Int) {
        if let tokens = context.tokens {
            if contextTokens == nil {
                contextTokens = tokens
                systemTokens = context.systemTokens
                toolTokens = context.toolTokens
                conversationTokens = context.conversationTokens
            }
            latestContextTokens = tokens
        }
        if contextLimit == nil { contextLimit = context.limit }
        // Only the prompt itself: messages sent into the running turn come later.
        if let characters = context.messageCharacters, messageTokens == nil {
            let sent = Self.estimatedTokens(characters: characters)
            messageTokens = sent
            addedTokens = max(0, sent - Self.estimatedTokens(characters: typedCharacters))
        }
    }

    mutating func apply(_ usage: BackendUsage) {
        modelCalls += usage.modelCalls
        inputTokens += usage.inputTokens
        cachedInputTokens += usage.cachedInputTokens
        outputTokens += usage.outputTokens
    }

    // MARK: - Presentation

    /// "38.2k tokens of context · 19% of 200k"
    var summary: String {
        if let contextTokens {
            var text = "\(Self.compact(contextTokens)) tokens of context"
            if let contextLimit, contextLimit > 0 {
                text += " · \(Self.percent(contextTokens, of: contextLimit)) of \(Self.compact(contextLimit))"
            }
            return text
        }
        if let messageTokens { return "About \(Self.compact(messageTokens)) tokens sent" }
        return "\(Self.compact(inputTokens)) input tokens"
    }

    var accessibilitySummary: String {
        if let contextTokens {
            var text = "\(contextTokens.formatted()) tokens of context"
            if let contextLimit, contextLimit > 0 {
                text += ", \(Self.percent(contextTokens, of: contextLimit)) of \(contextLimit.formatted())"
            }
            return text
        }
        if let messageTokens { return "About \(messageTokens.formatted()) tokens sent" }
        return "\(inputTokens.formatted()) input tokens"
    }

    struct Row: Equatable {
        let label: String
        let value: String
    }

    /// Details: what was in context when sent, then what the run used.
    var sections: [(title: String, rows: [Row])] {
        var sent: [Row] = []
        if let contextTokens {
            sent.append(Row(label: "Total", value: Self.full(contextTokens)
                + (contextLimit.map { $0 > 0 ? " of \(Self.full($0))" : "" } ?? "")))
        }
        if let systemTokens { sent.append(Row(label: "System instructions", value: Self.full(systemTokens))) }
        if let toolTokens { sent.append(Row(label: "Tool definitions", value: Self.full(toolTokens))) }
        if let conversationTokens { sent.append(Row(label: "Conversation", value: Self.full(conversationTokens))) }
        if let messageTokens {
            sent.append(Row(label: "This message", value: "≈ " + Self.full(messageTokens)))
            if let addedTokens, addedTokens > 0 {
                sent.append(Row(label: "Added by Cantrip", value: "≈ " + Self.full(addedTokens)))
            }
        }
        var run: [Row] = []
        if modelCalls > 0 {
            run.append(Row(label: "Model calls", value: modelCalls.formatted()))
            var input = Self.full(inputTokens)
            if inputTokens > 0, cachedInputTokens > 0 {
                input += " (\(Self.percent(cachedInputTokens, of: inputTokens)) cached)"
            }
            run.append(Row(label: "Input tokens", value: input))
            run.append(Row(label: "Output tokens", value: Self.full(outputTokens)))
        }
        if let latestContextTokens, latestContextTokens != contextTokens {
            run.append(Row(label: "Latest context", value: Self.full(latestContextTokens)))
        }
        return [("When sent", sent), ("This run", run)].filter { !$0.rows.isEmpty }
    }

    static let footnote = "Token counts come from the model provider. “This message” includes memory and context Cantrip added, estimated at about 4 characters per token. Run totals include subagents and every step’s model call."

    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000:
            let thousands = Double(value) / 1_000
            return thousands < 100 ? String(format: "%.1fk", thousands) : "\(Int(thousands.rounded()))k"
        default: return String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    static func full(_ value: Int) -> String { value.formatted() }

    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        let value = Double(part) / Double(whole) * 100
        return value > 0 && value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }

    /// Remote contract (web UI and Cantrip Agent); absent keys are unknown.
    var snapshot: [String: Any] {
        var result: [String: Any] = [
            "modelCalls": modelCalls, "inputTokens": inputTokens,
            "cachedInputTokens": cachedInputTokens, "outputTokens": outputTokens,
        ]
        result["contextTokens"] = contextTokens
        result["contextLimit"] = contextLimit
        result["systemTokens"] = systemTokens
        result["toolTokens"] = toolTokens
        result["conversationTokens"] = conversationTokens
        result["messageTokens"] = messageTokens
        result["addedTokens"] = addedTokens
        result["latestContextTokens"] = latestContextTokens
        return result
    }
}
