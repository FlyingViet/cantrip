import CryptoKit
import Foundation

/// The gate's decision for one request.
struct PrivacyDecision: Equatable {
    enum Source: String, Codable { case override, sticky, rule, classifier, cache, defaultRoute, offline }
    /// Nil when the classifier was needed and didn't answer: never treated as cloud.
    var route: PrivacyRoute?
    var source: Source
    var rule: String?
    var reason: String
    var hits: [String: Int] = [:]
    var probabilities: [PrivacyRoute: Double]?
    var rulesMs = 0
    var classifierMs: Int?
    var classifierError: String?
    /// The decision before "stays local" applied.
    var underlying: PrivacyRoute?
    /// The run's own route, when it has one.
    var override: PrivacyRouteOverride = .auto
}

/// What enforce mode does (or would do, when observing) with a decision.
enum PrivacyEnforcement: String, Codable {
    case local
    /// Cloud, as chosen, with every tool (an explicit "with private tools" route).
    case cloud
    /// Cloud without the private MCP servers and folders.
    case cloudRestricted
    case ask
    case hold
    case cancel

    static func of(_ decision: PrivacyDecision, kind: PrivacyGateRequest.Kind, settings: PrivacyGateSettings) -> Self {
        switch decision.route {
        case .local: return .local
        case .cloud: return decision.override == .cloudWithPrivateTools ? .cloud : .cloudRestricted
        case .redactApprove: return .ask
        case nil:
            if kind == .homeChat { return settings.offline.chat == .ask ? .ask : .cancel }
            return settings.offline.tasks == .hold ? .hold : .cancel
        }
    }
}

/// The route shown on a turn (persisted with the user's message, sent to every client).
struct PrivacyBadge: Codable, Equatable {
    /// local, cloud, redactApprove or offline.
    var route: String
    var mode: String
    /// Enforce mode acted on it; false while observing.
    var applied: Bool
    /// Short text for the badge.
    var label: String
    /// The reason, rule or classifier probabilities and timing.
    var detail: String
}

/// One line of the decision log. Never holds prompt text or matched values.
struct PrivacyDecisionRecord: Codable, Equatable {
    var at: Date
    var kind: String
    var task: String?
    var taskTitle: String?
    var mode: String
    var route: String
    var source: String
    var rule: String?
    var reason: String
    var hits: [String: Int]
    var pLocal: Double?
    var pCloud: Double?
    var pRedact: Double?
    var rulesMs: Int
    var classifierMs: Int?
    var classifierError: String?
    var totalMs: Int
    var backend: String
    var privateTools: [String]
    var enforce: String
    var applied: Bool
    var promptChars: Int
    var underlying: String?
}

/// What a cloud run in enforce mode may not touch. Backends read it before each tool call.
struct PrivacyCloudRestriction: Equatable {
    var excludedServers: Set<String>
    var deniedFolders: [String]

    init(_ runs: PrivacyCloudRuns) {
        excludedServers = Set(runs.excludeMCP.map { $0.lowercased() })
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        deniedFolders = runs.denyReads.map {
            ($0.hasPrefix("~") ? home + $0.dropFirst() : $0).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        }
    }

    /// Why the call is refused, or nil.
    func denial(for request: CantripHomeActionRequest) -> String? {
        if request.kind == .mcp, let server = request.server?.lowercased(),
           excludedServers.contains(where: { server == $0 || server.hasPrefix($0 + "-") || server.hasPrefix($0 + "_") }) {
            return "Privacy Gate: this run goes to a cloud model, so it can't use the \(server) tools. Ask the user to run it locally."
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var texts = request.paths.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        if !request.command.isEmpty { texts.append(request.command.replacingOccurrences(of: "~/", with: home + "/")) }
        for folder in deniedFolders where texts.contains(where: { $0 == folder || $0.contains(folder + "/") || $0.hasSuffix(folder) }) {
            let shown = folder.replacingOccurrences(of: home, with: "~")
            return "Privacy Gate: this run goes to a cloud model, so it can't read \(shown)."
        }
        return nil
    }
}

/// Each backend's restriction for its current run, read by `AgentPolicyGate`.
enum PrivacyRunRestrictions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byBackend: [ObjectIdentifier: PrivacyCloudRestriction] = [:]

