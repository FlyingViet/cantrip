import SwiftUI

/// A prompt's context size and its run's token use, from the Mac host
/// (`messages[].promptUsage`). Absent fields are unknown.
struct CantripPromptUsage: Decodable, Equatable {
    var contextTokens: Int?
    var contextLimit: Int?
    var systemTokens: Int?
    var toolTokens: Int?
    var conversationTokens: Int?
    var messageTokens: Int?
    var addedTokens: Int?
    var latestContextTokens: Int?
    var modelCalls = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
        contextLimit = try container.decodeIfPresent(Int.self, forKey: .contextLimit)
        systemTokens = try container.decodeIfPresent(Int.self, forKey: .systemTokens)
        toolTokens = try container.decodeIfPresent(Int.self, forKey: .toolTokens)
        conversationTokens = try container.decodeIfPresent(Int.self, forKey: .conversationTokens)
        messageTokens = try container.decodeIfPresent(Int.self, forKey: .messageTokens)
        addedTokens = try container.decodeIfPresent(Int.self, forKey: .addedTokens)
        latestContextTokens = try container.decodeIfPresent(Int.self, forKey: .latestContextTokens)
        modelCalls = try container.decodeIfPresent(Int.self, forKey: .modelCalls) ?? 0
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case contextTokens, contextLimit, systemTokens, toolTokens, conversationTokens, messageTokens,
             addedTokens, latestContextTokens, modelCalls, inputTokens, cachedInputTokens, outputTokens
    }

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

    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    struct Section: Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    /// Same grouping as the Mac: what was in context when sent, then what the run used.
    var sections: [Section] {
        var sent: [Row] = []
        if let contextTokens {
            let limit = contextLimit.map { $0 > 0 ? " of \($0.formatted())" : "" } ?? ""
            sent.append(Row(label: "Total", value: contextTokens.formatted() + limit))
        }
        if let systemTokens { sent.append(Row(label: "System instructions", value: systemTokens.formatted())) }
        if let toolTokens { sent.append(Row(label: "Tool definitions", value: toolTokens.formatted())) }
        if let conversationTokens { sent.append(Row(label: "Conversation", value: conversationTokens.formatted())) }
        if let messageTokens {
            sent.append(Row(label: "This message", value: "≈ " + messageTokens.formatted()))
            if let addedTokens, addedTokens > 0 {
                sent.append(Row(label: "Added by Cantrip", value: "≈ " + addedTokens.formatted()))
            }
        }
        var run: [Row] = []
        if modelCalls > 0 {
            run.append(Row(label: "Model calls", value: modelCalls.formatted()))
            var input = inputTokens.formatted()
            if inputTokens > 0, cachedInputTokens > 0 {
                input += " (\(Self.percent(cachedInputTokens, of: inputTokens)) cached)"
            }
            run.append(Row(label: "Input tokens", value: input))
            run.append(Row(label: "Output tokens", value: outputTokens.formatted()))
        }
        if let latestContextTokens, latestContextTokens != contextTokens {
            run.append(Row(label: "Latest context", value: latestContextTokens.formatted()))
        }
        return [Section(title: "When sent", rows: sent), Section(title: "This run", rows: run)]
            .filter { !$0.rows.isEmpty }
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

    static func percent(_ part: Int, of whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        let value = Double(part) / Double(whole) * 100
        return value > 0 && value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }
}

/// The small line under a sent prompt; tap for the token breakdown.
struct CantripPromptUsageLine: View {
    let usage: CantripPromptUsage
    @State private var showingDetails = false

    var body: some View {
        Button { showingDetails = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .imageScale(.small)
                Text(usage.summary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.caption2)
            .foregroundStyle(CantripReasoningFormat.secondaryText)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Prompt context")
        .accessibilityValue(usage.accessibilitySummary)
        .accessibilityHint("Shows the token breakdown")
        .accessibilityIdentifier("cantrip.promptUsage")
        .popover(isPresented: $showingDetails, arrowEdge: .top) {
            CantripPromptUsageDetails(usage: usage)
                .padding(16)
                .frame(idealWidth: 320, maxWidth: 360)
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct CantripPromptUsageDetails: View {
    let usage: CantripPromptUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(usage.sections) { section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CantripReasoningFormat.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.rows) { row in
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(row.label).fixedSize()
                                Spacer(minLength: 8)
                                Text(row.value).monospacedDigit().fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.label)
                                Text(row.value).monospacedDigit().foregroundStyle(CantripReasoningFormat.secondaryText)
                            }
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Text(CantripPromptUsage.footnote)
                .font(.caption2)
                .foregroundStyle(CantripReasoningFormat.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
