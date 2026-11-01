import SwiftUI

/// Runs and spend per model tier, today and over the last 7 days: the `tiers` section of
/// `/api/v1/copilot/usage` and the Mac's usage screen.
struct TierUsageSnapshot: Codable, Equatable {
    struct Totals: Codable, Equatable {
        var runs = 0
        var inputTokens = 0
        var outputTokens = 0
        /// Claude Code's reported cost; other backends report tokens only.
        var costUSD = 0.0

        init(_ summary: UsageTracker.Summary?) {
            runs = summary?.queries ?? 0
            inputTokens = summary?.inputTokens ?? 0
            outputTokens = summary?.outputTokens ?? 0
            costUSD = summary?.costUSD ?? 0
        }

        /// "12 runs · 1.2M tokens · $0.31"
        var detail: String {
            var parts = ["\(runs) run\(runs == 1 ? "" : "s")"]
            let tokens = inputTokens + outputTokens
            if tokens > 0 { parts.append("\(PromptUsage.compact(tokens)) tokens") }
            if costUSD > 0 { parts.append(costUSD < 0.1 ? String(format: "$%.3f", costUSD) : String(format: "$%.2f", costUSD)) }
            return parts.joined(separator: " · ")
        }
    }

    struct Row: Codable, Equatable, Identifiable {
        /// "fast", "standard", "deep", or "model" for runs on a model picked by name.
        let tier: String
        let label: String
        let today: Totals
        let week: Totals
        var id: String { tier }
    }

    /// Fast, Standard, Deep, then exact models; rows without runs this week are left out.
    let rows: [Row]

    static func current(_ usage: UsageTracker = .shared) -> TierUsageSnapshot {
        let today = usage.tierSummary(days: 1), week = usage.tierSummary(days: 7)
        let keys = ModelTier.allCases.map { ($0.rawValue, $0.label) } + [(UsageTracker.exactModelKey, "Exact model")]
        return TierUsageSnapshot(rows: keys.compactMap { key, label in
            guard (week[key]?.queries ?? 0) > 0 else { return nil }
            return Row(tier: key, label: label, today: Totals(today[key]), week: Totals(week[key]))
        })
    }
}

/// The usage screen's breakdown by model tier.
struct TierUsageView: View {
    @ObservedObject var usage: UsageTracker

    var body: some View {
        let _ = usage.revision
        let snapshot = TierUsageSnapshot.current(usage)
        if !snapshot.rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("By model tier", systemImage: "square.stack.3d.up").font(.headline)
                ForEach(snapshot.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).fontWeight(.medium)
                        Spacer()
                        Text("\(row.today.runs) today · \(row.week.detail) this week").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.caption)
        }
    }
}
