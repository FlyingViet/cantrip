import Foundation

/// Streams chat completions from any OpenAI-compatible server
/// (vLLM, llama.cpp, Ollama, LM Studio…) — e.g. a locally hosted Hermes.
/// When "Act on my behalf" is enabled, exposes a `run_shell` function and
/// executes tool-call loops so the local model can act, not just chat.
final class OpenAICompatibleBackend: NSObject, Backend, URLSessionDataDelegate {
    private let settings = AppSettings.shared
    private var history: [[String: Any]] = []
    private var task: URLSessionDataTask?
    private var urlSession: URLSession!
    private var onEvent: ((BackendEvent) -> Void)?
    private var assistantAccumulator = ""
    private var sseBuffer = ""
    private var finishReason: String?
    /// Tool-call fragments accumulated across SSE deltas, keyed by index.
    private var pendingToolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
    private var iterations = 0
    private let maxIterations = 6

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private var currentWorkdir = NSHomeDirectory()

    func send(
        _ request: BackendRequest,
        workdir: String,
        onEvent: @escaping (BackendEvent) -> Void
    ) {
        cancel()
        self.onEvent = onEvent
        self.currentWorkdir = workdir
        iterations = 0
        history = ConversationContextBuilder.chatMessages(
            for: request.userMessage,
            turns: request.previousTurns
        ).map {
            ["role": $0.role, "content": $0.content]
        }
        history.append(["role": "user", "content": request.prompt])
        onEvent(.status("Thinking…"))
        startRequest()
    }

    private func startRequest() {
        assistantAccumulator = ""
        sseBuffer = ""
        finishReason = nil
        pendingToolCalls = [:]

        let base = settings.localBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions") else {
            onEvent?(.failure("Invalid base URL: \(settings.localBaseURL)"))
            return
        }

        var messages: [[String: Any]] = []
        let system = settings.localSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages += history

        var body: [String: Any] = [
            "model": settings.localModel,
            "messages": messages,
            "stream": true,
        ]
        if settings.allowActions {
            var tools: [[String: Any]] = [[
                "type": "function",
                "function": [
                    "name": "run_shell",
                    "description": "Run a zsh command on the user's Mac and return stdout+stderr. Use for opening apps (open -a Name), reading/writing files, fetching URLs (curl), and system queries.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": ["type": "string", "description": "The shell command to run"]
                        ],
                        "required": ["command"],
                    ],
                ],
            ]]
            tools += MCPManager.shared.openAITools()
            body["tools"] = tools
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = settings.localAPIKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        task = urlSession.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func reset() {
        cancel()
        history.removeAll()
    }

    // MARK: - URLSessionDataDelegate (SSE parsing)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        sseBuffer += chunk
        while let range = sseBuffer.range(of: "\n") {
            let line = String(sseBuffer[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            sseBuffer.removeSubrange(..<range.upperBound)
            handleSSELine(line)
        }
    }

    private func handleSSELine(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first else { return }
        if let reason = first["finish_reason"] as? String { finishReason = reason }
        guard let delta = first["delta"] as? [String: Any] else { return }
        if let content = delta["content"] as? String, !content.isEmpty {
            assistantAccumulator += content
            onEvent?(.textDelta(content))
        }
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                let index = call["index"] as? Int ?? 0
                var entry = pendingToolCalls[index] ?? (id: "", name: "", arguments: "")
                if let id = call["id"] as? String { entry.id = id }
                if let function = call["function"] as? [String: Any] {
                    if let name = function["name"] as? String { entry.name += name }
                    if let args = function["arguments"] as? String { entry.arguments += args }
                }
                pendingToolCalls[index] = entry
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { self.task = nil }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                onEvent?(.done)
            } else {
                onEvent?(.failure(error.localizedDescription))
            }
            return
        }
        if let http = task.response as? HTTPURLResponse, http.statusCode >= 400 {
            onEvent?(.failure("Server returned HTTP \(http.statusCode)"))
            return
        }

        // Tool-call turn: execute and loop.
        if !pendingToolCalls.isEmpty, finishReason == "tool_calls" || assistantAccumulator.isEmpty {
            executeToolCallsAndContinue()
            return
        }

        if !assistantAccumulator.isEmpty {
            history.append(["role": "assistant", "content": assistantAccumulator])
        }
        onEvent?(.done)
    }

    // MARK: - Tool execution loop

    private func executeToolCallsAndContinue() {
        guard settings.allowActions else {
            onEvent?(.failure("Model requested tool use, but \"Act on my behalf\" is off."))
            return
        }
        iterations += 1
        guard iterations <= maxIterations else {
            onEvent?(.failure("Tool loop exceeded \(maxIterations) iterations — stopping."))
            return
        }

        let calls = pendingToolCalls.sorted { $0.key < $1.key }.map(\.value)
        // Record the assistant turn that requested the tools.
        var assistantMessage: [String: Any] = ["role": "assistant"]
        assistantMessage["content"] = assistantAccumulator.isEmpty ? NSNull() : assistantAccumulator
        assistantMessage["tool_calls"] = calls.map { call in
            ["id": call.id, "type": "function",
             "function": ["name": call.name, "arguments": call.arguments]] as [String: Any]
        }
        history.append(assistantMessage)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for call in calls {
                let command = (try? JSONSerialization.jsonObject(
                    with: Data(call.arguments.utf8)) as? [String: Any])?["command"] as? String
                let activity = ToolActivityFactory.start(
                    id: call.id.isEmpty ? UUID().uuidString : call.id,
                    toolName: call.name,
                    arguments: ["command": command ?? call.arguments])
                self.onEvent?(.activity(activity))

                let output: String
                let success: Bool
                if call.name == "run_shell", let command, !command.isEmpty {
                    (output, success) = Self.runShell(command, cwd: self.currentWorkdir)
                } else if call.name.hasPrefix("mcp__") {
                    let args = (try? JSONSerialization.jsonObject(
                        with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
                    (output, success) = MCPManager.shared.call(call.name, arguments: args)
                } else {
                    output = "Unknown tool or missing command"
                    success = false
                }
                self.history.append(["role": "tool",
                                     "tool_call_id": call.id,
                                     "content": String(output.prefix(4000))])
                self.onEvent?(.activity(ToolActivityFactory.complete(
                    activity, id: activity.id, success: success, output: output)))
            }
            self.onEvent?(.status("Thinking…"))
            self.startRequest()
        }
    }

    private static func runShell(_ command: String, cwd: String) -> (String, Bool) {
        Log.write("hermes tool: \(command.prefix(120))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return ("Failed to launch: \(error.localizedDescription)", false)
        }
        // 120s cap so a hung command can't wedge the loop.
        let deadline = Date().addingTimeInterval(120)
        while p.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if p.isRunning {
            p.terminate()
            return ("Command timed out after 120s", false)
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "(no output, exit \(p.terminationStatus))" : trimmed,
                p.terminationStatus == 0)
    }
}
