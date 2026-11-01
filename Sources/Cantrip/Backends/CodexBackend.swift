import Foundation

/// OpenAI's Codex CLI through `codex app-server` (JSON-RPC over stdio), one server per tab:
/// threads resume across restarts, Stop interrupts the turn in-band, messages sent during a turn
/// steer it, and every command, file change and MCP tool call that Codex wants to run comes to
/// Cantrip first as an approval request, so the action policy and Cantrip Home apply.
final class CodexBackend: Backend, CantripHomeGuardedBackend {
    /// The tab this backend serves: its commands and MCP servers see `CANTRIP_TAB_ID`.
    var tabID: UUID?
    /// Shared MCP servers this run doesn't get (a scheduled task's limits).
    var excludedMcpServers: Set<String> = []
    /// Per-instance model and effort (per-tab settings, council seats). Nil = the settings.
    var modelOverride: String?
    var effortOverride: String?
    /// Council advisors: Codex's read-only sandbox, and Cantrip declines anything else.
    let readOnly: Bool
    var guardrail: CantripHomeGuardrail?
    var guardrailLabel = "Cantrip Home"
    /// A child tab's shared-resource rules (Simulator, builds), consulted before the policy for commands.
    var childPolicy: CopilotBackend.ChildPolicy? {
        get { lock.withLock { storedChildPolicy } }
        set { lock.withLock { storedChildPolicy = newValue } }
    }
    private var storedChildPolicy: CopilotBackend.ChildPolicy?
    /// Cantrip Home's fixed protocol, sent once as the thread's developer instructions.
    var homeProtocol: String?
    /// Test seam: the app server to talk to (the default launches `codex app-server`).
    var makeServer: ((_ arguments: [String], _ environment: [String: String], _ workdir: String) throws -> CodexAppServer)?

