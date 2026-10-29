import Foundation

/// Claude's plan limits for the signed-in Claude Code account: the 5-hour session and weekly
/// windows (and per-model weekly limits when the plan has them), with their reset times.
struct ClaudeAccountUsage: Codable, Equatable {
    let plan: String?
    let windows: [ClaudeLimitWindow]

    /// The window closest to its limit, for one-line summaries.
    var primary: ClaudeLimitWindow? { windows.max { $0.percentUsed < $1.percentUsed } }
}

struct ClaudeLimitWindow: Codable, Equatable, Identifiable {
    /// `five_hour`, `seven_day`, `seven_day_opus` or `seven_day_sonnet`.
    let id: String
    let percentUsed: Double
    let resetsAt: String?
    /// The API's own reading: `normal`, `warning` or `critical`, when it gives one.
    let severity: String?
    /// Set while the window blocks new requests.
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

    var isExhausted: Bool { lockedReason != nil || percentUsed >= 100 }

    var summary: String {
        let used = String(format: "%.0f%% used", min(100, max(0, percentUsed)))
        guard let reset = resetsAt.flatMap({ ISODate.date(from: $0) }) else { return used }
        let style: Date.FormatStyle = Calendar.current.isDateInToday(reset)
            ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
        return "\(used) · resets \(reset.formatted(style))"
    }
}

enum ClaudeUsageError: String, Error, LocalizedError, Codable {
    case signedOut, expired, response, timeout

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Claude Code isn't signed in on the Mac."
        case .expired: return "Claude Code's sign-in needs a refresh: run a Claude tab once, then check again."
        case .response: return "Claude didn't return its usage limits. Check the Mac's connection and try again."
        case .timeout: return "Claude's usage limits didn't load in time. Try again in a moment."
        }
    }
}

/// Reads Claude's limits the way Claude Code's own `/usage` does: its OAuth sign-in from the login
/// keychain (read only; never refreshed, which would rotate Claude Code's token) and one request.
enum ClaudeUsageFetcher {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let windowIDs = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

    struct Credentials: Equatable {
        let accessToken: String
        let expiresAt: Date?
        let plan: String?
    }

    static func fetch(completion: @escaping (Result<ClaudeAccountUsage, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let credentials = readCredentials() else { return completion(.failure(ClaudeUsageError.signedOut)) }
            if let expiry = credentials.expiresAt, expiry <= Date() {
                return completion(.failure(ClaudeUsageError.expired))
            }
            var request = URLRequest(url: endpoint, timeoutInterval: 15)
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error as? URLError, error.code == .timedOut {
                    return completion(.failure(ClaudeUsageError.timeout))
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status != 401 else { return completion(.failure(ClaudeUsageError.expired)) }
                guard status == 200, let data, let usage = parse(data, plan: credentials.plan) else {
                    return completion(.failure(ClaudeUsageError.response))
                }
                completion(.success(usage))
            }.resume()
        }
    }

    /// Claude Code's sign-in from the login keychain, via `security` (as Claude Code reads it).
    static func readCredentials() -> Credentials? {
        guard let run = try? ProcessRunner.run(
            "/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
            errorOutput: .discard, timeout: 10
        ), run.status == 0, !run.timedOut else { return nil }
        return credentials(from: run.output)
    }

    static func credentials(from data: Data) -> Credentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiry = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token, expiresAt: expiry, plan: oauth["subscriptionType"] as? String)
    }

    /// The usage reply's windows, with the severity its `limits` list gives each one.
    static func parse(_ data: Data, plan: String?) -> ClaudeAccountUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var severity: [String: String] = [:]
        for limit in object["limits"] as? [[String: Any]] ?? [] {
            guard let kind = limit["kind"] as? String, let level = limit["severity"] as? String else { continue }
            let id = kind == "session" ? "five_hour" : kind == "weekly_all" ? "seven_day"
                : kind.hasPrefix("weekly_") ? "seven_day_" + kind.dropFirst("weekly_".count) : kind
            severity[id] = level
        }
        let windows = windowIDs.compactMap { id -> ClaudeLimitWindow? in
            guard let window = object[id] as? [String: Any],
                  let percent = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (window["resets_at"] as? String).flatMap { ISODate.date(from: $0) }.map(ISODate.string(from:))
            return ClaudeLimitWindow(id: id, percentUsed: percent, resetsAt: reset, severity: severity[id],
                                     lockedReason: window["locked_reason"] as? String)
        }
        guard !windows.isEmpty else { return nil }
        return ClaudeAccountUsage(plan: plan, windows: windows)
    }
}
