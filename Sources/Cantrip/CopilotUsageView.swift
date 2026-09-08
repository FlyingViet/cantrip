import SwiftUI

struct CopilotUsageView: View {
    @ObservedObject var usage: UsageTracker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Copilot account usage", systemImage: "chart.bar.xaxis").font(.headline)
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
