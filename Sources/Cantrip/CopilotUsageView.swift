import SwiftUI

/// One limit: how much is used and when it resets. Nothing else.
struct UsageLimitRow: View {
    let title: String
    /// Nil for an unlimited allowance (no bar, no reset).
    let percentUsed: Double?
    let resetsAt: Date?
    var critical = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text(percentUsed.map { String(format: "%.0f%% used", min(100, max(0, $0))) } ?? "Unlimited")
                    .monospacedDigit().foregroundStyle(tint)
            }
            if let percentUsed {
                // Drawn rather than ProgressView: macOS ignores a ProgressView's tint.
                Capsule().fill(Color.secondary.opacity(0.25))
                    .frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().fill(tint)
                                .frame(width: max(percentUsed > 0 ? 6 : 0,
                                                  proxy.size.width * min(100, max(0, percentUsed)) / 100))
                        }
                    }
                    .accessibilityHidden(true)
            }
            if let resetsAt {
                Text("Resets \(resetsAt.formatted(Self.resetStyle(resetsAt)))").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        guard let percentUsed else { return .secondary }
        if critical || percentUsed >= 100 { return .red }
        return percentUsed >= 80 ? .orange : .primary
    }

    static func resetStyle(_ date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date) ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
    }
}

struct CopilotUsageView: View {
    @ObservedObject var usage: UsageTracker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Copilot", systemImage: "chart.bar.xaxis").font(.headline)
                    Spacer()
                    Button { usage.refreshQuotas() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(usage.copilotUsage.isRefreshing)
                        .help("Refresh usage limits (at most once a minute)")
                    if usage.copilotUsage.isRefreshing { ProgressView().controlSize(.small) }
                }
                if let error = usage.copilotUsage.error {
                    Text(error).foregroundStyle(.orange)
                }
                if let account = usage.copilotUsage.account {
                    if usage.copilotUsage.isStale(at: context.date) {
                        Label("Last known limits - data is stale", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    ForEach(account.buckets) { bucket in
                        UsageLimitRow(title: bucket.title,
                                      percentUsed: bucket.isUnlimited ? nil : bucket.remainingPercent.map { 100 - $0 } ?? 0,
                                      resetsAt: bucket.isUnlimited ? nil : copilotDate(bucket.resetAt))
                    }
                } else if usage.copilotUsage.error == nil {
                    Text(usage.copilotUsage.isRefreshing ? "Reading Copilot's limits..." : "Copilot's limits unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .task {
            while !Task.isCancelled {
                usage.refreshQuotas()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}

/// Claude Code's 5-hour and weekly limits, read from Claude's usage API (the same numbers as
/// Claude Code's `/usage`), with the last streamed rate-limit event as a fallback.
struct ClaudeUsageView: View {
    @ObservedObject var usage: UsageTracker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 6) {
                Label("Claude Code", systemImage: "gauge.with.dots.needle.67percent").font(.headline)
                if let state = usage.copilotUsage.claude, let account = state.account {
                    if state.isStale(at: context.date) {
                        Label("Last known limits - data is stale", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    ForEach(account.windows) { window in
                        UsageLimitRow(title: window.title, percentUsed: window.percentUsed,
                                      resetsAt: copilotDate(window.resetsAt),
                                      critical: window.isExhausted || window.severity == "critical")
                    }
                    if let error = state.error { Text(error).foregroundStyle(.orange) }
                } else if let limit = usage.rateLimit {
                    UsageLimitRow(title: limit.type == "five_hour" ? "5-hour session"
                                    : limit.type.replacingOccurrences(of: "_", with: " ").capitalized,
                                  percentUsed: limit.percentUsed, resetsAt: limit.resetsAt,
                                  critical: limit.status == "rejected")
                    if let error = usage.copilotUsage.claude?.error { Text(error).foregroundStyle(.orange) }
                } else {
                    Text(usage.copilotUsage.claude?.error
                         ?? (usage.copilotUsage.isRefreshing ? "Reading Claude's limits..." : "Claude's limits unavailable"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }
}

/// Antigravity's weekly and 5-hour limits per model group, from `agy -p /usage` (no quota spent).
struct AntigravityUsageView: View {
    @ObservedObject var usage: UsageTracker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 6) {
                Label("Antigravity", systemImage: "gauge.with.dots.needle.33percent").font(.headline)
                if let state = usage.copilotUsage.antigravity, let account = state.account {
                    if state.isStale(at: context.date) {
                        Label("Last known limits - data is stale", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    ForEach(account.groups) { group in
                        Text(group.name).fontWeight(.semibold).padding(.top, 2)
                        ForEach(group.buckets) { bucket in
                            UsageLimitRow(title: bucket.title, percentUsed: bucket.percentUsed,
                                          resetsAt: copilotDate(bucket.resetsAt), critical: bucket.isExhausted)
                        }
                    }
                    if let error = state.error { Text(error).foregroundStyle(.orange) }
                } else {
                    Text(usage.copilotUsage.antigravity?.error
                         ?? (usage.copilotUsage.isRefreshing ? "Reading Antigravity's limits..." : "Antigravity's limits unavailable"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }
}
