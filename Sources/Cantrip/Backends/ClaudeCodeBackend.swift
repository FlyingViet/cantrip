import Foundation

/// Runs queries through the Claude Code CLI in headless mode:
///   claude -p "<prompt>" --output-format stream-json --verbose
/// Follow-ups resume the same session via --resume <session_id>.
final class ClaudeCodeBackend: Backend {
    private var process: Process?
    /// Persisted so conversations resume across app restarts.
    private let persistKey: String
    private var sessionID: String? {
        didSet { UserDefaults.standard.set(sessionID, forKey: persistKey) }
    }
    private var activities: [String: ToolActivity] = [:]
    /// child tool_use id → parent Task activity id (subagent steps).
    private var childIndex: [String: String] = [:]
    /// Whether any text has streamed this run (for block separation).
    private var hasEmittedText = false
    private let settings = AppSettings.shared
    private let queue = DispatchQueue(label: "claude-code-backend")

    init(persistKey: String = "claudeSessionID") {
        self.persistKey = persistKey
        sessionID = UserDefaults.standard.string(forKey: persistKey)
    }

    func send(
        _ request: BackendRequest,
        workdir: String,
        onEvent: @escaping (BackendEvent) -> Void
    ) {
        queue.async { [weak self] in
            self?.run(prompt: request.prompt, workdir: workdir, onEvent: onEvent)
        }
    }

