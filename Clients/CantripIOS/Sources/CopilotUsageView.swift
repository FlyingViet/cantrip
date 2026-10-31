import SwiftUI

/// `GET /api/v1/copilot/usage`: Copilot's allowance at the top level, Claude Code's limits under
/// `claude` (Macs with Cantrip 1.1.4+), Antigravity's under `antigravity`, and the Mac's active backend.
struct CopilotUsageSnapshot: Decodable {
    let account: CopilotAccountUsage?
    let checkedAt: String?
    let isRefreshing: Bool
    let error: String?
    var claude: ClaudeUsageState? = nil
    var antigravity: AntigravityUsageState? = nil
    var activeBackend: String? = nil

    /// The Mac runs Claude Code and has its limits: lead with them.
    var leadsWithClaude: Bool { activeBackend == "Claude Code" && claude?.account != nil }
    /// The Mac runs Antigravity and has its limits: lead with them.
    var leadsWithAntigravity: Bool { activeBackend == "Antigravity" && antigravity?.account != nil }

    func isStale(at now: Date = Date()) -> Bool {
        guard account != nil, error == nil, let checked = copilotDate(checkedAt),
              now.timeIntervalSince(checked) < 300 else { return true }
        return account?.buckets.contains {
            if let observed = copilotDate($0.observedAt), now.timeIntervalSince(observed) > 600 { return true }
            if let reset = copilotDate($0.resetAt), now >= reset { return true }
            return false
        } ?? true
    }
}

struct ClaudeUsageState: Decodable, Equatable {
    let account: ClaudeAccountUsage?
    let checkedAt: String?
    let error: String?

    /// Older than ten minutes, or a window has reset since it was read.
    func isStale(at now: Date = Date()) -> Bool {
        guard account != nil, let checked = copilotDate(checkedAt), now.timeIntervalSince(checked) < 600 else {
            return true
        }
        return account?.windows.contains { copilotDate($0.resetsAt).map { now >= $0 } ?? false } ?? true
    }
}

struct ClaudeAccountUsage: Decodable, Equatable {
    let plan: String?
    let windows: [ClaudeLimitWindow]
    var primary: ClaudeLimitWindow? { windows.max { $0.percentUsed < $1.percentUsed } }
}

struct ClaudeLimitWindow: Decodable, Equatable, Identifiable {
    let id: String
    let percentUsed: Double
    let resetsAt: String?
    let severity: String?
    let lockedReason: String?

    var title: String {
        switch id {
        case "five_hour": return "5-hour session"
        case "seven_day": return "Weekly limit"
        case "seven_day_opus": return "Weekly Opus limit"
        case "seven_day_sonnet": return "Weekly Sonnet limit"
        default: return "Claude limit"
        }
    }

    /// For the header button: "5h", "Week", "Opus" or "Sonnet".
    var shortTitle: String {
        switch id {
        case "five_hour": return "5h"
        case "seven_day": return "Week"
        case "seven_day_opus": return "Opus"
        case "seven_day_sonnet": return "Sonnet"
        default: return "Claude"
        }
    }

    var isExhausted: Bool { lockedReason != nil || percentUsed >= 100 }
    var percentText: String { String(format: "%.0f%%", min(100, max(0, percentUsed))) }
}

struct AntigravityUsageState: Decodable, Equatable {
    let account: AntigravityAccountUsage?
    let checkedAt: String?
    let error: String?

    /// Older than ten minutes, or a window has reset since it was read.
    func isStale(at now: Date = Date()) -> Bool {
        guard account != nil, let checked = copilotDate(checkedAt), now.timeIntervalSince(checked) < 600 else {
            return true
        }
        return account?.groups.contains { $0.buckets.contains { copilotDate($0.resetsAt).map { now >= $0 } ?? false } } ?? true
    }
}

/// Antigravity's limits per model group (Gemini, Claude and GPT, Gemini 4 Argon).
struct AntigravityAccountUsage: Decodable, Equatable {
    let groups: [AntigravityLimitGroup]

