import Foundation

/// A separate transport with no redirects, proxy, credentials, or cloud fallback. Tools only when
/// switched on (read-only, `PrivateLocalTools`), and only with OpenAI-compatible servers.
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

    private func check(_ response: URLResponse, _ api: PrivateLocalAPI) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let hint = api == .openAI && status == 404
                ? " Check that the URL ends in the server's API version path, such as /v1." : ""
            throw SessionModelSettingsError(502, "Your \(api.serverName) rejected the request (HTTP \(status)).\(hint) No cloud fallback was used.")
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

    private func object(_ request: URLRequest, _ api: PrivateLocalAPI) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        try check(response, api)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionModelSettingsError(502, "Your \(api.serverName) returned an invalid response.")
        }
        return object
    }

    func models(_ configuration: PrivateLocalConfiguration) async throws -> [String] {
        try configuration.validate(requireModel: false)
        let api = configuration.api
        let value = try await object(request(configuration, path: api.modelsPath), api)
        switch api {
        case .ollama:
            guard let models = value["models"] as? [[String: Any]] else {
                throw SessionModelSettingsError(502, "This server did not return an Ollama installed-model list.")
            }
            return models.compactMap { model in
                guard let name = model["name"] as? String, !PrivateLocalConfiguration.isCloudModel(name),
                      model["remote_model"] == nil, model["remote_host"] == nil else { return nil }
                return name
            }.sorted()
        case .openAI:
            return try Self.openAIModels(value)
        }
    }

    /// `GET /models` from an OpenAI-compatible server: `data[].id`, without cloud-named models.
    static func openAIModels(_ value: [String: Any]) throws -> [String] {
        guard let models = value["data"] as? [[String: Any]] else {
            throw SessionModelSettingsError(502, "This server did not return an OpenAI-compatible model list. Check that the URL ends in its API version path, such as /v1.")
        }
        return Set(models.compactMap { model -> String? in
            guard let id = model["id"] as? String, !id.isEmpty,
                  !PrivateLocalConfiguration.isCloudModel(id) else { return nil }
            return id
        }).sorted()
    }

    func chat(_ configuration: PrivateLocalConfiguration, request input: BackendRequest,
              tools: PrivateLocalToolSession? = nil,
              onEvent: @escaping (BackendEvent) -> Void) async throws {
        try configuration.validate()
        let api = configuration.api
        let installed = try await models(configuration)
        switch api {
        case .ollama:
            let name = configuration.model.contains(":") ? configuration.model : configuration.model + ":latest"
            guard installed.contains(configuration.model) || installed.contains(name) else {
                throw SessionModelSettingsError(409, "The selected model is not installed on your self-hosted server. Install it there with Ollama, then reload models. Nothing was sent to a cloud model.")
            }
            // A cloud alias can appear in /api/tags. Require local model metadata before sending any text.
            let details = try await object(request(configuration, path: "/api/show", body: ["model": configuration.model]), api)
            guard details["remote_model"] == nil, details["remote_host"] == nil,
                  let info = details["model_info"] as? [String: Any],
                  let architecture = info["general.architecture"] as? String, !architecture.isEmpty else {
                throw SessionModelSettingsError(409, "Ollama did not confirm a model installed on the selected server. Cloud aliases and models forwarded to another inference provider are not allowed.")
            }
        case .openAI:
            // OpenAI-compatible servers have no /api/show equivalent. Locality rests on the address
            // rule (HTTPS to the user's own server, or loopback HTTP), on that server being the user's,
            // and on refusing cloud-named models; the model must still be one the server lists.
            guard installed.contains(configuration.model) else {
                throw SessionModelSettingsError(409, "The selected model is not available on your self-hosted server. Load or install it there, then reload models. Nothing was sent to a cloud model.")
            }
        }
        try Task.checkCancellation()
        if let tools, api == .openAI, !tools.isEmpty {
            return try await chatWithTools(configuration, request: input, tools: tools, onEvent: onEvent)
        }
        var messages: [[String: String]] = []
        if !configuration.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": configuration.systemPrompt])
        }
        messages += (input.replay ?? ConversationContextBuilder.chatMessages(for: input.userMessage, turns: input.previousTurns))
            .map { ["role": $0.role, "content": $0.content] }
        messages.append(["role": "user", "content": input.prompt])
        var body: [String: Any] = ["model": configuration.model, "messages": messages, "stream": true]
        // The context window has no portable OpenAI field; those servers set it themselves.
        if api == .ollama { body["options"] = ["num_ctx": configuration.contextWindow] }
        let (bytes, response) = try await session.bytes(for: request(configuration, path: api.chatPath, body: body))
        try check(response, api)
        var completed = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let chunk = try api == .ollama ? Self.ollamaStreamChunk(line) : Self.openAIStreamChunk(line)
            guard let chunk else { continue }
            if !chunk.thinking.isEmpty { onEvent(.thinkingDelta(chunk.thinking)) }
            if !chunk.text.isEmpty { onEvent(.textDelta(chunk.text)) }
            if chunk.finished { completed = true; break }
        }
        guard completed else {
            throw SessionModelSettingsError(502, "Your \(api.serverName) disconnected before finishing. No cloud fallback was used.")
        }
        onEvent(.done)
    }

    /// Replies that may use read-only tools: each step streams; requested tools run (refused when
    /// not offered) and show as tool steps; older tool output is left out first to fit the window.
    private func chatWithTools(_ configuration: PrivateLocalConfiguration, request input: BackendRequest,
                               tools: PrivateLocalToolSession, onEvent: @escaping (BackendEvent) -> Void) async throws {
        let base = configuration.systemPrompt == PrivateLocalConfiguration().systemPrompt
            ? "You are a helpful private assistant." : configuration.systemPrompt
        let system = (base.isEmpty ? "" : base + "\n\n") + tools.instructions
        var history: [[String: Any]] = (input.replay ?? ConversationContextBuilder.chatMessages(for: input.userMessage, turns: input.previousTurns))
            .map { ["role": $0.role, "content": $0.content] }
        var replayed = history.count
        history.append(["role": "user", "content": input.prompt])
        var steps = 0
        while true {
            try Task.checkCancellation()
            let offered = steps < PrivateLocalTools.maxSteps ? tools.openAITools() : []
            if steps == PrivateLocalTools.maxSteps {
                history.append(["role": "user", "content": "(Tool step limit reached. Answer now with what you found, and say what you couldn't check.)"])
            }
            let fixed = HomeLocalProfile.estimate(system)
                + HomeLocalProfile.estimate(String(decoding: (try? JSONSerialization.data(withJSONObject: offered)) ?? Data(), as: UTF8.self))
            let budget = configuration.contextWindow - HomeLocalProfile.outputReserveTokens - fixed
            let before = history.filter { $0["content"] as? String == OpenAICompatibleBackend.leftOut }.count
            guard OpenAICompatibleBackend.fit(&history, budget: budget, replayed: &replayed) else {
                throw SessionModelSettingsError(413, "This reply needs more than the \(configuration.contextWindow)-token context window, even after leaving out earlier tool output. Nothing was sent to a cloud model.")
            }
            let leftOut = history.filter { $0["content"] as? String == OpenAICompatibleBackend.leftOut }.count - before
            if leftOut > 0 { Log.write("private local: left out \(leftOut) earlier tool outputs to fit \(configuration.contextWindow) tokens") }
            var body: [String: Any] = ["model": configuration.model, "stream": true,
                                       "messages": [["role": "system", "content": system]] + history]
            if !offered.isEmpty { body["tools"] = offered }
            let (bytes, response) = try await session.bytes(for: request(configuration, path: PrivateLocalAPI.openAI.chatPath, body: body))
            try check(response, .openAI)
            var text = "", finish: String?, calls: [Int: (id: String, name: String, arguments: String)] = [:]
            var completed = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let chunk = try Self.openAIToolChunk(line) else { continue }
                if !chunk.thinking.isEmpty { onEvent(.thinkingDelta(chunk.thinking)) }
                if !chunk.text.isEmpty { text += chunk.text; onEvent(.textDelta(chunk.text)) }
                for delta in chunk.calls {
                    var call = calls[delta.index] ?? ("", "", "")
                    if let id = delta.id { call.id = id }
                    call.name += delta.name ?? ""
                    call.arguments += delta.arguments ?? ""
                    calls[delta.index] = call
                }
                if let reason = chunk.finishReason { finish = reason }
                if chunk.done || chunk.finishReason != nil { completed = true }
                if chunk.done { break }
            }
            guard completed else {
                throw SessionModelSettingsError(502, "Your self-hosted server disconnected before finishing. No cloud fallback was used.")
            }
            let requested = calls.sorted { $0.key < $1.key }.map(\.value).filter { !$0.name.isEmpty }
            guard !requested.isEmpty, finish != "stop" || text.isEmpty, steps < PrivateLocalTools.maxSteps else {
                onEvent(.done)
                return
            }
            steps += 1
            let named = requested.enumerated().map { index, call in
                (id: call.id.isEmpty ? "call_\(steps)_\(index)" : call.id, name: call.name, arguments: call.arguments)
            }
            history.append(["role": "assistant", "content": text.isEmpty ? NSNull() : text,
                            "tool_calls": named.map { ["id": $0.id, "type": "function",
                                                       "function": ["name": $0.name, "arguments": $0.arguments]] }])
            for call in named {
                try Task.checkCancellation()
                let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
                let activity = ToolActivityFactory.start(id: call.id, toolName: call.name, arguments: arguments)
                onEvent(.activity(activity))
                let result = await tools.call(call.name, arguments: arguments)
                onEvent(.activity(ToolActivityFactory.complete(activity, id: call.id, success: result.success, output: result.output)))
                var content = result.output
                if content.count > PrivateLocalTools.resultCharacters {
                    content = String(content.prefix(PrivateLocalTools.resultCharacters))
                        + "\n[\(content.count - PrivateLocalTools.resultCharacters) more characters left out]"
                }
                history.append(["role": "tool", "tool_call_id": call.id, "content": content])
            }
            onEvent(.status("Reading tool results…"))
        }
    }

    struct ToolCallDelta: Equatable {
        var index = 0
        var id: String?
        var name: String?
        var arguments: String?
    }

    struct ToolStreamChunk: Equatable {
        var text = ""
        var thinking = ""
        var calls: [ToolCallDelta] = []
        var finishReason: String?
        /// `data: [DONE]`.
        var done = false
    }

    /// One server-sent-events line of a stream that may call tools, or nil for a blank line,
    /// comment or non-data field.
    static func openAIToolChunk(_ line: String) throws -> ToolStreamChunk? {
        let invalid = SessionModelSettingsError(502, "Your self-hosted server returned an invalid stream.")
        guard !line.isEmpty, !line.hasPrefix(":") else { return nil }
        guard line.hasPrefix("data:") else {
            guard ["event:", "id:", "retry:"].contains(where: line.hasPrefix) else { throw invalid }
            return nil
        }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { return ToolStreamChunk(done: true) }
        guard let value = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw invalid }
        if let error = value["error"], !(error is NSNull) {
            throw SessionModelSettingsError(502, "Your self-hosted server could not complete the request. Check the model and available memory on that server.")
        }
        var chunk = ToolStreamChunk()
        guard let choice = (value["choices"] as? [[String: Any]])?.first else { return chunk }
        if let delta = choice["delta"] as? [String: Any] {
            chunk.text = delta["content"] as? String ?? ""
            chunk.thinking = [delta["reasoning_content"], delta["reasoning"]]
                .lazy.compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
            chunk.calls = (delta["tool_calls"] as? [[String: Any]] ?? []).map { call in
                let function = call["function"] as? [String: Any]
                return ToolCallDelta(index: (call["index"] as? NSNumber)?.intValue ?? 0, id: call["id"] as? String,
                                     name: function?["name"] as? String, arguments: function?["arguments"] as? String)
            }
        }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty { chunk.finishReason = reason }
        return chunk
    }

    struct StreamChunk: Equatable {
        var text = ""
        var thinking = ""
        var finished = false
    }

    static var toolsDisabled: SessionModelSettingsError {
        SessionModelSettingsError(409, "Tools are disabled in Private Local. No tool was executed.")
    }

    /// One NDJSON line of Ollama's `/api/chat` stream, or nil for a blank line.
    static func ollamaStreamChunk(_ line: String) throws -> StreamChunk? {
        guard !line.isEmpty else { return nil }
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionModelSettingsError(502, "Your self-hosted Ollama server returned an invalid stream.")
        }
        if value["error"] != nil {
            throw SessionModelSettingsError(502, "Your self-hosted Ollama server could not complete the request. Check the model and available memory on that server.")
        }
        var chunk = StreamChunk()
        if let message = value["message"] as? [String: Any] {
            if let tools = message["tool_calls"] as? [Any], !tools.isEmpty { throw toolsDisabled }
            chunk.text = message["content"] as? String ?? ""
            chunk.thinking = message["thinking"] as? String ?? ""
        }
        chunk.finished = value["done"] as? Bool == true
        return chunk
    }

    /// One server-sent-events line of an OpenAI-compatible `/chat/completions` stream, or nil for a
    /// blank line, comment or non-data field. `data: [DONE]` or a finish reason ends the reply.
    static func openAIStreamChunk(_ line: String) throws -> StreamChunk? {
        let invalid = SessionModelSettingsError(502, "Your self-hosted server returned an invalid stream.")
        guard !line.isEmpty, !line.hasPrefix(":") else { return nil }
        guard line.hasPrefix("data:") else {
            guard ["event:", "id:", "retry:"].contains(where: line.hasPrefix) else { throw invalid }
            return nil
        }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" { return StreamChunk(finished: true) }
        guard let value = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw invalid
        }
        if let error = value["error"], !(error is NSNull) {
            throw SessionModelSettingsError(502, "Your self-hosted server could not complete the request. Check the model and available memory on that server.")
        }
        var chunk = StreamChunk()
        guard let choice = (value["choices"] as? [[String: Any]])?.first else { return chunk }
        if let delta = choice["delta"] as? [String: Any] {
            if let tools = delta["tool_calls"] as? [Any], !tools.isEmpty { throw toolsDisabled }
            if let call = delta["function_call"], !(call is NSNull) { throw toolsDisabled }
            chunk.text = delta["content"] as? String ?? ""
            chunk.thinking = [delta["reasoning_content"], delta["reasoning"]]
                .lazy.compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
        }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            guard !["tool_calls", "function_call"].contains(reason) else { throw toolsDisabled }
            chunk.finished = true
        }
        return chunk
    }
}

final class PrivateLocalBackend: Backend {
    var configuration = PrivateLocalConfiguration()
    /// Tests replace the tools.
    var tools: PrivateLocalTools = .shared
    private var task: Task<Void, Never>?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        cancel()
        let configuration = configuration
        let provider = tools
        task = Task {
            let client = PrivateLocalClient()
            var session: PrivateLocalToolSession?
            defer { client.close(); session?.close() }
            do {
                onEvent(.status("Checking self-hosted model..."))
                if configuration.tools.enabled, configuration.api == .openAI {
                    onEvent(.status("Listing read-only tools..."))
                    session = await provider.session(configuration.tools)
                }
                try await client.chat(configuration, request: request, tools: session, onEvent: onEvent)
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
