import SwiftUI
import AppKit

/// One consumer's endpoint calls over a period.
struct EndpointUsageTotals: Codable, Equatable {
    /// Calls a backend answered.
    var calls = 0
    var failed = 0
    /// Calls refused because every backend that could answer was at its usage limit.
    var limited = 0
    var inputTokens = 0
    var outputTokens = 0
    /// Copilot's premium requests.
    var premiumRequests = 0.0
    /// Claude Code's reported cost.
    var costUSD = 0.0
    /// Answered calls per backend (`BackendKind` raw values).
    var backends: [String: Int] = [:]

    mutating func add(_ other: EndpointUsageTotals) {
        calls += other.calls
        failed += other.failed
        limited += other.limited
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        premiumRequests += other.premiumRequests
        costUSD += other.costUSD
        for (backend, count) in other.backends { backends[backend, default: 0] += count }
    }

    /// "Copilot 41 · Claude Code 3 · 12 premium requests · 1.2M tokens · 2 failed"
    var detail: String {
        var parts = backends.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map { "\($0.key) \($0.value)" }
        if premiumRequests > 0 {
            let value = premiumRequests.rounded() == premiumRequests ? String(Int(premiumRequests))
                : String(format: "%.2f", premiumRequests)
            parts.append("\(value) premium request\(premiumRequests == 1 ? "" : "s")")
        }
        let tokens = inputTokens + outputTokens
        if tokens > 0 { parts.append("\(PromptUsage.compact(tokens)) tokens") }
        if limited > 0 { parts.append("\(limited) at usage limits") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }
}

struct EndpointConsumerUsage: Codable, Equatable, Identifiable {
    var name: String
    var today: EndpointUsageTotals
    var week: EndpointUsageTotals
    var lastCallAt: String?
    var id: String { name }
}

/// The endpoint section of `/api/v1/copilot/usage` (`endpoint`); absent on older hosts.
struct EndpointUsageSnapshot: Codable, Equatable {
    var enabled: Bool
    var listening: Bool
    var port: Int?
    /// Busiest first, over the last 7 days.
    var consumers: [EndpointConsumerUsage]
}

/// Endpoint calls per consumer and local day, kept 90 days in UserDefaults. Each answered call
/// also counts toward its backend in `UsageTracker`, like a tab's message.
final class EndpointUsageLedger: ObservableObject {
    static let shared = EndpointUsageLedger()

    enum Outcome { case answered, limited, failed }

    /// Bumped on every write so views refresh.
    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    private let key: String
    private let tracker: UsageTracker?
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "usageEndpointDaily", tracker: UsageTracker? = .shared) {
        self.defaults = defaults
        self.key = key
        self.tracker = tracker
    }

