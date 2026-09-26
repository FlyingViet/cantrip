import Foundation

/// A separate transport with no tools, redirects, proxy, credentials, or cloud fallback.
final class PrivateLocalClient: NSObject, URLSessionTaskDelegate {
    private var session: URLSession!

    init(configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func close() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SessionModelSettingsError(502, "Your self-hosted Ollama server rejected the request (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). No cloud fallback was used.")
        }
    }

    private func request(_ configuration: PrivateLocalConfiguration, path: String,
                         body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: try configuration.endpoint(path))
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func object(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        try check(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionModelSettingsError(502, "Your self-hosted Ollama server returned an invalid response.")
        }
        return object
    }

    func models(_ configuration: PrivateLocalConfiguration) async throws -> [String] {
        try configuration.validate(requireModel: false)
        let value = try await object(request(configuration, path: "/api/tags"))
        guard let models = value["models"] as? [[String: Any]] else {
            throw SessionModelSettingsError(502, "This server did not return an Ollama installed-model list.")
        }
        return models.compactMap { model in
            guard let name = model["name"] as? String, !PrivateLocalConfiguration.isCloudModel(name),
                  model["remote_model"] == nil, model["remote_host"] == nil else { return nil }
            return name
        }.sorted()
    }

    func chat(_ configuration: PrivateLocalConfiguration, request input: BackendRequest,
              onEvent: @escaping (BackendEvent) -> Void) async throws {
        try configuration.validate()
        let installed = try await models(configuration)
        let name = configuration.model.contains(":") ? configuration.model : configuration.model + ":latest"
        guard installed.contains(configuration.model) || installed.contains(name) else {
            throw SessionModelSettingsError(409, "The selected model is not installed on your self-hosted server. Install it there with Ollama, then reload models. Nothing was sent to a cloud model.")
        }
        // A cloud alias can appear in /api/tags. Require local model metadata before sending any text.
        let details = try await object(request(configuration, path: "/api/show", body: ["model": configuration.model]))
        guard details["remote_model"] == nil, details["remote_host"] == nil,
              let info = details["model_info"] as? [String: Any],
              let architecture = info["general.architecture"] as? String, !architecture.isEmpty else {
            throw SessionModelSettingsError(409, "Ollama did not confirm a model installed on the selected server. Cloud aliases and models forwarded to another inference provider are not allowed.")
        }
        try Task.checkCancellation()
        var messages: [[String: String]] = []
        if !configuration.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": configuration.systemPrompt])
        }
        messages += ConversationContextBuilder.chatMessages(for: input.userMessage, turns: input.previousTurns)
            .map { ["role": $0.role, "content": $0.content] }
        messages.append(["role": "user", "content": input.prompt])
        let body: [String: Any] = ["model": configuration.model, "messages": messages, "stream": true,
                                   "options": ["num_ctx": configuration.contextWindow]]
        let (bytes, response) = try await session.bytes(for: request(configuration, path: "/api/chat", body: body))
        try check(response)
        var completed = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SessionModelSettingsError(502, "Your self-hosted Ollama server returned an invalid stream.")
            }
            if value["error"] != nil {
                throw SessionModelSettingsError(502, "Your self-hosted Ollama server could not complete the request. Check the model and available memory on that server.")
            }
            if let message = value["message"] as? [String: Any] {
                if let tools = message["tool_calls"] as? [Any], !tools.isEmpty {
                    throw SessionModelSettingsError(409, "Tools are disabled in Private Local. No tool was executed.")
                }
                if let text = message["content"] as? String, !text.isEmpty { onEvent(.textDelta(text)) }
                if let text = message["thinking"] as? String, !text.isEmpty { onEvent(.thinkingDelta(text)) }
            }
            if value["done"] as? Bool == true { completed = true; break }
        }
        guard completed else {
            throw SessionModelSettingsError(502, "Your self-hosted Ollama server disconnected before finishing. No cloud fallback was used.")
        }
        onEvent(.done)
    }
}

final class PrivateLocalBackend: Backend {
    var configuration = PrivateLocalConfiguration()
    private var task: Task<Void, Never>?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        cancel()
        let configuration = configuration
        task = Task {
            let client = PrivateLocalClient()
            defer { client.close() }
            do {
                onEvent(.status("Checking self-hosted model..."))
                try await client.chat(configuration, request: request, onEvent: onEvent)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                onEvent(.failure("Private Local: \(error.localizedDescription) No cloud fallback is available."))
            }
        }
    }

    func cancel() { task?.cancel(); task = nil }
    func reset() { cancel() }
}