    func cancel() {
        guard let p = process else { return }
        process = nil
        activities.removeAll()
        childIndex.removeAll()
        p.terminate()
        // Escalate to SIGKILL if it ignores SIGTERM.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning {
                Log.write("cancel: escalating to SIGKILL (pid \(p.processIdentifier))")
                kill(p.processIdentifier, SIGKILL)
            }
        }
    }

    func reset() {
        cancel()
        sessionID = nil
        activities.removeAll()
    }

    // MARK: - Internals

    private func resolveClaudePath() -> String? {
        Self.findClaude(configured: settings.claudePath)
    }

    static func findClaude(configured raw: String) -> String? {
        let configured = raw.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty { return configured }
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Last resort: ask the login shell.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "command -v claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    private func run(prompt: String, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        guard let claudePath = resolveClaudePath() else {
            Log.write("claude CLI not found")
            onEvent(.failure("Couldn't find the `claude` CLI. Set its path in Settings."))
            return
        }
        Log.write("launching \(claudePath), workdir=\(workdir)")

        hasEmittedText = false
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages"]
        let model = settings.claudeModel.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { args += ["--model", model] }
        if settings.allowActions {
            args += ["--permission-mode", "bypassPermissions"]
        } else if settings.claudePermissionMode != "default" {
            args += ["--permission-mode", settings.claudePermissionMode]
        }
        if let sessionID { args += ["--resume", sessionID] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: workdir)
        var env = ProcessInfo.processInfo.environment
        // Ensure node/claude find their usual PATH entries.
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        // Critical: claude -p waits for stdin EOF when spawned from a GUI app.
        p.standardInput = FileHandle.nullDevice

        // Drain stderr continuously so the pipe never fills and blocks the process.
        var errData = Data()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            errData.append(handle.availableData)
        }

        var buffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            buffer.append(data)
            // Process complete lines.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                self?.handleLine(lineData, onEvent: onEvent)
            }
        }

        p.terminationHandler = { [weak self] proc in
            Log.write("claude exited, status=\(proc.terminationStatus), reason=\(proc.terminationReason.rawValue)")
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if proc.terminationStatus != 0 {
                errData.append(stderr.fileHandleForReading.readDataToEndOfFile())
                let errText = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationReason == .uncaughtSignal {
                    onEvent(.done) // cancelled by user
                } else {
                    onEvent(.failure(errText.isEmpty ? "claude exited with status \(proc.terminationStatus)" : errText))
                }
            } else {
                onEvent(.done)
            }
            self?.process = nil
        }

        do {
            try p.run()
            process = p
            Log.write("claude started, pid=\(p.processIdentifier)")
        } catch {
            Log.write("launch failed: \(error.localizedDescription)")
            onEvent(.failure("Failed to launch claude: \(error.localizedDescription)"))
        }
    }

    private func handleLine(_ data: Data, onEvent: @escaping (BackendEvent) -> Void) {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            Log.write("unparseable line (\(data.count) bytes): \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
            return
        }
        if type != "stream_event" { Log.write("line type=\(type)") }

        if let sid = obj["session_id"] as? String { sessionID = sid }

        switch type {
        case "stream_event":
            // Token-level streaming (--include-partial-messages).
            guard let event = obj["event"] as? [String: Any],
                  let eventType = event["type"] as? String else { return }
            if eventType == "content_block_start",
               let block = event["content_block"] as? [String: Any],
               block["type"] as? String == "text",
               hasEmittedText {
                onEvent(.textDelta("\n\n")) // separate consecutive text blocks
            } else if eventType == "content_block_delta",
                      let delta = event["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty {
                hasEmittedText = true
                onEvent(.textDelta(text))
            }
        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            let parentID = obj["parent_tool_use_id"] as? String
            for block in content {
                switch block["type"] as? String {
                case "text":
                    // Text already streamed token-by-token via stream_event;
                    // the complete message would duplicate it.
                    break
                case "tool_use":
                    guard let id = block["id"] as? String else { continue }
                    let name = block["name"] as? String ?? "tool"
                    let activity = ToolActivityFactory.start(
                        id: id,
                        toolName: name,
                        arguments: block["input"]
                    )
                    if let parentID, var parent = activities[parentID] {
                        // Subagent step: nest under its Task activity.
                        parent.children.append(activity)
                        activities[parentID] = parent
                        childIndex[id] = parentID
                        onEvent(.activity(parent))
                    } else {
                        activities[id] = activity
                        onEvent(.activity(activity))
                    }
                default:
                    break
                }
            }
        case "user":
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                let isError = block["is_error"] as? Bool ?? false
                let output = block["content"] ?? obj["tool_use_result"]
                if let parentID = childIndex.removeValue(forKey: id),
                   var parent = activities[parentID] {
                    // Complete the nested subagent step; re-emit the parent.
                    if let childIdx = parent.children.firstIndex(where: { $0.id == id }) {
                        parent.children[childIdx] = ToolActivityFactory.complete(
                            parent.children[childIdx], id: id,
                            success: !isError, output: output)
                    }
                    activities[parentID] = parent
                    onEvent(.activity(parent))
                    continue
                }
                let completed = ToolActivityFactory.complete(
                    activities.removeValue(forKey: id),
                    id: id,
                    success: !isError,
                    output: output
                )
                onEvent(.activity(completed))
            }
        case "result":
            if let cost = obj["total_cost_usd"] as? Double {
                let usage = obj["usage"] as? [String: Any]
                UsageTracker.shared.recordCost(
                    backend: .claudeCode, costUSD: cost,
                    inputTokens: (usage?["input_tokens"] as? Int ?? 0)
                        + (usage?["cache_creation_input_tokens"] as? Int ?? 0)
                        + (usage?["cache_read_input_tokens"] as? Int ?? 0),
                    outputTokens: usage?["output_tokens"] as? Int ?? 0)
            }
            if let isError = obj["is_error"] as? Bool, isError,
               let result = obj["result"] as? String {
                onEvent(.failure(result))
            }
        case "rate_limit_event":
            if let info = obj["rate_limit_info"] as? [String: Any],
               let resets = info["resetsAt"] as? TimeInterval {
                // Utilization appears only in some CLI versions/situations;
                // grab it under any of its known names when present.
                let rawUtil = (info["utilization"] ?? info["used_percentage"]
                    ?? info["percentUsed"] ?? info["percent_used"]) as? Double
                let percent = rawUtil.map { $0 <= 1.0 ? $0 * 100 : $0 }
                UsageTracker.shared.updateRateLimit(
                    type: info["rateLimitType"] as? String ?? "window",
                    resetsAtEpoch: resets,
                    status: info["status"] as? String ?? "unknown",
                    percentUsed: percent)
            }
        case "system":
            if obj["subtype"] as? String == "init" {
                onEvent(.status("Thinking…"))
            }
        default:
            break
        }
    }
}