    /// The window closest to its limit.
    var primary: (group: AntigravityLimitGroup, bucket: AntigravityLimitBucket)? {
        groups.flatMap { group in group.buckets.map { (group: group, bucket: $0) } }
            .min { $0.bucket.remainingPercent < $1.bucket.remainingPercent }
    }
}

struct AntigravityLimitGroup: Decodable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let models: String?
    let buckets: [AntigravityLimitBucket]
}

struct AntigravityLimitBucket: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let window: String?
    let remainingPercent: Double
    let resetsAt: String?

    var percentUsed: Double { min(100, max(0, 100 - remainingPercent)) }
    var isExhausted: Bool { remainingPercent <= 0 }
    var percentText: String { String(format: "%.0f%%", percentUsed) }

    var title: String {
        switch window {
        case "weekly": return "Weekly limit"
        case "5h", "five_hour": return "5-hour limit"
        default: return name
        }
    }

    /// For the header button: "5h" or "Week".
    var shortTitle: String { window == "weekly" ? "Week" : window == "5h" ? "5h" : "Limit" }
}

struct CopilotAccountUsage: Decodable {
    let login: String?
    let plan: String?
    let buckets: [CopilotQuotaBucket]
    var primary: CopilotQuotaBucket? { buckets.first { $0.id == "premium_interactions" } ?? buckets.first }
}

struct CopilotQuotaBucket: Decodable, Identifiable {
    let id: String
    let billingMode: String
    let isUnlimited: Bool
    let remainingPercent: Double?
    let entitlement: Double?
    let remaining: Double?
    let overage: Double?
    let overageAllowed: Bool?
    let resetAt: String?
    let observedAt: String?

    var title: String {
        switch id {
        case "premium_interactions": return billingMode == "credits" ? "Included AI-credit budget" : "Premium allowance"
        case "chat": return "Chat allowance"
        case "completions": return "Completions allowance"
        default: return "Copilot allowance"
        }
    }

    var summary: String {
        if isUnlimited { return "Unlimited \(title.lowercased())" }
        if let amounts = amountSummary { return amounts }
        if billingMode == "credits" { return "AI-credit amounts unavailable" }
        return percentageSummary ?? "\(title): used amount unavailable"
    }

    var amountSummary: String? {
        guard let ratio = amountRatio(), let unit else { return nil }
        return "\(ratio) \(unit) used"
    }

    var unit: String? {
        switch billingMode {
        case "credits": return "AI credits"
        case "requests": return "requests"
        default: return nil
        }
    }

    func amountRatio(compact: Bool = false, locale: Locale = .current) -> String? {
        guard !isUnlimited, unit != nil, let remaining, let entitlement,
              remaining.isFinite, entitlement.isFinite, remaining >= 0, entitlement >= remaining,
              let totalAmount = Decimal(string: String(entitlement), locale: Locale(identifier: "en_US_POSIX")),
              let remainingAmount = Decimal(string: String(remaining), locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        // Subtract decimal amounts so binary rounding cannot lose a hundredth when formatting down.
        let used = NSDecimalNumber(decimal: totalAmount - remainingAmount).doubleValue
        return "\(copilotAmount(used, compact: compact, locale: locale)) / \(copilotAmount(entitlement, compact: compact, locale: locale))"
    }

    var percentageSummary: String? {
        guard let remainingPercent, remainingPercent.isFinite else { return nil }
        return String(format: "%.1f%% used / %.1f%% remaining", 100 - remainingPercent, remainingPercent)
    }
}

func copilotAmount(_ amount: Double, compact: Bool = false, locale: Locale = .current) -> String {
    let format = FloatingPointFormatStyle<Double>.number.locale(locale)
    // Keep compact values below the next unit and tiny nonzero amounts visible.
    if amount > 0 && amount < 0.01 {
        return "<" + 0.01.formatted(format.precision(.fractionLength(2)))
    }
    if compact && amount >= 1000 {
        return amount.formatted(format.notation(.compactName).precision(.fractionLength(0...1)).rounded(rule: .down))
    }
    return amount.formatted(format.precision(.fractionLength(0...2)).rounded(rule: .down))
}

func copilotDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

@MainActor
final class CopilotUsageModel: ObservableObject {
    @Published private(set) var snapshot: CopilotUsageSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private var generation = 0
    private var sourceIdentity: UUID?

