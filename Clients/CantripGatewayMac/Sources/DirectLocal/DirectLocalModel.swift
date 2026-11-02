import Foundation

/// Direct local mode: chat with a model served on THIS Mac (an Ollama-compatible server on
/// loopback, or HTTPS elsewhere), without the paired Cantrip host. Same rules as the host's
/// Private Local tab: no credentials, no redirects or proxies, no cloud models and no cloud
/// fallback. Conversations stay on this Mac and are never synced. Unlike Private Local, the model
/// can use tools from MCP servers on this Mac that you turn on; each asks first unless you allow it.
struct DirectLocalConfiguration: Codable, Equatable {
    static let defaultBaseURL = "http://127.0.0.1:11434"
    static let defaultSystemPrompt = "You are a helpful private assistant running on this Mac. Answer from this conversation and any tool results, and never claim to have looked something up unless a tool returned it."
    /// The default before tools existed; saved copies of it are upgraded to the current default.
    static let legacyDefaultSystemPrompt = "You are a helpful private assistant. Answer using only this conversation. You have no tools or internet access."
    static let contextRange = 512...131072

    var baseURL = defaultBaseURL
    var model = ""
    var contextWindow = 8192
    var systemPrompt = defaultSystemPrompt
    var tools = DirectLocalToolSettings()

    enum CodingKeys: String, CodingKey {
        case baseURL, model, contextWindow, systemPrompt, tools
    }

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

extension DirectLocalConfiguration {
    /// Settings saved by older versions lack newer keys; they keep their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.defaultBaseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 8192
        let prompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? Self.defaultSystemPrompt
        systemPrompt = prompt == Self.legacyDefaultSystemPrompt ? Self.defaultSystemPrompt : prompt
        tools = try container.decodeIfPresent(DirectLocalToolSettings.self, forKey: .tools) ?? DirectLocalToolSettings()
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
    /// A reply that used tools: what the model wrote and called in each round before `content`,
    /// which is the text of the final round.
    var toolRounds: [DirectLocalToolRound]?

    /// Everything the reply wrote, across tool rounds.
    var displayText: String {
        ((toolRounds ?? []).map(\.content) + [content]).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var toolCalls: [DirectLocalToolCall] { (toolRounds ?? []).flatMap(\.calls) }
}

/// One round of a reply: text the model wrote, then the tools it called.
struct DirectLocalToolRound: Codable, Equatable {
    var content: String
    var calls: [DirectLocalToolCall]
}

struct DirectLocalToolCall: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case waiting, running, done, failed, denied

        var isFinished: Bool { self != .waiting && self != .running }
    }

    var id = UUID()
    /// The function name the model called.
    let name: String
    /// The MCP server and tool it maps to; nil when the model named a tool that wasn't offered.
    var server: String?
    var tool: String?
    /// The arguments as JSON.
    var arguments: String
    var state: State
    /// What the model is told: the tool's output, or why it didn't run.
    var result: String?

    var label: String {
        if let server, let tool { return "\(server) · \(tool)" }
        return name
    }
}

// MARK: - Stream parsing

/// A tool call from the model's reply.
struct DirectLocalToolRequest: Equatable {
    let name: String
    /// The arguments as JSON (an object).
    let arguments: String
}

