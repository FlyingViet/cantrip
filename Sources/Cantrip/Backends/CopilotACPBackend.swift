import Foundation
import Network

/// Connects to a GitHub Copilot CLI instance running as an ACP server
/// (Agent Client Protocol: JSON-RPC 2.0 as newline-delimited JSON).
///
/// Start the server wherever you like:
///     copilot --acp --port 3000            # local machine
///     ssh box -L 3000:127.0.0.1:3000 \
///         'copilot --acp --port 3000'      # remote machine, tunneled
/// then point Cantrip's "Copilot Remote" backend at host:port. The server
/// binds loopback by default, so a tunnel (ssh -L / tailscale) is the
/// safe way to reach a remote instance.
///
/// Flow: initialize → session/new (per conversation) → session/prompt per
/// turn. The server streams session/update notifications (message chunks,
/// thoughts, tool calls, plans) and sends session/request_permission when
/// a tool needs approval — answered here from Cantrip's settings:
/// allowActions (and not readOnly) approves, anything else declines.
final class CopilotACPBackend: Backend {
    /// Kept for council API parity; the model is whatever the ACP server
    /// was started with — there is no per-session override in ACP.
    var modelOverride: String?
    /// Council advisors: decline every permission request so the seat
    /// can't take actions even against a permissive server.
    var readOnly = false

    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "cantrip.acp")
    private var connection: NWConnection?
    private var connectedEndpoint: String?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (_ result: [String: Any]?, _ error: [String: Any]?) -> Void] = [:]
    private var sessionID: String?
    private var initialized = false
    private var currentOnEvent: ((BackendEvent) -> Void)?
    private var promptInFlight = false
    /// Request id of the outstanding session/prompt, so an interrupt can
    /// re-route its eventual (cancelled) response into a silent drain.
    private var promptRequestID: Int?
    /// After an interrupt: swallow session/update noise from the aborted
    /// turn until its prompt response drains (ACP runs one turn at a time
    /// per session, so the redirect prompt also waits behind this).
    private var suppressUpdates = false
    private var queuedPrompt: (text: String, gen: Int)?
    /// Bumped on cancel/reset/interrupt so stale handlers can't touch a
    /// newer turn.
    private var generation = 0
    private var activities: [String: ToolActivity] = [:]

    deinit {
        connection?.cancel() // don't leak the socket with a closed tab
    }

    // MARK: - Backend

    func send(
        _ request: BackendRequest,
        workdir: String,
        onEvent: @escaping (BackendEvent) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.currentOnEvent = onEvent
            self.activities.removeAll()
            let gen = self.generation
            onEvent(.status("Connecting to Copilot"))
            self.withReadySession(workdir: workdir, generation: gen) { [weak self] in
                self?.sendPrompt(request.prompt, generation: gen)
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            if self.promptInFlight, let sessionID = self.sessionID {
                self.notify("session/cancel", params: ["sessionId": sessionID])
            }
            self.promptInFlight = false
            self.promptRequestID = nil
            self.suppressUpdates = false
            self.queuedPrompt = nil
            self.currentOnEvent = nil
            self.pending.removeAll()
        }
    }

    func reset() {
        cancel()
        queue.async { [weak self] in self?.sessionID = nil }
    }

    func interruptTurn() -> Bool {
        var interrupted = false
        queue.sync {
            guard promptInFlight, let sessionID else { return }
            notify("session/cancel", params: ["sessionId": sessionID])
            // Same idiom as ClaudeCodeBackend's interrupt: the aborted
            // turn's response must NOT reach the next turn. Bump the
            // generation (stale completions drop), silence its updates,
            // and reroute its pending response into a drain that releases
            // the queued redirect prompt.
            generation += 1
            let gen = generation
            promptInFlight = false
            suppressUpdates = true
            if let pid = promptRequestID {
                pending[pid] = { [weak self] _, _ in self?.drainComplete(for: gen) }
            }
            promptRequestID = nil
            // Safety valve: a wedged server must not strand the redirect.
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.suppressUpdates else { return }
                self.drainComplete(for: gen)
            }
            interrupted = true
        }
        return interrupted
    }

    /// The aborted turn's response has drained (or timed out): stop
    /// suppressing and start the redirect prompt that was waiting.
    /// `gen` is the generation the interrupt established — a drain left
    /// over from an EARLIER interrupt (valve fired, then its response
    /// finally arrived after another interrupt/cancel took over) must not
    /// touch the newer turn's suppress/queue state.
    private func drainComplete(for gen: Int) {
        guard generation == gen else { return }
        suppressUpdates = false
        guard let queued = queuedPrompt else { return }
        queuedPrompt = nil
        if generation == queued.gen {
            sendPrompt(queued.text, generation: queued.gen)
        }
    }

    // MARK: - Handshake & prompt

    private var configuredEndpoint: (host: String, port: UInt16)? {
        let raw = settings.acpAddress.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return ("127.0.0.1", 3000) }
        // One colon max: bare IPv6 (::1) would silently mis-parse, so it
        // must be tunneled to a host:port form instead.
        guard raw.filter({ $0 == ":" }).count <= 1 else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            let host = parts[0].isEmpty ? "127.0.0.1" : String(parts[0])
            if parts[1].isEmpty { return (host, 3000) } // "host:"
            guard let port = UInt16(parts[1]) else { return nil } // "host:junk"
            return (host, port)
        }
        if let port = UInt16(raw) { return ("127.0.0.1", port) } // bare port
        return (raw, 3000) // bare host
    }

    /// Connect + initialize + session/new as needed, then run `ready`.
    private func withReadySession(workdir: String, generation gen: Int,
                                  ready: @escaping () -> Void) {
        guard let endpoint = configuredEndpoint else {
            fail("Invalid ACP address “\(settings.acpAddress)” — use host:port.")
            return
        }
        let endpointKey = "\(endpoint.host):\(endpoint.port)"
        if connection == nil || connectedEndpoint != endpointKey {
            teardownConnection()
            openConnection(to: endpoint, key: endpointKey, generation: gen)
        }
        ensureInitialized(generation: gen) { [weak self] in
            self?.ensureSession(workdir: workdir, generation: gen, ready: ready)
        }
    }

    private func openConnection(to endpoint: (host: String, port: UInt16),
                                key: String, generation gen: Int) {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(endpoint.host),
                                port: port, using: .tcp)
        connection = conn
        connectedEndpoint = key
        initialized = false
        sessionID = nil
        buffer.removeAll()
        conn.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                guard let self, self.connection === conn else { return }
                switch state {
                case .failed(let error):
                    self.connectionLost("Copilot ACP connection failed: \(error.localizedDescription). Start it with `copilot --acp --port \(endpoint.port)` (tunnel remote instances with ssh -L).")
                case .waiting(let error):
                    // Refused/unreachable surfaces as .waiting with
                    // endless retries — for a loopback/tunnel target
                    // that means "not running": fail fast with the fix.
                    self.connectionLost("Can't reach Copilot ACP at \(key): \(error.localizedDescription). Start it with `copilot --acp --port \(endpoint.port)` (tunnel remote instances: ssh -N -L \(endpoint.port):127.0.0.1:\(endpoint.port) host).")
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        receiveLoop(on: conn)
        conn.start(queue: queue)
        Log.write("acp: connecting to \(key)")
    }

    private func ensureInitialized(generation gen: Int,
                                   then next: @escaping () -> Void) {
        guard !initialized else { next(); return }
        request("initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
            ],
            "clientInfo": ["name": "Cantrip", "version": "1.0"],
        ], timeout: 15) { [weak self] result, error in
            guard let self, self.generation == gen else { return }
            guard error == nil, result != nil else {
                self.fail("Copilot ACP initialize failed: \(Self.errorText(error))")
                return
            }
            self.initialized = true
            next()
        }
    }

    private func ensureSession(workdir: String, generation gen: Int,
                               ready: @escaping () -> Void) {
        guard sessionID == nil else { ready(); return }
        newSession(cwd: workdir, generation: gen) { [weak self] ok in
            guard let self, self.generation == gen else { return }
            if ok { ready(); return }
            // The tab's workdir may not exist on a REMOTE machine; retry
            // rooted at "/" so the session still opens, and say so.
            self.currentOnEvent?(.status("Workdir unavailable remotely — using /"))
            self.newSession(cwd: "/", generation: gen) { ok in
                if ok { ready() } else {
                    self.fail("Copilot ACP couldn't open a session (is the server signed in?).")
                }
            }
        }
    }

    private func newSession(cwd: String, generation gen: Int,
                            completion: @escaping (Bool) -> Void) {
        request("session/new", params: [
            "cwd": cwd,
            "mcpServers": [] as [Any],
        ], timeout: 30) { [weak self] result, _ in
            guard let self, self.generation == gen else { return }
            if let sid = result?["sessionId"] as? String {
                self.sessionID = sid
                Log.write("acp: session \(sid) (cwd \(cwd))")
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    private func sendPrompt(_ prompt: String, generation gen: Int) {
        guard generation == gen else { return }
        guard let sessionID else {
            fail("Copilot ACP: no session to prompt.")
            return
        }
        if suppressUpdates {
            // An aborted turn is still draining; ACP sessions are one
            // turn at a time, so the redirect waits for drainComplete().
            queuedPrompt = (prompt, gen)
            return
        }
        promptInFlight = true
        promptRequestID = request("session/prompt", params: [
            "sessionId": sessionID,
            "prompt": [["type": "text", "text": prompt]],
        ], timeout: 1200) { [weak self] result, error in
            guard let self, self.generation == gen else { return }
            self.promptInFlight = false
            self.promptRequestID = nil
            if let error {
                self.fail("Copilot ACP: \(Self.errorText(error))")
                return
            }
            // Any stopReason ends the turn; the transcript already has
            // whatever streamed in. Only surface the abnormal ones.
            if let reason = result?["stopReason"] as? String {
                let normal = ["end_turn", "completed", "endturn"]
                if !normal.contains(reason.lowercased()) {
                    self.currentOnEvent?(.status("Stopped: \(reason)"))
                }
            }
            self.currentOnEvent?(.done)
        }
    }

    // MARK: - Incoming messages

    private func receiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self, self.connection === conn else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if isComplete || error != nil {
                self.connectionLost("Copilot ACP server closed the connection.")
                return
            }
            self.receiveLoop(on: conn)
        }
    }

    private func drainBuffer() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line)
                      as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ message: [String: Any]) {
        // Response to one of our requests.
        if let id = message["id"] as? Int, message["method"] == nil {
            let completion = pending.removeValue(forKey: id)
            completion?(message["result"] as? [String: Any],
                        message["error"] as? [String: Any])
            return
        }
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "session/update":
            handleUpdate(params["update"] as? [String: Any] ?? [:])
        case "session/request_permission":
            handlePermission(id: message["id"], params: params)
        case "fs/read_text_file", "fs/write_text_file":
            // Capabilities were declared false; refuse politely if asked.
            if let id = message["id"] {
                sendRaw(["jsonrpc": "2.0", "id": id,
                         "error": ["code": -32601,
                                   "message": "Cantrip does not expose client fs"]])
            }
        default:
            break
        }
    }

    private func handleUpdate(_ update: [String: Any]) {
        guard !suppressUpdates else { return } // aborted turn draining
        let kind = update["sessionUpdate"] as? String ?? ""
        switch kind {
        case "agent_message_chunk":
            if let text = Self.contentText(update["content"]) {
                currentOnEvent?(.textDelta(text))
            }
        case "agent_thought_chunk":
            if let text = Self.contentText(update["content"]) {
                currentOnEvent?(.thinkingDelta(text))
            }
        case "tool_call":
            let id = update["toolCallId"] as? String ?? UUID().uuidString
            var activity = ToolActivityFactory.start(
                id: id,
                toolName: update["kind"] as? String ?? "tool",
                arguments: update["rawInput"],
                intentionSummary: update["title"] as? String)
            if (update["status"] as? String) == "completed" {
                activity.state = .succeeded
            }
            activities[id] = activity
            currentOnEvent?(.activity(activity))
        case "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            var activity = activities[id] ?? ToolActivityFactory.start(
                id: id, toolName: "tool", arguments: nil)
            switch update["status"] as? String {
            case "completed": activity.state = .succeeded
            case "failed": activity.state = .failed
            case "cancelled": activity.state = .cancelled
            default: break
            }
            if let text = Self.contentText((update["content"] as? [[String: Any]])?
                .first?["content"]) {
                activity.output = ToolActivityFactory.detailText(text)
            }
            activities[id] = activity
            currentOnEvent?(.activity(activity))
        case "plan":
            if let entries = update["entries"] as? [[String: Any]],
               let current = entries.first(where: {
                   ($0["status"] as? String) == "in_progress"
               }) ?? entries.first,
               let content = current["content"] as? String {
                currentOnEvent?(.status(String(content.prefix(80))))
            }
        default:
            break // available_commands_update, current_mode_update, …
        }
    }

    /// Tool approval, decided by Cantrip's own policy: "Act on my behalf"
    /// (and not a read-only council seat) approves once; otherwise decline.
    private func handlePermission(id: Any?, params: [String: Any]) {
        let options = params["options"] as? [[String: Any]] ?? []
        let allow = settings.allowActions && !readOnly

        func option(kinds: [String]) -> String? {
            for kind in kinds {
                if let match = options.first(where: {
                    ($0["kind"] as? String) == kind
                }) { return match["optionId"] as? String }
            }
            return nil
        }
        // Declining with no reject option on offer must NOT fall back to
        // picking some other (allow) option — leave chosen nil and answer
        // with the cancelled outcome below instead.
        let chosen = allow
            ? option(kinds: ["allow_once", "allow_always"])
                ?? (options.first?["optionId"] as? String)
            : option(kinds: ["reject_once", "reject_always"])

        let title = ((params["toolCall"] as? [String: Any])?["title"] as? String)
            ?? "a tool"
        // Report what was actually chosen — a fallback pick may not match
        // the allow intent (e.g. server offered only reject options).
        let chosenKind = options.first(where: {
            ($0["optionId"] as? String) == chosen
        })?["kind"] as? String ?? ""
        let approved = chosenKind.hasPrefix("allow")
        currentOnEvent?(.status((approved ? "Approved: " : "Declined: ")
                                + String(title.prefix(60))))
        currentOnEvent?(.approval(BackendApproval(
            tool: title,
            decision: approved ? "allowed" : "denied",
            decidedBy: readOnly ? "council-policy" : "action-policy"
        )))
        if !approved {
            Log.write("acp: declined permission for \(title) (enable Act on my behalf to approve)")
        }
        guard let id, let chosen else {
            if let id {
                sendRaw(["jsonrpc": "2.0", "id": id,
                         "result": ["outcome": ["outcome": "cancelled"]]])
            }
            return
        }
        sendRaw(["jsonrpc": "2.0", "id": id,
                 "result": ["outcome": ["outcome": "selected",
                                        "optionId": chosen]]])
    }

    // MARK: - JSON-RPC plumbing

    @discardableResult
    private func request(_ method: String, params: [String: Any],
                         timeout: TimeInterval,
                         completion: @escaping ([String: Any]?, [String: Any]?) -> Void) -> Int {
        let id = nextID
        nextID += 1
        pending[id] = completion
        sendRaw(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let completion = self.pending.removeValue(forKey: id)
            else { return }
            completion(nil, ["message": "\(method) timed out after \(Int(timeout))s"])
        }
        return id
    }

    private func notify(_ method: String, params: [String: Any]) {
        sendRaw(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func sendRaw(_ message: [String: Any]) {
        guard let connection,
              var data = try? JSONSerialization.data(withJSONObject: message)
        else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func fail(_ message: String) {
        promptInFlight = false
        currentOnEvent?(.failure(message))
        currentOnEvent = nil
    }

    private func connectionLost(_ message: String) {
        let hadTurn = promptInFlight || !pending.isEmpty
        teardownConnection()
        if hadTurn { fail(message) }
    }

    private func teardownConnection() {
        connection?.cancel()
        connection = nil
        connectedEndpoint = nil
        initialized = false
        sessionID = nil
        promptInFlight = false
        promptRequestID = nil
        suppressUpdates = false
        queuedPrompt = nil
        buffer.removeAll()
        // Dropped, not invoked: connectionLost emits the single failure
        // event itself — invoking these too would double-report it.
        pending.removeAll()
    }

    private static func contentText(_ content: Any?) -> String? {
        guard let block = content as? [String: Any] else { return nil }
        return block["text"] as? String
    }

    private static func errorText(_ error: [String: Any]?) -> String {
        (error?["message"] as? String) ?? "unknown error"
    }
}
