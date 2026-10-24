import Foundation

/// Direct local mode: chat with a model served on THIS Mac (an Ollama-compatible server on
/// loopback, or HTTPS elsewhere), without the paired Cantrip host. Same rules as the host's
/// Private Local tab: no credentials, no tools, no redirects or proxies, no cloud models and no
/// cloud fallback. Conversations stay on this Mac and are never synced.
struct DirectLocalConfiguration: Codable, Equatable {
    static let defaultBaseURL = "http://127.0.0.1:11434"
    static let defaultSystemPrompt = "You are a helpful private assistant. Answer using only this conversation. You have no tools or internet access."
    static let contextRange = 512...131072

    var baseURL = defaultBaseURL
    var model = ""
    var contextWindow = 8192
    var systemPrompt = defaultSystemPrompt

    /// The server URL for an API path. Plain HTTP only on loopback; credentials, queries,
    /// fragments and dot segments are refused, so the address can't smuggle anything along.
    func endpoint(_ path: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !components.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw DirectLocalError("Enter the local model server's address without credentials, query parameters, fragments or dot-path segments, for example \(Self.defaultBaseURL).")
        }
        guard components.scheme?.lowercased() == "https" || Self.isLoopback(host) else {
            throw DirectLocalError("Unencrypted HTTP is allowed only on this Mac (127.0.0.1, localhost or [::1]). Use HTTPS for a server on another machine.")
        }
        if host == "localhost" { components.host = "127.0.0.1" }
        components.percentEncodedPath = components.percentEncodedPath
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression) + path
        guard let url = components.url else { throw DirectLocalError("Invalid local model server address.") }
        return url
    }

    static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
    }

    func validate(requireModel: Bool = true) throws {
        _ = try endpoint("/api/chat")
        guard Self.contextRange.contains(contextWindow), systemPrompt.count <= 8000 else {
            throw DirectLocalError("Choose 512-131072 context tokens and a system prompt of at most 8000 characters.")
        }
        guard !requireModel || !model.isEmpty else {
            throw DirectLocalError("Choose a model: load the models installed on the server, then pick one.")
        }
        guard model.count <= 200, model.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !model.contains("://"), !Self.isCloudModel(model) else {
            throw DirectLocalError("Choose a model installed on the local server, not a cloud model.")
        }
    }

    static func isCloudModel(_ name: String) -> Bool {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("cloud")
    }

    /// "host:port" for labels, e.g. "127.0.0.1:11434".
    var serverLabel: String {
        guard let components = URLComponents(string: baseURL), let host = components.host else { return baseURL }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    var isLoopbackServer: Bool {
        URLComponents(string: baseURL)?.host.map(Self.isLoopback) ?? false
    }
}

struct DirectLocalError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One stored message of the direct local conversation.
struct DirectLocalMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    let role: Role
    var content: String
    var thinking: String?
    var error: String?
    /// The model that wrote an assistant reply.
    var model: String?
    var date = Date()
    /// Still streaming; a message saved in this state was interrupted (the app quit mid-reply).
    var streaming = false
}

// MARK: - Stream parsing

/// One line of Ollama's `/api/chat` NDJSON stream.
enum DirectLocalStreamEvent: Equatable {
    case content(String)
    case thinking(String)
    case done
    case failure(String)
}

enum DirectLocalStream {
    static func events(fromLine line: String) throws -> [DirectLocalStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DirectLocalError("The local server returned an invalid stream.")
        }
        if let error = value["error"] {
            return [.failure(serverMessage(error) ?? "The local server couldn't finish the reply.")]
        }
        var events: [DirectLocalStreamEvent] = []
        if let message = value["message"] as? [String: Any] {
            if let tools = message["tool_calls"] as? [Any], !tools.isEmpty {
                throw DirectLocalError("The model asked to use a tool. Tools are off in direct local mode, so nothing ran.")
            }
            if let thinking = message["thinking"] as? String, !thinking.isEmpty { events.append(.thinking(thinking)) }
            if let content = message["content"] as? String, !content.isEmpty { events.append(.content(content)) }
        }
        if value["done"] as? Bool == true { events.append(.done) }
        return events
    }

    /// Ollama sends `"error": "text"`; OpenAI-style servers (such as mlx-serve) send
    /// `"error": {"message": "text"}`.
    static func serverMessage(_ error: Any) -> String? {
        if let text = error as? String { return text.isEmpty ? nil : String(text.prefix(600)) }
        if let object = error as? [String: Any], let text = object["message"] as? String, !text.isEmpty {
            return String(text.prefix(600))
        }
        return nil
    }
}

