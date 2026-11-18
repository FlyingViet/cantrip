import Foundation

/// Content-aware routing for scheduled Home tasks, observe only: which private sources a task
/// actually needs (before the run, from its prompt and the tools its recent runs used) and what
/// each private tool result could become (during the run, judged on the local model). Both are
/// logged beside the gate's route, which today follows the tools a run *can* use. Nothing here
/// changes how a run executes or which tools it gets. Logs hold counts and labels, never content.

/// Where a run could go if its content decided.
enum PrivacyContentRoute: String, Codable {
    /// Nothing private is needed: the cloud model as is.
    case cloud
    /// The cloud model, with names, emails, phone numbers and account numbers masked first.
    case cloudRedacted
    /// The local model turns personal threads into short facts; the cloud model works from those.
    case hybrid
    /// Something must stay on the local model (passwords, or a result judged too sensitive).
    case local
}

/// What one private tool result could become.
enum PrivacyResultLabel: String, Codable, CaseIterable {
    case pass, redact, extract, local
}

// MARK: - Layer 1: sources

enum PrivacyContentSources {
    /// System locations that hold private data, matched in commands and paths.
    static let builtInPaths: [(String, PrivateSource)] = [
        ("library/mail", .mail), ("envelope index", .mail),
        ("library/messages", .messages), ("chat.db", .messages),
        ("calendar.sqlitedb", .calendar), ("library/calendars", .calendar),
        ("addressbook", .contacts),
        ("bw get", .passwords), ("bw list", .passwords), ("bw unlock", .passwords),
    ]

    /// Splits "personal-mail_search", "mcp__personal__mail_search" or "personal.mail_search" into
    /// server and tool.
    static func split(_ toolName: String) -> (server: String, tool: String) {
        var name = toolName.lowercased()
        if name.hasPrefix("mcp__") { name = String(name.dropFirst(5)).replacingOccurrences(of: "__", with: "-") }
        for separator in ["-", "."] where name.contains(separator) {
            let parts = name.split(separator: Character(separator), maxSplits: 1).map(String.init)
            if parts.count == 2 { return (parts[0], parts[1]) }
        }
        return ("", name)
    }

    /// The private sources one tool call reads: an MCP tool by name, a shell command or file path
    /// by what it touches. Status checks read nothing private.
    static func sources(tool toolName: String, input: String?, settings: PrivacyContentRoutingSettings) -> Set<PrivateSource> {
        let (server, tool) = split(toolName)
        switch server {
        case "personal":
            if tool.hasPrefix("mail") { return [.mail] }
            if tool.hasPrefix("messages") { return [.messages] }
            if tool.hasPrefix("calendar") { return [.calendar] }
            if tool.hasPrefix("contacts") { return [.contacts] }
            return []
        case "homelab":
            if tool.hasPrefix("firefly") || tool.contains("expenses") { return [.finance] }
            if tool.hasPrefix("paperless") { return [.documents] }
            if tool.hasPrefix("ha_") { return [.home] }
            return []
        case "bitwarden":
            return tool == "status" || tool == "lock" ? [] : [.passwords]
        default:
            break
        }
        guard let text = input?.lowercased(), !text.isEmpty else { return [] }
        var found = Set<PrivateSource>()
        for (needle, source) in builtInPaths where text.contains(needle) { found.insert(source) }
        for (needle, source) in settings.privatePaths where text.contains(needle.lowercased()) { found.insert(source) }
        return found
    }

    /// Words in a task's prompt that ask for a source, matched whole.
    static let promptWords: [(String, PrivateSource)] = [
        ("email", .mail), ("emails", .mail), ("mail", .mail), ("inbox", .mail), ("gmail", .mail),
        ("texts", .messages), ("imessage", .messages), ("sms", .messages), ("text messages", .messages), ("messages", .messages),
        ("calendar", .calendar), ("meetings", .calendar), ("appointments", .calendar),
        ("contacts", .contacts),
        ("bank", .finance), ("transactions", .finance), ("spending", .finance), ("bills", .finance),
        ("subscriptions", .finance), ("firefly", .finance), ("expenses", .finance), ("budget", .finance),
        ("paperless", .documents), ("receipts", .documents), ("documents", .documents),
        ("home assistant", .home), ("thermostat", .home),
        ("password", .passwords), ("passwords", .passwords), ("bitwarden", .passwords),
    ]