    func record(consumer: String, backend: BackendKind?, outcome: Outcome, result: OneShotResult?, at date: Date = Date()) {
        lock.withLock {
            var store = defaults.dictionary(forKey: key) as? [String: [String: Data]] ?? [:]
            let day = ISODate.localDay(date)
            var dayStore = store[day] ?? [:]
            var totals = dayStore[consumer].flatMap { try? JSONDecoder().decode(EndpointUsageTotals.self, from: $0) }
                ?? EndpointUsageTotals()
            switch outcome {
            case .answered:
                totals.calls += 1
                if let backend { totals.backends[backend.rawValue, default: 0] += 1 }
            case .limited: totals.limited += 1
            case .failed: totals.failed += 1
            }
            if let result {
                totals.inputTokens += result.inputTokens
                totals.outputTokens += result.outputTokens
                totals.premiumRequests += result.premiumRequests ?? 0
                totals.costUSD += result.costUSD ?? 0
            }
            dayStore[consumer] = try? JSONEncoder().encode(totals)
            store[day] = dayStore
            var last = defaults.dictionary(forKey: key + ".last") as? [String: String] ?? [:]
            last[consumer] = ISODate.string(from: date)
            if store.count > 95, let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: date) {
                let oldest = ISODate.localDay(cutoff)
                store = store.filter { $0.key >= oldest }
            }
            defaults.set(store, forKey: key)
            defaults.set(last, forKey: key + ".last")
        }
        if let backend, outcome == .answered {
            tracker?.recordQuery(backend: backend)
            if let result, let cost = result.costUSD {
                tracker?.recordCost(backend: backend, costUSD: cost, inputTokens: result.inputTokens,
                                    outputTokens: result.outputTokens)
            }
        }
        if Thread.isMainThread { revision += 1 } else { DispatchQueue.main.async { self.revision += 1 } }
    }

    /// Totals per consumer over the last `days` local days (1 = today).
    func totals(days: Int, now: Date = Date()) -> [String: EndpointUsageTotals] {
        let store = lock.withLock { defaults.dictionary(forKey: key) as? [String: [String: Data]] ?? [:] }
        var result: [String: EndpointUsageTotals] = [:]
        for offset in 0..<max(1, days) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now),
                  let dayStore = store[ISODate.localDay(date)] else { continue }
            for (consumer, data) in dayStore {
                guard let totals = try? JSONDecoder().decode(EndpointUsageTotals.self, from: data) else { continue }
                result[consumer, default: EndpointUsageTotals()].add(totals)
            }
        }
        return result
    }

    /// Consumers seen in the last 7 days, busiest first.
    func consumers(now: Date = Date()) -> [EndpointConsumerUsage] {
        let today = totals(days: 1, now: now)
        let week = totals(days: 7, now: now)
        let last = lock.withLock { defaults.dictionary(forKey: key + ".last") as? [String: String] ?? [:] }
        return week.map { name, totals in
            EndpointConsumerUsage(name: name, today: today[name] ?? EndpointUsageTotals(), week: totals, lastCallAt: last[name])
        }
        .sorted { ($0.week.calls + $0.week.failed + $0.week.limited, $1.name) > ($1.week.calls + $1.week.failed + $1.week.limited, $0.name) }
    }

    func snapshot(enabled: Bool, listening: Int?, now: Date = Date()) -> EndpointUsageSnapshot {
        EndpointUsageSnapshot(enabled: enabled, listening: listening != nil, port: listening, consumers: consumers(now: now))
    }
}

/// The usage dashboard's endpoint section: who called it, today and this week.
struct EndpointUsageView: View {
    @ObservedObject var ledger: EndpointUsageLedger
    @ObservedObject var settings: AppSettings