    static func set(_ restriction: PrivacyCloudRestriction?, for backend: AnyObject) {
        lock.withLock { byBackend[ObjectIdentifier(backend)] = restriction }
    }

    static func restriction(for backend: AnyObject) -> PrivacyCloudRestriction? {
        lock.withLock { byBackend[ObjectIdentifier(backend)] }
    }
}

/// Decides, records and remembers. Observe mode only records; enforce mode's routing lives in
/// ChatSession, which asks `decide` first.
final class PrivacyGate: @unchecked Sendable {
    static let shared = PrivacyGate()

    var classifier: PrivacyClassifier
    var directory: URL
    /// Private Local's settings, for a classifier without its own address.
    var privateLocal: () -> PrivateLocalConfiguration? = {
        guard let data = UserDefaults.standard.data(forKey: "privateLocalConfiguration") else { return nil }
        return try? JSONDecoder().decode(PrivateLocalConfiguration.self, from: data)
    }
    var policy: () -> AgentPolicyDocument = { AgentPolicyStore.shared.current() }

    private let lock = NSLock()
    private var cache: [String: (classification: PrivacyClassification, at: Date)] = [:]
    /// Home conversations that turned private, with the turns they stay local for.
    private var sticky: [String: Int] = [:]
    private var loadedState = false

    init(classifier: PrivacyClassifier = PrivacyClassifier(), directory: URL = CantripPaths.cache("privacy")) {
        self.classifier = classifier
        self.directory = directory
    }

    var logURL: URL { directory.appendingPathComponent("decisions.jsonl") }
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    static let logLimit = 10_000_000

    var settings: PrivacyGateSettings { policy().privacyGate }

    // MARK: Deciding

    /// The text the classifier reads: the request, then the latest earlier turn.
    static func classifierInput(_ request: PrivacyGateRequest, limit: Int) -> String {
        let budget = max(200, limit)
        let ask = String(request.request.trimmingCharacters(in: .whitespacesAndNewlines).prefix(budget * 2 / 3))
        let earlier = request.earlier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !earlier.isEmpty else { return String(ask.prefix(budget)) }
        let room = budget - ask.count - 40
        guard room > 100 else { return ask }
        return ask + "\n\n(Earlier in this conversation: " + String(earlier.suffix(room)) + ")"
    }

    /// `skipsClassifierWhenFixed`: enforce mode doesn't wait on the classifier when the run's own
    /// route or "stays local" decides anyway; observe mode asks it to collect the data.
    func decide(_ request: PrivacyGateRequest, settings: PrivacyGateSettings? = nil,
                skipsClassifierWhenFixed: Bool = false) async -> PrivacyDecision {
        let settings = settings ?? self.settings
        let terms = policy().privateTerms
        let outcome = await Task.detached(priority: .userInitiated) {
            PrivacyRules.evaluate(request, settings: settings, privateTerms: terms)
        }.value
        let override = settings.override(forTask: request.kind == .homeTask ? request.taskID : nil)
        let isSticky = request.kind == .homeChat && settings.stickyTurns > 0 && isStickyLocal(request.conversationKey)
        var decision = PrivacyDecision(route: nil, source: .rule, rule: outcome.rule?.id, reason: outcome.reason,
                                       hits: outcome.hits, rulesMs: outcome.elapsedMs, override: override)
        if let rule = outcome.rule {
            decision.route = rule.route
            decision.reason = "\(rule.id): \(outcome.reason)"
        } else if !(skipsClassifierWhenFixed && (override != .auto || isSticky)) {
            await classify(request, settings: settings, into: &decision)
        }
        decision.underlying = decision.route
        if override != .auto, let route = override.route {
            decision.route = route
            decision.source = .override
            decision.reason = override.label + (decision.underlying.map { " (gate: \($0.label.lowercased()))" } ?? "")
        } else if isSticky, decision.route != .local {
            decision.route = .local
            decision.source = .sticky
            decision.reason = "an earlier private turn still goes along with this message, so it stays local"
        }
        return decision
    }