    struct Need: Equatable {
        var sources: Set<PrivateSource>
        /// "prompt", "history" or both.
        var basis: [String]
    }

    /// Layer 1: what the task needs, from its prompt and the tools its recent runs used (not the
    /// tools it can use).
    static func needed(prompt: String, history: [String: Int], settings: PrivacyContentRoutingSettings) -> Need {
        let text = " " + prompt.lowercased().replacingOccurrences(of: "[^a-z0-9 ]+", with: " ", options: .regularExpression) + " "
        var fromPrompt = Set<PrivateSource>()
        for (word, source) in promptWords where text.contains(" \(word) ") { fromPrompt.insert(source) }
        var fromHistory = Set<PrivateSource>()
        for (key, _) in history {
            let parts = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
            fromHistory.formUnion(sources(tool: parts[0], input: parts.count > 1 ? parts[1] : nil, settings: settings))
        }
        var basis: [String] = []
        if !fromPrompt.isEmpty { basis.append("prompt") }
        if !fromHistory.isEmpty { basis.append("history") }
        return Need(sources: fromPrompt.union(fromHistory), basis: basis)
    }

    /// Before the run: passwords stay local; personal threads go hybrid; other private sources
    /// go masked; nothing private goes as is.
    static func preRoute(_ sources: Set<PrivateSource>) -> PrivacyContentRoute {
        if sources.contains(.passwords) { return .local }
        if sources.contains(.mail) || sources.contains(.messages) { return .hybrid }
        return sources.isEmpty ? .cloud : .cloudRedacted
    }

    /// After the run, from its judged results.
    static func route(_ labels: [PrivacyResultLabel: Int]) -> PrivacyContentRoute {
        if (labels[.local] ?? 0) > 0 { return .local }
        if (labels[.extract] ?? 0) > 0 { return .hybrid }
        if (labels[.redact] ?? 0) > 0 { return .cloudRedacted }
        return .cloud
    }
}

// MARK: - Layer 2: judging results

/// Asks the local model what a cloud model may see of one tool result, through Splash's
/// `POST /judgments` (two option orders, averaged). Passwords are never asked about.
final class PrivacyResultJudge {
    static let instructions = """
        A personal assistant's scheduled task called a tool. Decide what a cloud AI service may see \
        of this result. Pass: public or not personal (code, logs, build or app statistics, \
        newsletters, marketing, news, shipping or service notices). Redact: mainly not personal, \
        with a few personal details (names, email addresses, phone numbers, street addresses, \
        account numbers) that can be masked. Extract: personal correspondence or records (mail, \
        texts, calendar, people, money, health) where only a few short facts are needed. Keep \
        local: passwords, secrets, identity documents, detailed medical or financial records, or \
        anything too sensitive to summarize.
        """
    static let options: [(PrivacyResultLabel, String)] = [
        (.pass, "send it as is"),
        (.redact, "mask names, emails, phone numbers and account numbers, then send it"),
        (.extract, "turn it into a few short facts on the private model and send only those"),
        (.local, "keep it on the private model and send nothing"),
    ]

    let transport: PrivacyClassifier.Transport

    init(transport: PrivacyClassifier.Transport? = nil) {
        self.transport = transport ?? PrivacyClassifier.urlSessionTransport
    }

    static func bodies(tool: String, result: String, model: String, characters: Int) throws -> [Data] {
        let state = "Tool: \(tool)\n\n" + String(result.prefix(max(200, characters)))
        let orders = [options, Array(options.reversed())]
        return try orders.enumerated().map { index, order in
            try JSONSerialization.data(withJSONObject: [
                "model": model, "id": "result_\(index)", "state": state, "question": instructions,
                "options": order.map { ["id": $0.0.rawValue, "description": $0.1] }, "priority": "background",
            ] as [String: Any])
        }
    }