    var body: some View {
        let _ = ledger.revision
        let consumers = ledger.consumers()
        VStack(alignment: .leading, spacing: 6) {
            Label("API endpoint", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
            Text(settings.openAIEndpointStatusText).foregroundStyle(settings.openAIEndpointError == nil ? Color.secondary : .orange)
            if consumers.isEmpty {
                Text("No calls in the last 7 days.").foregroundStyle(.secondary)
            }
            ForEach(consumers) { consumer in
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(consumer.name).fontWeight(.medium)
                        Spacer()
                        Text("\(consumer.today.calls) today · \(consumer.week.calls) this week").monospacedDigit()
                    }
                    let detail = consumer.week.detail
                    if !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(.caption)
    }
}

/// Settings › the OpenAI-compatible API: on/off, port, the model calls without one use, and the
/// key for requests that come through a proxy.
struct OpenAIEndpointSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var keyNote: String?

    private var primary: BackendKind { settings.backend }

    private var model: Binding<String> {
        Binding(
            get: {
                guard case .backend(let kind, let model) = OpenAIEndpointModel.parse(settings.openAIEndpointModel),
                      kind == primary, !settings.openAIEndpointModel.isEmpty else { return "" }
                return model
            },
            set: { settings.openAIEndpointModel = $0.isEmpty ? "" : OpenAIEndpointModel.name(primary, model: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("OpenAI-compatible API for apps on this Mac", isOn: $settings.openAIEndpointEnabled)
                .font(.caption)
                .toggleStyle(.checkbox)
            if settings.openAIEndpointEnabled {
                HStack(spacing: 8) {
                    Text("Port").font(.caption).foregroundStyle(.secondary)
                    TextField(String(OpenAIEndpoint.defaultPort), text: Binding(
                        get: { String(settings.openAIEndpointPort) },
                        set: { if let port = Int($0), (1...65535).contains(port) { settings.openAIEndpointPort = port } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                }
                if let reason = OneShotCompletion.unsupportedReason(primary) {
                    Text("\(reason) Calls go to the usage-limit backups.").font(.caption2).foregroundStyle(.orange)
                } else if primary != .localModel {
                    modelPickers
                }
                Text(settings.openAIEndpointStatusText)
                    .font(.caption2)
                    .foregroundStyle(settings.openAIEndpointError == nil ? Color.secondary : .red)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(settings.openAIEndpointKey == nil ? "Proxy key: none" : "Proxy key: set")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(settings.openAIEndpointKey == nil ? "Make key" : "Replace key") {
                        if let key = settings.generateOpenAIEndpointKey() {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(key, forType: .string)
                            keyNote = "Copied the new key. Cantrip won't show it again."
                        } else {
                            keyNote = "The Keychain didn't save the key."
                        }
                    }
                    .font(.caption)
                    if settings.openAIEndpointKey != nil {
                        Button("Remove") {
                            settings.clearOpenAIEndpointKey()
                            keyNote = nil
                        }
                        .font(.caption)
                    }
                }
                if let keyNote { Text(keyNote).font(.caption2).foregroundStyle(.secondary) }
                Text("Apps call http://127.0.0.1:\(String(settings.openAIEndpointPort))/v1 and name themselves with /consumer/NAME/v1 for the usage screen. The model auto uses this Mac's backend, then its usage-limit backups; fast, standard or deep runs that chain at the tier, and copilot:deep one backend's tier. Each call is stateless and tool-free. Requests through a proxy such as Tailscale Serve need the key.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var modelPickers: some View {
        let catalog = settings.tabModelCatalog(for: primary)
        let choices = settings.tabModelChoices(for: primary)
        let tiers = settings.tierOptions(for: primary)
        let info = choices.first { $0.id == model.wrappedValue } ?? catalog.info(model.wrappedValue)
        Picker("Model", selection: model) {
            Text("Same as tabs").tag("")
            ForEach(tiers, id: \.id) { tier in
                Text("\(tier.label) — \(tier.modelLabel)").tag(tier.id)
            }
            ForEach(catalog.models) { model in
                Text(settings.fallbackModelLabel(primary, model.id)).tag(model.id)
            }
            if !model.wrappedValue.isEmpty, !choices.contains(where: { $0.id == model.wrappedValue }) {
                Text("\(model.wrappedValue) (not offered now)").tag(model.wrappedValue)
            }
        }
        .font(.caption)
        if let efforts = info?.reasoningEfforts, !efforts.isEmpty {
            Picker("Effort", selection: $settings.openAIEndpointEffort) {
                Text("Same as tabs").tag("")
                ForEach(efforts, id: \.self) { Text($0).tag($0) }
                if !settings.openAIEndpointEffort.isEmpty, !efforts.contains(settings.openAIEndpointEffort) {
                    Text(settings.openAIEndpointEffort).tag(settings.openAIEndpointEffort)
                }
            }
            .font(.caption)
        }
        if primary == .copilot, let tiers = info?.contextTiers, !tiers.isEmpty {
            Picker("Context", selection: $settings.openAIEndpointContextTier) {
                Text("Same as tabs").tag("")
                ForEach(tiers, id: \.self) { Text($0).tag($0) }
                if !settings.openAIEndpointContextTier.isEmpty, !tiers.contains(settings.openAIEndpointContextTier) {
                    Text(settings.openAIEndpointContextTier).tag(settings.openAIEndpointContextTier)
                }
            }
            .font(.caption)
        }
    }
}
