import Foundation

/// Antigravity's limits for the signed-in account: per model group (Gemini, Claude and GPT,
/// Gemini 4 Argon) a weekly and a 5-hour window, with their reset times.
struct AntigravityAccountUsage: Codable, Equatable {
    let groups: [AntigravityLimitGroup]

    /// The window closest to its limit, for one-line summaries.
    var primary: (group: AntigravityLimitGroup, bucket: AntigravityLimitBucket)? {
        groups.flatMap { group in group.buckets.map { (group: group, bucket: $0) } }
            .min { $0.bucket.remainingPercent < $1.bucket.remainingPercent }
    }

    /// The group a model's requests count against: Claude and GPT models share one, Argon has
    /// its own, everything else (Auto, Flash, Pro) is Gemini.
    func group(forModel model: String) -> AntigravityLimitGroup? {
        let slug = model.lowercased()
        if slug.hasPrefix("claude") || slug.hasPrefix("gpt") {
            return groups.first { $0.name.lowercased().contains("claude") }
        }
        if slug.contains("argon"), let argon = groups.first(where: { $0.name.lowercased().contains("argon") }) {
            return argon
        }
        return groups.first { $0.name.lowercased().hasPrefix("gemini models") }
            ?? groups.first { $0.name.lowercased().contains("gemini") && !$0.name.lowercased().contains("argon") }
    }
}

struct AntigravityLimitGroup: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    /// Which models share the group, as Antigravity words it ("Gemini Flash, Gemini Pro").
    let models: String?
    let buckets: [AntigravityLimitBucket]
}

struct AntigravityLimitBucket: Codable, Equatable, Identifiable {
    /// `gemini-weekly`, `gemini-5h`, ...
    let id: String
    let name: String
    /// `weekly` or `5h`.
    let window: String?
    let remainingPercent: Double
    let resetsAt: String?

    var percentUsed: Double { min(100, max(0, 100 - remainingPercent)) }
    var isExhausted: Bool { remainingPercent <= 0 }

    var title: String {
        switch window {
        case "weekly": return "Weekly limit"
        case "5h", "five_hour": return "5-hour limit"
        default: return name
        }
    }

    var summary: String {
        let used = String(format: "%.0f%% used", percentUsed)
        guard let reset = resetsAt.flatMap({ ISODate.date(from: $0) }) else { return used }
        let style: Date.FormatStyle = Calendar.current.isDateInToday(reset)
            ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
        return "\(used) · resets \(reset.formatted(style))"
    }
}

enum AntigravityUsageError: String, Error, LocalizedError, Codable {
    case unavailable, response, timeout

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Could not start the Antigravity CLI. Check its path in Settings."
        case .response: return "Antigravity didn't return its limits. Run `agy` once to sign in, then check again."
        case .timeout: return "Antigravity's limits didn't load in time. Try again in a moment."
        }
    }
}

/// Reads the limits the way Antigravity's own `/usage` does: `agy -p /usage` is answered by the
/// CLI itself, without a model call or a conversation, so checking spends no quota.
enum AntigravityUsageFetcher {
    static func fetch(command: String, completion: @escaping (Result<AntigravityAccountUsage, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = ToolPath.value(inherited: environment["PATH"])
            environment["NO_COLOR"] = "1"
            let result: ProcessRunner.Result
            do {
                result = try ProcessRunner.run(command, ["-p", "/usage", "--output-format", "json"],
                                               environment: environment,
                                               directory: FileManager.default.homeDirectoryForCurrentUser,
                                               errorOutput: .discard, timeout: 30)
            } catch {
                return completion(.failure(AntigravityUsageError.unavailable))
            }
            if result.timedOut { return completion(.failure(AntigravityUsageError.timeout)) }
            guard result.succeeded, let usage = parse(result.output) else {
                return completion(.failure(AntigravityUsageError.response))
            }
            completion(.success(usage))
        }
    }

    /// `/usage` as JSON: `command.data.groups[]`, each with `buckets[]` of `remaining_fraction`
    /// (0-1) and `reset_time`.
    static func parse(_ data: Data) -> AntigravityAccountUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? [String: Any],
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]] else { return nil }
        let parsed = groups.compactMap { group -> AntigravityLimitGroup? in
            guard let name = group["name"] as? String else { return nil }
            let buckets = (group["buckets"] as? [[String: Any]] ?? []).compactMap { bucket -> AntigravityLimitBucket? in
                guard let fraction = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue else { return nil }
                let reset = (bucket["reset_time"] as? String).flatMap { ISODate.date(from: $0) }.map(ISODate.string(from:))
                return AntigravityLimitBucket(
                    id: bucket["id"] as? String ?? UUID().uuidString,
                    name: bucket["name"] as? String ?? name,
                    window: bucket["window"] as? String,
                    remainingPercent: min(100, max(0, fraction * 100)),
                    resetsAt: reset)
            }
            guard !buckets.isEmpty else { return nil }
            let models = (group["description"] as? String)?
                .replacingOccurrences(of: "Models within this group: ", with: "")
            return AntigravityLimitGroup(name: name, models: models, buckets: buckets)
        }
        return parsed.isEmpty ? nil : AntigravityAccountUsage(groups: parsed)
    }
}