    /// The label with the highest averaged probability, or nil when the server can't judge.
    func judge(tool: String, result: String, endpoint: PrivacyClassifierEndpoint,
               settings: PrivacyContentRoutingSettings, timeoutMs: Int = 30_000) async -> PrivacyResultLabel? {
        if PrivacyContentSources.sources(tool: tool, input: nil, settings: settings).contains(.passwords) { return .local }
        guard let bodies = try? Self.bodies(tool: tool, result: result, model: endpoint.model,
                                            characters: settings.judgeCharacters) else { return nil }
        let transport = self.transport
        let replies = await withTaskGroup(of: [PrivacyResultLabel: Double]?.self) { group in
            for body in bodies {
                group.addTask {
                    var request = URLRequest(url: endpoint.judgmentsURL, timeoutInterval: Double(timeoutMs) / 1000)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = body
                    guard let (data, response) = try? await transport(request),
                          (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let ids = object["option_ids"] as? [String], let values = object["probabilities"] as? [NSNumber],
                          ids.count == values.count else { return nil }
                    var result: [PrivacyResultLabel: Double] = [:]
                    for (id, value) in zip(ids, values) { if let label = PrivacyResultLabel(rawValue: id) { result[label] = value.doubleValue } }
                    return result.count == PrivacyResultLabel.allCases.count ? result : nil
                }
            }
            var all: [[PrivacyResultLabel: Double]] = []
            for await reply in group { if let reply { all.append(reply) } }
            return all
        }
        guard !replies.isEmpty else { return nil }
        var sums: [PrivacyResultLabel: Double] = [:]
        for reply in replies { for (label, p) in reply { sums[label, default: 0] += p } }
        return PrivacyResultLabel.allCases.max { (sums[$0] ?? 0) < (sums[$1] ?? 0) }
    }
}

// MARK: - Runs

/// One line of the decision log for a finished task run: labels and counts, never content.
struct PrivacyContentRecord: Codable, Equatable {
    var at: Date
    var kind = "homeTaskContent"
    var task: String
    var taskTitle: String?
    /// The gate's own route for this run (tool-based).
    var gateRoute: String?
    var preRoute: String
    var sources: [String]
    var basis: [String]
    /// From the judged results; the pre-run route when nothing private came back.
    var route: String
    /// Results judged per label, and their raw characters.
    var labels: [String: Int]
    var labelChars: [String: Int]
    /// Private results the judge couldn't read (server, timeout) or past the per-run cap.
    var unchecked: Int
    /// Tool results that read nothing private, and their characters (they'd go as is).
    var publicResults: Int
    var publicChars: Int
    var rawChars: Int
    /// Estimated characters a cloud model would see: public and passed results whole, redacted
    /// ones masked (about the same length), extracted ones as facts (`factRatio`), local ones none.
    var cloudChars: Int
    /// Local model time spent judging.
    var studioMs: Int
}

/// Collects each hidden task run's results (observe only) and logs a `PrivacyContentRecord` when
/// it ends.
final class PrivacyContentRouting: @unchecked Sendable {
    static let shared = PrivacyContentRouting()

    struct Plan: Equatable {
        var need: PrivacyContentSources.Need
        var preRoute: PrivacyContentRoute
    }

    private final class Run {
        let taskID: UUID
        let taskTitle: String?
        var gateRoute: String?
        let plan: Plan
        let settings: PrivacyContentRoutingSettings
        let endpoint: PrivacyClassifierEndpoint?
        var seen = Set<String>()
        var tools: [String: Int] = [:]
        var labels: [PrivacyResultLabel: Int] = [:]
        var labelChars: [PrivacyResultLabel: Int] = [:]
        /// Past the per-run cap, or no server to ask.
        var capped = 0
        /// The judge couldn't answer.
        var failed = 0
        var judged = 0
        var publicResults = 0
        var publicChars = 0
        var studioMs = 0
        var pending: [Task<Void, Never>] = []

