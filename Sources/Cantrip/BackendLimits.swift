import Foundation

/// Recognizes a backend error that means the account's plan is used up for now (Claude's
/// 5-hour and weekly limits, Copilot's premium requests, Codex and Gemini quotas), as opposed
/// to a failure retrying the same backend could fix.
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
/// straight to the fallback backend instead of failing first. Kept in memory only: after a
/// relaunch each backend is tried again.
final class BackendLimitTracker {
    static let shared = BackendLimitTracker()
    /// How long a backend is skipped when its error doesn't say when the limit lifts.
    static var defaultCooldown: TimeInterval = 60 * 60

    private let lock = NSLock()
    private var limitedUntil: [BackendKind: Date] = [:]

    func markLimited(_ kind: BackendKind, message: String, now: Date = Date()) {
        var until = UsageLimit.resetDate(in: message, now: now)
        if until == nil, kind == .claudeCode, let limit = UsageTracker.shared.rateLimit,
           limit.status == "rejected", limit.resetsAt > now {
            until = limit.resetsAt
        }
        let date = until ?? now.addingTimeInterval(Self.defaultCooldown)
        lock.withLock { limitedUntil[kind] = date }
        Log.write("usage-limit: \(kind.rawValue) limited until \(ISODate.string(from: date))")
    }

    func limitedUntil(_ kind: BackendKind, now: Date = Date()) -> Date? {
        lock.withLock {
            guard let date = limitedUntil[kind] else { return nil }
            guard date > now else { limitedUntil[kind] = nil; return nil }
            return date
        }
    }

    func clear(_ kind: BackendKind? = nil) {
        lock.withLock {
            if let kind { limitedUntil[kind] = nil } else { limitedUntil.removeAll() }
        }
    }
}

enum BackendFallback {
    /// The backend to use instead of `primary` when it's at its limit, or nil to stay put.
    /// Unattended Home runs never move to a backend Cantrip can't check per action.
    static func target(for primary: BackendKind, configured: String, homeRun: Bool,
                       tracker: BackendLimitTracker = .shared, now: Date = Date()) -> BackendKind? {
        guard let fallback = BackendKind(rawValue: configured), fallback != primary,
              tracker.limitedUntil(fallback, now: now) == nil else { return nil }
        if homeRun, [.codex, .copilotRemote].contains(fallback) { return nil }
        return fallback
    }

    static func untilLabel(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDate(date, inSameDayAs: now) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
