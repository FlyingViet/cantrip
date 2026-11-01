import Foundation

/// Codex's limits for the signed-in ChatGPT account, from the app server's
/// `account/rateLimits/read` (no quota spent): each limit's windows (a 5-hour and a weekly one
/// on paid plans, a 30-day one on the free plan), how much is used and when each resets.
struct CodexAccountUsage: Codable, Equatable {
    var plan: String?
    var windows: [CodexLimitWindow]

    /// The window closest to its limit, for one-line summaries.
    var primary: CodexLimitWindow? { windows.max { $0.usedPercent < $1.usedPercent } }
}

struct CodexLimitWindow: Codable, Equatable, Identifiable {
    /// "codex/primary", "codex/secondary", or another limit's ID and slot.
    let id: String
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: String?
    /// A limit other than the main Codex one (a model's own quota), by its name.
    var limitName: String?

    var isExhausted: Bool { usedPercent >= 100 }

    var title: String {
        let window: String
        switch windowMinutes {
        case 300?: window = "5-hour limit"
        case 10_080?: window = "Weekly limit"
        case let minutes? where minutes >= 40_000: window = "Monthly limit"
        case let minutes? where minutes % 1_440 == 0: window = "\(minutes / 1_440)-day limit"
        case let minutes? where minutes % 60 == 0: window = "\(minutes / 60)-hour limit"
        default: window = "Usage limit"
        }
        return limitName.map { "\($0) \(window.lowercased())" } ?? window
    }
}

struct CodexUsageState: Codable, Equatable {
    var account: CodexAccountUsage?
    var checkedAt: String?
    var error: String?

    /// Older than ten minutes, or a window has reset since it was read.
    func isStale(at now: Date = Date()) -> Bool {
        guard account != nil, let checked = copilotDate(checkedAt), now.timeIntervalSince(checked) < 600 else { return true }
        return account?.windows.contains { copilotDate($0.resetsAt).map { now >= $0 } ?? false } ?? true
    }
}

enum CodexUsageError: String, Error, LocalizedError {
    case unavailable, response

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Couldn't start the Codex CLI. Check its path in Settings."
        case .response: return "Codex didn't return its limits. Run `codex login`, then check again."
        }
    }
}

enum CodexUsage {
    /// `account/rateLimits/read`'s result or an `account/rateLimits/updated` snapshot as windows:
    /// every limit in `rateLimitsByLimitId` (else the single `rateLimits`), primary and secondary.
    static func parse(_ result: [String: Any]) -> CodexAccountUsage? {
        var snapshots: [(String, [String: Any])] = []
        if let byID = result["rateLimitsByLimitId"] as? [String: [String: Any]], !byID.isEmpty {
            snapshots = byID.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        } else if let single = result["rateLimits"] as? [String: Any] {
            snapshots = [(single["limitId"] as? String ?? "codex", single)]
        } else if result["primary"] != nil || result["secondary"] != nil {
            snapshots = [(result["limitId"] as? String ?? "codex", result)]
        }
        var plan: String?
        var windows: [CodexLimitWindow] = []
        for (id, snapshot) in snapshots {
            plan = plan ?? snapshot["planType"] as? String
            let name = id == "codex" ? nil : (snapshot["limitName"] as? String ?? id)
            for slot in ["primary", "secondary"] {
                guard let window = snapshot[slot] as? [String: Any],
                      let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { continue }
                let reset = (window["resetsAt"] as? NSNumber).map { ISODate.string(from: Date(timeIntervalSince1970: $0.doubleValue)) }
                windows.append(CodexLimitWindow(id: "\(id)/\(slot)", usedPercent: min(100, max(0, used)),
                                                windowMinutes: (window["windowDurationMins"] as? NSNumber)?.intValue,
                                                resetsAt: reset, limitName: name))
            }
        }
        return windows.isEmpty ? nil : CodexAccountUsage(plan: plan, windows: windows)
    }

    /// When a full window lifts (the latest reset among full windows), from a rate-limit snapshot.
    static func limitedUntil(_ rateLimits: [String: Any]?) -> Date? {
        guard let rateLimits, let account = parse(rateLimits) else { return nil }
        return account.windows.filter(\.isExhausted).compactMap { copilotDate($0.resetsAt) }.max()
    }

    /// Reads the limits through a short-lived app server.
    static func fetch(executable: String, completion: @escaping (Result<CodexAccountUsage, Error>) -> Void) {
        Task.detached(priority: .utility) {
            do {
                let result = try await CodexAppServer.withServer(executable: executable) { server in
                    try await server.request("account/rateLimits/read", [:], timeout: 30)
                }
                guard let usage = parse(result) else { return completion(.failure(CodexUsageError.response)) }
                completion(.success(usage))
            } catch {
                completion(.failure(error is CodexAppServer.Failure ? CodexUsageError.response : CodexUsageError.unavailable))
            }
        }
    }

    /// A tab's live `account/rateLimits/updated`: refreshes the usage screen and marks Codex
    /// limited as soon as a window fills, before Codex refuses a message.
    static func record(rateLimits: [String: Any]) {
        guard let account = parse(["rateLimits": rateLimits]) else { return }
        DispatchQueue.main.async { UsageTracker.shared.applyCodex(.success(account), merging: true) }
    }
}
