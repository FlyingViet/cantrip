import Foundation

/// A chat request reduced to what one stateless model call needs: no session, no tools, no MCP
/// servers and no files. The OpenAI-compatible endpoint (`OpenAIEndpoint`) runs these.
struct OneShotPrompt: Sendable {
    struct Turn: Equatable, Sendable {
        let role: String
        let text: String
    }

    struct Image: Equatable, Sendable {
        let data: Data
        let mediaType: String
        let fileExtension: String

        /// PNG, JPEG, GIF or WebP, told apart by their first bytes.
        init?(data: Data) {
            let bytes = [UInt8](data.prefix(12))
            if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
                (mediaType, fileExtension) = ("image/jpeg", "jpg")
            } else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
                (mediaType, fileExtension) = ("image/png", "png")
            } else if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
                (mediaType, fileExtension) = ("image/gif", "gif")
            } else if bytes.count == 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) {
                (mediaType, fileExtension) = ("image/webp", "webp")
            } else {
                return nil
            }
            self.data = data
        }
    }

    /// System and developer messages, in order.
    var system: String
    /// User and assistant messages, in order.
    var turns: [Turn]
    var images: [Image] = []
    /// The request's `messages` as sent, for backends that take them as they are (Local Model).
    var messagesJSON = Data("[]".utf8)
    var maxTokens: Int?

    /// The conversation as one message: a lone user message as it is, otherwise every turn
    /// labelled `[role]`.
    var conversationText: String {
        if turns.count == 1, turns[0].role == "user" { return turns[0].text }
        return turns.map { "[\($0.role)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// System text and conversation together, for CLIs without a system prompt option.
    var combinedText: String {
        guard !system.isEmpty else { return conversationText }
        return (["[system]\n\(system)"] + turns.map { "[\($0.role)]\n\($0.text)" }).joined(separator: "\n\n")
    }

    var characterCount: Int { system.count + turns.reduce(0) { $0 + $1.text.count } }
}

/// The backend, model and effort one attempt runs with. Empty fields leave the CLI's own default.
struct OneShotTarget: Equatable, Sendable {
    let backend: BackendKind
    var model = ""
    var effort = ""
    var contextTier = ""

    var label: String {
        ([backend.rawValue] + [model, effort, contextTier].filter { !$0.isEmpty }).joined(separator: " · ")
    }
}

struct OneShotResult: Equatable, Sendable {
    var text: String
    /// The model that answered, as the backend reported it (or as requested).
    var model: String
    var inputTokens = 0
    var outputTokens = 0
    var cachedInputTokens = 0
    /// Copilot's premium requests for the call.
    var premiumRequests: Double?
    /// Claude Code's reported cost.
    var costUSD: Double?
}

enum OneShotError: Error, Equatable {
    /// The account's plan is used up for now, from the backend's structured error.
    case usageLimit(UsageLimitReport, String)
    /// This backend can't take this request at all (not installed, no images, no tool-free mode).
    case unavailable(String)
    case failed(String)
    case timedOut
    case cancelled

    var message: String {
        switch self {
        case .usageLimit(_, let text): return text
        case .unavailable(let text), .failed(let text): return text
        case .timedOut: return "The model didn't answer in time."
        case .cancelled: return "The request was cancelled."
        }
    }
}

protocol OneShotRunning: Sendable {
    func run(_ prompt: OneShotPrompt, on target: OneShotTarget, timeout: TimeInterval) async throws -> OneShotResult
}

/// Settings a call needs, read on the main thread when the request arrives.
struct OneShotConfiguration: Sendable {
    var copilotPath = ""
    var claudePath = ""
    var agyPath = ""
    var localBaseURL = ""
    var localAPIKey = ""
    var localModel = ""

    @MainActor
    static func current(_ settings: AppSettings = .shared) -> OneShotConfiguration {
        OneShotConfiguration(copilotPath: settings.copilotPath, claudePath: settings.claudePath,
                             agyPath: settings.agyPath, localBaseURL: settings.localBaseURL,
                             localAPIKey: settings.localAPIKey, localModel: settings.localModel)
    }
}

/// Runs one-shot calls through the real CLIs, each in a fresh private folder that is deleted
/// afterwards. Every call is tool-free:
/// - Copilot: `-p` with an isolated config, no tools (`MessageRouter.copilotNoTools`), no MCP
///   servers; images go in as `--attachment`.
/// - Claude Code: `-p` stream-json with `--tools ""` and an empty strict MCP config; images go in
///   as image blocks.
/// - Antigravity: has no tool-free mode, so Cantrip's hook denies every tool call. Text only.
/// - Local Model: the messages are sent to its OpenAI-compatible server as they are.
/// Codex can't turn its shell off and Copilot Remote has no one-shot mode, so neither is used.
struct OneShotCompletion: OneShotRunning {
    var configuration: OneShotConfiguration
    /// Copilot and Antigravity take the prompt as an argument, which the system caps (ARG_MAX).
    static let maximumArgumentCharacters = 200_000

    static func unsupportedReason(_ backend: BackendKind) -> String? {
        switch backend {
        case .copilot, .claudeCode, .antigravity, .localModel: return nil
        case .codex: return "Codex can't run without its shell tool, so it can't answer tool-free requests."
        case .copilotRemote: return "Copilot Remote runs sessions on another machine and has no one-shot mode."
        }
    }

    func run(_ prompt: OneShotPrompt, on target: OneShotTarget, timeout: TimeInterval) async throws -> OneShotResult {
        if let reason = Self.unsupportedReason(target.backend) { throw OneShotError.unavailable(reason) }
        try Task.checkCancellation()
        switch target.backend {
        case .copilot: return try await runCopilot(prompt, target: target, timeout: timeout)
        case .claudeCode: return try await runClaude(prompt, target: target, timeout: timeout)
        case .antigravity: return try await runAntigravity(prompt, target: target, timeout: timeout)
        default: return try await runLocal(prompt, target: target, timeout: timeout)
        }
    }

    // MARK: - Copilot

    static func copilotArguments(_ prompt: OneShotPrompt, target: OneShotTarget, attachments: [String]) -> [String] {
        var arguments = [
            "-p", prompt.combinedText, "-s", "--stream", "on", "--output-format", "json",
            MessageRouter.copilotNoTools, "--disable-builtin-mcps", "--no-custom-instructions",
            "--no-ask-user", "--no-auto-update", "--sync-session=off", "--log-level", "none",
        ]
        if !target.model.isEmpty { arguments += ["--model", target.model] }
        if !target.effort.isEmpty { arguments += ["--reasoning-effort", target.effort] }
        if !target.contextTier.isEmpty { arguments += ["--context", target.contextTier] }
        for path in attachments { arguments += ["--attachment", path] }
        return arguments
    }

    private func runCopilot(_ prompt: OneShotPrompt, target: OneShotTarget, timeout: TimeInterval) async throws -> OneShotResult {
        guard prompt.combinedText.count <= Self.maximumArgumentCharacters else {
            throw OneShotError.unavailable("The prompt is too long for Copilot's command line.")
        }
        guard let executable = ToolLocator.shared.copilot(configured: configuration.copilotPath) else {
            throw OneShotError.unavailable("Couldn't find the `copilot` CLI.")
        }
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Isolated config: no hooks, plugins, MCP servers, memory or history. The sign-in still
        // comes from the CLI's keychain item.
        let config = try JSONSerialization.data(withJSONObject: [
            "disableAllHooks": true, "memory": false, "ide": ["autoConnect": false],
        ] as [String: Any])
        try config.write(to: folder.appendingPathComponent("config.json"))
        try config.write(to: folder.appendingPathComponent("settings.json"))
        let attachments = try Self.stage(prompt.images, in: folder)
        var environment = Self.environment()
        environment["COPILOT_HOME"] = folder.path
        let result = try await OneShotProcess.run(
            executable, Self.copilotArguments(prompt, target: target, attachments: attachments),
            environment: environment, directory: folder, input: nil, timeout: timeout
        )
        return try Self.copilotResult(result.output, status: result.status, errorText: result.errorText, target: target)
    }

    /// What `copilot -p --output-format json` printed: the answer, a usage-limit error from
    /// `session.error` (`errorType` quota or rate_limit), or why it failed.
    static func copilotResult(_ output: Data, status: Int32, errorText: String, target: OneShotTarget,
                              now: Date = Date()) throws -> OneShotResult {
        var answer: String?
        var streamed = ""
        var model = target.model
        var premium: Double?
        var sessionError: (type: String?, code: String?, message: String)?
        var usedTools = false
        for line in output.split(separator: 0x0A) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            let data = event["data"] as? [String: Any] ?? [:]
            let root = data["parentToolCallId"] == nil && data["agentId"] == nil
            switch type {
            case "assistant.message" where root:
                if let content = data["content"] as? String, !content.isEmpty { answer = content }
                if let used = data["model"] as? String, !used.isEmpty { model = used }
            case "assistant.message_delta" where root:
                streamed += data["deltaContent"] as? String ?? ""
            case "session.error" where root:
                sessionError = (data["errorType"] as? String, data["errorCode"] as? String,
                                data["message"] as? String ?? "Copilot reported an error.")
            case "tool.execution_start":
                usedTools = true
            case "session.usage_checkpoint":
                premium = (data["totalPremiumRequests"] as? NSNumber)?.doubleValue ?? premium
            case "result":
                let usage = event["usage"] as? [String: Any]
                premium = (usage?["premiumRequests"] as? NSNumber)?.doubleValue ?? premium
            default:
                break
            }
        }
        if let sessionError {
            if let report = UsageLimit.copilotReport(errorType: sessionError.type, errorCode: sessionError.code,
                                                     message: sessionError.message, now: now) {
                throw OneShotError.usageLimit(report, sessionError.message)
            }
            throw OneShotError.failed("Copilot: \(sessionError.message)")
        }
        guard !usedTools else { throw OneShotError.failed("Copilot tried to use a tool, which these calls don't allow.") }
        let text = (answer ?? streamed).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else {
            throw OneShotError.failed("Copilot exited with status \(status)" + Self.detail(errorText))
        }
        guard !text.isEmpty else { throw OneShotError.failed("Copilot returned an empty answer" + Self.detail(errorText)) }
        return OneShotResult(text: text, model: model, premiumRequests: premium)
    }

    // MARK: - Claude Code

    static let defaultSystemPrompt = "You are a helpful assistant."

    static func claudeArguments(_ prompt: OneShotPrompt, target: OneShotTarget) -> [String] {
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--system-prompt", prompt.system.isEmpty ? defaultSystemPrompt : prompt.system,
            "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--safe-mode", "--disable-slash-commands", "--no-session-persistence",
        ]
        if !target.model.isEmpty { arguments += ["--model", target.model] }
        if !target.effort.isEmpty { arguments += ["--effort", target.effort] }
        return arguments
    }

    /// The one user message Claude reads from standard input: the conversation, then the images.
    static func claudeInput(_ prompt: OneShotPrompt) throws -> Data {
        var content: [[String: Any]] = []
        let text = prompt.conversationText
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        for image in prompt.images {
            content.append(["type": "image", "source": [
                "type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString(),
            ]])
        }
        var line = try JSONSerialization.data(withJSONObject: [
            "type": "user", "message": ["role": "user", "content": content],
        ] as [String: Any])
        line.append(0x0A)
        return line
    }

    private func runClaude(_ prompt: OneShotPrompt, target: OneShotTarget, timeout: TimeInterval) async throws -> OneShotResult {
        guard let executable = ToolLocator.shared.claude(configured: configuration.claudePath) else {
            throw OneShotError.unavailable("Couldn't find the `claude` CLI.")
        }
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await OneShotProcess.run(
            executable, Self.claudeArguments(prompt, target: target), environment: Self.environment(),
            directory: folder, input: try Self.claudeInput(prompt), timeout: timeout
        )
        return try Self.claudeResult(result.output, status: result.status, errorText: result.errorText, target: target)
    }

    /// What `claude -p --output-format stream-json` printed. Limits come from the same fields
    /// Claude Code tabs use: an `assistant` message's `error` and a `rejected` rate-limit event.
    static func claudeResult(_ output: Data, status: Int32, errorText: String, target: OneShotTarget,
                             tracker: UsageTracker = .shared) throws -> OneShotResult {
        var texts: [String] = []
        var model = target.model
        var limitText: String?
        var report: UsageLimitReport?
        var usedTools = false
        var final: [String: Any]?
        for line in output.split(separator: 0x0A) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "system":
                if event["subtype"] as? String == "init", let used = event["model"] as? String { model = used }
            case "assistant" where event["parent_tool_use_id"] as? String == nil:
                if let limit = ClaudeCodeBackend.usageLimitMessage(event) {
                    limitText = limit.text
                    report = report ?? limit.report
                    continue
                }
                let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content {
                    switch block["type"] as? String {
                    case "text": if let text = block["text"] as? String { texts.append(text) }
                    case "tool_use": usedTools = true
                    default: break
                    }
                }
            case "rate_limit_event":
                if let rejected = ClaudeCodeBackend.rateLimitEvent(event, tracker: tracker) { report = rejected }
            case "result":
                final = event
            default:
                break
            }
        }
        guard let final else {
            if let report { throw OneShotError.usageLimit(report, limitText ?? "Claude usage limit reached.") }
            throw OneShotError.failed("Claude ended without an answer (status \(status))" + Self.detail(errorText))
        }
        let resultText = (final["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if final["is_error"] as? Bool == true {
            if let report { throw OneShotError.usageLimit(report, resultText.isEmpty ? limitText ?? "Claude usage limit reached." : resultText) }
            throw OneShotError.failed("Claude: " + (resultText.isEmpty ? "the request failed" : resultText))
        }
        if let limitText, texts.isEmpty {
            throw OneShotError.usageLimit(report ?? UsageLimitReport(code: "rate_limit", resetsAt: nil), limitText)
        }
        guard !usedTools else { throw OneShotError.failed("Claude tried to use a tool, which these calls don't allow.") }
        let text = resultText.isEmpty ? texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : resultText
        guard !text.isEmpty else { throw OneShotError.failed("Claude returned an empty answer.") }
        let usage = final["usage"] as? [String: Any] ?? [:]
        let cached = usage["cache_read_input_tokens"] as? Int ?? 0
        if let models = final["modelUsage"] as? [String: Any], models.count == 1, let used = models.keys.first { model = used }
        return OneShotResult(
            text: text, model: model,
            inputTokens: (usage["input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0) + cached,
            outputTokens: usage["output_tokens"] as? Int ?? 0, cachedInputTokens: cached,
            costUSD: (final["total_cost_usd"] as? NSNumber)?.doubleValue
        )
    }

    // MARK: - Antigravity

    static func antigravityArguments(_ prompt: OneShotPrompt, target: OneShotTarget, timeout: TimeInterval) -> [String] {
        var arguments = [
            "-p", "Answer from the text below alone; don't use any tools.\n\n" + prompt.combinedText,
            "--output-format", "json", "--disable-slash-commands",
            "--print-timeout", "\(max(1, Int(timeout)))s",
            "--settings", #"{"permissions":{"deny":["command(*)"]}}"#,
        ]
        if !target.model.isEmpty { arguments += ["--model", target.model] }
        if !target.effort.isEmpty { arguments += ["--effort", target.effort] }
        return arguments
    }

    private func runAntigravity(_ prompt: OneShotPrompt, target: OneShotTarget, timeout: TimeInterval) async throws -> OneShotResult {
        guard prompt.images.isEmpty else {
            throw OneShotError.unavailable("Antigravity reads images only with its file tools, which these calls don't allow.")
        }
        guard prompt.combinedText.count <= Self.maximumArgumentCharacters else {
            throw OneShotError.unavailable("The prompt is too long for Antigravity's command line.")
        }
        guard let executable = AntigravityBackend.resolveExecutable(customPath: configuration.agyPath) else {
            throw OneShotError.unavailable("Couldn't find the `agy` CLI.")
        }
        // agy has no tool-free mode, so Cantrip's guardrail hook refuses every tool it asks for.
        do { try AntigravityHook.install() } catch {
            throw OneShotError.unavailable("Cantrip couldn't set up Antigravity's tool check: \(error.localizedDescription)")
        }
        let hook = try AntigravityHookServer { _, respond in
            respond("deny", "Tools are off for this request. Answer from the text you were given.")
        }
        defer { hook.stop() }
        let folder = try Self.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var environment = Self.environment()
        environment[AntigravityHook.socketVariable] = hook.socketPath
        let result = try await OneShotProcess.run(
            executable, Self.antigravityArguments(prompt, target: target, timeout: timeout),
            environment: environment, directory: folder, input: nil, timeout: timeout + 10
        )
        return try Self.antigravityResult(result.output, status: result.status, errorText: result.errorText, target: target)
    }

    /// `agy -p --output-format json`: `status`, `response` and `usage`. agy reports no limit code, so
    /// its limits come only from the usage read (`UsageTracker`), which marks the backend limited.
    static func antigravityResult(_ output: Data, status: Int32, errorText: String, target: OneShotTarget) throws -> OneShotResult {
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            throw OneShotError.failed("Antigravity exited with status \(status)" + detail(errorText))
        }
        let state = object["status"] as? String ?? ""
        let text = (object["response"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard state.uppercased() == "SUCCESS", !text.isEmpty else {
            let reason = (object["error"] as? String) ?? (object["message"] as? String) ?? (state.isEmpty ? "no answer" : state)
            throw OneShotError.failed("Antigravity: \(reason)" + detail(errorText))
        }
        let usage = object["usage"] as? [String: Any] ?? [:]
        return OneShotResult(text: text, model: target.model,
                             inputTokens: usage["input_tokens"] as? Int ?? 0,
                             outputTokens: usage["output_tokens"] as? Int ?? 0,
                             cachedInputTokens: usage["cache_read_tokens"] as? Int ?? 0)
    }

    // MARK: - Local Model

    private func runLocal(_ prompt: OneShotPrompt, target: OneShotTarget, timeout: TimeInterval) async throws -> OneShotResult {
        let base = configuration.localBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions"), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw OneShotError.unavailable("The Local Model address isn't set.")
        }
        let model = target.model.isEmpty ? configuration.localModel : target.model
        var body: [String: Any] = [
            "model": model, "stream": false,
            "messages": (try? JSONSerialization.jsonObject(with: prompt.messagesJSON)) ?? [],
        ]
        if let maxTokens = prompt.maxTokens { body["max_tokens"] = maxTokens }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.localAPIKey.isEmpty {
            request.setValue("Bearer \(configuration.localAPIKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw OneShotError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw OneShotError.timedOut
        } catch {
            throw OneShotError.failed("The local model server couldn't be reached: \(error.localizedDescription)")
        }
        return try Self.localResult(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, model: model)
    }

    /// An OpenAI-compatible reply. A 429 whose `error.code` or `type` names a used-up quota is a limit.
    static func localResult(_ data: Data, status: Int, model: String) throws -> OneShotResult {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = object?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "HTTP \(status)"
            let code = (error?["code"] as? String) ?? (error?["type"] as? String) ?? ""
            if status == 429, ["insufficient_quota", "rate_limit_exceeded", "usage_limit_reached"].contains(code) {
                throw OneShotError.usageLimit(UsageLimitReport(code: code, resetsAt: nil), message)
            }
            throw OneShotError.failed("Local model: \(message)")
        }
        let message = ((object?["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any]
        let content = message?["content"]
        let text = ((content as? String)
            ?? (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw OneShotError.failed("The local model returned an empty answer.") }
        let usage = object?["usage"] as? [String: Any] ?? [:]
        return OneShotResult(text: text, model: object?["model"] as? String ?? model,
                             inputTokens: usage["prompt_tokens"] as? Int ?? 0,
                             outputTokens: usage["completion_tokens"] as? Int ?? 0)
    }

    // MARK: - Helpers

    static func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-oneshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    static func stage(_ images: [OneShotPrompt.Image], in folder: URL) throws -> [String] {
        try images.enumerated().map { index, image in
            let url = folder.appendingPathComponent("image-\(index + 1).\(image.fileExtension)")
            try image.data.write(to: url, options: .withoutOverwriting)
            return url.path
        }
    }

    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolPath.value(inherited: environment["PATH"])
        // No project: the Default profile, if there is one.
        EnvironmentProfiles.apply(to: &environment, workdir: nil)
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        environment[AntigravityHook.socketVariable] = nil
        environment["CANTRIP_TAB_ID"] = nil
        return environment
    }

    static func detail(_ errorText: String) -> String {
        let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "." : ": " + String(trimmed.suffix(300))
    }
}

/// Runs a CLI off the main thread. Cancelling the task stops the process.
enum OneShotProcess {
    private final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func started(_ process: Process) {
            let stop = lock.withLock { () -> Bool in
                self.process = process
                return cancelled
            }
            if stop { Self.stop(process) }
        }

        func cancel() {
            let process = lock.withLock { () -> Process? in
                cancelled = true
                return self.process
            }
            if let process { Self.stop(process) }
        }

        private static func stop(_ process: Process) {
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String], directory: URL,
                    input: Data?, timeout: TimeInterval) async throws -> ProcessRunner.Result {
        let handle = Handle()
        let result: ProcessRunner.Result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try ProcessRunner.run(
                            executable, arguments, environment: environment, directory: directory, input: input,
                            errorOutput: .capture, timeout: timeout, outputLimit: 16_000_000,
                            launched: { handle.started($0) }
                        ))
                    } catch {
                        continuation.resume(throwing: OneShotError.unavailable(
                            "Couldn't start \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)"))
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
        if Task.isCancelled { throw OneShotError.cancelled }
        if result.timedOut { throw OneShotError.timedOut }
        return result
    }
}

/// At most `limit` one-shot calls at once; the rest wait their turn (each CLI process takes a
/// few hundred MB).
actor OneShotGate {
    private let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async throws {
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiting.isEmpty {
            running = max(0, running - 1)
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }

    var waitingCount: Int { waiting.count }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
