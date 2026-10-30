import Foundation

/// When memory consolidation is due, how failures back off, and what Cantrip Home shows while it
/// keeps failing. `lastSuccess` is stamped only after a run exits successfully.
struct ConsolidationState: Equatable {
    var lastSuccess: Date?
    var failures = 0
    var lastAttempt: Date?
    var lastError: String?
    var nextRetry: Date?
    var lastBackend: String?

    /// A successful run covers this long.
    static let interval: TimeInterval = 20 * 3600
    static let firstRetry: TimeInterval = 30 * 60
    static let maximumRetry: TimeInterval = 12 * 3600

    /// 30 minutes after the first failure, doubling to at most 12 hours.
    static func backoff(afterFailures failures: Int) -> TimeInterval {
        let doublings = Double(max(0, min(failures - 1, 16)))
        return min(firstRetry * pow(2, doublings), maximumRetry)
    }

    func isDue(now: Date) -> Bool {
        if let lastSuccess, now.timeIntervalSince(lastSuccess) <= Self.interval { return false }
        if let nextRetry, now < nextRetry { return false }
        return true
    }

    mutating func recordSuccess(backend: String, at now: Date) {
        lastSuccess = now
        lastAttempt = now
        lastBackend = backend
        failures = 0
        lastError = nil
        nextRetry = nil
    }

    mutating func recordFailure(_ error: String, at now: Date) {
        failures += 1
        lastAttempt = now
        lastError = error
        nextRetry = now.addingTimeInterval(Self.backoff(afterFailures: failures))
    }

    /// The warning Cantrip Home shows above its tasks while consolidation keeps failing.
    func warning(memoryEnabled: Bool, timeZone: TimeZone = .current) -> String? {
        guard memoryEnabled, failures > 0, let lastError else { return nil }
        let attempts = failures == 1 ? "1 attempt" : "\(failures) attempts"
        var text = "Memory consolidation failed (\(attempts)): \(Self.clipped(lastError, to: 300))"
        if let nextRetry {
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            text += " Next try \(formatter.string(from: nextRetry))."
        }
        return text
    }

    static func clipped(_ text: String, to limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    // MARK: Persistence

    enum Key {
        static let lastSuccess = "lastConsolidation"
        static let failures = "consolidationFailures"
        static let lastAttempt = "consolidationLastAttempt"
        static let lastError = "consolidationLastError"
        static let nextRetry = "consolidationNextRetry"
        static let lastBackend = "consolidationLastBackend"
        /// Set once `lastConsolidation` means "last success". Before, it was written as each run
        /// started, so a stamp from an older build may record a run that failed.
        static let successStamp = "consolidationStampsSuccess"
    }

    /// Drops a `lastConsolidation` written by a build that stamped runs as they started, so the
    /// first check after updating runs (all of those runs may have failed). Runs once.
    static func migrateLegacyStamp(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: Key.successStamp) else { return }
        defaults.removeObject(forKey: Key.lastSuccess)
        defaults.set(true, forKey: Key.successStamp)
    }

    static func load(from defaults: UserDefaults) -> ConsolidationState {
        ConsolidationState(
            lastSuccess: defaults.object(forKey: Key.lastSuccess) as? Date,
            failures: defaults.integer(forKey: Key.failures),
            lastAttempt: defaults.object(forKey: Key.lastAttempt) as? Date,
            lastError: defaults.string(forKey: Key.lastError),
            nextRetry: defaults.object(forKey: Key.nextRetry) as? Date,
            lastBackend: defaults.string(forKey: Key.lastBackend)
        )
    }

    func save(to defaults: UserDefaults) {
        func put(_ value: Any?, _ key: String) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        put(lastSuccess, Key.lastSuccess)
        put(failures > 0 ? failures : nil, Key.failures)
        put(lastAttempt, Key.lastAttempt)
        put(lastError, Key.lastError)
        put(nextRetry, Key.nextRetry)
        put(lastBackend, Key.lastBackend)
        defaults.set(true, forKey: Key.successStamp)
    }
}

/// A CLI that can run the consolidation prompt headlessly.
enum ConsolidationBackend: Equatable {
    case antigravity(path: String, model: String?)
    case claude(path: String)
    case copilot(path: String, model: String?)