    private func classify(_ request: PrivacyGateRequest, settings: PrivacyGateSettings, into decision: inout PrivacyDecision) async {
        let input = Self.classifierInput(request, limit: settings.classifier.maxInputCharacters)
        switch PrivacyClassifierEndpoint.resolve(settings.classifier, privateLocal: privateLocal()) {
        case .failure(.notConfigured(let why)):
            decision.route = settings.defaultRoute == .cloud ? .cloud : settings.defaultRoute
            decision.source = .defaultRoute
            decision.reason = "no rule matched; " + why
            return
        case .failure(let error):
            decision.source = .offline
            decision.classifierError = error.message
            decision.reason = error.message
            return
        case .success(let endpoint):
            let key = Self.cacheKey(request, input: input, endpoint: endpoint)
            if let hit = cached(key, minutes: settings.classifier.cacheMinutes) {
                decision.probabilities = hit.probabilities
                decision.route = hit.route(cloudMinimum: settings.classifier.cloudMinProbability, uncertain: settings.uncertainRoute)
                decision.source = .cache
                decision.classifierMs = 0
                decision.reason = Self.classifierReason(hit, route: decision.route, cached: true)
                return
            }
            switch await classifier.classify(text: input, endpoint: endpoint, settings: settings.classifier) {
            case .success(let classification):
                store(key, classification)
                decision.probabilities = classification.probabilities
                decision.route = classification.route(cloudMinimum: settings.classifier.cloudMinProbability,
                                                      uncertain: settings.uncertainRoute)
                decision.source = .classifier
                decision.classifierMs = classification.elapsedMs
                decision.reason = Self.classifierReason(classification, route: decision.route, cached: false)
            case .failure(let error):
                decision.route = nil
                decision.source = .offline
                decision.classifierError = error.message
                decision.reason = error.message
                if case .timedOut(let ms) = error { decision.classifierMs = ms }
            }
        }
    }

    static func classifierReason(_ c: PrivacyClassification, route: PrivacyRoute?, cached: Bool) -> String {
        let percent = { (r: PrivacyRoute) in Int((c.probability(r) * 100).rounded()) }
        return "classifier\(cached ? " (cached)" : ""): cloud \(percent(.cloud))%, local \(percent(.local))%, "
            + "redact \(percent(.redactApprove))% over \(c.answered) orderings"
    }

    static func cacheKey(_ request: PrivacyGateRequest, input: String, endpoint: PrivacyClassifierEndpoint) -> String {
        let digest = SHA256.hash(data: Data((endpoint.model + "\n" + input).utf8))
        return request.conversationKey + ":" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func cached(_ key: String, minutes: Int) -> PrivacyClassification? {
        lock.withLock {
            guard let entry = cache[key], Date().timeIntervalSince(entry.at) < Double(max(0, minutes)) * 60 else { return nil }
            return entry.classification
        }
    }

    private func store(_ key: String, _ classification: PrivacyClassification) {
        lock.withLock {
            if cache.count > 500 { cache = cache.filter { Date().timeIntervalSince($0.value.at) < 3600 } }
            cache[key] = (classification, Date())
        }
    }

    private var lastPrewarm = Date.distantPast

    /// Warms the classifier's connection while Cantrip prepares the message, at most every 30 s.
    func prewarm(_ settings: PrivacyGateSettings? = nil) {
        let settings = settings ?? self.settings
        guard settings.enabled, case .success(let endpoint) = PrivacyClassifierEndpoint.resolve(settings.classifier, privateLocal: privateLocal())
        else { return }
        let due = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(lastPrewarm) > 30 else { return false }
            lastPrewarm = Date()
            return true
        }
        guard due else { return }
        let classifier = self.classifier
        Task.detached(priority: .utility) { await classifier.prewarm(endpoint: endpoint) }
    }

    // MARK: Staying local

    func isStickyLocal(_ key: String) -> Bool {
        loadStateIfNeeded()
        return lock.withLock { (sticky[key] ?? 0) > 0 }
    }