    private let persistKey: String
    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "codex-backend")
    private let lock = NSLock()

    private var server: CodexAppServer?
    private var launchSignature: String?
    private var askpass: RemoteAskpass?
    private var threadID: String? {
        didSet { UserDefaults.standard.set(threadID, forKey: persistKey) }
    }
    private var threadFolderKey: String { persistKey + ".folder" }
    private var seenTurnsKey: String { persistKey + ".seenTurns" }
    private var pendingSeenTurns: Int?

    // The running turn (guarded by `lock`).
    private var turnID: String?
    /// Turns Stop interrupted: Codex still finishes them, sometimes after the next turn starts.
    private var stoppedTurns: Set<String> = []
    private var onEvent: ((BackendEvent) -> Void)?
    private var finished = true
    private var activities: [String: ToolActivity] = [:]
    private var streamed: Set<String> = []
    /// The agent message the reply's text last came from, and how that text ended.
    private var textItem: String?
    private var textEnding = ""
    private var checkedItems: Set<String> = []
    private var turnUsage = (input: 0, cached: 0, output: 0, calls: 0)
    private var lastLimit: [String: Any]?
    private var limitReported = false
    private var pendingInputs: [UUID: BackendInputRequest] = [:]
    private var approvedScopes: Set<String> = []
    private var workdir = NSHomeDirectory()

    init(persistKey: String = "codexSessionID", readOnly: Bool = false,
         modelOverride: String? = nil, effortOverride: String? = nil) {
        self.persistKey = persistKey
        self.readOnly = readOnly
        self.modelOverride = modelOverride
        self.effortOverride = effortOverride
        threadID = UserDefaults.standard.string(forKey: persistKey)
    }

    var model: String { (modelOverride ?? settings.codexModel).trimmingCharacters(in: .whitespaces) }
    var effort: String { (effortOverride ?? settings.codexEffort).trimmingCharacters(in: .whitespaces) }

    var supportsMidTurnInjection: Bool { true }
    var canSteerTurns: Bool { true }

    // MARK: - Permissions

    enum Access: Equatable {
        /// Council seats: Codex's read-only sandbox; every request is declined.
        case readOnly
        /// Cantrip Home: each request goes through `CantripHomeActionPolicy`.
        case guardrail(CantripHomeGuardrail)
        /// Workspace sandbox; each request asks the user.
        case ask
        /// Full access, and every request still comes to Cantrip's agent policy (Act on my
        /// behalf, or the explicit full-access setting): it runs unless a rule denies or asks.
        case policy
        /// Full access, no requests: only when the agent policy is turned off.
        case full
    }

    var access: Access {
        if readOnly { return .readOnly }
        if let guardrail { return .guardrail(guardrail) }
        guard settings.allowActions || settings.codexPermissionMode == "bypassPermissions" else { return .ask }
        return AgentPolicyGate.enforcesEverywhere ? .policy : .full
    }

    /// The sandbox and approval policy Codex runs under for `access`.
    static func threadPolicy(_ access: Access) -> (sandbox: String, approval: String) {
        switch access {
        case .readOnly: return ("read-only", "untrusted")
        case .full: return ("danger-full-access", "never")
        // Codex runs reads it knows are safe on its own and asks about everything else.
        case .policy: return ("danger-full-access", "untrusted")
        case .ask, .guardrail: return ("workspace-write", "untrusted")
        }
    }

    /// Launch arguments after `app-server`: Codex's own memory off, then the shared MCP servers
    /// (and plugin servers).
    func launchArguments() -> [String] {
        var args = CLIMemory.codexArguments + PluginManager.codexMCPOverrides()
        if let snapshot = MCPRegistry.load(), snapshot.importedAt != nil {
            args += MCPBackendConfig.codexArgs(snapshot, excluded: excludedMcpServers.union(MCPBackendConfig.tabDisabled(tabID)))
        }
        return args
    }

    /// What the system message carries: reply visibility, images, simulators, Home's protocol and
    /// the rules Cantrip keeps for `workdir`.
    func developerInstructions(workdir: String) -> String {
        var parts = [RemoteGeneratedImages.agentGuidance(sessionFilesFolder: false), ReplyVisibility.guidance,
                     WeatherCardResolver.agentGuidance(command: TabInsight.command)]
        if !readOnly { parts.append(SimulatorPool.agentGuidance(command: TabInsight.command)) }
        if let homeProtocol { parts.append(homeProtocol) }
        if let rules = FolderInstructions().guidance(for: workdir) { parts.append(rules) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Backend

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            Task { await self.run(request, workdir: workdir, onEvent: onEvent) }
        }
    }

    deinit {
        server?.terminate()
        askpass?.stop()
    }

    func cancel() {
        interruptServerTurn()
        finish(nil)
    }

    /// Stops the turn and keeps the thread (and the process) warm.
    private func interruptServerTurn() {
        let (server, thread, turn) = lock.withLock { (self.server, threadID, turnID) }
        cancelPendingInputs()
        if let server, let thread, let turn {
            lock.withLock { _ = stoppedTurns.insert(turn) }
            server.request("turn/interrupt", ["threadId": thread, "turnId": turn], timeout: 10) { _ in }
        }
    }

    func interruptTurn() -> Bool {
        let busy = lock.withLock { turnID != nil && !finished }
        guard busy else { return false }
        cancel()
        return true
    }

    func reset() {
        cancel()
        stopServer()
        lock.withLock {
            threadID = nil
            approvedScopes.removeAll()
        }
        UserDefaults.standard.removeObject(forKey: threadFolderKey)
        UserDefaults.standard.removeObject(forKey: seenTurnsKey)
        pendingSeenTurns = nil
    }

    func injectMidTurn(_ text: String, completion: @escaping (MidTurnDelivery) -> Void) {
        let (server, thread, turn) = lock.withLock { (self.server, threadID, finished ? nil : turnID) }
        guard let server, let thread, let turn else { return completion(.notSent) }
        server.request("turn/steer", ["threadId": thread, "expectedTurnId": turn,
                                      "input": [["type": "text", "text": text]]], timeout: 20) { result in
            switch result {
            case .success: completion(.accepted(messageID: nil))
            case .failure(let error): completion(.uncertain(error.localizedDescription))
            }
        }
    }

    // MARK: - Running a turn

    private func run(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) async {
        lock.withLock {
            self.onEvent = onEvent
            finished = false
            turnID = nil
            activities.removeAll()
            streamed.removeAll()
            textItem = nil
            textEnding = ""
            checkedItems.removeAll()
            turnUsage = (0, 0, 0, 0)
            lastLimit = nil
            limitReported = false
            self.workdir = workdir
        }
        do {
            let server = try await ensureServer(workdir: workdir)
            let thread = try await ensureThread(server, workdir: workdir)
            var input: [[String: Any]] = [["type": "text", "text": Self.textWithoutImages(promptWithMissedTurns(request))]]
            for path in Self.imagePaths(in: request.prompt) { input.append(["type": "localImage", "path": path]) }
            var params: [String: Any] = ["threadId": thread, "input": input]
            if !model.isEmpty { params["model"] = model }
            if !effort.isEmpty { params["effort"] = effort }
            let result = try await server.request("turn/start", params, timeout: 60)
            if let id = (result["turn"] as? [String: Any])?["id"] as? String { lock.withLock { turnID = id } }
        } catch {
            finish(.failure(Self.launchFailureText(error)))
        }
    }

    /// A tab's thread: the saved one when it belongs to this folder (resumed in the server),
    /// else a new one. Changing folders starts a new conversation (Codex ties threads to a folder).
    private func ensureThread(_ server: CodexAppServer, workdir: String) async throws -> String {
        let policy = Self.threadPolicy(access)
        var params: [String: Any] = ["cwd": workdir, "sandbox": policy.sandbox, "approvalPolicy": policy.approval,
                                     "developerInstructions": developerInstructions(workdir: workdir)]
        if !model.isEmpty { params["model"] = model }
        let savedFolder = UserDefaults.standard.string(forKey: threadFolderKey)
        if let saved = lock.withLock({ threadID }), savedFolder == nil || savedFolder == workdir {
            if lock.withLock({ server === self.server && loadedThread == saved }) { return saved }
            var resume = params
            resume["threadId"] = saved
            resume["excludeTurns"] = true
            do {
                _ = try await server.request("thread/resume", resume, timeout: 60)
                lock.withLock { loadedThread = saved }
                return saved
            } catch {
                Log.write("codex: couldn't resume thread \(saved.prefix(8)); starting a new one: \(error.localizedDescription)")
                lock.withLock { threadID = nil }
            }
        }
        let result = try await server.request("thread/start", params, timeout: 60)
        guard let id = (result["thread"] as? [String: Any])?["id"] as? String else {
            throw CodexAppServer.Failure(message: "Codex didn't start a conversation.")
        }
        lock.withLock {
            threadID = id
            loadedThread = id
        }
        UserDefaults.standard.set(workdir, forKey: threadFolderKey)
        UserDefaults.standard.removeObject(forKey: seenTurnsKey)
        return id
    }
    private var loadedThread: String?

    /// Earlier turns this thread hasn't seen (a tab that ran on another backend, a new thread).
    private func promptWithMissedTurns(_ request: BackendRequest) -> String {
        let turns = request.previousTurns
        let seen = UserDefaults.standard.object(forKey: seenTurnsKey) as? Int
        let missed: ArraySlice<ConversationTurn> = seen.map { $0 <= turns.count ? turns.dropFirst($0) : [] } ?? turns[...]
        pendingSeenTurns = turns.count + 1
        guard !missed.isEmpty else { return request.prompt }
        Log.write("codex: carrying \(missed.count) earlier turn(s) into the thread")
        return ConversationContextBuilder.composePrompt(currentPrompt: request.prompt, query: request.userMessage,
                                                        turns: Array(missed))
    }

    private func ensureServer(workdir: String) async throws -> CodexAppServer {
        let arguments = launchArguments()
        // New developer instructions (Home's protocol) need a restart: a loaded thread keeps its own.
        let profile = EnvironmentProfiles.resolved(for: workdir)
        let signature = "\(workdir)|\(access)|\(arguments.joined(separator: " "))|\(tabID?.uuidString ?? "")|\(developerInstructions(workdir: workdir).hashValue)|\(profile?.fingerprint ?? "")"
        if let server = lock.withLock({ self.server }), server.isRunning, launchSignature == signature { return server }
        stopServer()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolPath.value(inherited: environment["PATH"])
        if let profile { EnvironmentProfiles.apply(profile, to: &environment) }
        environment["NO_COLOR"] = "1"
        if let tabID { environment[TabInsight.tabIDVariable] = tabID.uuidString }
        let server: CodexAppServer
        if let makeServer {
            server = try makeServer(arguments, environment, workdir)
        } else {
            guard let executable = ToolLocator.shared.codex(configured: settings.codexPath) else {
                throw CodexAppServer.Failure(message: "codex not found")
            }
            server = CodexAppServer(executable: executable, arguments: arguments, environment: environment,
                                    directory: URL(fileURLWithPath: workdir))
            if !readOnly {
                // `sudo`/`ssh` password prompts from Codex's commands come to Cantrip's secure prompt.
                let broker = try RemoteAskpass(process: server.process) { [weak self] request in
                    guard let callback = self?.lock.withLock({ self?.onEvent }) else { return request.cancel() }
                    callback(.inputRequired(request))
                }
                var env = server.process.environment ?? environment
                env.merge(broker.environment) { _, new in new }
                server.process.environment = env
                askpass = broker
            }
        }
        server.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
        server.onServerRequest = { [weak self] id, method, params in self?.handleServerRequest(id, method, params) }
        server.onExit = { [weak self, weak server] status, tail in
            guard let self, let server, self.lock.withLock({ self.server === server }) else { return }
            self.lock.withLock {
                self.server = nil
                self.loadedThread = nil
            }
            Log.write("codex: app server exited (\(status))")
            self.finish(.failure(tail.isEmpty ? "Codex stopped unexpectedly (status \(status))." : String(tail.suffix(600))))
        }
        try server.start()
        try await server.handshake()
        lock.withLock {
            self.server = server
            launchSignature = signature
            loadedThread = nil
        }
        return server
    }

    private func stopServer() {
        let old = lock.withLock { () -> CodexAppServer? in
            defer { server = nil; loadedThread = nil; launchSignature = nil }
            return server
        }
        old?.terminate()
        askpass?.stop()
        askpass = nil
    }

    /// Exactly one terminal event per turn.
    private func finish(_ event: BackendEvent?) {
        let (callback, open) = lock.withLock { () -> (((BackendEvent) -> Void)?, [ToolActivity]) in
            guard !finished else { return (nil, []) }
            finished = true
            let callback = onEvent
            onEvent = nil
            let open = activities.values.filter { $0.state == .running }
            activities.removeAll()
            turnID = nil
            return (callback, open)
        }
        guard let callback else { return }
        for activity in open { callback(.activity(activity.finishing(as: .cancelled))) }
        if let event { callback(event) }
    }

    private func emit(_ event: BackendEvent) {
        lock.withLock { finished ? nil : onEvent }?(event)
    }

    // MARK: - Notifications

    func handleNotification(_ method: String, _ params: [String: Any]) {
        let turn = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
        if let turn, lock.withLock({ () -> Bool in
            // A stopped turn's late events, or another turn's while this one is known.
            stoppedTurns.contains(turn) || (turnID.map { $0 != turn } ?? false)
        }) {
            if method == "turn/completed" { lock.withLock { _ = stoppedTurns.remove(turn) } }
            return
        }
        switch method {
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String, !delta.isEmpty else { return }
            let id = params["itemId"] as? String
            if let id { lock.withLock { _ = streamed.insert(id) } }
            emitText(delta, item: id)
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            if let delta = params["delta"] as? String, !delta.isEmpty { emit(.thinkingDelta(delta)) }
        case "item/started":
            if let item = params["item"] as? [String: Any] { itemStarted(item) }
        case "item/completed":
            if let item = params["item"] as? [String: Any] { itemCompleted(item) }
        case "item/commandExecution/outputDelta":
            guard let id = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            let updated = lock.withLock { () -> ToolActivity? in
                guard var activity = activities[id] else { return nil }
                activity.output = String(((activity.output ?? "") + delta).suffix(4_000))
                activities[id] = activity
                return activity
            }
            if let updated { emit(.activity(updated)) } else { emit(.heartbeat) }
        case "item/mcpToolCall/progress", "turn/plan/updated", "turn/diff/updated":
            emit(.heartbeat)
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"] as? [String: Any] else { return }
            let last = usage["last"] as? [String: Any] ?? [:]
            func int(_ key: String) -> Int { (last[key] as? NSNumber)?.intValue ?? 0 }
            lock.withLock {
                turnUsage.input += int("inputTokens")
                turnUsage.cached += int("cachedInputTokens")
                turnUsage.output += int("outputTokens")
                turnUsage.calls += 1
            }
            if let window = (usage["modelContextWindow"] as? NSNumber)?.intValue {
                emit(.context(BackendContextUsage(tokens: int("inputTokens") + int("outputTokens"), limit: window)))
            }
        case "account/rateLimits/updated":
            if let limits = params["rateLimits"] as? [String: Any] {
                lock.withLock { lastLimit = limits }
                CodexUsage.record(rateLimits: limits)
            }
        case "error":
            guard let error = params["error"] as? [String: Any], params["willRetry"] as? Bool != true else { return }
            reportLimit(error)
        case "turn/completed":
            turnCompleted(params["turn"] as? [String: Any] ?? [:])
        default:
            break
        }
    }

    private func turnCompleted(_ turn: [String: Any]) {
        let usage = lock.withLock { turnUsage }
        if usage.calls > 0 {
            emit(.usage(BackendUsage(backend: BackendKind.codex.rawValue, costUSD: 0, inputTokens: usage.input,
                                     outputTokens: usage.output, cachedInputTokens: usage.cached, modelCalls: usage.calls)))
        }
        switch turn["status"] as? String {
        case "failed":
            let error = turn["error"] as? [String: Any] ?? [:]
            reportLimit(error)
            finish(.failure(error["message"] as? String ?? "Codex couldn't finish this turn."))
        case "interrupted":
            finish(.done)
        default:
            if let seen = pendingSeenTurns { UserDefaults.standard.set(seen, forKey: seenTurnsKey) }
            pendingSeenTurns = nil
            finish(.done)
        }
    }

    /// Once per turn: Codex sends the error, then fails the turn with the same one.
    private func reportLimit(_ error: [String: Any]) {
        guard let report = Self.usageLimit(from: error, rateLimits: lock.withLock({ lastLimit })),
              lock.withLock({ () -> Bool in defer { limitReported = true }; return !limitReported }) else { return }
        emit(.usageLimit(report))
    }

    /// `usageLimitExceeded` / `rateLimitExceeded` from Codex's structured error, with the window's
    /// reset time from the last rate-limit snapshot when it's full.
    static func usageLimit(from error: [String: Any], rateLimits: [String: Any]?) -> UsageLimitReport? {
        guard let code = error["codexErrorInfo"] as? String, ["usageLimitExceeded", "rateLimitExceeded"].contains(code) else {
            return nil
        }
        return UsageLimitReport(code: "codex/\(code)", resetsAt: CodexUsage.limitedUntil(rateLimits))
    }

    // MARK: - Items

    /// A turn's agent messages (progress notes between steps, then the answer) become paragraphs
    /// of one reply instead of running together.
    private func emitText(_ text: String, item: String?) {
        let prefix = lock.withLock { () -> String in
            defer {
                if let item { textItem = item }
                textEnding = String((textEnding + text).suffix(2))
            }
            guard let item, let previous = textItem, previous != item, !textEnding.isEmpty,
                  !textEnding.hasSuffix("\n\n") else { return "" }
            return textEnding.hasSuffix("\n") ? "\n" : "\n\n"
        }
        emit(.textDelta(prefix + text))
    }

    private func itemStarted(_ item: [String: Any]) {
        guard let id = item["id"] as? String, let activity = Self.activity(for: item, running: true) else { return }
        lock.withLock { activities[id] = activity }
        emit(.activity(activity))
    }

    private func itemCompleted(_ item: [String: Any]) {
        guard let id = item["id"] as? String else { return }
        if item["type"] as? String == "agentMessage" {
            // Text not streamed as deltas (a resumed or very short reply) still reaches the reply.
            let wasStreamed = lock.withLock { streamed.contains(id) }
            if !wasStreamed, let text = item["text"] as? String, !text.isEmpty { emitText(text, item: id) }
            return
        }
        guard var activity = Self.activity(for: item, running: false) else { return }
        let previous = lock.withLock { activities.removeValue(forKey: id) }
        if let previous, activity.output == nil { activity.output = previous.output }
        emit(.activity(activity))
        if item["type"] as? String == "commandExecution", item["status"] as? String == "completed" { auditUnchecked(item) }
    }

    /// Tool activity for an item Cantrip shows as a step; nil for messages and reasoning.
    static func activity(for item: [String: Any], running: Bool) -> ToolActivity? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        let status = item["status"] as? String ?? (running ? "inProgress" : "completed")
        let state: ToolActivityState = running ? .running
            : ["failed", "declined"].contains(status) ? .failed : status == "inProgress" ? .running : .succeeded
        var activity: ToolActivity
        switch type {
        case "commandExecution":
            let command = Self.displayCommand(item["command"] as? String ?? "")
            activity = ToolActivityFactory.start(id: id, toolName: "shell", arguments: ["command": command])
            // Codex gives no description, so the command is the step's name.
            if !command.isEmpty { activity.title = String(command.prefix(120)) }
            activity.output = (item["aggregatedOutput"] as? String).flatMap { $0.isEmpty ? nil : String($0.suffix(4_000)) }
            if status == "declined" { activity.output = "Declined: Cantrip didn't allow this command." }
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            activity = ToolActivityFactory.start(id: id, toolName: "apply_patch", arguments: nil)
            activity.fileChanges = changes.enumerated().compactMap { index, change in
                guard let path = change["path"] as? String else { return nil }
                return ToolFileChange(id: "\(id)-\(index)", path: path, diff: change["diff"] as? String ?? "")
            }
            let paths = activity.fileChanges.map { ($0.path as NSString).lastPathComponent }
            activity.title = paths.isEmpty ? "Edit files" : "Edit " + paths.joined(separator: ", ")
            if status == "declined" { activity.output = "Declined: Cantrip didn't allow this edit." }
        case "mcpToolCall":
            let server = item["server"] as? String ?? "mcp", tool = item["tool"] as? String ?? "tool"
            activity = ToolActivityFactory.start(id: id, toolName: "\(server)-\(tool)", arguments: item["arguments"])
            activity.title = "\(server): \(tool)"
            if let error = item["error"] as? [String: Any] { activity.output = error["message"] as? String }
            else if let result = item["result"] { activity.output = ToolActivityFactory.detailText(result) }
        case "webSearch":
            activity = ToolActivityFactory.start(id: id, toolName: "web_search", arguments: ["query": item["query"] ?? ""])
            activity.title = "Search the web: \(item["query"] as? String ?? "")"
        case "collabAgentToolCall", "subAgentActivity":
            let prompt = item["prompt"] as? String ?? item["agentPath"] as? String ?? "Subagent"
            activity = ToolActivityFactory.start(id: id, toolName: "agent", arguments: ["description": prompt])
            var info = SubagentInfo(agentID: id, name: "Codex agent", agentType: "codex",
                                    summary: String(prompt.prefix(160)))
            info.model = item["model"] as? String
            info.effort = item["reasoningEffort"] as? String
            info.status = running ? .running : (state == .failed ? .failed : .completed)
            info.canCancel = false
            activity.subagent = info
        case "imageGeneration":
            activity = ToolActivityFactory.start(id: id, toolName: "image_generation", arguments: nil)
            activity.title = "Generate an image"
        default:
            return nil
        }
        activity.state = state
        return activity
    }

    /// `/bin/zsh -lc 'cat a.txt'` → `cat a.txt` (Codex double-quotes commands that contain `'`).
    static func displayCommand(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc ", "/bin/sh -c "] where command.hasPrefix(prefix) {
            let rest = String(command.dropFirst(prefix.count))
            guard rest.count >= 2, let quote = rest.first, quote == "'" || quote == "\"", rest.last == quote else { return rest }
            let inner = String(rest.dropFirst().dropLast())
            if quote == "'" { return inner.replacingOccurrences(of: #"'\''"#, with: "'") }
            return inner.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: #"\"#)
        }
        return command
    }

    /// A command that ran without asking (Codex runs some reads it knows are safe). Under Cantrip
    /// Home only a plain read may do that; anything else escaped the check, so the turn stops.
    private func auditUnchecked(_ item: [String: Any]) {
        guard case .guardrail = access, let id = item["id"] as? String,
              !lock.withLock({ checkedItems.contains(id) }) else { return }
        let command = Self.displayCommand(item["command"] as? String ?? "")
        guard !Self.isKnownRead(command) else { return }
        Log.write("codex: a command ran without Cantrip's check under Home; stopping the turn")
        interruptServerTurn()
        finish(.failure("Codex ran a command Cantrip didn't check (\(command.prefix(80))), so this run stopped."))
    }

    /// Commands Codex runs without asking under `untrusted` are reads; this recognizes them so
    /// the audit doesn't stop a turn for `cat` or `ls`.
    static func isKnownRead(_ command: String) -> Bool {
        let first = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let reads: Set<String> = ["cat", "ls", "pwd", "head", "tail", "wc", "grep", "rg", "find", "echo", "which", "file",
                                  "stat", "sed", "awk", "sort", "uniq", "cut", "nl", "date", "whoami", "uname", "true"]
        let unsafe = [">", "|", ";", "&&", "||", "`", "$(", " -i", " -delete", " -exec"]
        return reads.contains((first as NSString).lastPathComponent) && !unsafe.contains { command.contains($0) }
    }

    // MARK: - Approvals

    func handleServerRequest(_ id: Any, _ method: String, _ params: [String: Any]) {
        guard let server = lock.withLock({ self.server }) else { return }
        let itemID = params["itemId"] as? String
        if let itemID { lock.withLock { _ = checkedItems.insert(itemID) } }
        let action: CantripHomeActionRequest
        let label: String
        let accept: [String: Any], decline: [String: Any]
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let command = Self.displayCommand(params["command"] as? String
                ?? (params["command"] as? [String])?.joined(separator: " ") ?? "")
            action = .shell(command)
            label = "run \(command.prefix(120))"
            accept = ["decision": "accept"]; decline = ["decision": "decline"]
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let paths = lock.withLock { itemID.flatMap { activities[$0]?.fileChanges.map(\.path) } } ?? []
            action = CantripHomeActionRequest(kind: .write, paths: paths)
            label = paths.isEmpty ? "edit files" : "edit " + paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            accept = ["decision": "accept"]; decline = ["decision": "decline"]
        case "mcpServer/elicitation/request":
            let meta = params["_meta"] as? [String: Any] ?? [:]
            guard meta["codex_approval_kind"] as? String == "mcp_tool_call" else {
                // A server asking the user a question: Cantrip has no form for it.
                return server.respond(id: id, result: ["action": "decline"])
            }
            let serverName = params["serverName"] as? String ?? "mcp"
            let tool = (meta["tool_name"] ?? meta["toolName"]) as? String
                ?? Self.quotedTool(in: params["message"] as? String ?? "") ?? "a tool"
            action = CantripHomeActionRequest(kind: .mcp, server: serverName, tool: tool)
            label = "use \(serverName) (\(tool))"
            accept = ["action": "accept", "content": [String: Any]()]; decline = ["action": "decline"]
        case "item/permissions/requestApproval":
            action = CantripHomeActionRequest(kind: .other, command: "more permissions")
            label = "get more permissions"
            accept = ["permissions": params["permissions"] ?? [String: Any](), "scope": "turn"]
            decline = ["permissions": [String: Any](), "scope": "turn"]
        default:
            return server.respondError(id: id, message: "Cantrip doesn't handle \(method).")
        }
        decide(action, label: label) { approved in
            server.respond(id: id, result: approved ? accept : decline)
        }
    }

    /// Cantrip's answer for one tool call: read-only seats only look, Home follows its policy,
    /// everything else asks (or runs, with full access).
    func decide(_ action: CantripHomeActionRequest, label: String, reply: @escaping (Bool) -> Void) {
        let callback = lock.withLock { onEvent }
        if action.kind == .shell, let childPolicy, !readOnly {
            // A child tab's turn for the Simulator, builds and deploys comes first.
            return childPolicy(action, { [weak self] verdict in
                switch verdict {
                case .proceed: self?.decideWithPolicy(action, label: label, callback: callback, reply: reply)
                case .deny(let reason):
                    callback?(.approval(BackendApproval(tool: action.kind.rawValue, decision: "denied", decidedBy: "Child tab rules")))
                    Log.write("codex: child tab rules declined a command: \(reason)")
                    reply(false)
                }
            }, { status in callback?(.status(status)) })
        }
        decideWithPolicy(action, label: label, callback: callback, reply: reply)
    }

    private func decideWithPolicy(_ action: CantripHomeActionRequest, label: String,
                                  callback: ((BackendEvent) -> Void)?, reply: @escaping (Bool) -> Void) {
        func record(_ approved: Bool, by: String) {
            callback?(.approval(BackendApproval(tool: action.kind.rawValue, decision: approved ? "approved" : "denied", decidedBy: by)))
            reply(approved)
        }
        switch access {
        case .readOnly:
            return record(isRead(action), by: "Read-only session")
        case .full:
            return record(true, by: "Act on my behalf")
        case .ask, .policy, .guardrail:
            let approval = CantripHomeApproval.chosen(for: .codex, settings: settings)
            let outcome = AgentPolicyGate.decide(action, guardrail: guardrail, approval: approval,
                                                 label: guardrailLabel, workdir: lock.withLock { workdir })
            switch outcome {
            case .deny(let reason, let by):
                Log.write("codex: \(by) blocked \(action.kind.rawValue): \(reason)")
                callback?(.activity(AgentPolicyGate.denialActivity(action, reason: reason, by: by)))
                record(false, by: by)
            case .allow(let by):
                record(true, by: by)
            case .prompt where isRead(action):
                // Codex asks even for `cat`; plain reads aren't worth a prompt, as with the other backends.
                record(true, by: "Read-only command")
            case .prompt:
                ask("Allow Codex to \(label)?", detail: action.command.isEmpty ? label : action.command, scope: nil,
                    callback: callback, reply: { record($0, by: "User") })
            case .ask(let title, let detail, let scope, let source, _):
                if lock.withLock({ approvedScopes.contains(scope) }) { return record(true, by: "Earlier approval") }
                ask(title, detail: detail, scope: scope, source: source, callback: callback, reply: { record($0, by: "User") })
            }
        }
    }

    private func isRead(_ action: CantripHomeActionRequest) -> Bool {
        action.kind == .read || (action.kind == .shell && Self.isKnownRead(action.command))
    }

    private func ask(_ title: String, detail: String, scope: String?, source: String? = nil,
                     callback: ((BackendEvent) -> Void)?, reply: @escaping (Bool) -> Void) {
        guard let callback else { return reply(false) }
        let request = BackendInputRequest(kind: .approval, source: source ?? (guardrail != nil ? "Cantrip Home" : "Codex"),
                                          title: title, detail: detail) { [weak self] answer in
            let approved = answer.decision == .approve
            if approved, let scope, !scope.isEmpty { self?.lock.withLock { _ = self?.approvedScopes.insert(scope) } }
            reply(approved)
        }
        let id = request.snapshot.id
        lock.withLock { pendingInputs[id] = request }
        request.onResolved = { [weak self] in _ = self?.lock.withLock { self?.pendingInputs.removeValue(forKey: id) } }
        callback(.inputRequired(request))
    }

    private func cancelPendingInputs() {
        let requests = lock.withLock { () -> [BackendInputRequest] in
            defer { pendingInputs.removeAll() }
            return Array(pendingInputs.values)
        }
        requests.forEach { $0.cancel() }
    }

    // MARK: - Helpers

    private static let imagePrefixes = [("[Attached image — read this file with your Read/view tool: ", "]"), ("(Attached image: ", ")")]

    /// Images attached to the prompt, sent to Codex as images rather than paths to read.
    static func imagePaths(in prompt: String) -> [String] {
        var paths: [String] = []
        for (prefix, close) in imagePrefixes {
            var range = prompt.startIndex..<prompt.endIndex
            while let start = prompt.range(of: prefix, range: range),
                  let end = prompt.range(of: close, range: start.upperBound..<prompt.endIndex) {
                let path = String(prompt[start.upperBound..<end.lowerBound])
                if FileManager.default.fileExists(atPath: path) { paths.append(path) }
                range = end.upperBound..<prompt.endIndex
            }
        }
        return paths
    }

    static func textWithoutImages(_ prompt: String) -> String { prompt }

    /// `Allow the echo MCP server to run tool "shout"?` → `shout` (Codex 0.166 names the tool only there).
    static func quotedTool(in message: String) -> String? {
        guard let start = message.range(of: "tool \""),
              let end = message.range(of: "\"", range: start.upperBound..<message.endIndex) else { return nil }
        let tool = String(message[start.upperBound..<end.lowerBound])
        return tool.isEmpty ? nil : tool
    }

    static func launchFailureText(_ error: Error) -> String {
        let text = error.localizedDescription
        if text == "codex not found" {
            return "Codex CLI not found. Install it (`npm install -g @openai/codex` or the Codex app), run `codex login`, then try again."
        }
        return "Codex: \(text)"
    }
}

extension CodexBackend: CantripHomeProtocolCarrier {}
