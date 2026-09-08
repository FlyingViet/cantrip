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