    /// After a Home chat decision: a local one keeps the next `turns` local; one that stayed local
    /// because of an earlier turn uses one up.
    func noteHomeTurn(_ key: String, decision: PrivacyDecision, turns: Int) {
        loadStateIfNeeded()
        let changed = lock.withLock { () -> Bool in
            let before = sticky[key]
            if decision.underlying == .local, turns > 0 {
                sticky[key] = turns
            } else if decision.source == .sticky, let left = before {
                sticky[key] = left > 1 ? left - 1 : nil
            }
            return sticky[key] != before
        }
        if changed { saveState() }
    }

    /// Start Fresh or a new conversation: earlier turns no longer go along.
    func resetConversation(_ key: String) {
        loadStateIfNeeded()
        let changed = lock.withLock { sticky.removeValue(forKey: key) != nil }
        if changed { saveState() }
    }

    private func loadStateIfNeeded() {
        let needs = lock.withLock { () -> Bool in defer { loadedState = true }; return !loadedState }
        guard needs, let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let saved = object["stickyLocal"] as? [String: Int] else { return }
        lock.withLock { sticky = saved }
    }

    private func saveState() {
        let snapshot = lock.withLock { sticky }
        guard let data = try? JSONSerialization.data(withJSONObject: ["stickyLocal": snapshot], options: [.sortedKeys]) else { return }
        try? PrivateFile.write(data, to: stateURL)
    }

    // MARK: Recording

    func record(_ decision: PrivacyDecision, request: PrivacyGateRequest, settings: PrivacyGateSettings,
                applied: Bool, totalMs: Int, at: Date = Date()) {
        let enforcement = PrivacyEnforcement.of(decision, kind: request.kind, settings: settings)
        if request.kind == .homeChat { noteHomeTurn(request.conversationKey, decision: decision, turns: settings.stickyTurns) }
        let privateTools = request.mcpServers.filter { server in
            settings.cloudRuns.excludeMCP.contains { server.lowercased() == $0.lowercased() }
        }.sorted()
        let record = PrivacyDecisionRecord(
            at: at, kind: request.kind.rawValue, task: request.taskID?.uuidString, taskTitle: request.taskTitle,
            mode: settings.mode.rawValue, route: decision.route?.rawValue ?? "offline", source: decision.source.rawValue,
            rule: decision.rule, reason: String(decision.reason.prefix(300)), hits: decision.hits,
            pLocal: decision.probabilities?[.local], pCloud: decision.probabilities?[.cloud],
            pRedact: decision.probabilities?[.redactApprove], rulesMs: decision.rulesMs, classifierMs: decision.classifierMs,
            classifierError: decision.classifierError, totalMs: totalMs, backend: request.backend,
            privateTools: privateTools, enforce: enforcement.rawValue, applied: applied,
            promptChars: request.message.count, underlying: decision.underlying?.rawValue)
        append(record)
        Log.write("privacy: \(request.kind.rawValue)\(request.taskTitle.map { " “\($0.prefix(40))”" } ?? "") "
                  + "\(settings.mode.rawValue) -> \(record.route) (\(record.source)\(record.rule.map { " \($0)" } ?? "")), "
                  + "enforce \(record.enforce), \(totalMs) ms")
    }

    private func append(_ record: PrivacyDecisionRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let size = (try? manager.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > Self.logLimit {
                let older = directory.appendingPathComponent("decisions.1.jsonl")
                try? manager.removeItem(at: older)
                try manager.moveItem(at: logURL, to: older)
            }
            if !manager.fileExists(atPath: logURL.path) {
                manager.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            Log.write("privacy: couldn't record a decision: \(error.localizedDescription)")
        }
    }

    func records(since: Date) -> [PrivacyDecisionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return [directory.appendingPathComponent("decisions.1.jsonl"), logURL].flatMap { url -> [PrivacyDecisionRecord] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? decoder.decode(PrivacyDecisionRecord.self, from: Data($0.utf8)) }
        }.filter { $0.at >= since }
    }

    // MARK: Badges