// MARK: - Conversation history

enum DirectLocalHistory {
    /// The chat messages to send: the system prompt, then as many recent turns as fit in about
    /// three characters per context token (newest first), always including the latest message.
    /// Failed or empty replies are left out.
    static func chatMessages(_ conversation: [DirectLocalMessage],
                             configuration: DirectLocalConfiguration) -> [[String: String]] {
        let usable = conversation.filter { !$0.content.isEmpty && ($0.role == .user || $0.error == nil) }
        var budget = max(1_000, configuration.contextWindow * 3 - configuration.systemPrompt.count)
        var picked: [DirectLocalMessage] = []
        for message in usable.reversed() {
            if !picked.isEmpty, message.content.count > budget { break }
            picked.append(message)
            budget -= message.content.count
        }
        // A reply with nothing before it confuses chat templates.
        while picked.last?.role == .assistant { picked.removeLast() }
        var messages: [[String: String]] = []
        if !configuration.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": configuration.systemPrompt])
        }
        messages += picked.reversed().map { ["role": $0.role.rawValue, "content": $0.content] }
        return messages
    }
}

// MARK: - Transport

/// A dedicated session: no proxy, cookies, cache, credentials or redirects.
final class DirectLocalClient: NSObject, URLSessionTaskDelegate {
    private var session: URLSession!

