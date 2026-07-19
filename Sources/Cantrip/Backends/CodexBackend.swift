import Foundation

/// Runs queries through OpenAI's Codex CLI in headless mode:
///   codex exec --json "<prompt>"          (first turn)
///   codex exec resume <id> --json "…"     (follow-ups)
/// Parses the JSONL event stream for text deltas, shell activities,
/// and the session id. Launched via the login shell so PATH matches
/// the user's terminal.
final class CodexBackend: Backend {
    private var process: Process?
    private let persistKey: String
    private var sessionID: String? {
        didSet { UserDefaults.standard.set(sessionID, forKey: persistKey) }
    }
    private var activities: [String: ToolActivity] = [:]
    private var streamedDeltas = false
    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "codex-backend")

    init(persistKey: String = "codexSessionID") {
        self.persistKey = persistKey
        sessionID = UserDefaults.standard.string(forKey: persistKey)
    }

    func send(_ prompt: String, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        queue.async { [weak self] in
            self?.run(prompt: prompt, workdir: workdir, onEvent: onEvent)
        }
    }

    func cancel() {
        guard let p = process else { return }
        process = nil
        activities.removeAll()
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    func reset() {
        cancel()
        sessionID = nil
        activities.removeAll()
    }

    // MARK: - Internals

    private func run(prompt: String, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        let configured = settings.codexPath.trimmingCharacters(in: .whitespaces)
        let command = configured.isEmpty ? "codex" : configured
        streamedDeltas = false

        var codexArgs = ["exec"]
        if let sessionID { codexArgs += ["resume", sessionID] }
        codexArgs += ["--json", "--cd", workdir]
        let model = settings.codexModel.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { codexArgs += ["-m", model] }
        if settings.allowActions {
            codexArgs.append("--dangerously-bypass-approvals-and-sandbox")
        }
        codexArgs.append(prompt)

        Log.write("launching \(command) via login shell, workdir=\(workdir)")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "exec \"$0\" \"$@\"", command] + codexArgs
        p.currentDirectoryURL = URL(fileURLWithPath: workdir)
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr

        var errData = Data()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            errData.append(handle.availableData)
        }

        var buffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                self?.handleLine(line, onEvent: onEvent)
            }
        }

        p.terminationHandler = { [weak self] proc in
            Log.write("codex exited, status=\(proc.terminationStatus)")
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if proc.terminationStatus != 0 {
                errData.append(stderr.fileHandleForReading.readDataToEndOfFile())
                let errText = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationReason == .uncaughtSignal {
                    onEvent(.done)
                } else if proc.terminationStatus == 127 {
                    onEvent(.failure("Codex CLI not found. Install with `npm install -g @openai/codex`, run `codex` once to sign in, then try again."))
                } else {
                    onEvent(.failure(errText.isEmpty
                        ? "codex exited with status \(proc.terminationStatus)"
                        : String(errText.suffix(600))))
                }
            } else {
                onEvent(.done)
            }
            self?.process = nil
        }

        do {
            try p.run()
            process = p
        } catch {
            onEvent(.failure("Failed to launch codex: \(error.localizedDescription)"))
        }
    }

    /// Codex JSONL has shipped in a couple of shapes (Rust: {"id","msg":{…}},
    /// TS: {"type":"item.completed","item":{…}}); parse defensively.
    private func handleLine(_ data: Data, onEvent: @escaping (BackendEvent) -> Void) {
        guard !data.isEmpty,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let obj = (raw["msg"] as? [String: Any]) ?? raw
        let type = (obj["type"] as? String) ?? (raw["type"] as? String) ?? ""

        // Session id, wherever it lives.
        for key in ["session_id", "thread_id", "conversation_id"] {
            if let sid = (raw[key] ?? obj[key]) as? String { sessionID = sid }
        }

        switch true {
        case type.contains("agent_message_delta") || type.contains("agent_message.delta"):
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                streamedDeltas = true
                onEvent(.textDelta(delta))
            }
        case type.contains("agent_message"):
            // Whole message — only use if deltas weren't streamed.
            if !streamedDeltas, let text = obj["message"] as? String, !text.isEmpty {
                onEvent(.textDelta(text))
            }
        case type == "item.completed":
            if let item = raw["item"] as? [String: Any],
               item["type"] as? String == "agent_message",
               !streamedDeltas,
               let text = (item["text"] ?? item["message"]) as? String {
                onEvent(.textDelta(text))
            }
        case type.contains("exec_command_begin"):
            let id = (obj["call_id"] as? String) ?? UUID().uuidString
            let cmd = (obj["command"] as? [String])?.joined(separator: " ")
                ?? obj["command"] as? String ?? "command"
            let activity = ToolActivityFactory.start(
                id: id, toolName: "shell", arguments: ["command": cmd])
            activities[id] = activity
            onEvent(.activity(activity))
        case type.contains("exec_command_end"):
            guard let id = obj["call_id"] as? String else { return }
            let exitCode = obj["exit_code"] as? Int ?? 0
            let output = (obj["aggregated_output"] ?? obj["stdout"]) as? String
            onEvent(.activity(ToolActivityFactory.complete(
                activities.removeValue(forKey: id), id: id,
                success: exitCode == 0, output: output)))
        case type.contains("task_started"), type.contains("turn.started"):
            onEvent(.status("Thinking…"))
        case type.contains("error"):
            if let message = obj["message"] as? String {
                onEvent(.failure(message))
            }
        default:
            break
        }
    }
}
