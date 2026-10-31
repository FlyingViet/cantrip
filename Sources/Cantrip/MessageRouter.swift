import Foundation

/// Separate, tool-free inference; never reuses or resumes the worker session.
enum MessageRouter {
    /// The Copilot CLI model for routing and planning (cheapest available; gpt-5.4-mini was retired).
    static let copilotModel = "claude-haiku-4.5"
    /// The Antigravity CLI model for lightweight routing, queue planning, and Done-when checks.
    static let antigravityModel = "gemini-3.8-flash-medium"

    enum Provider {
        case copilot(command: String)
        case claude(command: String)
        case antigravity(command: String, model: String = MessageRouter.antigravityModel)
        case local(baseURL: String, model: String, apiKey: String)
        case unavailable(String)
    }

    static func classify(
        _ snapshot: MessageRoutingSnapshot, provider: Provider
    ) async throws -> MessageRoutingDecision {
        let response = try await completion(snapshot, provider: provider)
        return try MessageRoutingDecision.parse(response)
    }

    static func completion(
        _ snapshot: MessageRoutingSnapshot, provider: Provider
    ) async throws -> String {
        try await completion(input: snapshot.encoded(), instructions: MessageRoutingPolicy.instructions,
                             provider: provider)
    }

    /// Which queued messages to run together with the next one (one tool-free inference).
    static func groupQueue(
        _ snapshot: QueueGroupingSnapshot, provider: Provider
    ) async throws -> QueueGroupingDecision {
        let response = try await completion(input: snapshot.encoded(),
                                            instructions: QueueGroupingPolicy.instructions,
                                            provider: provider)
        return try QueueGroupingDecision.parse(response)
    }

    /// `timeout` bounds CLI inference: quick for routing a message as it arrives, longer for
    /// work that runs while the tab is busy anyway (queue plans).
    static func completion(
        input: String, instructions: String, provider: Provider, timeout: TimeInterval = 12,
        maxTokens: Int = 200
    ) async throws -> String {
        let response: String
        switch provider {
        case .local(let baseURL, let model, let key):
            response = try await localCompletion(input, instructions: instructions, baseURL: baseURL,
                                                 model: model, key: key, timeout: timeout, maxTokens: maxTokens)
        case .copilot, .claude, .antigravity:
            response = try await RouterProcess().run(provider: provider, input: input,
                                                     instructions: instructions, timeout: timeout)
        case .unavailable(let reason):
            throw MessageRoutingError.unavailable(reason)
        }
        return jsonAnswer(response)
    }

    /// The answer's JSON object. Some models wrap it in a Markdown fence or add a sentence after it.
    static func jsonAnswer(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{") else { return trimmed }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(trimmed[start...index]) }
            }
            index = trimmed.index(after: index)
        }
        return trimmed
    }

    private static func localCompletion(
        _ input: String, instructions: String, baseURL: String, model: String, key: String,
        timeout: TimeInterval, maxTokens: Int
    ) async throws -> String {
        let request = try localRequest(input, instructions: instructions,
                                       baseURL: baseURL, model: model, key: key, maxTokens: maxTokens)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: RouterNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MessageRoutingError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MessageRoutingError.http(http.statusCode)
        }
        return try localResponse(data)
    }

    static func localRequest(
        _ input: String, instructions: String = MessageRoutingPolicy.instructions,
        baseURL: String, model: String, key: String, maxTokens: Int = 200
    ) throws -> URLRequest {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/chat/completions"),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw MessageRoutingError.unavailable("the local router URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": input],
            ],
        ])
        return request
    }

    static func localResponse(_ data: Data) throws -> String {
        guard data.count <= 32_768,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              message["tool_calls"] == nil,
              let text = message["content"] as? String else {
            throw MessageRoutingError.invalidResponse
        }
        return text
    }
}