    init(configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 1800
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func close() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// Refuses every credential challenge: nothing is sent but the request itself.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func request(_ configuration: DirectLocalConfiguration, path: String,
                         body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: try configuration.endpoint(path))
        request.httpShouldHandleCookies = false
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func object(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await transport { try await self.session.data(for: request) }
        try Self.check(response, body: data)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DirectLocalError("The local server returned a response that isn't from an Ollama-compatible API.")
        }
        return object
    }

    /// Connection failures say what to check, since the usual cause is a stopped server.
    private func transport<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .timedOut, .notConnectedToInternet:
                throw DirectLocalError("Couldn't reach the local model server (\(error.localizedDescription)). Check that it is running and listening on that address.")
            default:
                throw DirectLocalError("The local model server couldn't be reached: \(error.localizedDescription)")
            }
        }
    }

    static func check(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DirectLocalError("The local server returned an invalid response.")
        }
        guard http.statusCode == 200 else {
            let detail = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                .flatMap { $0["error"] }.flatMap(DirectLocalStream.serverMessage)
            throw DirectLocalError(detail.map { "The local server couldn't do that (HTTP \(http.statusCode)): \($0)" }
                ?? "The local server rejected the request (HTTP \(http.statusCode)).")
        }
    }

    /// Installed models from `/api/tags`, without cloud models or ones forwarded elsewhere.
    func models(_ configuration: DirectLocalConfiguration) async throws -> [String] {
        try configuration.validate(requireModel: false)
        let value = try await object(request(configuration, path: "/api/tags"))
        guard let models = value["models"] as? [[String: Any]] else {
            throw DirectLocalError("This server did not return an Ollama installed-model list from /api/tags.")
        }
        return Self.localModelNames(models)
    }

    static func localModelNames(_ models: [[String: Any]]) -> [String] {
        Array(Set(models.compactMap { model -> String? in
            guard let name = (model["name"] as? String) ?? (model["model"] as? String), !name.isEmpty,
                  !DirectLocalConfiguration.isCloudModel(name),
                  model["remote_model"] == nil, model["remote_host"] == nil else { return nil }
            return name
        })).sorted()
    }

    /// Confirms the model is installed here with its own weights before any text is sent.
    func verify(_ configuration: DirectLocalConfiguration) async throws {
        try configuration.validate()
        let installed = try await models(configuration)
        let tagged = configuration.model.contains(":") ? configuration.model : configuration.model + ":latest"
        guard installed.contains(configuration.model) || installed.contains(tagged) else {
            throw DirectLocalError("\(configuration.model) isn't installed on the local server. Reload models and pick one it lists.")
        }
        let details = try await object(request(configuration, path: "/api/show", body: ["model": configuration.model]))
        guard Self.isLocalModel(details) else {
            throw DirectLocalError("The server did not confirm a model installed on it. Cloud aliases and models forwarded to another provider are not allowed.")
        }
    }

    static func isLocalModel(_ details: [String: Any]) -> Bool {
        guard details["remote_model"] == nil, details["remote_host"] == nil,
              let info = details["model_info"] as? [String: Any],
              let architecture = info["general.architecture"] as? String else { return false }
        return !architecture.isEmpty
    }

    /// Streams one reply. `onEvent` runs on an arbitrary queue; it gets `.done` last.
    func chat(_ configuration: DirectLocalConfiguration, messages: [[String: String]],
              onEvent: @escaping (DirectLocalStreamEvent) -> Void) async throws {
        try await verify(configuration)
        try Task.checkCancellation()
        let body: [String: Any] = ["model": configuration.model, "messages": messages, "stream": true,
                                   "options": ["num_ctx": configuration.contextWindow]]
        let request = try request(configuration, path: "/api/chat", body: body)
        let (bytes, response) = try await transport { try await self.session.bytes(for: request) }
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 16_000 { break }
            }
            try Self.check(response, body: data)
        }
        var finished = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in try DirectLocalStream.events(fromLine: line) {
                if case .failure(let message) = event {
                    throw DirectLocalError("The local server stopped: \(message)")
                }
                if event == .done { finished = true } else { onEvent(event) }
            }
            if finished { break }
        }
        guard finished else {
            throw DirectLocalError("The local server disconnected before finishing the reply.")
        }
        onEvent(.done)
    }
}

// MARK: - Storage on this Mac

/// The conversation (Application Support) and settings (this app's defaults), never synced.
struct DirectLocalStore {
    static let configurationKey = "directLocal.configuration.v1"
    let directory: URL
    let defaults: UserDefaults

    static var standardDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Cantrip Gateway Mac", isDirectory: true)
            .appendingPathComponent("DirectLocal", isDirectory: true)
    }

    init(directory: URL = DirectLocalStore.standardDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
    }

    var conversationURL: URL { directory.appendingPathComponent("conversation.json") }

    func loadConfiguration() -> DirectLocalConfiguration {
        guard let data = defaults.data(forKey: Self.configurationKey),
              let value = try? JSONDecoder().decode(DirectLocalConfiguration.self, from: data) else {
            return DirectLocalConfiguration()
        }
        return value
    }

    func saveConfiguration(_ configuration: DirectLocalConfiguration) throws {
        try configuration.validate(requireModel: false)
        defaults.set(try JSONEncoder().encode(configuration), forKey: Self.configurationKey)
    }

    /// A reply cut off by a quit or crash is kept and marked interrupted.
    func loadConversation() -> [DirectLocalMessage] {
        guard let data = try? Data(contentsOf: conversationURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var messages = try? decoder.decode([DirectLocalMessage].self, from: data) else { return [] }
        for index in messages.indices where messages[index].streaming {
            messages[index].streaming = false
            if messages[index].error == nil { messages[index].error = "Interrupted: the app quit before the reply finished." }
        }
        return messages
    }

    func saveConversation(_ messages: [DirectLocalMessage]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(messages).write(to: conversationURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: conversationURL.path)
    }
}
