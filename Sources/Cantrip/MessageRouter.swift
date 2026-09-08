import Foundation

/// Separate, tool-free inference; never reuses or resumes the worker session.
enum MessageRouter {
    enum Provider {
        case copilot(command: String)
        case claude(command: String)
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
        let input = try snapshot.encoded()
        let response: String
        switch provider {
        case .local(let baseURL, let model, let key):
            response = try await localCompletion(input, baseURL: baseURL, model: model, key: key)
        case .copilot, .claude:
            response = try await RouterProcess().run(provider: provider, input: input)
        case .unavailable(let reason):
            throw MessageRoutingError.unavailable(reason)
        }
        return response
    }

    private static func localCompletion(
        _ input: String, baseURL: String, model: String, key: String
    ) async throws -> String {
        let request = try localRequest(input, baseURL: baseURL, model: model, key: key)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 12
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
        _ input: String, baseURL: String, model: String, key: String
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
            "model": model, "stream": false, "max_tokens": 200,
            "messages": [
                ["role": "system", "content": MessageRoutingPolicy.instructions],
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

    func run(provider: MessageRouter.Provider, input: String) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    if self.cancelled {
                        self.finish(.failure(CancellationError()))
                    } else {
                        self.start(provider: provider, input: input)
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

    private func start(provider: MessageRouter.Provider, input: String) {
        do {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("cantrip-router-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: scratch, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            directory = scratch
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
                + (env["PATH"] ?? "/usr/bin:/bin")
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
                    "-p", MessageRoutingPolicy.instructions + "\n\n" + input,
                    "-s", "--stream", "on", "--output-format", "json",
                    "--model", "gpt-5.4-mini", "--reasoning-effort", "low",
                    "--available-tools=", "--disable-builtin-mcps",
                    "--no-custom-instructions", "--no-ask-user",
                    "--no-auto-update", "--no-remote-export", "--log-level", "none",
                ]
            case .claude(let executable):
                command = executable
                arguments = [
                    "-p", input, "--model", "haiku", "--output-format", "text",
                    "--system-prompt", MessageRoutingPolicy.instructions,
                    "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--safe-mode", "--disable-slash-commands", "--no-session-persistence",
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
            queue.asyncAfter(deadline: .now() + 12) {
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