    static func badge(_ decision: PrivacyDecision, kind: PrivacyGateRequest.Kind, settings: PrivacyGateSettings,
                      applied: Bool, totalMs: Int) -> PrivacyBadge {
        let enforcement = PrivacyEnforcement.of(decision, kind: kind, settings: settings)
        let observing = settings.mode == .observe
        let head: String
        switch enforcement {
        case .local: head = observing ? "Would run locally" : "Ran locally"
        case .cloud: head = "Cloud"
        case .cloudRestricted: head = observing ? "Cloud" : "Cloud, no private tools"
        case .ask: head = decision.route == nil ? "Privacy check offline" : (observing ? "Would ask first" : "Asked first")
        case .hold: head = observing ? "Privacy check offline" : "Held: privacy check offline"
        case .cancel: head = observing ? "Privacy check offline" : "Not sent"
        }
        let why: String
        switch decision.source {
        case .rule: why = decision.rule ?? "rule"
        case .classifier, .cache:
            why = decision.probabilities.map { "\(Int(($0[.cloud] ?? 0) * 100))% cloud" } ?? "classifier"
        case .override: why = "your setting"
        case .sticky: why = "private conversation"
        case .defaultRoute: why = "no rule matched"
        case .offline: why = "classifier offline"
        }
        let details = [decision.reason,
                       "Rules \(decision.rulesMs) ms" + (decision.classifierMs.map { ", classifier \($0) ms" } ?? "")
                        + ", \(totalMs) ms in all.",
                       observing ? "Observing: this run was sent as usual." : nil].compactMap { $0 }
        return PrivacyBadge(route: decision.route?.rawValue ?? "offline", mode: settings.mode.rawValue, applied: applied,
                            label: "\(head) · \(why)", detail: details.joined(separator: " "))
    }

    // MARK: Report

    /// A summary of what the gate decided, for reviewing observe mode.
    func report(days: Int, now: Date = Date()) -> String {
        let since = now.addingTimeInterval(-Double(max(1, days)) * 86_400)
        let all = records(since: since)
        guard !all.isEmpty else {
            return "No privacy decisions in the last \(days) day(s). The log is \(logURL.path)."
        }
        func percent(_ n: Int, _ of: Int) -> String { of == 0 ? "0%" : "\(Int((Double(n) / Double(of) * 100).rounded()))%" }
        func counts(_ items: [String]) -> [(String, Int)] {
            Dictionary(grouping: items, by: { $0 }).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 || $0.1 == $1.1 && $0.0 < $1.0 }
        }
        var lines = ["Privacy Gate: \(all.count) decisions in the last \(days) day(s) "
                     + "(\(all.filter { $0.kind == "homeChat" }.count) Home chat, \(all.filter { $0.kind == "homeTask" }.count) Home tasks)."]
        let observed = all.filter { $0.mode == "observe" }.count
        lines.append("Mode: \(observed) observed, \(all.count - observed) enforced.")
        lines.append("")
        lines.append("Route the gate chose:")
        for (route, n) in counts(all.map(\.route)) { lines.append("  \(route): \(n) (\(percent(n, all.count)))") }
        lines.append("")
        lines.append("What enforce mode does with them:")
        let changes = all.filter { $0.enforce != "cloud" }
        for (effect, n) in counts(all.map(\.enforce)) {
            let meaning = ["local": "run locally", "cloud": "cloud with every tool (your setting)",
                           "cloudRestricted": "cloud without private tools", "ask": "ask first",
                           "hold": "wait for the classifier", "cancel": "not sent"][effect] ?? effect
            lines.append("  \(meaning): \(n) (\(percent(n, all.count)))")
        }
        let toolLoss = all.filter { $0.enforce == "cloudRestricted" && !$0.privateTools.isEmpty }.count
        lines.append("  \(changes.count) of \(all.count) runs would change; \(toolLoss) cloud runs would lose private tools they had.")
        lines.append("")
        lines.append("Why:")
        for (source, n) in counts(all.map { $0.source == "rule" ? "rule \($0.rule ?? "?")" : $0.source }) {
            lines.append("  \(source): \(n)")
        }
        let hits = all.flatMap { $0.hits.filter { $0.value > 0 }.map(\.key) }
        if !hits.isEmpty {
            lines.append("")
            lines.append("Detector hits (kind@part, requests with at least one):")
            for (hit, n) in counts(hits).prefix(12) { lines.append("  \(hit): \(n)") }
        }
        let tasks = Dictionary(grouping: all.filter { $0.kind == "homeTask" }, by: { $0.taskTitle ?? $0.task ?? "?" })
        if !tasks.isEmpty {
            lines.append("")
            lines.append("Tasks (what enforce mode would do):")
            for (title, runs) in tasks.sorted(by: { $0.key < $1.key }) {
                let summary = counts(runs.map(\.enforce)).map { "\($0.0) \($0.1)" }.joined(separator: ", ")
                lines.append("  \(title.prefix(48)): \(runs.count) run(s): \(summary)")
            }
        }
        let asked = all.filter { $0.source == "classifier" || $0.source == "offline" && $0.classifierError != nil }
        if !asked.isEmpty {
            let times = asked.compactMap(\.classifierMs).sorted()
            let errors = asked.filter { $0.classifierError != nil }.count
            func at(_ q: Double) -> Int { times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count - 1) * q))] }
            lines.append("")
            lines.append("Classifier: \(asked.count) calls, \(errors) unanswered; median \(at(0.5)) ms, 95th percentile \(at(0.95)) ms.")
            let near = all.filter { ($0.pCloud ?? 0) >= 0.7 && ($0.pCloud ?? 0) < 0.9 }.count
            if near > 0 { lines.append("  \(near) answers were 70-89% cloud: just under the cloud threshold.") }
        }
        let rulesSorted = all.map(\.rulesMs).sorted()
        lines.append("")
        lines.append("Rules: median \(rulesSorted[rulesSorted.count / 2]) ms. Log: \(logURL.path) (no prompt text).")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Status and connection test (Settings on every client)