        init(taskID: UUID, taskTitle: String?, gateRoute: String?, plan: Plan,
             settings: PrivacyContentRoutingSettings, endpoint: PrivacyClassifierEndpoint?) {
            self.taskID = taskID; self.taskTitle = taskTitle; self.gateRoute = gateRoute; self.plan = plan
            self.settings = settings; self.endpoint = endpoint
        }
    }

    var judge = PrivacyResultJudge()
    var directory: URL
    /// Appends a finished run's record (the gate's decision log).
    var append: (PrivacyContentRecord) -> Void
    private let lock = NSLock()
    private var runs: [UUID: Run] = [:]

    init(directory: URL = CantripPaths.cache("privacy"), append: ((PrivacyContentRecord) -> Void)? = nil) {
        self.directory = directory
        self.append = append ?? { PrivacyGate.shared.appendContent($0) }
    }

    private var historyURL: URL { directory.appendingPathComponent("task-tools.json") }
    /// Tool names (and, for shell commands and files, the private paths they touched) per task,
    /// one entry per recent run, newest last. Names only.
    static let historyRuns = 5

    func history(_ taskID: UUID) -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return loadHistory()[taskID.uuidString]?.reduce(into: [:]) { sum, run in
            for (key, count) in run { sum[key, default: 0] += count }
        } ?? [:]
    }

    private func loadHistory() -> [String: [[String: Int]]] {
        guard let data = try? Data(contentsOf: historyURL),
              let value = try? JSONDecoder().decode([String: [[String: Int]]].self, from: data) else { return [:] }
        return value
    }

    /// Layer 1 for a task run about to start: logged beside the gate's decision.
    func begin(run sessionID: UUID, taskID: UUID, taskTitle: String?, prompt: String, gateRoute: String?,
               gate: PrivacyGateSettings, endpoint: PrivacyClassifierEndpoint?) -> Plan {
        let settings = gate.contentRouting
        let need = PrivacyContentSources.needed(prompt: prompt, history: history(taskID), settings: settings)
        let plan = Plan(need: need, preRoute: PrivacyContentSources.preRoute(need.sources))
        if settings.observe {
            lock.lock()
            runs[sessionID] = Run(taskID: taskID, taskTitle: taskTitle, gateRoute: gateRoute, plan: plan,
                                  settings: settings, endpoint: endpoint)
            lock.unlock()
        }
        return plan
    }

    /// Tools whose results are never content (their own changes, searches for tools).
    static let contentlessTools: Set<String> = ["edit", "create", "write", "tool_search_tool", "stop_bash", "ask_user",
                                                "task", "read_agent", "list_agents", "write_agent", "sql"]

    /// Shell and file tools, by raw name and by the display name a run's `ToolActivity` carries
    /// (bash and run_shell show as "Shell", view as "Read", grep_search as "Search").
    static let shellOrFileTools: Set<String> = ["bash", "shell", "write_bash", "read_bash", "view", "read",
                                                "grep", "glob", "search"]

    /// Layer 2: one finished tool call of a task run. Private results (by tool, command or path)
    /// are judged on the local model in the background; the others are counted as public.
    func observe(run sessionID: UUID, activityID: String, tool: String, input: String?, output: String?) {
        lock.lock()
        guard let run = runs[sessionID], run.seen.insert(activityID).inserted else { lock.unlock(); return }
        let sources = PrivacyContentSources.sources(tool: tool, input: input, settings: run.settings)
        let key = sources.isEmpty ? tool : tool + "\u{1F}" + sources.map(\.rawValue).sorted().joined(separator: ",")
        run.tools[key, default: 0] += 1
        let text = output ?? ""
        let (_, bare) = PrivacyContentSources.split(tool)
        if Self.contentlessTools.contains(bare) || text.isEmpty {
            lock.unlock(); return
        }
        // Only private sources and, in a run that needs one, shell output and files (which may
        // print private data the patterns don't name) go to the judge.
        guard !sources.isEmpty || (Self.shellOrFileTools.contains(bare) && run.plan.preRoute != .cloud) else {
            run.publicResults += 1
            run.publicChars += text.count
            lock.unlock(); return
        }
        guard run.judged < run.settings.maxResultsPerRun, let endpoint = run.endpoint else {
            run.capped += 1
            lock.unlock(); return
        }
        run.judged += 1
        let judge = self.judge
        let settings = run.settings
        let task = Task.detached(priority: .background) { [weak self] in
            let started = Date()
            let label = await judge.judge(tool: tool, result: text, endpoint: endpoint, settings: settings)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard let self else { return }
            self.lock.lock()
            run.studioMs += ms
            if let label {
                run.labels[label, default: 0] += 1
                run.labelChars[label, default: 0] += text.count
            } else {
                run.failed += 1
            }
            self.lock.unlock()
        }
        run.pending.append(task)
        lock.unlock()
    }

