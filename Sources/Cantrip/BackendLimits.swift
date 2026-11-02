import Foundation

/// Recognizes a backend error that means the account's plan is used up for now (Claude's
/// 5-hour and weekly limits, Copilot's premium requests, Codex and Gemini quotas), as opposed
/// to a failure retrying the same backend could fix. Backends that send a structured error
/// (Copilot's `session.error`, Claude's `rate_limit` and `billing_error`) report it as a
/// `UsageLimitReport`; the phrases are only the last resort for CLIs that don't.
enum UsageLimit {
    /// Lowercased phrases each CLI uses. Generic "limit reached" is left out on purpose:
    /// "Context limit reached" means the conversation is full, not the plan.
    static let phrases = [
        "usage limit", "hit your limit", "session limit", "weekly limit", "5-hour limit",
        "five-hour limit", "monthly limit", "out of extra usage", "premium request",
        "hit a rate limit", "weekly rate limit", "user_weekly_rate_limited",
        "quota exceeded", "exceeded your quota", "exceeded your current quota", "insufficient_quota",
        "no quota", "resource_exhausted", "exhausted your capacity", "usage_limit_reached",
        "credit balance is too low",
    ]

    /// Copilot's `session.error` categories that mean the plan, not the request, is the problem.
    /// `errorCode` narrows it ("quota_exceeded", "user_weekly_rate_limited", ...).
    static func copilotReport(errorType: String?, errorCode: String?, message: String,
                              now: Date = Date()) -> UsageLimitReport? {
        guard let errorType, ["quota", "rate_limit"].contains(errorType) else { return nil }
        var resets = resetDate(in: message, now: now)
        // The monthly premium-request allowance resets on the 1st at 00:00 UTC; skipping
        // Copilot for only the default hour would fail again every hour until then.
        if resets == nil, errorType == "quota", errorCode == "quota_exceeded" {
            resets = startOfNextMonthUTC(after: now)
        }
        return UsageLimitReport(code: [errorType, errorCode].compactMap { $0 }.joined(separator: "/"),
                                resetsAt: resets)
    }

    static func startOfNextMonthUTC(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let month = calendar.dateInterval(of: .month, for: date) else { return nil }
        return month.end
    }

    static func isLimitError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return phrases.contains { lowered.contains($0) }
    }

    /// When the limit lifts, if the message says: Claude's `…limit reached|<epoch>` form or
    /// "try again in 2 hours 5 minutes" (Copilot, Codex).
    static func resetDate(in text: String, now: Date = Date()) -> Date? {
        if let bar = text.lastIndex(of: "|"),
           let epoch = TimeInterval(text[text.index(after: bar)...].trimmingCharacters(in: .whitespacesAndNewlines)),
           epoch > now.timeIntervalSince1970 {
            return Date(timeIntervalSince1970: epoch)
        }
        let lowered = text.lowercased()
        guard let start = lowered.range(of: "try again in ") else { return nil }
        let units: [(String, TimeInterval)] = [("day", 86_400), ("hour", 3_600), ("minute", 60), ("second", 1)]
        var seconds: TimeInterval = 0
        let words = lowered[start.upperBound...].split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var index = 0
        while index + 1 < words.count, let value = Double(words[index]),
              let unit = units.first(where: { words[index + 1].hasPrefix($0.0) }) {
            seconds += value * unit.1
            index += 2
            if index < words.count, words[index] == "and" { index += 1 }
        }
        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }
}

/// Backends at their usage limit, app-wide (every tab shares the account), so new messages go
/// straight to the fallback backend instead of failing first. A limit covers the whole backend
/// (a shared quota, such as Copilot's premium requests) or one model scope where the backend keeps
/// quotas per model (Claude's weekly Opus and Sonnet limits, Antigravity's model groups); the
/// report's `scope` decides. Kept in memory only: after a relaunch each backend is tried again.
final class BackendLimitTracker {
    static let shared = BackendLimitTracker()
    /// How long a backend is skipped when its error doesn't say when the limit lifts.
    static var defaultCooldown: TimeInterval = 60 * 60

    struct ScopeLimit: Equatable {
        let backend: BackendKind
        let scope: String
        let until: Date
    }

    private struct ScopeKey: Hashable {
        let backend: BackendKind
        let scope: String
    }

    private let lock = NSLock()
    private var limitedUntil: [BackendKind: Date] = [:]
    private var scopeLimitedUntil: [ScopeKey: Date] = [:]
    /// Backends a check found signed out (BackendStatusMonitor), with why.
    private var unavailable: [BackendKind: String] = [:]

    /// Marks `kind` unusable (signed out) until a check finds it signed in; nil clears it.
    func setUnavailable(_ kind: BackendKind, reason: String?) {
        let changed: Bool = lock.withLock {
            let before = unavailable[kind]
            unavailable[kind] = reason
            return before != reason
        }
        if changed {
            Log.write("routing: \(kind.rawValue) " + (reason.map { "unavailable (\($0))" } ?? "available again"))
        }
    }

    /// Why `kind` can't be used at all right now (signed out), or nil.
    func unavailableReason(_ kind: BackendKind) -> String? {
        lock.withLock { unavailable[kind] }
    }

    /// The quota a model's requests count against, where the backend keeps one per model: Claude's
    /// model tiers and Antigravity's model groups (Claude and GPT share one, Argon has its own,
    /// everything else, Auto included, is Gemini). nil: the backend's models share one quota.
    static func modelScope(_ kind: BackendKind, model: String) -> String? {
        let slug = model.lowercased()
        switch kind {
        case .claudeCode:
            return ["opus", "sonnet", "haiku"].first { slug.contains($0) }
        case .antigravity:
            if slug.hasPrefix("claude") || slug.hasPrefix("gpt") { return "claude-gpt" }
            return slug.contains("argon") ? "argon" : "gemini"
        default:
            return nil
        }
    }

