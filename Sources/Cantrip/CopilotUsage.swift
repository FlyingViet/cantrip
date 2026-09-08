import Foundation

struct CopilotUsageSnapshot: Codable {
    var account: CopilotAccountUsage?
    var checkedAt: String?
    var isRefreshing = false
    var error: String?

    func isStale(at now: Date = Date()) -> Bool {
        guard account != nil, error == nil, let checked = copilotDate(checkedAt),
              now.timeIntervalSince(checked) < 300 else { return true }
        return account?.buckets.contains {
            if let observed = copilotDate($0.observedAt), now.timeIntervalSince(observed) > 600 { return true }
            if let reset = copilotDate($0.resetAt), now >= reset { return true }
            return false
        } ?? true
    }

    var summary: String? {
        guard let bucket = account?.primary else { return nil }
        return (isStale() ? "Last known: " : "") + bucket.summary
    }
}

struct CopilotAccountUsage: Codable {
    let login: String?
    let plan: String?
    let buckets: [CopilotQuotaBucket]
    var primary: CopilotQuotaBucket? { buckets.first { $0.id == "premium_interactions" } ?? buckets.first }
}

struct CopilotQuotaBucket: Codable, Identifiable {
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
        return percentageSummary ?? "\(title): remaining amount unavailable"
    }

    var amountSummary: String? {
        guard let ratio = amountRatio(), let unit else { return nil }
        return "\(ratio) \(unit) remaining"
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
              remaining.isFinite, entitlement.isFinite, remaining >= 0, entitlement >= 0 else { return nil }
        return "\(copilotAmount(remaining, compact: compact, locale: locale)) / \(copilotAmount(entitlement, compact: compact, locale: locale))"
    }

    var percentageSummary: String? {
        guard let remainingPercent, remainingPercent.isFinite else { return nil }
        return String(format: "%.1f%% used / %.1f%% remaining", 100 - remainingPercent, remainingPercent)
    }
}

func copilotAmount(_ amount: Double, compact: Bool = false, locale: Locale = .current) -> String {
    let format = FloatingPointFormatStyle<Double>.number.locale(locale)
    // Do not round a nearly exhausted balance up, or a small positive balance down to zero.
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
