import SwiftUI

struct CopilotUsageSnapshot: Decodable {
    let account: CopilotAccountUsage?
    let checkedAt: String?
    let isRefreshing: Bool
    let error: String?

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
        guard let remainingPercent else { return "\(title): remaining amount unavailable" }
        return String(format: "%.1f%% used / %.1f%% remaining", 100 - remainingPercent, remainingPercent)
    }
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

    func headerText(at date: Date) -> String {
        guard let snapshot, let bucket = snapshot.account?.primary else { return "--" }
        guard error == nil, !snapshot.isStale(at: date) else { return "Stale" }
        if bucket.isUnlimited { return "Unlimited" }
        return bucket.remainingPercent.map { String(format: "%.1f%%", $0) } ?? "--"
    }
}

struct CopilotUsageButton: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var remote: CantripRemoteModel
    @StateObject private var model = CopilotUsageModel()
    @State private var isPresented = false
    var onOpen: () -> Void = {}

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Button {
                onOpen()
                isPresented = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                    Text(model.headerText(at: context.date))
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 78, height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Copilot account usage")
            .accessibilityValue(model.headerText(at: context.date) + " remaining; tap for details")
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
                    if let account = model.snapshot?.account {
                        Section("Mac account") {
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
                        Text("The Mac refreshes at most once a minute. No prompts are sent and no model is invoked. Credentials stay on the Mac.")
                        Text("Remaining account allowance does not rule out model-specific or short-term rate limits.")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .refreshable { await model.refresh { try await remote.copilotUsage() } }
            }
            .navigationTitle("Copilot Usage")
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
                        .accessibilityLabel("Refresh Copilot usage")
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
            if !bucket.isUnlimited, let remaining = bucket.remainingPercent {
                ProgressView(value: 100 - remaining, total: 100)
                    .tint(remaining <= 10 ? .orange : .accentColor)
                    .accessibilityLabel("Included allowance used")
                    .accessibilityValue(String(format: "%.1f%%", 100 - remaining))
            }
            Text(bucket.billingMode == "credits"
                 ? "Token / AI-credit billing; these are not prompt counts."
                 : bucket.billingMode == "requests" ? "Request-based billing" : "Billing units not reported")
                .font(.caption).foregroundStyle(.secondary)
            if bucket.billingMode == "requests", !bucket.isUnlimited,
               let remaining = bucket.remaining, let entitlement = bucket.entitlement {
                Text("\(remaining.formatted()) of \(entitlement.formatted()) included requests remaining")
            }
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