    /// The scope of an Antigravity `/usage` group, by its name ("Gemini 4 Argon", "Claude and GPT models").
    static func antigravityScope(group name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("claude") || lowered.contains("gpt") { return "claude-gpt" }
        return lowered.contains("argon") ? "argon" : "gemini"
    }

    /// The scope of a Claude limit window or rate-limit type ("seven_day_opus"); nil for the
    /// account-wide windows (five_hour, seven_day).
    static func claudeScope(window id: String) -> String? {
        ["opus", "sonnet", "haiku"].first { id.lowercased().contains($0) }
    }

    func markLimited(_ kind: BackendKind, model: String? = nil, message: String, report: UsageLimitReport? = nil,
                     now: Date = Date()) {
        var until = report?.resetsAt.flatMap { $0 > now ? $0 : nil } ?? UsageLimit.resetDate(in: message, now: now)
        if until == nil, kind == .claudeCode, report?.scope == nil, let limit = UsageTracker.shared.rateLimit,
           limit.status == "rejected", limit.resetsAt > now {
            until = limit.resetsAt
        }
        let date = until ?? now.addingTimeInterval(Self.defaultCooldown)
        if let scope = report?.scope {
            lock.withLock { scopeLimitedUntil[ScopeKey(backend: kind, scope: scope)] = date }
        } else {
            lock.withLock { limitedUntil[kind] = date }
        }
        Log.write("usage-limit: \(kind.rawValue)\(report?.scope.map { " (\($0) models)" } ?? "") limited until "
            + ISODate.string(from: date) + (report.map { " (\($0.code))" } ?? "")
            + (model.map { $0.isEmpty ? "" : " while on \($0)" } ?? ""))
    }

    /// When `kind` can be used again: the whole backend's limit, and with `model` also that model's
    /// scope; nil when it can be used now. A signed-out backend is never usable (`.distantFuture`),
    /// so routing, fallback and backups pass it over like a used-up one.
    func limitedUntil(_ kind: BackendKind, model: String? = nil, now: Date = Date()) -> Date? {
        if unavailableReason(kind) != nil { return .distantFuture }
        return usageLimitedUntil(kind, model: model, now: now)
    }

    /// `limitedUntil` for usage limits only, without a signed-out backend's `.distantFuture`.
    func usageLimitedUntil(_ kind: BackendKind, model: String? = nil, now: Date = Date()) -> Date? {
        lock.withLock {
            var dates: [Date] = []
            if let date = limitedUntil[kind] {
                if date > now { dates.append(date) } else { limitedUntil[kind] = nil }
            }
            if let model, let scope = Self.modelScope(kind, model: model) {
                let key = ScopeKey(backend: kind, scope: scope)
                if let date = scopeLimitedUntil[key] {
                    if date > now { dates.append(date) } else { scopeLimitedUntil[key] = nil }
                }
            }
            return dates.max()
        }
    }

    /// Model scopes at their limit now, soonest reset first.
    func scopeLimits(now: Date = Date()) -> [ScopeLimit] {
        lock.withLock {
            scopeLimitedUntil = scopeLimitedUntil.filter { $0.value > now }
            return scopeLimitedUntil.map { ScopeLimit(backend: $0.key.backend, scope: $0.key.scope, until: $0.value) }
                .sorted { ($0.until, $0.backend.rawValue, $0.scope) < ($1.until, $1.backend.rawValue, $1.scope) }
        }
    }

    /// Clears a backend's limits, its model scopes' too, or every limit.
    func clear(_ kind: BackendKind? = nil) {
        lock.withLock {
            if let kind {
                limitedUntil[kind] = nil
                scopeLimitedUntil = scopeLimitedUntil.filter { $0.key.backend != kind }
            } else {
                limitedUntil.removeAll()
                scopeLimitedUntil.removeAll()
            }
        }
    }
}

enum BackendFallback {
    /// The backup to use when the backend and model a run is on reached its limit: the first entry
    /// in the chain that isn't the one being left and whose backend and model aren't limited too,
    /// or nil to stay put. Every hop marks what it leaves as limited, so a run can't go round in
    /// circles. `model` resolves an entry's "" (default) model. Unattended Home runs skip Copilot
    /// Remote, whose tools Cantrip can't check per action.
    static func next(after current: BackendKind, model currentModel: String, chain: [FallbackEntry], homeRun: Bool,
                     model resolve: (BackendKind, String) -> String = { $1 },
                     tracker: BackendLimitTracker = .shared, now: Date = Date()) -> FallbackEntry? {
        chain.first { entry in
            guard let kind = entry.kind else { return false }
            let model = resolve(kind, entry.model)
            return !(kind == current && model == currentModel)
                && tracker.limitedUntil(kind, model: model, now: now) == nil
                && !(homeRun && kind == .copilotRemote)
        }
    }

    /// The backup backend for `primary` when backups are named by backend only.
    static func target(for primary: BackendKind, chain: [String], homeRun: Bool,
                       tracker: BackendLimitTracker = .shared, now: Date = Date()) -> BackendKind? {
        next(after: primary, model: "", chain: chain.map { FallbackEntry(backend: $0) }, homeRun: homeRun,
             tracker: tracker, now: now)?.kind
    }

    static func untilLabel(_ date: Date, now: Date = Date()) -> String {
        if date == .distantFuture { return "you sign in again" }
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDate(date, inSameDayAs: now) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
