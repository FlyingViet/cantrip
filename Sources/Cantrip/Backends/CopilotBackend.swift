import Foundation

/// One SDK session per tab, with native immediate delivery during an active turn.
/// A lost runtime is replaced and its Copilot session resumed. A prompt is resent only when
/// nothing of its turn (text, tools, approvals, steering) reached the user, and only once.
final class CopilotBackend: Backend, CantripHomeGuardedBackend {
    var modelOverride: String?
    var effortOverride: String?
    var contextTierOverride: String?
    var readOnly = false
    /// Receives each CLI session ID this backend runs on (called on the backend queue).
    var onAgentSession: ((String) -> Void)?
    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "copilot-backend")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var parser = CopilotJSONStreamParser(canCancelSubagents: true)
    private var configuration: Configuration?
    private var runID: String?
    private var onEvent: ((BackendEvent) -> Void)?
    private let availabilityLock = NSLock()
    private var injectionAvailable = false
    private var ready = false {
        didSet { availabilityLock.withLock { injectionAvailable = ready } }
    }
    private var idle = false
    private var deliveries: [String: (MidTurnDelivery) -> Void] = [:]
    private var appRequests: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var cancelRequests: [String: (Result<Bool, Error>) -> Void] = [:]
    private var inputRequests: [String: BackendInputRequest] = [:]
    private var askpass: RemoteAskpass?
    private let bridgeScript: String
    private let guardrailLock = NSLock()
    private var storedGuardrail: CantripHomeGuardrail?
    private var storedGuardrailLabel = "Cantrip Home"
    /// Actions the user approved during the current turn (queue-owned).
    private var approvedScopes: Set<String> = []
    /// The Copilot CLI runtime has crashed (stack overflow) on the first request after
    /// 9.5-19 hours idle, while reuse after up to 8 hours was fine. A runtime idle this long
    /// is restarted before reuse, resuming the same Copilot session.
    var idleRuntimeLimit: TimeInterval = 2 * 60 * 60
    /// A healthy idle runtime accepts a prompt in well under a second.
    var reusedStartupLimit: TimeInterval = 30
    /// New runtimes accepted prompts within about 5 seconds; resuming a long session takes longer.
    var newRuntimeStartupLimit: TimeInterval = 60
    /// Queue-owned startup state that lets a lost runtime be replaced without losing the prompt.
    private struct Attempt {
        let request: BackendRequest
        let config: Configuration
        let number: Int
        let newRuntime: Bool
        let startedAt: Date
        var accepted = false
        /// Text, reasoning, tool activity, approvals or steering reached this turn. Replaying it
        /// could repeat work, so a lost runtime then ends the turn instead of retrying.
        var visibleOutput = false
    }
    private var attempt: Attempt?
    /// The Copilot session this tab last ran, and the one to resume in the next new runtime.
    private var agentSessionID: String?
    private var resumeTarget: (sessionID: String, config: Configuration)?
    private var lastTurnEnded: Date?

    var guardrail: CantripHomeGuardrail? {
        get { guardrailLock.withLock { storedGuardrail } }
        set { guardrailLock.withLock { storedGuardrail = newValue } }
    }

    var guardrailLabel: String {
        get { guardrailLock.withLock { storedGuardrailLabel } }
        set { guardrailLock.withLock { storedGuardrailLabel = newValue } }
    }

    struct Configuration: Equatable {
        let command: String
        let workdir: String
        let model: String
        let effort: String
        let contextTier: String
        let allowTools: Bool
        let readOnly: Bool
        var autoApprove = true
        var allowSubagents = true
        var mcpApps = true
        /// Cantrip Home sessions route every tool request through the host's action policy.
        var guardrail: String?

        var json: [String: Any] {
            var object: [String: Any] = ["command": command, "workdir": workdir, "model": model,
             "effort": effort, "contextTier": contextTier,
             "allowTools": allowTools, "readOnly": readOnly, "autoApprove": autoApprove,
             "allowSubagents": allowSubagents, "mcpApps": mcpApps,
             "systemGuidance": CopilotBackend.systemGuidance(allowSubagents: allowSubagents)]
            if let guardrail { object["guardrail"] = guardrail }
            return object
        }
    }

    static func systemGuidance(allowSubagents: Bool) -> String {
        allowSubagents ? previewGuidance + "\n\n" + subagentGuidance : previewGuidance
    }

    /// Appended once to the session's system message, so images reach the Remote apps.
    static let previewGuidance = RemoteGeneratedImages.agentGuidance(sessionFilesFolder: true)

    /// Appended once to the session's system message (not to every prompt).
    static let subagentGuidance = """
    Subagents cost extra tokens and time. Delegate only when that saves main-context \
    tokens or wall time: broad multi-file exploration (explore), noisy builds, tests or \
    installs where only the outcome matters (task), or genuinely independent threads run \
    in parallel. Do small lookups and edits yourself. Give each subagent a complete, \
    self-contained brief and ask for a concise result: findings with file:line, or pass/fail \
    with only the relevant errors. Don't re-read what a subagent reported or launch \
    speculative agents.

    For passive waiting after you have already started an external build, TestFlight upload, \
    download, or similar long-running job, launch one background `task` agent whose name \
    starts with `watch-`. Its only job is to wait with a bounded timeout, verify the terminal \
    result, and report it; it must not edit files or start the job again. Continue all \
    independent work immediately. Do not call `read_agent` or keep the root turn blocked only \
    to poll a `watch-` agent. When your immediate work is done, briefly tell the user the \
    watcher is continuing and finish the root turn. Cantrip keeps that run available, wakes \
    you when the watcher finishes, and asks you to read its result once so you can continue \
    from the exact point you paused. Never use the `watch-` prefix for implementation, \
    research, or other delegated work. While only `watch-*` agents remain, Cantrip may deliver \
    new user prompts immediately into the idle root; handle them as normal new work without \
    waiting for the watcher or describing them as queued. Wait for every other background \
    agent before finishing your reply.
    """

    init(bridgeScript: String = CopilotSessionBridge.script) {
        self.bridgeScript = bridgeScript
    }

    deinit {
        input?.closeFile()
        if let process { Self.terminate(process) }
    }

    var supportsMidTurnInjection: Bool {
        availabilityLock.withLock { injectionAvailable }
    }

    func send(_ request: BackendRequest, workdir: String,
              onEvent: @escaping (BackendEvent) -> Void) {
        let config = Configuration(
            command: settings.copilotPath.trimmingCharacters(in: .whitespaces).isEmpty
                ? "copilot" : settings.copilotPath,
            workdir: workdir,
            model: modelOverride ?? settings.copilotModel,
            effort: effortOverride ?? settings.copilotEffort,
            contextTier: contextTierOverride ?? settings.copilotContextTier,
            allowTools: settings.copilotAllowTools || settings.allowActions,
            readOnly: readOnly, autoApprove: settings.allowActions,
            allowSubagents: settings.copilotAllowSubagents,
            mcpApps: settings.copilotMCPApps,
            guardrail: guardrail?.rawValue
        )
        queue.async { [weak self] in
            guard let self else { return }
            guard self.runID == nil else {
                onEvent(.failure("Copilot already has a running turn. Queue this message instead."))
                return
            }
            self.onEvent = onEvent
            let id = UUID().uuidString
            self.runID = id
            if self.resumeTarget?.config != config { self.resumeTarget = nil }
            if self.process?.isRunning == true, self.configuration == config,
               let ended = self.lastTurnEnded, Date().timeIntervalSince(ended) >= self.idleRuntimeLimit,
               let session = self.agentSessionID {
                Log.write(String(format: "copilot: restarting a runtime idle for %.1f h before reuse", Date().timeIntervalSince(ended) / 3600))
                self.resumeTarget = (session, config)
                let old = self.stopProcess()
                self.afterExit(of: old) { [weak self] in
                    guard let self, self.runID == id, self.process == nil else { return }
                    self.begin(id, request: request, config: config, number: 1)
                }
                return
            }
            if self.configuration != config || self.process?.isRunning != true {
                self.stopProcess()
            }
            self.begin(id, request: request, config: config, number: 1)
        }
    }

    /// Writes the turn's start command, launching (or resuming in) a new runtime when none is live.
    private func begin(_ id: String, request: BackendRequest, config: Configuration, number: Int) {
        approvedScopes = []
        ready = false
        idle = false
        parser = CopilotJSONStreamParser(canCancelSubagents: true)
        do {
            var command: [String: Any] = [
                "kind": "start", "runID": id, "config": config.json, "prompt": request.prompt
            ]
            let newRuntime = process == nil
            if newRuntime {
                command["initialPrompt"] = ConversationContextBuilder.composePrompt(
                    currentPrompt: request.prompt, query: request.userMessage, turns: request.previousTurns
                )
                if let target = resumeTarget, target.config == config {
                    command["resumeSessionID"] = target.sessionID
                }
                resumeTarget = nil
                try launch(config)
            }
            attempt = Attempt(request: request, config: config, number: number,
                              newRuntime: newRuntime, startedAt: Date())
            askpass?.beginTurn()
            onEvent?(.status(number == 1 ? "Connecting to Copilot" : "Restarting Copilot"))
            try write(command)
            let limit = newRuntime ? newRuntimeStartupLimit : reusedStartupLimit
            queue.asyncAfter(deadline: .now() + limit) { [weak self] in
                guard let self, self.runID == id, self.attempt?.number == number,
                      !self.ready, self.inputRequests.isEmpty else { return }
                self.runtimeLost("no reply to the prompt within \(Int(limit)) s",
                                 otherwise: Self.startupFailure)
            }
        } catch {
            fail("Could not start Copilot: \(error.localizedDescription)")
        }
    }

    static let startupFailure = "Copilot didn't start, even after Cantrip restarted it. Check that the Copilot CLI works and is signed in on the Mac, then send again."
    static let lostMidReply = "Copilot's runtime stopped unexpectedly mid-reply. The conversation is kept, so resuming continues it in a new runtime."

    /// The runtime died, stalled or rejected a prompt it should have accepted. Before anything
    /// reached the turn, it is replaced once and the prompt resent in the same Copilot session;
    /// otherwise the turn ends now (rather than waiting out the stall timer), and the next prompt
    /// resumes the session in a new runtime.
    private func runtimeLost(_ reason: String, otherwise message: String) {
        guard let id = runID, let current = attempt else {
            Log.write("copilot: runtime lost outside a turn (\(reason))")
            return fail(message)
        }
        let session = agentSessionID
        if current.number == 1, !current.visibleOutput, inputRequests.isEmpty, deliveries.isEmpty {
            Log.write("copilot: runtime lost before replying (\(reason)); retrying in a new runtime")
            if let session { resumeTarget = (session, current.config) }
            // Supersede attempt 1 now, so its startup timer can't start a second retry while waiting.
            attempt = nil
            let old = stopProcess()
            afterExit(of: old) { [weak self] in
                guard let self, self.runID == id, self.attempt == nil, self.process == nil else { return }
                self.begin(id, request: current.request, config: current.config, number: 2)
            }
            return
        }
        Log.write("copilot: runtime lost (\(reason)); attempt \(current.number), output \(current.visibleOutput)")
        if let session { resumeTarget = (session, current.config) }
        fail(current.accepted && current.visibleOutput ? Self.lostMidReply : message)
    }

    /// Runs `body` on the queue once `process` has exited (or after a bounded wait), so a resumed
    /// session never overlaps the runtime that still holds it.
    private func afterExit(of process: Process?, _ body: @escaping () -> Void, deadline: Date = Date().addingTimeInterval(4)) {
        guard let process, process.isRunning, Date() < deadline else { return body() }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.afterExit(of: process, body, deadline: deadline)
        }
    }

    func injectMidTurn(_ text: String, completion: @escaping (MidTurnDelivery) -> Void) {
        queue.async { [weak self] in
            guard let self, self.ready, let runID = self.runID,
                  self.process?.isRunning == true else {
                completion(.notSent)
                return
            }
            self.attempt?.visibleOutput = true
            let id = UUID().uuidString
            self.deliveries[id] = completion
            do {
                try self.write(["kind": "inject", "runID": runID, "id": id, "text": text])
            } catch {
                self.deliveries.removeValue(forKey: id)?(.uncertain(
                    "Copilot's input channel failed; delivery could not be confirmed."
                ))
                self.fail("Copilot's input channel failed: \(error.localizedDescription)")
                return
            }
            self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self else { return }
                self.deliveries.removeValue(forKey: id)?(.uncertain(
                    "Copilot did not acknowledge the context in time. It was not resent."
                ))
                self.finishIfIdle()
            }
        }
    }

    func cancel() {
        availabilityLock.withLock { injectionAvailable = false }
        queue.async { [weak self] in
            guard let self else { return }
            // Stopping a live turn starts the next one fresh; a runtime already lost (Cantrip cancels
            // after every failure) keeps its session for the next prompt or automatic resume.
            if self.runID != nil { self.resumeTarget = nil }
            self.teardown()
        }
    }

    func reset() {
        cancel()
        queue.async { [weak self] in
            self?.resumeTarget = nil
            self?.agentSessionID = nil
        }
    }

    /// Proxies an MCP App view's `tools/call`, `tools/list` or `resources/read`
    /// to its server through this tab's live session, between turns too.
    /// Completion runs on the backend queue.
    func mcpAppRequest(serverName: String, method: String, params: [String: Any],
                       completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, self.process?.isRunning == true, self.configuration?.mcpApps == true else {
                completion(.failure(MCPAppRequestError.sessionUnavailable))
                return
            }
            guard ["tools/call", "tools/list", "resources/read"].contains(method),
                  !serverName.isEmpty, JSONSerialization.isValidJSONObject(params) else {
                completion(.failure(MCPAppRequestError.invalidRequest))
                return
            }
            let id = UUID().uuidString
            self.appRequests[id] = completion
            do {
                try self.write(["kind": "appRequest", "id": id, "serverName": serverName,
                                "method": method, "params": params])
            } catch {
                self.appRequests.removeValue(forKey: id)?(.failure(error))
                return
            }
            self.queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.appRequests.removeValue(forKey: id)?(.failure(MCPAppRequestError.timedOut))
            }
        }
    }

    /// Stops one running subagent in this tab's live session. `true` = stopped,
    /// `false` = it had already finished. Completion runs on the backend queue.
    func cancelSubagent(agentID: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, self.process?.isRunning == true else {
                completion(.failure(SubagentCancelError.sessionUnavailable))
                return
            }
            let id = UUID().uuidString
            self.cancelRequests[id] = completion
            do {
                try self.write(["kind": "cancelAgent", "id": id, "agentID": agentID])
            } catch {
                self.cancelRequests.removeValue(forKey: id)?(.failure(error))
                return
            }
            self.queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.cancelRequests.removeValue(forKey: id)?(.failure(SubagentCancelError.timedOut))
            }
        }
    }

    private func launch(_ config: Configuration) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "exec node --input-type=module -e \"$1\"", "cantrip-copilot", bridgeScript]
        p.currentDirectoryURL = URL(fileURLWithPath: config.workdir)
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        // The runtime only honours `enableMcpApps` while its MCP_APPS gate is on.
        if config.mcpApps { environment["COPILOT_MCP_APPS"] = "true" }
        if !config.readOnly {
            let broker = try RemoteAskpass(process: p) { [weak self] request in
                self?.queue.async {
                    guard let self, self.process === p, self.runID != nil else { request.cancel(); return }
                    self.ready = true
                    self.onEvent?(.inputRequired(request))
                }
            }
            environment.merge(broker.environment) { _, new in new }
            askpass = broker
        }
        p.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let outputLock = NSLock()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            outputLock.withLock {
                let data = handle.availableData
                self?.queue.async { [weak self] in
                    guard let self, self.process === p else { return }
                    self.consume(data)
                }
            }
        }
        // Drain stderr without exposing SDK authentication payloads in logs/Remote.
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        p.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            outputLock.withLock {
                let tail = stdout.fileHandleForReading.readDataToEndOfFile()
                self?.queue.async { [weak self] in
                    guard let self, self.process === proc else { return }
                    self.consume(tail)
                    guard self.process === proc else { return }
                    let reason = proc.terminationReason == .uncaughtSignal
                        ? "signal \(proc.terminationStatus)" : "status \(proc.terminationStatus)"
                    if self.runID != nil {
                        self.runtimeLost("session bridge exited with \(reason)",
                                         otherwise: "Copilot session disconnected (\(reason)). Check Node.js, the Copilot CLI version, and CLI sign-in on the Mac.")
                    } else {
                        self.rememberLostIdleRuntime("session bridge exited with \(reason)")
                    }
                }
            }
        }
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
        configuration = config
        Log.write("copilot: native session bridge started, pid=\(p.processIdentifier)")
    }

    /// Decides one Home tool request with the host policy (queue-owned). Asked actions become
    /// a normal approval request, so they reach the user's phone and expire like any other.
    private func answerPolicy(id: String, owner: String, detail: String) {
        func reply(_ approved: Bool, _ feedback: String? = nil) {
            var answer: [String: Any] = ["kind": "inputAnswer", "runID": owner, "id": id,
                                         "decision": approved ? "approve" : "deny"]
            if let feedback { answer["text"] = feedback }
            do { try write(answer) }
            catch { fail("Could not deliver Cantrip's decision to Copilot. It was not retried.") }
        }
        guard let request = CantripHomeActionRequest(copilotJSON: detail) else {
            return reply(false, "Cantrip couldn't read this tool request, so it was not run.")
        }
        let mode = guardrail ?? .unattended
        // The mode this turn started with ("Act on my behalf"), matching the bridge's own checks.
        let approval: CantripHomeApproval = configuration?.autoApprove == true ? .automatic : .ask
        let decision = CantripHomeActionPolicy.evaluate(
            request, mode: mode, approval: approval,
            environment: .current(workdir: configuration?.workdir ?? "")
        )
        if decision.verdict == .deny {
            Log.write("home policy: denied \(request.kind.rawValue): \(request.command.prefix(160))")
            return reply(false, decision.reason)
        }
        if decision.verdict == .allow, approval.runsWithoutAsking(request) {
            if decision.automatic {
                Log.write("home policy: approved \(decision.action) automatically (Act on my behalf)")
            }
            return reply(true)
        }
        if decision.verdict == .ask, approvedScopes.contains(decision.scope) { return reply(true) }
        let label = guardrailLabel
        let title = decision.verdict == .ask
            ? "\(label) wants to \(decision.action)"
            : "Allow \(request.kind.rawValue)?"
        let detailText = decision.verdict == .ask ? decision.detail
            : String((request.command.isEmpty ? request.paths.joined(separator: "\n") : request.command).prefix(2_000))
        let scope = decision.scope
        let pending = BackendInputRequest(
            kind: .approval, source: "Cantrip Home", title: title, detail: detailText
        ) { [weak self] answer in
            self?.queue.async {
                guard let self, self.runID == owner,
                      self.inputRequests.removeValue(forKey: id) != nil else { return }
                if answer.decision == .approve {
                    if !scope.isEmpty { self.approvedScopes.insert(scope) }
                    reply(true)
                } else {
                    let what = decision.action.isEmpty ? "this action" : decision.action
                    reply(false, answer.decision == .deny
                        ? "The user declined to \(what). Don't retry it another way; say in your reply that it was skipped."
                        : "No approval arrived to \(what), so it was skipped. Say so in your reply.")
                }
            }
        }
        Log.write("home policy: asking the user before \(decision.action.isEmpty ? request.kind.rawValue : decision.action)")
        inputRequests[id] = pending
        ready = true
        onEvent?(.inputRequired(pending))
    }

    private func write(_ object: [String: Any]) throws {
        guard let input else { throw CocoaError(.fileWriteUnknown) }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            do {
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let kind = object["kind"] as? String else {
                    throw CocoaError(.coderReadCorrupt)
                }
                if kind == "log" {
                    Log.write("copilot: \(String((object["message"] as? String ?? "").prefix(300)))")
                    continue
                }
                if kind == "runtimeExited" {
                    let detail = String((object["detail"] as? String ?? "unknown").prefix(120))
                    if runID != nil {
                        runtimeLost("runtime exited (\(detail))", otherwise: Self.startupFailure)
                    } else {
                        rememberLostIdleRuntime("runtime exited (\(detail))")
                    }
                    return
                }
                if kind == "appResponse" {
                    guard let id = object["id"] as? String,
                          let completion = appRequests.removeValue(forKey: id) else { continue }
                    if let result = object["result"] as? [String: Any] {
                        completion(.success(result))
                    } else {
                        completion(.failure(MCPAppRequestError.server(
                            object["error"] as? String ?? "The MCP server request failed.")))
                    }
                    continue
                }
                if kind == "agentCancelResponse" {
                    guard let id = object["id"] as? String,
                          let completion = cancelRequests.removeValue(forKey: id) else { continue }
                    if let cancelled = object["cancelled"] as? Bool {
                        completion(.success(cancelled))
                    } else {
                        completion(.failure(SubagentCancelError.server(
                            object["error"] as? String ?? "Copilot couldn't stop the subagent.")))
                    }
                    continue
                }
                guard let current = runID, object["runID"] as? String == current else { continue }
                switch kind {
                case "input" where object["inputKind"] as? String == "policy":
                    guard let id = object["id"] as? String else { throw CocoaError(.coderReadCorrupt) }
                    attempt?.visibleOutput = true
                    answerPolicy(id: id, owner: current, detail: object["detail"] as? String ?? "")
                case "input":
                    guard let id = object["id"] as? String,
                          let rawKind = object["inputKind"] as? String,
                          let inputKind = InputRequestSnapshot.Kind(rawValue: rawKind),
                          [.approval, .question].contains(inputKind) else { throw CocoaError(.coderReadCorrupt) }
                    let owner = current
                    let request = BackendInputRequest(kind: inputKind, source: "Copilot",
                        title: object["title"] as? String ?? "Input needed",
                        detail: object["detail"] as? String ?? "",
                        choices: object["choices"] as? [String] ?? [],
                        allowsFreeform: object["allowsFreeform"] as? Bool ?? false) { [weak self] answer in
                        self?.queue.async {
                            guard let self, self.runID == owner, self.inputRequests.removeValue(forKey: id) != nil else { return }
                            do {
                                var reply: [String: Any] = ["kind": "inputAnswer", "runID": owner, "id": id,
                                                          "decision": answer.decision.rawValue]
                                if let text = answer.text { reply["text"] = text }
                                try self.write(reply)
                            } catch { self.fail("Could not deliver your response to Copilot. It was not retried.") }
                        }
                    }
                    inputRequests[id] = request
                    ready = true
                    attempt?.visibleOutput = true
                    onEvent?(.inputRequired(request))
                case "inputClosed":
                    if let id = object["id"] as? String { inputRequests.removeValue(forKey: id)?.cancel() }
                case "started":
                    ready = true
                    if let session = object["sessionID"] as? String {
                        agentSessionID = session
                        onAgentSession?(session)
                    }
                    if let started = attempt?.startedAt {
                        let how = attempt?.newRuntime == true
                            ? (object["resumed"] as? Bool == true ? "new runtime, resumed session" : "new runtime")
                            : "reused runtime"
                        Log.write(String(format: "copilot: prompt accepted in %.1f s (%@, attempt %d)",
                                         Date().timeIntervalSince(started), how, attempt?.number ?? 1))
                    }
                    attempt?.accepted = true
                    onEvent?(.status("Thinking..."))
                case "watcherWaiting":
                    let count = object["count"] as? Int ?? 1
                    onEvent?(.status(count == 1
                        ? "Background watcher running"
                        : "\(count) background watchers running"))
                case "watcherResuming":
                    onEvent?(.status("Watcher finished; resuming..."))
                case "delivery":
                    guard let id = object["id"] as? String,
                          let completion = deliveries.removeValue(forKey: id) else { continue }
                    switch object["status"] as? String {
                    case "accepted":
                        completion(.accepted(messageID: object["messageID"] as? String))
                    case "notSent": completion(.notSent)
                    default: completion(.uncertain(
                        object["message"] as? String ?? "Copilot context delivery is uncertain."
                    ))
                    }
                    finishIfIdle()
                case "event":
                    guard let event = object["event"] as? [String: Any] else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    var encoded = try JSONSerialization.data(withJSONObject: event)
                    encoded.append(0x0A)
                    let events = parser.consume(encoded) { error, _ in
                        Log.write("copilot: \(error.localizedDescription)")
                    }
                    if events.contains(where: \.isVisibleOutput) { attempt?.visibleOutput = true }
                    for event in events { onEvent?(event) }
                case "approval":
                    attempt?.visibleOutput = true
                    onEvent?(.approval(BackendApproval(
                        tool: object["tool"] as? String ?? "tool",
                        decision: object["decision"] as? String ?? "denied", decidedBy: "Cantrip"
                    )))
                case "done":
                    idle = true
                    ready = false
                    finishIfIdle()
                case "failure":
                    let message = object["message"] as? String ?? "Copilot session failed."
                    // An idle runtime that rejects a prompt before accepting it is broken; a new one may not be.
                    if let current = attempt, !current.newRuntime, !current.accepted {
                        runtimeLost("reused runtime rejected the prompt: \(message.prefix(200))", otherwise: message)
                        return
                    }
                    fail(message)
                default:
                    throw CocoaError(.coderReadCorrupt)
                }
            } catch {
                fail("Invalid response from Copilot session bridge: \(error.localizedDescription)")
                return
            }
        }
    }

    /// A runtime that died between turns is replaced on the next prompt, resuming its session.
    private func rememberLostIdleRuntime(_ reason: String) {
        if let session = agentSessionID, let config = configuration { resumeTarget = (session, config) }
        Log.write("copilot: idle runtime lost (\(reason)); the next prompt resumes its session in a new runtime")
        teardown()
    }

    private func finishIfIdle() {
        guard idle, runID != nil, deliveries.isEmpty else { return }
        askpass?.endTurn()
        let sink = onEvent
        runID = nil
        onEvent = nil
        attempt = nil
        lastTurnEnded = Date()
        sink?(.done)
    }

    private func resolveUncertainDeliveries() {
        let callbacks = deliveries.values
        deliveries.removeAll()
        for callback in callbacks {
            callback(.uncertain("Copilot disconnected before acknowledging context. It was not resent."))
        }
    }

    private func fail(_ message: String) {
        let sink = onEvent
        teardown()
        sink?(.failure(message))
    }

    private func teardown() {
        stopProcess()
        runID = nil
        onEvent = nil
        attempt = nil
    }

    /// Ends the runtime and everything tied to it, keeping the current turn so it can retry.
    @discardableResult
    private func stopProcess() -> Process? {
        let pendingInputs = Array(inputRequests.values)
        inputRequests.removeAll()
        for request in pendingInputs { request.cancel() }
        askpass?.stop()
        askpass = nil
        resolveUncertainDeliveries()
        let pendingAppRequests = Array(appRequests.values)
        appRequests.removeAll()
        for completion in pendingAppRequests { completion(.failure(MCPAppRequestError.sessionUnavailable)) }
        let pendingCancels = Array(cancelRequests.values)
        cancelRequests.removeAll()
        for completion in pendingCancels { completion(.failure(SubagentCancelError.sessionUnavailable)) }
        let old = process
        process = nil
        input?.closeFile()
        input = nil
        buffer.removeAll()
        ready = false
        idle = false
        configuration = nil
        if let old { Self.terminate(old) }
        return old
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

private extension BackendEvent {
    /// Output the user can see, which a replayed prompt could repeat.
    var isVisibleOutput: Bool {
        switch self {
        case .textDelta, .thinkingDelta, .activity, .approval, .inputRequired: true
        case .status, .usage, .context, .done, .failure: false
        }
    }
}