private final class RouterNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private final class RouterProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cantrip.message-router")
    private var process: Process?
    private var continuation: CheckedContinuation<String, Error>?
    private var cancelled = false
    private var output = Data()
    private var directory: URL?

    func run(provider: MessageRouter.Provider, input: String, instructions: String,
             timeout: TimeInterval = 12) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    if self.cancelled {
                        self.finish(.failure(CancellationError()))
                    } else {
                        self.start(provider: provider, input: input, instructions: instructions, timeout: timeout)
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func start(provider: MessageRouter.Provider, input: String, instructions: String, timeout: TimeInterval) {
        do {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("cantrip-router-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: scratch, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            directory = scratch
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ToolPath.value(inherited: env["PATH"])
            env["NO_COLOR"] = "1"
            env["TERM"] = "dumb"
            let command: String
            let arguments: [String]
            switch provider {
            case .copilot(let executable):
                command = executable
                // Isolated config excludes user/repo hooks, plugins, MCPs and
                // history. Authentication still uses the CLI's OS credential store.
                let config: [String: Any] = [
                    "disableAllHooks": true, "memory": false,
                    "ide": ["autoConnect": false],
                ]
                let data = try JSONSerialization.data(withJSONObject: config)
                try data.write(to: scratch.appendingPathComponent("config.json"))
                try data.write(to: scratch.appendingPathComponent("settings.json"))
                env["COPILOT_HOME"] = scratch.path
                arguments = [
                    "-p", instructions + "\n\n" + input,
                    "-s", "--stream", "on", "--output-format", "json",
                    // 0.33 premium requests a call; it takes no reasoning-effort setting.
                    "--model", MessageRouter.copilotModel,
                    "--available-tools=", "--disable-builtin-mcps",
                    "--no-custom-instructions", "--no-ask-user",
                    "--no-auto-update", "--sync-session=off", "--log-level", "none",
                ]
            case .claude(let executable):
                command = executable
                arguments = [
                    "-p", input, "--model", "haiku", "--output-format", "text",
                    "--system-prompt", instructions,
                    "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--safe-mode", "--disable-slash-commands", "--no-session-persistence",
                ]
            case .antigravity(let executable, let model):
                command = executable
                // agy has no tool-free mode. Headless, a shell command it reaches for is refused and
                // the run then prints nothing, so deny commands outright (the model is told and
                // answers) and say up front that no tools are needed.
                arguments = [
                    "-p", "Answer from the text below alone; don't use any tools.\n\n" + instructions + "\n\n" + input,
                    "--model", model,
                    "--output-format", "text",
                    "--disable-slash-commands",
                    "--settings", #"{"permissions":{"deny":["command(*)"]}}"#,
                ]
            default:
                throw MessageRoutingError.unavailable("no tool-free router is configured for this backend.")
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [command] + arguments
            p.environment = env
            p.currentDirectoryURL = scratch
            p.standardInput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            let stdoutLock = NSLock()
            p.standardOutput = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                stdoutLock.withLock {
                    let data = handle.availableData
                    self.queue.async {
                        guard self.continuation != nil else { return }
                        self.output.append(data)
                        if self.output.count > 262_144 {
                            self.finish(.failure(MessageRoutingError.invalidResponse))
                        }
                    }
                }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                stdoutLock.lock()
                defer { stdoutLock.unlock() }
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                self.queue.async {
                    guard self.continuation != nil else { return }
                    self.output.append(tail)
                    if proc.terminationStatus == 0, self.output.count <= 262_144 {
                        do {
                            let text: String
                            if case .copilot = provider {
                                var parser = CopilotJSONStreamParser()
                                var malformed = false
                                let events = parser.consume(self.output) { _, _ in malformed = true }
                                    + parser.finish { _, _ in malformed = true }
                                let usedTools = events.contains {
                                    if case .activity = $0 { return true }
                                    return false
                                }
                                guard !malformed, !usedTools else { throw MessageRoutingError.invalidResponse }
                                text = parser.answer
                            } else {
                                text = String(decoding: self.output, as: UTF8.self)
                            }
                            self.finish(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                        } catch {
                            self.finish(.failure(error))
                        }
                    } else {
                        self.finish(.failure(MessageRoutingError.processFailed(proc.terminationStatus)))
                    }
                }
            }
            process = p
            try p.run()
            // agy starts a language server per call: 5-11 s where the other CLIs take 2-4.
            let limit: TimeInterval
            if case .antigravity = provider { limit = max(timeout, 25) } else { limit = timeout }
            queue.asyncAfter(deadline: .now() + limit) {
                guard self.continuation != nil else { return }
                self.finish(.failure(MessageRoutingError.timeout))
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let p = process
        process = nil
        if let p, p.isRunning {
            p.terminate()
            queue.asyncAfter(deadline: .now() + 1) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        // Wait for process teardown before removing its isolated state.
        if let directory {
            self.directory = nil
            queue.asyncAfter(deadline: .now() + 2) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { Log.write("message-router: temporary-state cleanup failed: \(error.localizedDescription)") }
            }
        }
        continuation.resume(with: result)
    }
}