    /// The run ended: waits for its judgments (bounded), logs the record and keeps the run's tool
    /// names for layer 1. Returns the record.
    @discardableResult
    func finish(run sessionID: UUID, waitSeconds: Double = 120) async -> PrivacyContentRecord? {
        lock.lock()
        guard let run = runs.removeValue(forKey: sessionID) else { lock.unlock(); return nil }
        let pending = run.pending
        lock.unlock()
        let deadline = Date().addingTimeInterval(waitSeconds)
        for task in pending {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { task.cancel(); continue }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(nanoseconds: UInt64(left * 1e9)) }
                await group.next()
                group.cancelAll()
            }
        }
        lock.lock()
        let labels = run.labels
        let labelChars = run.labelChars
        let answered = labels.values.reduce(0, +)
        // Capped, failed, and judgments still running at the deadline.
        let unchecked = run.capped + run.failed + max(0, run.judged - answered - run.failed)
        var history = loadHistory()
        var entries = history[run.taskID.uuidString] ?? []
        entries.append(run.tools)
        history[run.taskID.uuidString] = Array(entries.suffix(Self.historyRuns))
        if let data = try? JSONEncoder().encode(history) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: historyURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        }
        lock.unlock()
        let chars = { (label: PrivacyResultLabel) in labelChars[label] ?? 0 }
        let privateRaw = PrivacyResultLabel.allCases.map(chars).reduce(0, +)
        let cloud = run.publicChars + chars(.pass) + chars(.redact)
            + Int((Double(chars(.extract)) * run.settings.factRatio).rounded())
        // No judged result: a run whose results were all seen and none private read nothing private;
        // one that showed nothing, or whose judgments are missing, keeps its plan.
        let route = !labels.isEmpty ? PrivacyContentSources.route(labels)
            : unchecked == 0 && run.publicResults > 0 ? .cloud : run.plan.preRoute
        let record = PrivacyContentRecord(
            at: Date(), task: run.taskID.uuidString, taskTitle: run.taskTitle, gateRoute: run.gateRoute,
            preRoute: run.plan.preRoute.rawValue, sources: run.plan.need.sources.sorted().map(\.rawValue),
            basis: run.plan.need.basis, route: route.rawValue,
            labels: Dictionary(uniqueKeysWithValues: labels.map { ($0.key.rawValue, $0.value) }),
            labelChars: Dictionary(uniqueKeysWithValues: labelChars.filter { $0.value > 0 }.map { ($0.key.rawValue, $0.value) }),
            unchecked: unchecked, publicResults: run.publicResults, publicChars: run.publicChars,
            rawChars: run.publicChars + privateRaw, cloudChars: cloud, studioMs: run.studioMs)
        append(record)
        Log.write("privacy: content \(run.taskTitle.map { "“\($0.prefix(40))” " } ?? "")gate \(run.gateRoute ?? "?") "
                  + "-> content \(route.rawValue) (pre \(run.plan.preRoute.rawValue); "
                  + PrivacyResultLabel.allCases.map { "\($0.rawValue) \(labels[$0] ?? 0)" }.joined(separator: ", ")
                  + ", unchecked \(unchecked), \(run.studioMs) ms)")
        return record
    }

    /// The gate's route arrives after the run started (observe mode decides beside it).
    func noteGateRoute(run sessionID: UUID, route: String) {
        lock.lock(); runs[sessionID]?.gateRoute = route; lock.unlock()
    }

    func isObserving(_ sessionID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runs[sessionID] != nil
    }
}