    func useSource(_ identity: UUID) {
        guard sourceIdentity != identity else { return }
        sourceIdentity = identity
        reset()
    }

    func reset() {
        generation += 1
        snapshot = nil
        error = nil
        isLoading = false
    }

    func refresh(_ load: () async throws -> CopilotUsageSnapshot) async {
        guard !isLoading else { return }
        let requestedGeneration = generation
        isLoading = true
        defer { if generation == requestedGeneration { isLoading = false } }
        do {
            let value = try await load()
            try Task.checkCancellation()
            guard requestedGeneration == generation else { return }
            snapshot = value
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard requestedGeneration == generation else { return }
            self.error = error.localizedDescription
        }
    }

    func headerText(at date: Date, locale: Locale = .current) -> String {
        if let snapshot, snapshot.leadsWithAntigravity, let state = snapshot.antigravity,
           let primary = state.account?.primary {
            guard error == nil, !state.isStale(at: date) else { return "Stale" }
            return "\(primary.bucket.shortTitle) \(primary.bucket.percentText)"
        }
        if let snapshot, snapshot.leadsWithClaude, let state = snapshot.claude,
           let window = state.account?.primary {
            guard error == nil, !state.isStale(at: date) else { return "Stale" }
            return "\(window.shortTitle) \(window.percentText)"
        }
        guard let snapshot, let bucket = snapshot.account?.primary else { return "--" }
        guard error == nil, !snapshot.isStale(at: date) else { return "Stale" }
        if bucket.isUnlimited { return "Unlimited" }
        if let ratio = bucket.amountRatio(compact: true, locale: locale) { return ratio }
        if bucket.billingMode == "credits" { return "--" }
        guard let remainingPercent = bucket.remainingPercent, remainingPercent.isFinite else { return "--" }
        return String(format: "%.1f%%", 100 - remainingPercent)
    }

    func accessibilityValue(at date: Date) -> String {
        if let snapshot, snapshot.leadsWithAntigravity, let state = snapshot.antigravity,
           let primary = state.account?.primary {
            let stale = error != nil || state.isStale(at: date)
            return (stale ? "Stale. Last known: " : "")
                + "Antigravity \(primary.group.name) \(primary.bucket.title.lowercased()) \(primary.bucket.percentText) used"
        }
        if let snapshot, snapshot.leadsWithClaude, let state = snapshot.claude,
           let window = state.account?.primary {
            let stale = error != nil || state.isStale(at: date)
            return (stale ? "Stale. Last known: " : "") + "Claude \(window.title.lowercased()) \(window.percentText) used"
        }
        guard let snapshot, let bucket = snapshot.account?.primary else { return "Account allowance unavailable" }
        let stale = error != nil || snapshot.isStale(at: date)
        return (stale ? "Stale. Last known: " : "") + bucket.summary
    }
}

struct CopilotUsageButton: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var remote: CantripRemoteModel
    @StateObject private var model = CopilotUsageModel()
    @State private var isPresented = false
    var compact = false
    var onOpen: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Button {
                onOpen()
                isPresented = true
            } label: {
                CopilotUsageButtonLabel(
                    text: model.headerText(at: context.date),
                    compact: compact
                )
            }
            .accessibilityLabel("Usage limits")
            .accessibilityValue(model.accessibilityValue(at: context.date))
            .accessibilityHint("Shows Claude Code's and Antigravity's limits and the Copilot allowance")
            .accessibilityIdentifier("copilot-usage-button")
        }
        .sheet(isPresented: $isPresented) {
            CopilotUsageView(model: model, remote: remote)
        }
        .task(id: PollingIdentity(active: scenePhase == .active, configuration: remote.usageIdentity,
                                  configured: remote.isConfigured)) {
            model.useSource(remote.usageIdentity)
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refresh { try await remote.copilotUsage() }
                do {
                    try await Task.sleep(for: .seconds(model.snapshot?.isRefreshing == true ? 2 : 60))
                } catch { return }
            }
        }
    }

    struct CopilotUsageButtonLabel: View {
        let text: String
        var compact = false

        var body: some View {
            Group {
                if compact {
                    ChatHeaderIcon(systemName: "gauge.with.dots.needle.33percent")
                        .frame(width: 44, height: 44)
                } else {
                    HStack(spacing: 4) {
                        ChatHeaderIcon(systemName: "gauge.with.dots.needle.33percent")
                        ViewThatFits(in: .horizontal) {
                            amountText.fixedSize()
                            amountText
                                .dynamicTypeSize(.large)
                                .minimumScaleFactor(0.5)
                        }
                        .frame(minWidth: 58, idealWidth: 90, maxWidth: 90, alignment: .leading)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .frame(height: 44)
                }
            }
            // Full-size amounts remain in the accessible details sheet.
            .contentShape(Rectangle())
        }

        private var amountText: some View {
            Text(text)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .allowsTightening(true)
        }
    }

    private struct PollingIdentity: Hashable {
        let active: Bool
        let configuration: UUID
        let configured: Bool
    }
}

