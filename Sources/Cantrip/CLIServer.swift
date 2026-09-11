import Foundation
import Network

private final class CLIRunLatch {
    private let lock = NSLock()
    private var terminal = false
    private var artifacts: Set<String> = []
    private var output = ""

    func acceptsEvent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !terminal
    }

    func claimTerminal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminal else { return false }
        terminal = true
        return true
    }

    func claimArtifact(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return artifacts.insert(key).inserted
    }

    func appendOutput(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard output.count < 20_000 else { return }
        output += String(text.prefix(20_000 - output.count))
    }

    func outputSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return output
    }
}

/// Unix-socket server backing the `cantrip` CLI. Protocol: one JSON
/// request line in ({"text", "backend"?, "cwd"?}), streamed JSON lines
/// out ({"delta"} … {"done"} | {"error"}).
final class CLIServer {
    static let shared = CLIServer()
    private var listener: NWListener?
    /// Persistent CLI backends so consecutive invocations keep context.
    private var backends: [BackendKind: Backend] = [:]
    private let journalSessionID: UUID
    private lazy var runJournal: RunJournal? = {
        do {
            return try RunJournal(sessionID: journalSessionID)
        } catch {
            Log.write("cli: run journal unavailable: \(error.localizedDescription)")
            return nil
        }
    }()
    private var journalFailureReported = false
    private init() {
        let key = "cliRunJournalSessionID"
        if let raw = UserDefaults.standard.string(forKey: key),
           let id = UUID(uuidString: raw) {
            journalSessionID = id
        } else {
            let id = UUID()
            journalSessionID = id
            UserDefaults.standard.set(id.uuidString, forKey: key)
        }
    }

    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/cantrip.sock").path
    }

    func start() {
        _ = runJournal
        try? FileManager.default.removeItem(atPath: Self.socketPath)
        do {
            let params = NWParameters()
            params.requiredLocalEndpoint = NWEndpoint.unix(path: Self.socketPath)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            Log.write("cli: listening at \(Self.socketPath)")
        } catch {
            Log.write("cli: listener failed: \(error.localizedDescription)")
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        var buffer = Data()

        func readMore() {
            connection.receive(minimumIncompleteLength: 1,
                               maximumLength: 1 << 20) { [weak self] data, _, done, _ in
                if let data { buffer.append(data) }
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    self?.handleRequest(line, on: connection)
                } else if done {
                    connection.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private func handleRequest(_ data: Data, on connection: NWConnection) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            send(["error": "bad request"], on: connection, close: true)
            return
        }
        let cwd = obj["cwd"] as? String ?? NSHomeDirectory()
        let kind = (obj["backend"] as? String).flatMap(Self.backendKind)
            ?? AppSettings.shared.backend
        Log.write("cli: query via \(kind.rawValue) (\(text.count) chars)")
        let runID = UUID()
        let userMessageID = UUID()
        let assistantMessageID = UUID()
        let startedAt = Date()
        let latch = CLIRunLatch()
        recordRunStart(
            runID: runID,
            userMessageID: userMessageID,
            assistantMessageID: assistantMessageID,
            prompt: text,
            backend: kind,
            workdir: cwd
        )

        flushJournal { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                self.send(["error": "Run history could not be saved; the request was not started."],
                          on: connection, close: true)
                return
            }
            DispatchQueue.main.async { [self] in
                self.startBackend(kind: kind, text: text, cwd: cwd, runID: runID,
                                  assistantMessageID: assistantMessageID, startedAt: startedAt,
                                  latch: latch, connection: connection)
            }
        }
    }

    private func startBackend(kind: BackendKind, text: String, cwd: String, runID: UUID,
                              assistantMessageID: UUID, startedAt: Date, latch: CLIRunLatch,
                              connection: NWConnection) {
        let backend = self.backend(for: kind)
        let request = BackendRequest(prompt: text, userMessage: text, previousTurns: [])
        backend.send(request, workdir: cwd) { [weak self] event in
            guard let self, latch.acceptsEvent() else { return }
            switch event {
            case .textDelta(let delta):
                latch.appendOutput(delta)
                var output = RunJournal.Event(
                    sessionID: self.journalSessionID,
                    runID: runID,
                    kind: .output
                )
                output.messageID = assistantMessageID
                output.role = "assistant"
                output.channel = "text"
                output.text = delta
                self.appendRunEvent(output)
                self.send(["delta": delta], on: connection, close: false)
            case .thinkingDelta:
                break // reasoning isn't part of the CLI's output contract
            case .status(let status):
                self.send(["status": status], on: connection, close: false)
            case .activity(let activity):
                self.recordActivity(activity, messageID: assistantMessageID, runID: runID, latch: latch)
                if activity.state == .running {
                    self.send(["status": activity.title], on: connection, close: false)
                }
            case .usage(let usage):
                if let backend = BackendKind(rawValue: usage.backend) {
                    UsageTracker.shared.recordCost(
                        backend: backend,
                        costUSD: usage.costUSD,
                        inputTokens: usage.inputTokens,
                        outputTokens: usage.outputTokens
                    )
                }
                var usageEvent = RunJournal.Event(sessionID: self.journalSessionID, runID: runID, kind: .usage)
                usageEvent.usage = RunJournal.Usage(
                    backend: usage.backend, inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens, costUSD: usage.costUSD
                )
                self.appendRunEvent(usageEvent, durable: true)
            case .approval(let approval):
                var approvalEvent = RunJournal.Event(sessionID: self.journalSessionID, runID: runID, kind: .approval)
                approvalEvent.tool = approval.tool
                approvalEvent.decision = approval.decision
                approvalEvent.decidedBy = approval.decidedBy
                self.appendRunEvent(approvalEvent, durable: true)
                self.send(["status": "\(approval.decision.capitalized): \(approval.tool)"],
                          on: connection, close: false)
            case .done:
                guard latch.claimTerminal() else { return }
                self.recordTerminal(runID: runID, status: "succeeded", startedAt: startedAt,
                                    summary: latch.outputSummary()) { result in
                    if case .success = result {
                        self.send(["done": true], on: connection, close: true)
                    } else {
                        self.send(["error": "The task finished, but run history could not be saved. Recovery may be incomplete."],
                                  on: connection, close: true)
                    }
                }
            case .failure(let message):
                guard latch.claimTerminal() else { return }
                var interruption = RunJournal.Event(sessionID: self.journalSessionID, runID: runID, kind: .interruption)
                interruption.reason = message
                self.appendRunEvent(interruption, durable: true)
                self.recordTerminal(runID: runID, status: "failed", startedAt: startedAt,
                                    summary: message) { result in
                    let error: String
                    if case .success = result { error = message }
                    else { error = message + "\nRun history could not be saved; recovery may be incomplete." }
                    self.send(["error": error], on: connection, close: true)
                }
            }
        }
    }

    private func appendRunEvent(_ event: RunJournal.Event, durable: Bool = false) {
        guard let runJournal else { return } // Startup and request failure are surfaced separately.
        runJournal.enqueue(event, durable: durable) { result in
            if case .failure(let error) = result, !self.journalFailureReported {
                self.journalFailureReported = true
                Log.write("cli: run journal write failed code=\((error as NSError).code)")
            }
        }
    }

    private func flushJournal(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let runJournal else {
            completion(.failure(CocoaError(.fileNoSuchFile)))
            return
        }
        runJournal.flush(completion: completion)
    }

    private func recordRunStart(
        runID: UUID,
        userMessageID: UUID,
        assistantMessageID: UUID,
        prompt: String,
        backend: BackendKind,
        workdir: String
    ) {
        var start = RunJournal.Event(
            sessionID: journalSessionID,
            runID: runID,
            kind: .turnStarted
        )
        start.prompt = prompt
        start.mode = .single
        start.backend = backend.rawValue
        start.backends = [AppSettings.shared.backendLabel(backend)]
        start.workdir = workdir
        start.includesAmbientContext = false
        appendRunEvent(start, durable: true)

        var user = RunJournal.Event(
            sessionID: journalSessionID,
            runID: runID,
            kind: .messageStarted
        )
        user.messageID = userMessageID
        user.role = "user"
        user.text = prompt
        appendRunEvent(user)

        var assistant = RunJournal.Event(
            sessionID: journalSessionID,
            runID: runID,
            kind: .messageStarted
        )
        assistant.messageID = assistantMessageID
        assistant.role = "assistant"
        appendRunEvent(assistant)
    }

    private func recordActivity(
        _ activity: ToolActivity,
        messageID: UUID,
        runID: UUID,
        latch: CLIRunLatch
    ) {
        var event = RunJournal.Event(
            sessionID: journalSessionID,
            runID: runID,
            kind: .toolActivity
        )
        event.messageID = messageID
        event.activity = runActivity(activity)
        appendRunEvent(event, durable: activity.state != .running)

        for change in activity.fileChanges {
            let key = "\(activity.id)|\(change.id)"
            guard latch.claimArtifact(key) else { continue }
            var artifact = RunJournal.Event(
                sessionID: journalSessionID,
                runID: runID,
                kind: .artifact
            )
            artifact.messageID = messageID
            artifact.artifact = RunJournal.Artifact(
                path: change.path,
                kind: "diff",
                content: change.diff
            )
            appendRunEvent(artifact)
        }
    }

    private func runActivity(_ activity: ToolActivity) -> RunJournal.Activity {
        RunJournal.Activity(
            id: activity.id,
            title: activity.title,
            toolName: activity.toolName,
            state: activityState(activity.state),
            input: activity.input,
            output: activity.output,
            fileChanges: activity.fileChanges.map {
                RunJournal.FileChange(id: $0.id, path: $0.path, diff: $0.diff)
            },
            terminalCommand: activity.terminalCommand,
            children: activity.children.map(runActivity)
        )
    }

    private func recordTerminal(
        runID: UUID,
        status: String,
        startedAt: Date,
        summary: String = "",
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var result = RunJournal.Event(
            sessionID: journalSessionID,
            runID: runID,
            kind: .result
        )
        result.status = status
        result.durationMS = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        result.summaryDigest = RunJournal.digest(summary)
        appendRunEvent(result, durable: true)
        flushJournal(completion: completion)
    }

    private func backend(for kind: BackendKind) -> Backend {
        if let existing = backends[kind] { return existing }
        let fresh: Backend
        switch kind {
        case .claudeCode: fresh = ClaudeCodeBackend(persistKey: "cli-claudeSession")
        case .copilot: fresh = CopilotBackend()
        case .copilotRemote: fresh = CopilotACPBackend()
        case .codex: fresh = CodexBackend(persistKey: "cli-codexSession")
        case .localModel: fresh = OpenAICompatibleBackend()
        }
        backends[kind] = fresh
        return fresh
    }

    private static func backendKind(_ raw: String) -> BackendKind? {
        switch raw.lowercased() {
        case "claude", "claudecode", "claude-code": return .claudeCode
        case "copilot", "gh": return .copilot
        case "acp", "copilot-remote", "copilotremote": return .copilotRemote
        case "codex", "openai": return .codex
        case "local", "hermes": return .localModel
        default: return BackendKind(rawValue: raw)
        }
    }

    private func activityState(_ state: ToolActivityState) -> String {
        switch state {
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    private func send(_ object: [String: Any], on connection: NWConnection, close: Bool) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }
}
