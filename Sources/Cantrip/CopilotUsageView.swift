import SwiftUI

struct CopilotUsageView: View {
    @ObservedObject var usage: UsageTracker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Copilot allowance", systemImage: "chart.bar.xaxis").font(.headline)
                    Spacer()
                    Button { usage.refreshQuotas() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(usage.copilotUsage.isRefreshing)
                        .help("Refresh account allowance (at most once a minute)")
                    if usage.copilotUsage.isRefreshing { ProgressView().controlSize(.small) }
                }
                if let error = usage.copilotUsage.error {
                    Text(error).foregroundStyle(.orange)
                }
                if let account = usage.copilotUsage.account {
                    if usage.copilotUsage.isStale(at: context.date) {
                        Label("Last known allowance - data is stale", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let login = account.login { Text("Mac account: \(login)").foregroundStyle(.secondary) }
                    if let plan = account.plan { Text("Plan: \(plan)").foregroundStyle(.secondary) }
                    ForEach(account.buckets) { bucket in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bucket.title).fontWeight(.medium)
                            Text(bucket.summary)
                            if !bucket.isUnlimited, let remaining = bucket.remainingPercent,
                               let percentage = bucket.percentageSummary {
                                ProgressView(value: 100 - remaining, total: 100)
                                    .accessibilityLabel("Included allowance used")
                                    .accessibilityValue(String(format: "%.1f%%", 100 - remaining))
                                Text(percentage)
                                    .foregroundStyle(.secondary)
                            }
                            Text(bucket.billingMode == "credits"
                                 ? "Token / AI-credit billing; these are not prompt counts."
                                 : bucket.billingMode == "requests" ? "Request-based billing" : "Billing units not reported")
                                .foregroundStyle(.secondary)
                            Text(bucket.overageAllowed.map { "Additional usage: \($0 ? "enabled" : "disabled")" }
                                 ?? "Additional usage: not reported")
                            if let overage = bucket.overage {
                                Text(overage == 0 ? "No additional usage reported consumed"
                                     : "Additional usage consumed: \(overage.formatted()) \(bucket.billingMode == "requests" ? "requests" : "billing units")")
                            }
                            if let reset = copilotDate(bucket.resetAt) {
                                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened)) (local time)")
                            } else {
                                Text("Reset date unavailable").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let checked = copilotDate(usage.copilotUsage.checkedAt) {
                        Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                } else if usage.copilotUsage.error == nil {
                    Text(usage.copilotUsage.isRefreshing ? "Reading Copilot account allowance..." : "Account allowance unavailable")
                }
                Text("Account-wide allowance, not this conversation's usage. Model-specific and short-term rate limits may still apply.")
                    .foregroundStyle(.secondary)
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
                Label("Claude Code limits", systemImage: "gauge.with.dots.needle.67percent").font(.headline)
                if let state = usage.copilotUsage.claude, let account = state.account {
                    if state.isStale(at: context.date) {
                        Label("Last known limits - data is stale", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let plan = account.plan { Text("Plan: \(plan.capitalized)").foregroundStyle(.secondary) }
                    ForEach(account.windows) { window in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(window.title).fontWeight(.medium)
                                Spacer()
                                Text(window.summary).foregroundStyle(tint(window))
                            }
                            ProgressView(value: min(100, max(0, window.percentUsed)), total: 100)
                                .tint(tint(window))
                                .accessibilityLabel(window.title)
                                .accessibilityValue(String(format: "%.0f%% used", window.percentUsed))
                        }
                    }
                    if let error = state.error { Text(error).foregroundStyle(.orange) }
                    if let checked = copilotDate(state.checkedAt) {
                        Text("Checked \(checked.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    }
                } else if let limit = usage.rateLimit {
                    Text("From the last Claude reply: \(limit.type.replacingOccurrences(of: "_", with: " ")) window \(limit.status)"
                         + (limit.percentUsed.map { String(format: ", %.0f%% used", $0) } ?? "")
                         + " · resets \(limit.resetsAt.formatted(date: .omitted, time: .shortened))")
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

    private func tint(_ window: ClaudeLimitWindow) -> Color {
        if window.isExhausted || window.severity == "critical" { return .red }
        if window.severity == "warning" || window.percentUsed >= 80 { return .orange }
        return .primary
    }
}

/// Antigravity's weekly and 5-hour limits per model group, from `agy -p /usage` (no quota spent).
struct AntigravityUsageView: View {
    @ObservedObject var usage: UsageTracker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 6) {
                Label("Antigravity limits", systemImage: "gauge.with.dots.needle.33percent").font(.headline)
                if let state = usage.copilotUsage.antigravity, let account = state.account {
                    if state.isStale(at: context.date) {
                        Label("Last known limits - data is stale", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    ForEach(account.groups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.name).fontWeight(.semibold)
                            ForEach(group.buckets) { bucket in
                                HStack {
                                    Text(bucket.title).fontWeight(.medium)
                                    Spacer()
                                    Text(bucket.summary).foregroundStyle(tint(bucket))
                                }
                                ProgressView(value: bucket.percentUsed, total: 100)
                                    .tint(tint(bucket))
                                    .accessibilityLabel("\(group.name), \(bucket.title)")
                                    .accessibilityValue(String(format: "%.0f%% used", bucket.percentUsed))
                            }
                        }
                    }
                    if let error = state.error { Text(error).foregroundStyle(.orange) }
                    if let checked = copilotDate(state.checkedAt) {
                        Text("Checked \(checked.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    }
                } else {
                    Text(usage.copilotUsage.antigravity?.error
                         ?? (usage.copilotUsage.isRefreshing ? "Reading Antigravity's limits..." : "Antigravity's limits unavailable"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    private func tint(_ bucket: AntigravityLimitBucket) -> Color {
        if bucket.isExhausted { return .red }
        if bucket.percentUsed >= 80 { return .orange }
        return .primary
    }
}