/// One line of Ollama's `/api/chat` NDJSON stream.
enum DirectLocalStreamEvent: Equatable {
    case content(String)
    case thinking(String)
    case toolCalls([DirectLocalToolRequest])
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
            if let thinking = message["thinking"] as? String, !thinking.isEmpty { events.append(.thinking(thinking)) }
            if let content = message["content"] as? String, !content.isEmpty { events.append(.content(content)) }
            if let calls = message["tool_calls"] as? [Any], !calls.isEmpty {
                events.append(.toolCalls(calls.compactMap(toolRequest)))
            }
        }
        if value["done"] as? Bool == true { events.append(.done) }
        return events
    }

    /// Ollama sends `arguments` as an object; OpenAI-style servers send a JSON string.
    static func toolRequest(_ value: Any) -> DirectLocalToolRequest? {
        guard let call = value as? [String: Any], let function = call["function"] as? [String: Any],
              let name = function["name"] as? String, !name.isEmpty else { return nil }
        var arguments: Any = function["arguments"] ?? [String: Any]()
        if let text = arguments as? String {
            arguments = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? [String: Any]()
        }
        return DirectLocalToolRequest(name: name, arguments: DirectLocalTools.json(arguments as? [String: Any] ?? [:]))
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
    /// Tool results from earlier turns are cut to this many characters.
    static let olderResultLimit = 600

    /// The chat messages to send: the system prompt, then the current turn (your latest message
    /// and any tool rounds since), then as many earlier turns as fit in about three characters per
    /// context token, newest first. `reservedCharacters` is taken up by the tool definitions.
    /// Failed or empty replies are left out.
    static func chatMessages(_ conversation: [DirectLocalMessage], configuration: DirectLocalConfiguration,
                             reservedCharacters: Int = 0, systemNote: String? = nil) -> [[String: Any]] {
        let usable = conversation.filter { message in
            message.role == .user
                ? !message.content.isEmpty
                : message.error == nil && (!message.content.isEmpty || !(message.toolRounds ?? []).isEmpty)
        }
        let system = [configuration.systemPrompt, systemNote ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
        var budget = max(1_000, configuration.contextWindow * 3 - system.count - reservedCharacters)
        let currentTurn = usable.lastIndex { $0.role == .user } ?? 0
        // Room the question itself needs, so this turn's tool results never crowd it out (a server
        // over its context drops the oldest messages first: the question).
        let question = usable.indices.contains(currentTurn) && usable[currentTurn].role == .user
            ? usable[currentTurn].content.count : 0
        var picked: [(role: DirectLocalMessage.Role, messages: [[String: Any]])] = []
        for (index, message) in usable.enumerated().reversed() {
            let current = index >= currentTurn
            let limit = current ? nil : olderResultLimit
            var encoded = encode(message, earlierRounds: limit, lastRound: limit)
            var size = characters(encoded)
            let room = budget - (current && message.role == .assistant ? question : 0)
            if current, message.role == .assistant, size > room {
                // Shorten earlier rounds first, then share what's left among the newest round's results.
                encoded = encode(message, earlierRounds: olderResultLimit, lastRound: nil)
                size = characters(encoded)
                if size > room, let calls = message.toolRounds?.last?.calls.count, calls > 0 {
                    let withoutResults = characters(encode(message, earlierRounds: olderResultLimit, lastRound: 0))
                    let share = max(300, (room - withoutResults) / calls)
                    encoded = encode(message, earlierRounds: olderResultLimit, lastRound: share)
                    size = characters(encoded)
                }
            }
            if !current, !picked.isEmpty, size > budget { break }
            picked.append((message.role, encoded))
            budget -= size
        }
        // A reply with nothing before it confuses chat templates.
        while picked.last?.role == .assistant { picked.removeLast() }
        var messages: [[String: Any]] = []
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages += picked.reversed().flatMap(\.messages)
        return messages
    }

    /// One stored message as chat messages: each tool round becomes the assistant's tool calls
    /// followed by one `tool` message per result. Results are cut to `earlierRounds` characters,
    /// or `lastRound` in the newest round; nil keeps them whole.
    static func encode(_ message: DirectLocalMessage, earlierRounds: Int?, lastRound: Int?) -> [[String: Any]] {
        guard message.role == .assistant else { return [["role": "user", "content": message.content]] }
        var messages: [[String: Any]] = []
        let rounds = message.toolRounds ?? []
        for (index, round) in rounds.enumerated() {
            messages.append(["role": "assistant", "content": round.content, "tool_calls": round.calls.map { call in
                ["function": ["name": call.name, "arguments": DirectLocalTools.object(call.arguments)] as [String: Any]]
            }])
            let limit = index == rounds.count - 1 ? lastRound : earlierRounds
            for call in round.calls {
                let result = call.result ?? "(No result.)"
                messages.append(["role": "tool", "tool_name": call.name,
                                 "content": limit.map { DirectLocalTools.truncated(result, limit: $0) } ?? result])
            }
        }
        if !message.content.isEmpty { messages.append(["role": "assistant", "content": message.content]) }
        return messages
    }

    private static func characters(_ messages: [[String: Any]]) -> Int {
        messages.reduce(0) { total, message in
            let text = (message["content"] as? String)?.count ?? 0
            let calls = (message["tool_calls"] as? [Any]).map { DirectLocalTools.json(["c": $0]).count } ?? 0
            return total + text + calls
        }
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

    /// Streams one reply and returns the tools it called (only possible when `tools` were offered).
    /// `onEvent` runs on an arbitrary queue with text and thinking; it gets `.done` last.
    @discardableResult
    func chat(_ configuration: DirectLocalConfiguration, messages: [[String: Any]], tools: [[String: Any]] = [],
              onEvent: @escaping (DirectLocalStreamEvent) -> Void) async throws -> [DirectLocalToolRequest] {
        try await verify(configuration)
        try Task.checkCancellation()
        var body: [String: Any] = ["model": configuration.model, "messages": messages, "stream": true,
                                   "options": ["num_ctx": configuration.contextWindow]]
        if !tools.isEmpty { body["tools"] = tools }
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
        var requests: [DirectLocalToolRequest] = []
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in try DirectLocalStream.events(fromLine: line) {
                switch event {
                case .failure(let message):
                    throw DirectLocalError("The local server stopped: \(message)")
                case .toolCalls(let calls):
                    guard !tools.isEmpty else {
                        throw DirectLocalError("The model asked to use a tool, but no tools are turned on, so nothing ran.")
                    }
                    requests += calls
                case .done:
                    finished = true
                default:
                    onEvent(event)
                }
            }
            if finished { break }
        }
        guard finished else {
            throw DirectLocalError("The local server disconnected before finishing the reply.")
        }
        onEvent(.done)
        return requests
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
    var toolCatalogURL: URL { directory.appendingPathComponent("mcp-tools.json") }

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
            for round in (messages[index].toolRounds ?? []).indices {
                for call in messages[index].toolRounds![round].calls.indices
                where !messages[index].toolRounds![round].calls[call].state.isFinished {
                    messages[index].toolRounds![round].calls[call].state = .failed
                    messages[index].toolRounds![round].calls[call].result = "Interrupted: the app quit before this tool finished."
                }
            }
        }
        return messages
    }

    func saveConversation(_ messages: [DirectLocalMessage]) throws {
        try write(messages, to: conversationURL)
    }

    func loadToolCatalog() -> [String: DirectLocalToolCatalogEntry] {
        guard let data = try? Data(contentsOf: toolCatalogURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: DirectLocalToolCatalogEntry].self, from: data)) ?? [:]
    }

    func saveToolCatalog(_ catalog: [String: DirectLocalToolCatalogEntry]) throws {
        try write(catalog, to: toolCatalogURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