struct CopilotUsageView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: CopilotUsageModel
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List {
                    Section {
                        if model.isLoading || model.snapshot?.isRefreshing == true {
                            HStack {
                                ProgressView()
                                Text("Reading Copilot account allowance...")
                            }
                        }
                        if let error = model.error ?? model.snapshot?.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        if let snapshot = model.snapshot, snapshot.account != nil,
                           model.error != nil || snapshot.isStale(at: context.date) {
                            Label("Last known allowance - data is stale", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                        if model.snapshot?.account == nil && !model.isLoading
                            && model.snapshot?.isRefreshing != true {
                            Text("Account allowance unavailable").foregroundStyle(.secondary)
                        }
                        Text("The Copilot account signed in on your Cantrip Mac. This is account-wide, not just this conversation, and remains available from any chat lane.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let claude = model.snapshot?.claude {
                        ClaudeUsageSection(state: claude, now: context.date)
                    }
                    if let antigravity = model.snapshot?.antigravity {
                        AntigravityUsageSection(state: antigravity, now: context.date)
                    }
                    if let account = model.snapshot?.account {
                        Section("Copilot account") {
                            if let login = account.login { LabeledContent("Account", value: login) }
                            if let plan = account.plan { LabeledContent("Plan", value: plan) }
                            if let checked = copilotDate(model.snapshot?.checkedAt) {
                                LabeledContent("Checked", value: checked.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        ForEach(account.buckets) { bucket in
                            Section(bucket.title) { CopilotQuotaRow(bucket: bucket) }
                        }
                    }
                    Section {
                        Text("The Mac refreshes every five minutes, and at most once a minute when you ask. No prompts are sent and no model is invoked. Credentials stay on the Mac.")
                        Text("Remaining account allowance does not rule out model-specific or short-term rate limits.")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .refreshable { await model.refresh { try await remote.copilotUsage() } }
            }
            .navigationTitle("Usage Limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await model.refresh { try await remote.copilotUsage() } }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.isLoading || model.snapshot?.isRefreshing == true)
                        .accessibilityLabel("Refresh usage limits")
                }
            }
        }
    }
}

struct CopilotQuotaRow: View {
    let bucket: CopilotQuotaBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(bucket.summary).font(.headline)
            if !bucket.isUnlimited, let remaining = bucket.remainingPercent,
               let percentage = bucket.percentageSummary {
                ProgressView(value: 100 - remaining, total: 100)
                    .tint(remaining <= 10 ? .orange : .accentColor)
                    .accessibilityLabel("Included allowance used")
                    .accessibilityValue(String(format: "%.1f%%", 100 - remaining))
                Text(percentage)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(bucket.billingMode == "credits"
                 ? "Token / AI-credit billing; these are not prompt counts."
                 : bucket.billingMode == "requests" ? "Request-based billing" : "Billing units not reported")
                .font(.caption).foregroundStyle(.secondary)
            Text(bucket.overageAllowed.map { "Additional usage: \($0 ? "enabled" : "disabled")" }
                 ?? "Additional usage: not reported")
            if let overage = bucket.overage {
                Text(overage == 0 ? "No additional usage reported consumed"
                     : "Additional usage consumed: \(overage.formatted()) \(bucket.billingMode == "requests" ? "requests" : "billing units")")
                    .font(.subheadline)
            }
            if let reset = copilotDate(bucket.resetAt) {
                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened)) (local time)")
            } else {
                Text("Reset date unavailable").foregroundStyle(.secondary)
            }
            if let observed = copilotDate(bucket.observedAt) {
                Text("Source snapshot: \(observed.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Claude Code's 5-hour and weekly limits, as the Mac reads them from Claude.
struct ClaudeUsageSection: View {
    let state: ClaudeUsageState
    let now: Date

    var body: some View {
        Section {
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let account = state.account {
                if state.isStale(at: now) {
                    Label("Last known limits - data is stale", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                ForEach(account.windows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(window.title)
                            Spacer()
                            Text("\(window.percentText) used").monospacedDigit().foregroundStyle(tint(window))
                        }
                        ProgressView(value: min(100, max(0, window.percentUsed)), total: 100)
                            .tint(tint(window))
                        if let reset = copilotDate(window.resetsAt) {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("usage.claude.\(window.id)")
                }
                if let checked = copilotDate(state.checkedAt) {
                    LabeledContent("Checked", value: checked.formatted(date: .abbreviated, time: .shortened))
                }
            } else if state.error == nil {
                Text("Claude's limits unavailable").foregroundStyle(.secondary)
            }
        } header: {
            Text(state.account?.plan.map { "Claude Code · \($0.capitalized)" } ?? "Claude Code")
        }
    }

    private func tint(_ window: ClaudeLimitWindow) -> Color {
        if window.isExhausted || window.severity == "critical" { return .red }
        if window.severity == "warning" || window.percentUsed >= 80 { return .orange }
        return .accentColor
    }
}

/// Antigravity's weekly and 5-hour limits per model group, as the Mac reads them from `agy`.
struct AntigravityUsageSection: View {
    let state: AntigravityUsageState
    let now: Date

    var body: some View {
        if let error = state.error, state.account == nil {
            Section("Antigravity") {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        if let account = state.account {
            ForEach(account.groups) { group in
                Section {
                    if group.id == account.groups.first?.id {
                        if let error = state.error {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        if state.isStale(at: now) {
                            Label("Last known limits - data is stale", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                    }
                    ForEach(group.buckets) { bucket in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(bucket.title)
                                Spacer()
                                Text("\(bucket.percentText) used").monospacedDigit().foregroundStyle(tint(bucket))
                            }
                            ProgressView(value: bucket.percentUsed, total: 100)
                                .tint(tint(bucket))
                            if let reset = copilotDate(bucket.resetsAt) {
                                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("usage.antigravity.\(bucket.id)")
                    }
                    if group.id == account.groups.last?.id, let checked = copilotDate(state.checkedAt) {
                        LabeledContent("Checked", value: checked.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("Antigravity · \(group.name)")
                } footer: {
                    if let models = group.models { Text(models) }
                }
            }
        }
    }

    private func tint(_ bucket: AntigravityLimitBucket) -> Color {
        if bucket.isExhausted { return .red }
        if bucket.percentUsed >= 80 { return .orange }
        return .accentColor
    }
}
