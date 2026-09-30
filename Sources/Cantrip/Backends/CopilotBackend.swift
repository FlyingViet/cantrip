import Foundation

/// One SDK session per tab, with native immediate delivery during an active turn.
/// A stopped/crashed runtime is rebuilt from Cantrip's journal and recent history,
/// never by replaying possibly accepted session.send requests.
final class CopilotBackend: Backend {
    var modelOverride: String?
    var effortOverride: String?
    var contextTierOverride: String?
    var readOnly = false
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

        var json: [String: Any] {
            ["command": command, "workdir": workdir, "model": model,
             "effort": effort, "contextTier": contextTier,
             "allowTools": allowTools, "readOnly": readOnly, "autoApprove": autoApprove,
             "allowSubagents": allowSubagents, "mcpApps": mcpApps,
             "subagentGuidance": allowSubagents ? CopilotBackend.subagentGuidance : ""]
        }
    }

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
            mcpApps: settings.copilotMCPApps
        )
        queue.async { [weak self] in
            guard let self else { return }
            guard self.runID == nil else {
                onEvent(.failure("Copilot already has a running turn. Queue this message instead."))
                return
            }
            if self.configuration != config || self.process?.isRunning != true {
                self.teardown()
            }
            self.onEvent = onEvent
            let id = UUID().uuidString
            self.runID = id
            self.ready = false
            self.idle = false
            self.parser = CopilotJSONStreamParser(canCancelSubagents: true)
            do {
                var command: [String: Any] = [
                    "kind": "start", "runID": id, "config": config.json, "prompt": request.prompt
                ]
                if self.process == nil {
                    command["initialPrompt"] = ConversationContextBuilder.composePrompt(
                        currentPrompt: request.prompt, query: request.userMessage, turns: request.previousTurns
                    )
                    try self.launch(config)
                }
                self.askpass?.beginTurn()
                onEvent(.status("Connecting to Copilot"))
                try self.write(command)
                self.queue.asyncAfter(deadline: .now() + 45) { [weak self] in
                    guard let self, self.runID == id, !self.ready, self.inputRequests.isEmpty else { return }
                    self.fail("Copilot session startup timed out. Update the CLI and check its sign-in.")
                }
            } catch {
                self.fail("Could not start Copilot: \(error.localizedDescription)")
            }
        }
    }

    func injectMidTurn(_ text: String, completion: @escaping (MidTurnDelivery) -> Void) {
        queue.async { [weak self] in
            guard let self, self.ready, let runID = self.runID,
                  self.process?.isRunning == true else {
                completion(.notSent)
                return
            }
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
        queue.async { [weak self] in self?.teardown() }
    }
    func reset() { cancel() }

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
                    if self.runID != nil {
                        self.fail("Copilot session disconnected (status \(proc.terminationStatus)). Check Node.js, the Copilot CLI version, and CLI sign-in on the Mac.")
                    } else { self.teardown() }
                }
            }
        }
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
        configuration = config
        Log.write("copilot: native session bridge started, pid=\(p.processIdentifier)")
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
                    onEvent?(.inputRequired(request))
                case "inputClosed":
                    if let id = object["id"] as? String { inputRequests.removeValue(forKey: id)?.cancel() }
                case "started":
                    ready = true
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
                    for event in events { onEvent?(event) }
                case "approval":
                    onEvent?(.approval(BackendApproval(
                        tool: object["tool"] as? String ?? "tool",
                        decision: object["decision"] as? String ?? "denied", decidedBy: "Cantrip"
                    )))
                case "done":
                    idle = true
                    ready = false
                    finishIfIdle()
                case "failure":
                    fail(object["message"] as? String ?? "Copilot session failed.")
                default:
                    throw CocoaError(.coderReadCorrupt)
                }
            } catch {
                fail("Invalid response from Copilot session bridge: \(error.localizedDescription)")
                return
            }
        }
    }

    private func finishIfIdle() {
        guard idle, runID != nil, deliveries.isEmpty else { return }
        askpass?.endTurn()
        let sink = onEvent
        runID = nil
        onEvent = nil
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
        runID = nil
        ready = false
        idle = false
        onEvent = nil
        configuration = nil
        if let old { Self.terminate(old) }
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
