import Foundation

/// Streams chat completions from any OpenAI-compatible server
/// (vLLM, llama.cpp, Ollama, LM Studio…) — e.g. a locally hosted Hermes.
/// When "Act on my behalf" is enabled, exposes a `run_shell` function and
/// executes tool-call loops so the local model can act, not just chat.
final class OpenAICompatibleBackend: NSObject, Backend, URLSessionDataDelegate, CantripHomeGuardedBackend {
    /// Per-instance model override (council members run models different
    /// from the session's setting). Nil = use the configured model.
    var modelOverride: String?
    /// The server's base URL for this run instead of the Local Model setting (Privacy Gate local routes).
    var baseURLOverride: String?
    /// A hard input budget for this run (the Privacy Gate's local route): older tool output is left
    /// out first, and the run stops rather than overflow the model's window.
    var contextBudgetTokens: Int?
    /// Earlier-turn messages at the start of `history` (the budget may drop them).
    private var replayedMessages = 0
    /// Read-only instance (council advisors): no tool loop, regardless
    /// of global autonomy.
    var readOnly = false
    /// A Home shadow run (CantripHomeShadow): only its read-only tools, never the shell, its own
    /// step cap and result size; every call is counted.
    var shadow: (tools: CantripHomeShadowTools, run: CantripHomeShadowRun)?
    /// A shadow run's reply text so far (all steps), checked for record changes at the end.
    private var shadowReplyText = ""
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
    private let guardrailLock = NSLock()
    private var storedGuardrail: CantripHomeGuardrail?
    private var storedGuardrailLabel = "Cantrip Home"
    private var approvedScopes: Set<String> = []

    var guardrail: CantripHomeGuardrail? {
        get { guardrailLock.withLock { storedGuardrail } }
        set { guardrailLock.withLock { storedGuardrail = newValue } }
    }

    var guardrailLabel: String {
        get { guardrailLock.withLock { storedGuardrailLabel } }
        set { guardrailLock.withLock { storedGuardrailLabel = newValue } }
    }

    func send(
        _ request: BackendRequest,
        workdir: String,
        onEvent: @escaping (BackendEvent) -> Void
    ) {
        cancel()
        self.onEvent = onEvent
        self.currentWorkdir = workdir
        iterations = 0
        shadowReplyText = ""
        guardrailLock.withLock { approvedScopes = [] }
        history = ConversationContextBuilder.chatMessages(
            for: request.userMessage,
            turns: request.previousTurns
        ).map {
            ["role": $0.role, "content": $0.content]
        }
        replayedMessages = history.count
        history.append(["role": "user", "content": request.prompt])
        onEvent(.status("Thinking…"))
        startRequest()
    }

    static func tools() -> [[String: Any]] {
        [[
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
        ]] + MCPManager.shared.openAITools()
    }

    static let leftOut = "[Earlier tool output left out to stay within the local model's context.]"

