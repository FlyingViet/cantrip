import Foundation

/// One SDK session per tab, with native immediate delivery during an active turn.
/// A stopped/crashed runtime is rebuilt from Cantrip's journal and recent history,
/// never by replaying possibly accepted session.send requests.
final class CopilotBackend: Backend {
    var modelOverride: String?
    var readOnly = false
    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "copilot-backend")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var parser = CopilotJSONStreamParser()
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
    private let bridgeScript: String

    struct Configuration: Equatable {
        let command: String
        let workdir: String
        let model: String
        let effort: String
        let contextTier: String
        let allowTools: Bool
        let readOnly: Bool

        var json: [String: Any] {
            ["command": command, "workdir": workdir, "model": model,
             "effort": effort, "contextTier": contextTier,
             "allowTools": allowTools, "readOnly": readOnly]
        }
    }

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
            effort: settings.copilotEffort,
            contextTier: settings.copilotContextTier,
            allowTools: settings.copilotAllowTools || settings.allowActions,
            readOnly: readOnly
        )
        let suffix = settings.copilotDiscourageSubagents
            ? "\n\n(Work directly in this session; avoid spawning subagents or delegating tasks unless strictly necessary.)"
            : ""
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
            self.parser = CopilotJSONStreamParser()
            do {
                var command: [String: Any] = [
                    "kind": "start", "runID": id, "config": config.json, "prompt": request.prompt + suffix
                ]
                if self.process == nil {
                    command["initialPrompt"] = ConversationContextBuilder.composePrompt(
                        currentPrompt: request.prompt, query: request.userMessage, turns: request.previousTurns
                    ) + suffix
                    try self.launch(config)
                }
                onEvent(.status("Connecting to Copilot"))
                try self.write(command)
                self.queue.asyncAfter(deadline: .now() + 45) { [weak self] in
                    guard let self, self.runID == id, !self.ready else { return }
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

    private func launch(_ config: Configuration) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "exec node --input-type=module -e \"$1\"", "cantrip-copilot", bridgeScript]
        p.currentDirectoryURL = URL(fileURLWithPath: config.workdir)
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
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
                guard let current = runID, object["runID"] as? String == current else { continue }
                switch kind {
                case "started":
                    ready = true
                    onEvent?(.status("Thinking..."))
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
        resolveUncertainDeliveries()
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