/// Where the classifier is, for Settings: its own address or Private Local's, or why there's none.
struct PrivacyClassifierStatus: Encodable, Equatable {
    var address: String?
    var model: String?
    /// "own", "privateLocal" or "none".
    var from: String
    var problem: String?
    var log: String
}

/// The result of asking the classifier one synthetic question.
struct PrivacyClassifierTest: Encodable, Equatable {
    var ok: Bool
    var address: String?
    var model: String?
    var latencyMs: Int?
    var route: String?
    var probabilities: [String: Double]?
    var error: String?
}

extension PrivacyGate {
    func classifierStatus(_ settings: PrivacyGateSettings? = nil) -> PrivacyClassifierStatus {
        let settings = settings ?? self.settings
        let log = logURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        switch PrivacyClassifierEndpoint.resolve(settings.classifier, privateLocal: privateLocal()) {
        case .success(let endpoint):
            let address = endpoint.decisionsURL.deletingLastPathComponent().absoluteString
                .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            return PrivacyClassifierStatus(address: address, model: endpoint.model,
                                           from: settings.classifier.baseURL.isEmpty ? "privateLocal" : "own", log: log)
        case .failure(let error):
            return PrivacyClassifierStatus(from: "none", problem: error.message, log: log)
        }
    }

    /// Asks one synthetic coding question; a working classifier answers cloud quickly.
    func testClassifier(_ settings: PrivacyGateSettings? = nil) async -> PrivacyClassifierTest {
        let settings = settings ?? self.settings
        switch PrivacyClassifierEndpoint.resolve(settings.classifier, privateLocal: privateLocal()) {
        case .failure(let error):
            return PrivacyClassifierTest(ok: false, error: error.message)
        case .success(let endpoint):
            let result = await classifier.classify(text: "Write a Swift function that reverses the words in a sentence.",
                                                   endpoint: endpoint, settings: settings.classifier)
            let address = endpoint.decisionsURL.deletingLastPathComponent().absoluteString
            switch result {
            case .success(let c):
                let route = c.route(cloudMinimum: settings.classifier.cloudMinProbability, uncertain: settings.uncertainRoute)
                return PrivacyClassifierTest(
                    ok: true, address: address, model: endpoint.model, latencyMs: c.elapsedMs, route: route.rawValue,
                    probabilities: Dictionary(uniqueKeysWithValues: c.probabilities.map { ($0.key.rawValue, ($0.value * 10_000).rounded() / 10_000) }))
            case .failure(let error):
                return PrivacyClassifierTest(ok: false, address: address, model: endpoint.model, error: error.message)
            }
        }
    }

    /// How long a held task waits between checks.
    static var holdRetryNanoseconds: UInt64 = 60_000_000_000
}
