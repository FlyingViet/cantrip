import Foundation

/// Tracks per-backend usage: query counts for everything, real dollar
/// cost + token counts for Claude Code (from its result events), and the
/// Claude rate-limit window status. Persisted daily in UserDefaults.
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    struct Summary {
        var queries = 0
        var costUSD = 0.0
        var inputTokens = 0
        var outputTokens = 0
    }

    struct RateLimit: Codable {
        let type: String        // e.g. "five_hour", "weekly"
        let resetsAt: Date
        let status: String      // "allowed" / "rejected" / …
        /// 0–100; only present when the CLI includes utilization
        /// (not guaranteed in headless mode — open upstream issue).
        let percentUsed: Double?
    }

    @Published private(set) var lastQueryCost: Double?
    @Published private(set) var rateLimit: RateLimit?
    @Published private(set) var copilotUsage = CopilotUsageSnapshot()
    var copilotQuota: String? { copilotUsage.summary }
    private var lastQuotaRefresh = Date.distantPast
    private let quotaLoader: (@escaping (Result<CopilotAccountUsage, Error>) -> Void) -> Void
    private let quotaClock: () -> Date

    /// Mac and Remote share one single-flight, once-per-minute account lookup.
    func refreshQuotas() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refreshQuotas() }
            return
        }
        guard !copilotUsage.isRefreshing, quotaClock().timeIntervalSince(lastQuotaRefresh) >= 60 else { return }
        lastQuotaRefresh = quotaClock()
        copilotUsage.isRefreshing = true
        quotaLoader { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.copilotUsage.isRefreshing = false
                switch result {
                case .success(let account):
                    self.copilotUsage.account = account
                    self.copilotUsage.checkedAt = ISO8601DateFormatter().string(from: self.quotaClock())
                    self.copilotUsage.error = nil
                case .failure(let error):
                    self.copilotUsage.error = ((error as? CopilotQuotaError) ?? .response).localizedDescription
                }
            }
        }
    }
    /// Bumped on every write so views refresh.
    @Published private(set) var revision = 0

    private let dailyKey = "usageDaily"
    private let rateLimitKey = "claudeRateLimit"
    private let d = UserDefaults.standard

    init(
        quotaLoader: @escaping (@escaping (Result<CopilotAccountUsage, Error>) -> Void) -> Void = QuotaFetcher.fetchCopilotQuota,
        quotaClock: @escaping () -> Date = Date.init
    ) {
        self.quotaLoader = quotaLoader
        self.quotaClock = quotaClock
        if let data = d.data(forKey: rateLimitKey),
           let saved = try? JSONDecoder().decode(RateLimit.self, from: data) {
            rateLimit = saved
        }
    }

    // MARK: - Recording

    func recordQuery(backend: BackendKind) {
        mutateToday(backend) { $0.queries += 1 }
    }

    func recordCost(backend: BackendKind, costUSD: Double,
                    inputTokens: Int, outputTokens: Int) {
        DispatchQueue.main.async { self.lastQueryCost = costUSD }
        mutateToday(backend) {
            $0.costUSD += costUSD
            $0.inputTokens += inputTokens
            $0.outputTokens += outputTokens
        }
    }

    func updateRateLimit(type: String, resetsAtEpoch: TimeInterval,
                         status: String, percentUsed: Double? = nil) {
        let info = RateLimit(type: type,
                             resetsAt: Date(timeIntervalSince1970: resetsAtEpoch),
                             status: status,
                             percentUsed: percentUsed ?? rateLimit?.percentUsed)
        DispatchQueue.main.async {
            self.rateLimit = info
            self.revision += 1
        }
        if let data = try? JSONEncoder().encode(info) {
            d.set(data, forKey: rateLimitKey)
        }
    }

    // MARK: - Reading

    /// Aggregate over the last N days (1 = today), per backend rawValue.
    func summary(days: Int) -> [String: Summary] {
        let store = d.dictionary(forKey: dailyKey) as? [String: [String: [String: Any]]] ?? [:]
        var result: [String: Summary] = [:]
        for offset in 0..<days {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())
            else { continue }
            guard let dayStore = store[Self.dayKey(day)] else { continue }
            for (backend, values) in dayStore {
                var s = result[backend] ?? Summary()
                s.queries += values["q"] as? Int ?? 0
                s.costUSD += values["cost"] as? Double ?? 0
                s.inputTokens += values["in"] as? Int ?? 0
                s.outputTokens += values["out"] as? Int ?? 0
                result[backend] = s
            }
        }
        return result
    }

    // MARK: - Internals

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func mutateToday(_ backend: BackendKind,
                             _ change: (inout Summary) -> Void) {
        var store = d.dictionary(forKey: dailyKey) as? [String: [String: [String: Any]]] ?? [:]
        let day = Self.dayKey(Date())
        var dayStore = store[day] ?? [:]
        let values = dayStore[backend.rawValue] ?? [:]
        var s = Summary(queries: values["q"] as? Int ?? 0,
                        costUSD: values["cost"] as? Double ?? 0,
                        inputTokens: values["in"] as? Int ?? 0,
                        outputTokens: values["out"] as? Int ?? 0)
        change(&s)
        dayStore[backend.rawValue] = ["q": s.queries, "cost": s.costUSD,
                                      "in": s.inputTokens, "out": s.outputTokens]
        store[day] = dayStore
        // Prune anything older than 90 days.
        if store.count > 95 {
            let cutoff = Self.dayKey(Calendar.current.date(
                byAdding: .day, value: -90, to: Date()) ?? Date())
            store = store.filter { $0.key >= cutoff }
        }
        d.set(store, forKey: dailyKey)
        DispatchQueue.main.async { self.revision += 1 }
    }
}