    /// Fits a run's messages in `budget` tokens: older tool output goes first (the two latest stay),
    /// then the oldest of the `replayed` earlier-turn messages before the run's own request. False
    /// when even that isn't enough.
    static func fit(_ history: inout [[String: Any]], budget: Int, replayed: inout Int) -> Bool {
        func size() -> Int {
            history.reduce(0) { total, message in
                let content = message["content"] as? String ?? ""
                let calls = message["tool_calls"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { $0.count / 3 } ?? 0
                return total + HomeLocalProfile.estimate(content) + calls + 4
            }
        }
        let tools = history.indices.filter { history[$0]["role"] as? String == "tool" }
        for index in tools.dropLast(2) where size() > budget {
            history[index]["content"] = leftOut
        }
        while size() > budget, replayed > 0 {
            history.removeFirst()
            replayed -= 1
        }
        return size() <= budget
    }

    private func startRequest() {
        assistantAccumulator = ""
        sseBuffer = ""
        finishReason = nil
        pendingToolCalls = [:]

        let base = (baseURLOverride ?? settings.localBaseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions") else {
            onEvent?(.failure("Invalid base URL: \(baseURLOverride ?? settings.localBaseURL)"))
            return
        }

        var messages: [[String: Any]] = []
        var system = settings.localSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let extra = shadow?.run.config.instructions.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            system = system.isEmpty ? extra : system + "\n\n" + extra
        }
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        var tools = shadow.map { $0.tools.openAITools() } ?? (settings.allowActions && !readOnly ? Self.tools() : [])
        if shadow?.run.config.recordsTool == true { tools.append(CantripHomeShadowRun.recordsToolSchema) }
        if shadow?.run.config.memoryTools == true { tools += CantripHomeShadowRun.memoryToolSchemas }
        if let budget = contextBudgetTokens {
            let fixed = HomeLocalProfile.estimate(system)
                + HomeLocalProfile.estimate(String(decoding: (try? JSONSerialization.data(withJSONObject: tools)) ?? Data(), as: UTF8.self))
            let before = (history.count, history.filter { $0["content"] as? String == Self.leftOut }.count)
            guard Self.fit(&history, budget: budget - fixed, replayed: &replayedMessages) else {
                Log.write("local run: over its \(budget)-token budget even after leaving out earlier output; stopped")
                onEvent?(.failure("This local run reached its \(budget)-token budget for the model's window. Nothing was sent to a cloud model."))
                return
            }
            let leftOut = history.filter { $0["content"] as? String == Self.leftOut }.count - before.1
            if leftOut > 0 || history.count < before.0 {
                Log.write("local run: left out \(leftOut) earlier tool outputs and \(before.0 - history.count) earlier messages to stay within \(budget) tokens")
            }
        }
        messages += history

        var body: [String: Any] = [
            "model": modelOverride ?? settings.localModel,
            "messages": messages,
            "stream": true,
        ]
        if !tools.isEmpty { body["tools"] = tools }
        if let shadow {
            let config = shadow.run.config
            body["stream_options"] = ["include_usage": true]
            if !config.priority.isEmpty { body["priority"] = config.priority }
            if let temperature = config.temperature { body["temperature"] = temperature }
            if !config.reasoningEffort.isEmpty { body["reasoning_effort"] = config.reasoningEffort }
            shadow.run.saveRequest(body)
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
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let usage = obj["usage"] as? [String: Any], let shadow {
            shadow.run.noteUsage(prompt: usage["prompt_tokens"] as? Int ?? 0, completion: usage["completion_tokens"] as? Int ?? 0)
        }
        guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { return }
        if let reason = first["finish_reason"] as? String { finishReason = reason }
        guard let delta = first["delta"] as? [String: Any] else { return }
        if let content = delta["content"] as? String, !content.isEmpty {
            assistantAccumulator += content
            onEvent?(.textDelta(content))
        }
        // Reasoning-model thinking (DeepSeek-style `reasoning_content`,
        // some servers use `reasoning`). Display-only; not fed back into
        // history on tool loops.
        if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"]) as? String,
           !reasoning.isEmpty {
            onEvent?(.thinkingDelta(reasoning))
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

        shadowReplyText += assistantAccumulator
        if let shadow, shadow.run.config.validateRecords, !shadow.run.corrected {
            let problems = shadow.run.validate(shadowReplyText)
            if !problems.isEmpty {
                // One correction round, as saving would refuse them in a real run.
                shadow.run.corrected = true
                shadowReplyText = ""
                history.append(["role": "assistant", "content": assistantAccumulator])
                history.append(["role": "user", "content": CantripHomeShadowRun.correctionMessage(problems)])
                onEvent?(.textDelta("\n\n" + CantripHomeShadowRun.correctionMarker + "\n\n"))
                onEvent?(.status("Correcting record changes…"))
                startRequest()
                return
            }
        }
        if !assistantAccumulator.isEmpty {
            history.append(["role": "assistant", "content": assistantAccumulator])
        }
        onEvent?(.done)
    }

    // MARK: - Tool execution loop

    private func executeToolCallsAndContinue() {
        guard settings.allowActions || shadow != nil else {
            onEvent?(.failure("Model requested tool use, but \"Act on my behalf\" is off."))
            return
        }
        iterations += 1
        let cap = shadow?.run.config.maxSteps ?? maxIterations
        guard iterations <= cap else {
            onEvent?(.failure("Tool loop exceeded \(cap) iterations — stopping."))
            return
        }
        shadow?.run.noteStep()
        shadowReplyText += assistantAccumulator

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
                if let shadow = self.shadow {
                    // Only the shadow run's read-only tools; nothing else, not even the shell.
                    let args = (try? JSONSerialization.jsonObject(
                        with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
                    let config = shadow.run.config
                    let result: (output: String, success: Bool, allowed: Bool)
                    if config.guards, let earlier = shadow.run.repeatedCall(call.name, arguments: args, step: self.iterations) {
                        result = ("You already made this exact call (step \(earlier)); its result is above. Don't repeat "
                                  + "calls: use what you have, try a different search, or write your answer.", false, true)
                    } else if call.name == CantripHomeShadowRun.recordsToolName && config.recordsTool {
                        result = (shadow.run.recordsTool(args), true, true)
                    } else if CantripHomeShadowRun.memoryToolNames.contains(call.name) && config.memoryTools {
                        let vault = URL(fileURLWithPath: (self.settings.memoryPath as NSString).expandingTildeInPath)
                        result = (CantripHomeShadowRun.memoryTool(call.name, arguments: args, vault: vault), true, true)
                    } else {
                        result = shadow.tools.call(call.name, arguments: args)
                    }
                    shadow.run.noteToolCall(call.name, allowed: result.allowed)
                    shadow.run.recordToolCall(call.name, arguments: args, output: result.output,
                                              success: result.success, allowed: result.allowed)
                    (output, success) = (result.output, result.success)
                } else if let refusal = self.guardrailRefusal(for: call.name, command: command,
                                                       arguments: call.arguments) {
                    (output, success) = (refusal, false)
                } else if call.name == "run_shell", let command, !command.isEmpty {
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
                                     "content": String(output.prefix(self.shadow?.run.config.resultCharacters ?? 4000))])
                self.onEvent?(.activity(ToolActivityFactory.complete(
                    activity, id: activity.id, success: success, output: output)))
            }
            if let shadow = self.shadow, shadow.run.config.guards, self.iterations == shadow.run.config.maxSteps - 10 {
                self.history.append(["role": "user", "content": CantripHomeShadowRun.stepsLeftNote])
            }
            self.onEvent?(.status("Thinking…"))
            self.startRequest()
        }
    }

    /// Checks a tool call with Cantrip's agent policy (and Home's rules in Home), waiting for the
    /// user when it asks. Returns the text the model sees instead of the tool's output, or nil to run it.
    private func guardrailRefusal(for name: String, command: String?, arguments: String) -> String? {
        guard guardrail != nil || AgentPolicyGate.enforcesEverywhere else { return nil }
        let request: CantripHomeActionRequest
        if name == "run_shell" {
            request = .shell(command ?? "")
        } else if name.hasPrefix("mcp__") {
            request = .init(claudeTool: name, input: [:])
        } else {
            return nil
        }
        // Local models have no approval prompts of their own: what no rule stops runs.
        let outcome = AgentPolicyGate.decide(request, guardrail: guardrail, approval: .ask,
                                             label: guardrailLabel, workdir: currentWorkdir,
                                             privacy: PrivacyRunRestrictions.restriction(for: self))
        switch outcome {
        case .allow, .prompt:
            return nil
        case .deny(let reason, let by):
            onEvent?(.activity(AgentPolicyGate.denialActivity(request, reason: reason, by: by)))
            return reason
        case .ask(let title, let detail, let scope, let source, let action):
            if guardrailLock.withLock({ approvedScopes.contains(scope) }) { return nil }
            let done = DispatchSemaphore(value: 0)
            var approved = false
            var answered: InputRequestAnswer.Decision = .cancel
            let pending = BackendInputRequest(kind: .approval, source: source, title: title, detail: detail) { answer in
                answered = answer.decision
                approved = answer.decision == .approve
                done.signal()
            }
            Log.write("policy: asking the user before \(action)")
            onEvent?(.inputRequired(pending))
            if done.wait(timeout: .now() + 610) == .timedOut { pending.cancel() }
            if approved {
                guardrailLock.withLock { _ = approvedScopes.insert(scope) }
                return nil
            }
            return AgentPolicyGate.declined(action, answered: answered == .deny)
        }
    }

    private static func runShell(_ command: String, cwd: String) -> (String, Bool) {
        Log.write("hermes tool: \(command.prefix(120))")
        let result: ProcessRunner.Result
        do {
            // 120s cap so a hung command can't wedge the loop; the model sees the first 4,000 characters.
            result = try ProcessRunner.run("/bin/zsh", ["-l", "-c", command], directory: URL(fileURLWithPath: cwd),
                                           errorOutput: .merge, timeout: 120, outputLimit: 1_000_000)
        } catch {
            return ("Failed to launch: \(error.localizedDescription)", false)
        }
        if result.timedOut { return ("Command timed out after 120s", false) }
        let trimmed = result.text
        return (trimmed.isEmpty ? "(no output, exit \(result.status))" : trimmed, result.status == 0)
    }
}
