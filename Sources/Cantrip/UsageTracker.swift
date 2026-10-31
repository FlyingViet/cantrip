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
    private let claudeLoader: ((@escaping (Result<ClaudeAccountUsage, Error>) -> Void) -> Void)?
    /// Asked on every refresh, so Antigravity installed after launch shows up without a restart.
    private let antigravityLoader: () -> ((@escaping (Result<AntigravityAccountUsage, Error>) -> Void) -> Void)?
    private let quotaClock: () -> Date
    private var autoRefresh: Timer?

    /// Mac and Remote share one single-flight, once-per-minute lookup of every backend's limits.
    func refreshQuotas() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refreshQuotas() }
            return
        }
        guard !copilotUsage.isRefreshing, quotaClock().timeIntervalSince(lastQuotaRefresh) >= 60 else { return }
        lastQuotaRefresh = quotaClock()
        copilotUsage.isRefreshing = true
        let group = DispatchGroup()
        group.enter()
        quotaLoader { [weak self] result in
            DispatchQueue.main.async {
                defer { group.leave() }
                guard let self else { return }
                switch result {
                case .success(let account):
                    self.copilotUsage.account = account
                    self.copilotUsage.checkedAt = ISODate.string(from: self.quotaClock())
                    self.copilotUsage.error = nil
                case .failure(let error):
                    self.copilotUsage.error = ((error as? CopilotQuotaError) ?? .response).localizedDescription
                }
            }
        }
        if let claudeLoader {
            group.enter()
            claudeLoader { [weak self] result in
                DispatchQueue.main.async {
                    defer { group.leave() }
                    self?.apply(claude: result)
                }
            }
        }
        if let antigravityLoader = antigravityLoader() {
            group.enter()
            antigravityLoader { [weak self] result in
                DispatchQueue.main.async {
                    defer { group.leave() }
                    self?.apply(antigravity: result)
                }
            }
        }
        group.notify(queue: .main) { [weak self] in self?.copilotUsage.isRefreshing = false }
    }

    private func apply(antigravity result: Result<AntigravityAccountUsage, Error>) {
        var state = copilotUsage.antigravity ?? AntigravityUsageState()
        switch result {
        case .success(let account):
            state = AntigravityUsageState(account: account, checkedAt: ISODate.string(from: quotaClock()), error: nil)
            // The model group Antigravity runs on (Gemini for Auto) at its limit sends new messages to
            // the fallback backend before agy refuses one.
            let model = AppSettings.shared.agyModel.trimmingCharacters(in: .whitespaces)
            if let group = account.group(forModel: model),
               let full = group.buckets.filter(\.isExhausted)
                .max(by: { (copilotDate($0.resetsAt) ?? .distantPast) < (copilotDate($1.resetsAt) ?? .distantPast) }) {
                BackendLimitTracker.shared.markLimited(
                    .antigravity, message: "Antigravity \(group.name) \(full.title.lowercased()) reached",
                    report: UsageLimitReport(code: "usage/\(full.id)", resetsAt: copilotDate(full.resetsAt)),
                    now: quotaClock()
                )
            }
        case .failure(let error):
            state.error = ((error as? AntigravityUsageError) ?? .response).localizedDescription
        }
        copilotUsage.antigravity = state
    }

    private func apply(claude result: Result<ClaudeAccountUsage, Error>) {
        var state = copilotUsage.claude ?? ClaudeUsageState()
        switch result {
        case .success(let account):
            state = ClaudeUsageState(account: account, checkedAt: ISODate.string(from: quotaClock()), error: nil)
            // A window at its limit sends new messages to the fallback backend before Claude refuses one.
            if let full = account.windows.filter(\.isExhausted)
                .max(by: { (copilotDate($0.resetsAt) ?? .distantPast) < (copilotDate($1.resetsAt) ?? .distantPast) }) {
                BackendLimitTracker.shared.markLimited(
                    .claudeCode, message: "Claude \(full.title.lowercased()) reached",
                    report: UsageLimitReport(code: "usage/\(full.id)", resetsAt: copilotDate(full.resetsAt)),
                    now: quotaClock()
                )
            }
        case .failure(let error):
            state.error = ((error as? ClaudeUsageError) ?? .response).localizedDescription
        }
        copilotUsage.claude = state
    }

    /// Keeps the limits fresh without anyone looking, like Opsboard: every five minutes.
    func startAutoRefresh(every interval: TimeInterval = 300) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.startAutoRefresh(every: interval) }
            return
        }
        autoRefresh?.invalidate()
        refreshQuotas()
        autoRefresh = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshQuotas()
        }
    }
    /// Bumped on every write so views refresh.
    @Published private(set) var revision = 0

    private let dailyKey = "usageDaily"
    private let rateLimitKey = "claudeRateLimit"
    private let d = UserDefaults.standard

    init(
        quotaLoader: @escaping (@escaping (Result<CopilotAccountUsage, Error>) -> Void) -> Void = QuotaFetcher.fetchCopilotQuota,
        claudeLoader: ((@escaping (Result<ClaudeAccountUsage, Error>) -> Void) -> Void)? = UsageTracker.defaultClaudeLoader,
        antigravityLoader: @escaping () -> ((@escaping (Result<AntigravityAccountUsage, Error>) -> Void) -> Void)?
            = UsageTracker.defaultAntigravityLoader,
        quotaClock: @escaping () -> Date = Date.init
    ) {
        self.quotaLoader = quotaLoader
        self.claudeLoader = claudeLoader
        self.antigravityLoader = antigravityLoader
        self.quotaClock = quotaClock
        if let data = d.data(forKey: rateLimitKey),
           let saved = try? JSONDecoder().decode(RateLimit.self, from: data) {
            rateLimit = saved
        }
    }

    /// Claude's limits when Claude Code is installed; nil leaves them out.
    static var defaultClaudeLoader: ((@escaping (Result<ClaudeAccountUsage, Error>) -> Void) -> Void)? {
        ToolLocator.shared.claude(configured: AppSettings.shared.claudePath) == nil ? nil : ClaudeUsageFetcher.fetch
    }

    /// Antigravity's limits when `agy` is installed; nil leaves them out.
    static func defaultAntigravityLoader() -> ((@escaping (Result<AntigravityAccountUsage, Error>) -> Void) -> Void)? {
        guard let command = AntigravityBackend.resolveExecutable(customPath: AppSettings.shared.agyPath) else { return nil }
        return { AntigravityUsageFetcher.fetch(command: command, completion: $0) }
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
        ISODate.localDay(date)
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