    var name: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .claude: return "Claude Code"
        case .copilot: return "Copilot"
        }
    }

    var executable: String {
        switch self {
        case .antigravity(let path, _), .claude(let path), .copilot(let path, _): return path
        }
    }

    /// Claude Code stays first (a cheap Haiku run, as before); Copilot is the fallback. When
    /// Antigravity is available and preferred, it runs first with Gemini 3.8 Flash; otherwise it
    /// serves as a fallback after Claude Code and Copilot.
    static func candidates(
        antigravity: String? = nil,
        antigravityModels: [String] = [],
        preferAntigravity: Bool = false,
        claude: String?,
        copilot: String?,
        copilotModels: [String]
    ) -> [Self] {
        var result: [Self] = []
        let agyCandidate = antigravity.map {
            Self.antigravity(path: $0, model: preferredAntigravityModel(antigravityModels))
        }
        if preferAntigravity, let agyCandidate {
            result.append(agyCandidate)
        }
        if let claude { result.append(.claude(path: claude)) }
        if let copilot { result.append(.copilot(path: copilot, model: preferredCopilotModel(copilotModels))) }
        if !preferAntigravity, let agyCandidate {
            result.append(agyCandidate)
        }
        return result
    }

    /// Picks Gemini 3.8 Flash (or the newest Flash model in the Antigravity catalog) for fast,
    /// low-cost background memory consolidation instead of a heavy frontier model like Argon.
    static func preferredAntigravityModel(_ ids: [String]) -> String {
        if ids.contains("gemini-3.8-flash-medium") { return "gemini-3.8-flash-medium" }
        if ids.contains("gemini-3.8-flash-high") { return "gemini-3.8-flash-high" }
        if let flash38 = ids.first(where: { $0.lowercased().hasPrefix("gemini-3.8-flash") }) {
            return flash38
        }
        let flash = ids.filter { $0.lowercased().contains("flash") }
        if let best = flash.max(by: { versionParts($0).lexicographicallyPrecedes(versionParts($1)) }) {
            return best
        }
        return "gemini-3.8-flash-medium"
    }

    /// The newest Haiku in the Copilot catalog, matching Claude's `haiku` alias; nil keeps the
    /// CLI's default model.
    static func preferredCopilotModel(_ ids: [String]) -> String? {
        let haiku = ids.filter { $0.lowercased().contains("haiku") }
        return haiku.max { versionParts($0).lexicographicallyPrecedes(versionParts($1)) }
    }

    private static func versionParts(_ id: String) -> [Int] {
        id.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// The same permission policy for every CLI: with Allow actions on, every tool runs without
    /// asking (Antigravity `--dangerously-skip-permissions`, Claude `bypassPermissions`, Copilot
    /// `--allow-all-tools`); otherwise only file edits are approved and commands are refused
    /// (Antigravity `--mode accept-edits`, Claude `acceptEdits`, Copilot write-only).
    func arguments(prompt: String, allowActions: Bool) -> [String] {
        switch self {
        case .antigravity(_, let model):
            var arguments = ["-p", prompt]
            if let model, !model.isEmpty { arguments += ["--model", model] }
            arguments += allowActions
                ? ["--dangerously-skip-permissions"]
                : ["--mode", "accept-edits"]
            return arguments
        case .claude:
            return ["-p", prompt, "--model", "haiku",
                    "--permission-mode", allowActions ? "bypassPermissions" : "acceptEdits"]
        case .copilot(_, let model):
            var arguments = ["-p", prompt, "--silent", "--no-color", "--no-ask-user"]
            if let model { arguments += ["--model", model] }
            arguments += allowActions
                ? ["--allow-all-tools"]
                : ["--allow-tool", "write", "--deny-tool", "shell"]
            return arguments
        }
    }

    /// Whether a failed run means this CLI can't sign in, so the next backend should run instead.
    static func isAuthenticationFailure(_ output: String) -> Bool {
        let text = output.lowercased()
        return [
            "failed to authenticate", "oauth session expired", "oauth token", "invalid api key",
            "please run /login", "run /login", "not logged in", "authentication_error",
            "authentication failed", "unauthorized",
        ].contains { text.contains($0) }
    }
}

/// How one consolidation attempt went across the candidate backends.
struct ConsolidationOutcome: Equatable {
    var succeeded: Bool
    var backend: String?
    var summary: String
    /// What went wrong, naming each backend that was tried.
    var error: String?
}

enum ConsolidationAttempt {
    struct RunResult: Equatable {
        var status: Int32
        var output: String
        /// Set when the CLI couldn't be started (a timeout is a normal failure with output).
        var launchError: String? = nil

        var succeeded: Bool { launchError == nil && status == 0 }
    }

    /// Runs the candidates in order. A backend that can't start or can't sign in hands over to the
    /// next one; any other failure ends the attempt (it may have edited notes already).
    static func execute(_ candidates: [ConsolidationBackend],
                        run: (ConsolidationBackend) -> RunResult) -> ConsolidationOutcome {
        guard !candidates.isEmpty else {
            return ConsolidationOutcome(
                succeeded: false, backend: nil, summary: "",
                error: "Neither the Claude Code CLI nor the GitHub Copilot CLI was found. Install one, or set its path in Settings."
            )
        }
        var problems: [String] = []
        for (index, backend) in candidates.enumerated() {
            let result = run(backend)
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.succeeded {
                return ConsolidationOutcome(succeeded: true, backend: backend.name, summary: output, error: nil)
            }
            let detail = result.launchError
                ?? (output.isEmpty ? "exited with status \(result.status)" : ConsolidationState.clipped(output, to: 200))
            let unavailable = result.launchError != nil || isUnavailable(result)
            guard unavailable, index < candidates.count - 1 else {
                problems.append("\(backend.name): \(detail)")
                if unavailable, case .claude = backend {
                    problems.append("the GitHub Copilot CLI wasn't found to fall back to")
                }
                break
            }
            problems.append("\(backend.name) can't run (\(detail))")
        }
        return ConsolidationOutcome(succeeded: false, backend: nil, summary: "",
                                    error: problems.joined(separator: "; ") + ".")
    }

    private static func isUnavailable(_ result: RunResult) -> Bool {
        ConsolidationBackend.isAuthenticationFailure(result.output)
    }
}
