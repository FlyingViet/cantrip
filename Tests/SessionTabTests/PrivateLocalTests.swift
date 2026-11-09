import Foundation
import JavaScriptCore
import Network

private final class PrivateCloudTrap: Backend {
    var requests = 0
    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        requests += 1
        onEvent(.failure("A private request reached the cloud backend"))
    }
    func cancel() {}
    func reset() {}
}

private final class PrivateHTTPSFixture: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func clear() { lock.withLock { recorded = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request) }
        let url = request.url!
        let body: String
        switch url.lastPathComponent {
        case "tags": body = #"{"models":[{"name":"fixture:latest"}]}"#
        case "show": body = #"{"model_info":{"general.architecture":"llama"}}"#
        case "chat": body = #"{"message":{"content":"Self-hosted HTTPS response"},"done":true}"# + "\n"
        default: preconditionFailure("Unexpected self-hosted inference path")
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class PrivateOllamaFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cantrip-private-ollama-test")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var recorded: [HTTPRequest] = []
    private var scenario = "normal"
    var mode: String {
        get { lock.withLock { scenario } }
        set { lock.withLock { scenario = newValue; recorded = [] } }
    }
    var requests: [HTTPRequest] { lock.withLock { recorded } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)")
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            guard let request = HTTPRequest.parse(buffer) else {
                if !done && error == nil { self.receive(connection, buffer: buffer) }
                return
            }
            let mode = self.lock.withLock { self.recorded.append(request); return self.scenario }
            if mode == "redirectTags" || (mode == "redirectChat" && request.path == "/api/chat") {
                let header = "HTTP/1.1 307 Temporary Redirect\r\nLocation: /must-not-follow\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            var body: String
            switch request.path {
            case "/api/tags":
                body = mode == "missing" ? #"{"models":[]}"#
                    : #"{"models":[{"name":"fixture:latest"},{"name":"blocked:cloud"},{"name":"remote","remote_host":"cloud.example"}]}"#
            case "/api/show":
                body = mode == "cloud" ? #"{"remote_model":"hidden-proxy","model_info":{"general.architecture":"llama"}}"#
                    : mode == "unverified" ? #"{"model_info":{}}"# : #"{"model_info":{"general.architecture":"llama"}}"#
            case "/api/chat":
                if mode == "hold" { return }
                body = mode == "tools" ? #"{"message":{"tool_calls":[{"function":{"name":"run_shell"}}]},"done":true}"#
                    : mode == "malformed" ? "not-json"
                    : mode == "incomplete" ? #"{"message":{"content":"Partial"},"done":false}"#
                    : #"{"message":{"content":"Local answer ![blocked](https://cloud.example/pixel)"},"done":false}"#
                        + "\n" + #"{"message":{"content":" complete"},"done":true}"#
            case "/v1/models":
                body = mode == "openai-missing" ? #"{"object":"list","data":[]}"#
                    : #"{"object":"list","data":[{"id":"Fixture-8B-4bit","object":"model"},{"id":"gpt-cloud"},{"id":"Alpha-1B"}]}"#
            case "/v1/chat/completions":
                if mode == "openai-redirect" {
                    let header = "HTTP/1.1 307 Temporary Redirect\r\nLocation: /must-not-follow\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                func event(_ delta: String, finish: String = "null") -> String {
                    #"data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish)}]}"#
                        + "\n\n"
                }
                body = ": keep-alive\n\n" + event(#"{"role":"assistant","content":""}"#)
                switch mode {
                case "openai-tools":
                    body += event(#"{"tool_calls":[{"index":0,"id":"t1","type":"function","function":{"name":"run_shell","arguments":"{}"}}]}"#)
                case "openai-error":
                    body += #"data: {"error":{"message":"out of memory"}}"# + "\n\n"
                case "openai-incomplete":
                    body += event(#"{"content":"Partial"}"#)
                case "openai-malformed":
                    body += "data: not-json\n\n"
                case "openai-done":
                    body += event(#"{"content":"Only done"}"#) + "data: [DONE]\n\n"
                default:
                    body += event(#"{"reasoning_content":"Weighing it."}"#)
                        + event(#"{"content":"Local answer ![blocked](https://cloud.example/pixel)"}"#)
                        + event(#"{"content":" complete"}"#) + event("{}", finish: #""stop""#) + "data: [DONE]\n\n"
                }
                body = String(body.dropLast())
            default: body = #"{"error":"unexpected request"}"#
            }
            let data = Data((body + "\n").utf8)
            let type = request.path == "/v1/chat/completions" ? "text/event-stream" : "application/x-ndjson"
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header + data, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }
}

/// `precondition` for checks that throw.
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "") throws {
    let passed = try condition()
    precondition(passed, message())
}

extension SessionTabTests {
    @MainActor
    static func testPrivateLocal() async throws {
        let settings = AppSettings.shared
        let originalBackend = settings.backend, memory = settings.memoryEnabled
        let originalConfig = UserDefaults.standard.data(forKey: "privateLocalConfiguration")
        let digest = UserDefaults.standard.string(forKey: "lastConversationDigest")
        defer {
            settings.backend = originalBackend
            settings.memoryEnabled = memory
            UserDefaults.standard.set(originalConfig, forKey: "privateLocalConfiguration")
            UserDefaults.standard.set(digest, forKey: "lastConversationDigest")
        }
        let fixture = try PrivateOllamaFixture()
        var configuration = PrivateLocalConfiguration()
        configuration.baseURL = try await fixture.start()
        configuration.model = "fixture:latest"
        defer { fixture.stop() }
        for address in ["http://llm.example", "http://192.168.0.10:11434", "http://127.0.0.1.evil",
                        "http://127.0.0.1@cloud.example", "https://user:password@llm.example",
                        "http://127.0.0.1?url=cloud", "https://llm.example/../other",
                        "https://llm.example/ollama/%2e%2e/other", "https://",
                        "file:///tmp/model", "http://2130706433:11434", "http://127.0.0.1#fragment"] {
            var invalid = configuration
            invalid.baseURL = address
            do { try invalid.validate(); preconditionFailure("Unencrypted remote or ambiguous endpoints must fail") }
            catch let error as SessionModelSettingsError { precondition(error.status == 400) }
        }
        for address in ["http://localhost:11434", "http://127.0.0.1:11434", "https://[::1]:11434",
                        "https://192.168.0.34:11434", "https://ollama.lan", "https://llm.example.ts.net",
                        "https://llm.example/ollama/", "http://localhost:11434/ollama/"] {
            var valid = configuration
            valid.baseURL = address
            try valid.validate()
        }
        var remote = configuration
        remote.baseURL = "https://llm.example.ts.net/inference/ollama/"
        let endpoint = try remote.endpoint("/api/chat")
        precondition(endpoint.absoluteString == "https://llm.example.ts.net/inference/ollama/api/chat")
        var encoded = remote
        encoded.baseURL = "https://llm.example:8443/inference%20server/"
        let encodedEndpoint = try encoded.endpoint("/api/tags")
        precondition(encodedEndpoint.absoluteString == "https://llm.example:8443/inference%20server/api/tags")
        let httpsConfiguration = URLSessionConfiguration.ephemeral
        httpsConfiguration.protocolClasses = [PrivateHTTPSFixture.self]
        let httpsClient = PrivateLocalClient(configuration: httpsConfiguration)
        defer { httpsClient.close(); PrivateHTTPSFixture.clear() }
        try await httpsClient.chat(remote, request: BackendRequest(
            prompt: "Synthetic remote-inference fixture", userMessage: "Synthetic remote-inference fixture",
            previousTurns: [])) { _ in }
        precondition(PrivateHTTPSFixture.requests.map { $0.url!.path } ==
                     ["/inference/ollama/api/tags", "/inference/ollama/api/show", "/inference/ollama/api/chat"])
        precondition(PrivateHTTPSFixture.requests.allSatisfy {
            $0.url?.scheme == "https" && $0.url?.host == "llm.example.ts.net"
        }, "Inference must reach the configured self-hosted machine, not be rewritten to the Cantrip Mac")
        let remoteChat = ChatSession(id: ChatSession.privateLocalID)
        try remoteChat.updatePrivateLocalSettings(remote, revision: remoteChat.privateLocalRevision)
        let restoredRemote = try ChatSession(id: remoteChat.id).privateLocalConfiguration()
        precondition(restoredRemote.baseURL == remote.baseURL, "A remote self-hosted endpoint must persist")
        let client = PrivateLocalClient()
        defer { client.close() }
        let models = try await client.models(configuration)
        precondition(models == ["fixture:latest"])
        let input = BackendRequest(prompt: "private-fixture", userMessage: "private-fixture", previousTurns: [])
        for mode in ["missing", "cloud", "unverified", "redirectTags", "redirectChat", "tools", "malformed", "incomplete"] {
            fixture.mode = mode
            do {
                try await client.chat(configuration, request: input) { _ in }
                preconditionFailure("Unsafe or incomplete local response must fail: \(mode)")
            } catch {
                precondition(!fixture.requests.contains { $0.path == "/must-not-follow" })
                if ["missing", "cloud", "unverified", "redirectTags"].contains(mode) {
                    precondition(!fixture.requests.contains { $0.path == "/api/chat" },
                                 "Never send private text before confirming a local model")
                }
            }
        }
        try await testPrivateLocalOpenAI(fixture: fixture, base: configuration.baseURL)
        fixture.mode = "normal"
        settings.backend = .copilot
        settings.memoryEnabled = true
        UserDefaults.standard.set("public-digest-must-not-cross", forKey: "lastConversationDigest")
        let cloud = PrivateCloudTrap()
        let chat = ChatSession(id: ChatSession.privateLocalID, copilotBackend: cloud)
        let manager = SessionManager()
        manager.sessions = [chat, manager.newSession()]
        try chat.updatePrivateLocalSettings(configuration, revision: chat.privateLocalRevision)
        let initialRevision = chat.privateLocalRevision
        var changed = configuration
        changed.contextWindow = 4096
        try chat.updatePrivateLocalSettings(changed, revision: initialRevision)
        do {
            try chat.updatePrivateLocalSettings(configuration, revision: initialRevision)
            preconditionFailure("Stale configuration must fail")
        } catch let error as SessionModelSettingsError { precondition(error.status == 409) }
        let restoredConfiguration = try ChatSession(id: chat.id).privateLocalConfiguration()
        precondition(restoredConfiguration == changed)
        chat.councilMode = true
        chat.isPrivate = true
        precondition(!chat.councilMode && !chat.isPrivate && chat.isLocked && chat.isLocalPrivate)
        precondition(!chat.supportsRemoteImages && chat.effectiveBackendKind == .localModel)
        var completions = 0
        chat.onRunFinished = { completions += 1 }
        chat.messages = (0..<40).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "Saved turn \($0)") }
        chat.submitRemote("! /usr/bin/touch /tmp/must-not-run-private-fixture")
        try await waitForJournalTest { !chat.isStreaming }
        precondition(chat.messages.last?.text.contains("Local answer") == true)
        precondition(cloud.requests == 0 && completions == 0 && chat.remoteCompletion == nil)
        let sent = fixture.requests.first { $0.path == "/api/chat" }!
        let body = sent.json!
        precondition(body["tools"] == nil && body["model"] as? String == "fixture:latest")
        precondition((body["options"] as? [String: Int])?["num_ctx"] == 4096)
        precondition(!String(data: sent.body, encoding: .utf8)!.contains("public-digest-must-not-cross"))
        precondition((body["messages"] as? [[String: String]])?.last?["content"]?.hasPrefix("! /usr/bin/touch") == true)
        precondition(ChatSession(id: chat.id).messages.count == chat.messages.count, "Private history must not truncate on relaunch")
        let restored = SessionManager()
        precondition(restored.sessions.filter(\.isLocalPrivate).count == 1)
        manager.close(chat.id)
        chat.newConversation()
        precondition(manager.sessions.contains { $0 === chat } && chat.messages.count >= 42)
        precondition(UserDefaults.standard.string(forKey: "lastConversationDigest") == "public-digest-must-not-cross")
        let memoryFiles = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: settings.memoryPath).appendingPathComponent("sessions"),
            includingPropertiesForKeys: nil)) ?? []
        for file in memoryFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            precondition(!text.contains("must-not-run-private-fixture"), "Private history must not enter shared memory")
        }
        let transcript = SessionManager.chatsDir.appendingPathComponent("\(chat.id).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: transcript.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        chat.isStreaming = true
        let before = fixture.requests.count
        chat.submitRemote("A private follow-up", mode: .auto)
        try await Task.sleep(for: .milliseconds(100))
        precondition(chat.queued.count == 1 && fixture.requests.count == before && cloud.requests == 0)
        do {
            try chat.updatePrivateLocalSettings(configuration, revision: chat.privateLocalRevision)
            preconditionFailure("Cannot change private configuration while busy")
        } catch let error as SessionModelSettingsError { precondition(error.status == 409) }
        chat.cancel()
        try await chat.flushJournal()
        fixture.mode = "hold"
        chat.submitRemote("Private work before a redirect")
        try await waitForJournalTest { fixture.requests.contains { $0.path == "/api/chat" } }
        chat.submitRemote("A queued private follow-up", mode: .auto)
        settings.backend = .claudeCode
        fixture.mode = "normal"
        chat.submitRemote("Redirect only on the local model", mode: .interrupt)
        try await waitForJournalTest {
            !chat.isStreaming && chat.queued.isEmpty && fixture.requests.filter { $0.path == "/api/chat" }.count == 2
        }
        precondition(cloud.requests == 0 && chat.remoteCompletion == nil && completions == 0,
                     "Redirects and drained queues must remain local even when global backend settings change")
        try await testPrivateLocalAPI(chat: chat, manager: manager, configuration: configuration)
        try testPrivateLocalWeb()
        let savedTranscript = try Data(contentsOf: transcript)
        defer { try? savedTranscript.write(to: transcript) }
        let corrupt = Data("corrupt-private-history".utf8)
        try corrupt.write(to: transcript)
        let damaged = ChatSession(id: chat.id, copilotBackend: cloud)
        damaged.submitRemote("Do not send when saved history is damaged")
        precondition(damaged.privateStorageError != nil && !damaged.isStreaming && cloud.requests == 0)
        let retained = try Data(contentsOf: transcript)
        precondition(retained == corrupt, "Corrupt private history must never be silently overwritten")
        print("Private Local: self-hosted HTTPS/base paths, loopback, cloud/redirect/tool rejection, persistence, queue, memory isolation, API and web passed")
    }

    /// One streamed reply from a real self-hosted server: `CANTRIP_PRIVATE_LOCAL_LIVE_URL` (an
    /// OpenAI-compatible base ending in /v1, or Ollama's with `CANTRIP_PRIVATE_LOCAL_LIVE_API=ollama`)
    /// and `CANTRIP_PRIVATE_LOCAL_LIVE_MODEL`. Run with `CANTRIP_TAB_TEST_ONLY=private-local-live`.
    static func testPrivateLocalLive() async throws {
        let environment = ProcessInfo.processInfo.environment
        var configuration = PrivateLocalConfiguration()
        configuration.baseURL = environment["CANTRIP_PRIVATE_LOCAL_LIVE_URL"] ?? ""
        configuration.model = environment["CANTRIP_PRIVATE_LOCAL_LIVE_MODEL"] ?? ""
        configuration.api = PrivateLocalAPI(rawValue: environment["CANTRIP_PRIVATE_LOCAL_LIVE_API"] ?? "openai") ?? .openAI
        let client = PrivateLocalClient()
        defer { client.close() }
        let models = try await client.models(configuration)
        precondition(models.contains(configuration.model), "Live server lists: \(models)")
        var text = "", thinking = "", done = false
        try await client.chat(configuration, request: BackendRequest(
            prompt: "Reply with exactly: private local ok", userMessage: "Reply with exactly: private local ok",
            previousTurns: [])) { event in
            switch event {
            case .textDelta(let delta): text += delta
            case .thinkingDelta(let delta): thinking += delta
            case .done: done = true
            default: break
            }
        }
        precondition(done && !text.isEmpty)
        print("Private Local live (\(configuration.api.rawValue)): \(models.count) model(s); reply \(text.count) chars, thinking \(thinking.count) chars: \(text.prefix(80))")
    }

    @MainActor
    private static func testPrivateLocalOpenAI(fixture: PrivateOllamaFixture, base: String) async throws {
        // Settings saved before the API choice decode as Ollama; new saves record the choice.
        let legacy = Data(#"{"baseURL":"https://llm.example.ts.net/ollama","model":"local:latest","contextWindow":4096,"systemPrompt":"Keep local"}"#.utf8)
        let decoded = try JSONDecoder().decode(PrivateLocalConfiguration.self, from: legacy)
        precondition(decoded.api == .ollama && decoded.model == "local:latest" && decoded.contextWindow == 4096)
        var openAI = decoded
        openAI.api = .openAI
        let encodedFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(openAI)) as! [String: Any]
        precondition(encodedFields["api"] as? String == "openai")
        try expect(JSONDecoder().decode(PrivateLocalConfiguration.self, from: JSONEncoder().encode(openAI)) == openAI)
        let ollamaFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
        precondition(ollamaFields["api"] as? String == "ollama")
        do { _ = try JSONDecoder().decode(PrivateLocalConfiguration.self, from: Data(#"{"baseURL":"x","model":"","contextWindow":1,"systemPrompt":"","api":"cloud"}"#.utf8))
             preconditionFailure("Unknown server APIs must not decode") } catch is DecodingError {}

        // Older remote clients omit `api` and keep the saved choice; newer ones set it.
        var legacyFields = ollamaFields
        legacyFields["api"] = nil
        try expect(PrivateLocalConfiguration.remote(legacyFields, savedAPI: .openAI).api == .openAI)
        try expect(PrivateLocalConfiguration.remote(legacyFields, savedAPI: .ollama).api == .ollama)
        try expect(PrivateLocalConfiguration.remote(encodedFields, savedAPI: .ollama).api == .openAI)
        for bad: Any in ["cloud", NSNull(), 1] {
            var invalid = encodedFields
            invalid["api"] = bad
            do { _ = try PrivateLocalConfiguration.remote(invalid, savedAPI: .ollama); preconditionFailure("Invalid API") }
            catch let error as SessionModelSettingsError { precondition(error.status == 400) }
        }
        var extra = encodedFields
        extra["apiKey"] = "must-not-be-accepted"
        do { _ = try PrivateLocalConfiguration.remote(extra, savedAPI: .ollama); preconditionFailure("Unknown fields") }
        catch let error as SessionModelSettingsError { precondition(error.status == 400) }

        // The base URL includes the version path; the same address rule applies.
        for (address, models, chat) in [
            ("https://llm.example.ts.net/v1", "https://llm.example.ts.net/v1/models", "https://llm.example.ts.net/v1/chat/completions"),
            ("https://llm.example.ts.net/inference/v1/", "https://llm.example.ts.net/inference/v1/models",
             "https://llm.example.ts.net/inference/v1/chat/completions"),
            ("http://localhost:8000/v1", "http://127.0.0.1:8000/v1/models", "http://127.0.0.1:8000/v1/chat/completions"),
        ] {
            var value = openAI
            value.baseURL = address
            try value.validate()
            try expect(value.endpoint(value.api.modelsPath).absoluteString == models)
            try expect(value.endpoint(value.api.chatPath).absoluteString == chat)
        }
        for address in ["http://llm.example/v1", "http://192.168.0.10:8000/v1", "https://llm.example/v1?key=x"] {
            var invalid = openAI
            invalid.baseURL = address
            do { try invalid.validate(); preconditionFailure("Unencrypted remote or ambiguous endpoints must fail") }
            catch let error as SessionModelSettingsError { precondition(error.status == 400) }
        }
        var malformedURL = openAI
        malformedURL.baseURL = "https://"
        do { try malformedURL.validate(); preconditionFailure("Malformed URL") }
        catch let error as SessionModelSettingsError {
            precondition(error.message.contains("/v1") && !error.message.contains("Ollama"))
        }
        var cloudModel = openAI
        cloudModel.model = "gpt-cloud"
        do { try cloudModel.validate(); preconditionFailure("Cloud models must fail") }
        catch let error as SessionModelSettingsError {
            precondition(error.status == 400 && error.message.contains("self-hosted server") && !error.message.contains("Ollama"))
        }

        // Model lists and the stream parser.
        try expect(PrivateLocalClient.openAIModels(["data": [["id": "b-model"], ["id": "a-model"], ["id": "x-cloud"],
                                                                   ["id": ""], ["object": "model"], ["id": "a-model"]]])
                     == ["a-model", "b-model"])
        do { _ = try PrivateLocalClient.openAIModels(["models": []]); preconditionFailure("Ollama list in OpenAI mode") }
        catch let error as SessionModelSettingsError { precondition(error.status == 502 && error.message.contains("/v1")) }
        typealias Chunk = PrivateLocalClient.StreamChunk
        func chunk(_ line: String) throws -> Chunk? { try PrivateLocalClient.openAIStreamChunk(line) }
        func delta(_ delta: String, finish: String = "null") -> String {
            #"data: {"choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish)}]}"#
        }
        try expect(chunk("") == nil && chunk(": ping") == nil && chunk("event: message") == nil
                     && chunk("id: 7") == nil && chunk("retry: 1000") == nil)
        try expect(chunk("data: [DONE]") == Chunk(finished: true) && chunk("data:[DONE]") == Chunk(finished: true))
        try expect(chunk(delta(#"{"role":"assistant","content":""}"#)) == Chunk())
        try expect(chunk(delta(#"{"content":"Hi"}"#)) == Chunk(text: "Hi"))
        try expect(chunk(#"data:{"choices":[{"delta":{"content":" there"}}]}"#) == Chunk(text: " there"))
        try expect(chunk(delta(#"{"content":null}"#)) == Chunk())
        try expect(chunk(delta(#"{"reasoning_content":"Think"}"#)) == Chunk(thinking: "Think"))
        try expect(chunk(delta(#"{"reasoning":"Think more"}"#)) == Chunk(thinking: "Think more"))
        try expect(chunk(delta(#"{"reasoning_content":null,"reasoning":"Either"}"#)) == Chunk(thinking: "Either"))
        try expect(chunk(delta("{}", finish: #""stop""#)) == Chunk(finished: true))
        try expect(chunk(delta(#"{"content":"End"}"#, finish: #""length""#)) == Chunk(text: "End", finished: true))
        try expect(chunk(#"data: {"choices":[],"usage":{"total_tokens":3}}"#) == Chunk())
        for line in [delta(#"{"tool_calls":[{"index":0,"function":{"name":"run_shell"}}]}"#),
                     delta(#"{"function_call":{"name":"run_shell"}}"#), delta("{}", finish: #""tool_calls""#)] {
            do { _ = try chunk(line); preconditionFailure("Tool calls must fail") }
            catch let error as SessionModelSettingsError {
                precondition(error.status == 409 && error.message == "Tools are disabled in Private Local. No tool was executed.")
            }
        }
        try expect(chunk(delta(#"{"tool_calls":[]}"#)) == Chunk())
        for line in [#"data: {"error":{"message":"out of memory"}}"#, "data: not-json", "not-sse", "{\"done\":true}"] {
            do { _ = try chunk(line); preconditionFailure("Invalid or failed streams must fail: \(line)") }
            catch let error as SessionModelSettingsError {
                precondition(error.status == 502 && !error.message.contains("Ollama"))
            }
        }

        // End to end on loopback: no /api/show, no tools, no context option, no credentials.
        var configuration = PrivateLocalConfiguration()
        configuration.api = .openAI
        configuration.baseURL = base + "/v1"
        configuration.model = "Fixture-8B-4bit"
        let client = PrivateLocalClient()
        defer { client.close() }
        fixture.mode = "openai"
        let listed = try await client.models(configuration)
        precondition(listed == ["Alpha-1B", "Fixture-8B-4bit"])
        fixture.mode = "openai"
        var events: [String] = []
        let input = BackendRequest(prompt: "openai-private-fixture", userMessage: "openai-private-fixture", previousTurns: [])
        try await client.chat(configuration, request: input) { event in
            switch event {
            case .textDelta(let text): events.append("text:" + text)
            case .thinkingDelta(let text): events.append("thinking:" + text)
            case .done: events.append("done")
            default: break
            }
        }
        precondition(events == ["thinking:Weighing it.", "text:Local answer ![blocked](https://cloud.example/pixel)",
                                "text: complete", "done"], "\(events)")
        precondition(fixture.requests.map(\.path) == ["/v1/models", "/v1/chat/completions"])
        precondition(fixture.requests.allSatisfy { $0.headers["authorization"] == nil })
        let sent = fixture.requests.last!.json!
        precondition(Set(sent.keys) == ["model", "messages", "stream"] && sent["stream"] as? Bool == true
                     && sent["model"] as? String == "Fixture-8B-4bit")
        let messages = sent["messages"] as! [[String: String]]
        precondition(messages.first?["role"] == "system" && messages.last == ["role": "user", "content": "openai-private-fixture"])
        fixture.mode = "openai-done"
        var text = ""
        try await client.chat(configuration, request: input) { if case .textDelta(let delta) = $0 { text += delta } }
        precondition(text == "Only done", "[DONE] alone completes the reply")
        for mode in ["openai-missing", "openai-tools", "openai-error", "openai-incomplete", "openai-malformed", "openai-redirect"] {
            fixture.mode = mode
            do {
                try await client.chat(configuration, request: input) { _ in }
                preconditionFailure("Unsafe or incomplete OpenAI-compatible response must fail: \(mode)")
            } catch let error as SessionModelSettingsError {
                precondition(!fixture.requests.contains { $0.path == "/must-not-follow" })
                precondition(!error.message.contains("Ollama") && !fixture.requests.contains { $0.path.hasPrefix("/api/") })
                switch mode {
                case "openai-missing":
                    precondition(error.status == 409 && !fixture.requests.contains { $0.path == "/v1/chat/completions" },
                                 "Never send private text to a model the server does not list")
                case "openai-tools": precondition(error.message == "Tools are disabled in Private Local. No tool was executed.")
                case "openai-incomplete": precondition(error.message.contains("disconnected before finishing")
                                                       && error.message.contains("No cloud fallback"))
                default: precondition(error.status == 502)
                }
            }
        }
        var wrongPath = configuration
        wrongPath.baseURL = base
        fixture.mode = "openai"
        do { _ = try await client.models(wrongPath); preconditionFailure("A base URL without /v1 must fail") }
        catch let error as SessionModelSettingsError { precondition(error.status == 502 && error.message.contains("/v1")) }
        print("Private Local OpenAI-compatible: legacy decode, API preservation, endpoints, models, SSE, reasoning, tools, [DONE] and disconnects passed")
    }

    @MainActor
    private static func testPrivateLocalAPI(chat: ChatSession, manager: SessionManager,
                                           configuration: PrivateLocalConfiguration) async throws {
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 20_000...45_000), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))
        func request(_ action: String, method: String = "GET", body: [String: Any]? = nil,
                     auth: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(chat.id)/\(action)")!)
            request.httpMethod = method
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        let unauthenticated = try await request("private-settings", auth: false)
        let current = try await request("private-settings")
        precondition(unauthenticated.0 == 401 && current.0 == 200)
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as! [String: Any]
        let change: [String: Any] = ["revision": chat.privateLocalRevision, "configuration": fields]
        let saved = try await request("private-settings", method: "POST", body: change)
        precondition(saved.0 == 200)
        let stale = try await request("private-settings", method: "POST", body: change)
        precondition(stale.0 == 409)
        for action in ["close", "new-conversation", "model-settings"] {
            let rejected = try await request(action, method: "POST", body: ["usesDefaults": true])
            precondition(rejected.0 == 409)
        }
        let unlock = try await request("metadata", method: "POST", body: ["isLocked": false])
        precondition(unlock.0 == 409)
        var invalid = fields
        invalid["contextWindow"] = true
        let malformed = try await request("private-settings", method: "POST",
            body: ["revision": chat.privateLocalRevision, "configuration": invalid])
        precondition(malformed.0 == 400)
        let listed = try await request("private-models")
        precondition(listed.0 == 200 && listed.1["models"] as? [String] == ["fixture:latest"])
        let session = try await request("")
        let summary = session.1["session"] as! [String: Any]
        precondition(summary["isLocalPrivate"] as? Bool == true && summary["isLocked"] as? Bool == true)
        precondition(summary["supportsModelSettings"] as? Bool == false && summary["supportsPrivateLocalSettings"] as? Bool == true)
        var remoteFields = fields
        remoteFields["baseURL"] = "https://llm.example.ts.net/ollama"
        let remoteSaved = try await request("private-settings", method: "POST",
            body: ["revision": chat.privateLocalRevision, "configuration": remoteFields])
        precondition(remoteSaved.0 == 200)
        precondition((remoteSaved.1["configuration"] as? [String: Any])?["baseURL"] as? String
                     == "https://llm.example.ts.net/ollama")
        // A newer client picks the API; an older client's save keeps it; snapshots report it.
        precondition((remoteSaved.1["configuration"] as? [String: Any])?["api"] as? String == "ollama")
        var openAIFields = remoteFields
        openAIFields["api"] = "openai"
        openAIFields["baseURL"] = "https://llm.example.ts.net/v1"
        let openAISaved = try await request("private-settings", method: "POST",
            body: ["revision": chat.privateLocalRevision, "configuration": openAIFields])
        precondition(openAISaved.0 == 200 && (openAISaved.1["configuration"] as? [String: Any])?["api"] as? String == "openai")
        var olderClient = openAIFields
        olderClient["api"] = nil
        olderClient["contextWindow"] = 4096
        let olderSaved = try await request("private-settings", method: "POST",
            body: ["revision": chat.privateLocalRevision, "configuration": olderClient])
        precondition(olderSaved.0 == 200)
        let afterOlder = try await request("private-settings")
        let afterFields = afterOlder.1["configuration"] as! [String: Any]
        precondition(afterFields["api"] as? String == "openai" && afterFields["contextWindow"] as? Int == 4096,
                     "A client that predates the API choice must not reset it to Ollama")
        try expect(chat.privateLocalConfiguration().api == .openAI)
        var unknownAPI = openAIFields
        unknownAPI["api"] = "cloud"
        let rejectedAPI = try await request("private-settings", method: "POST",
            body: ["revision": chat.privateLocalRevision, "configuration": unknownAPI])
        try expect(rejectedAPI.0 == 400 && chat.privateLocalConfiguration().api == .openAI)
        let openAIBase = (configuration.baseURL + "/v1").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let openAIModels = try await request("private-models?api=openai&baseURL=\(openAIBase)")
        precondition(openAIModels.0 == 200 && openAIModels.1["models"] as? [String] == ["Alpha-1B", "Fixture-8B-4bit"])
        let badModels = try await request("private-models?api=cloud")
        precondition(badModels.0 == 400)
        var restoreFields = remoteFields
        restoreFields["api"] = "ollama"
        let restored = try await request("private-settings", method: "POST",
            body: ["revision": chat.privateLocalRevision, "configuration": restoreFields])
        try expect(restored.0 == 200 && chat.privateLocalConfiguration().api == .ollama)
    }

    @MainActor
    private static func testPrivateLocalWeb() throws {
        let source = try String(contentsOfFile: "Sources/Cantrip/RemoteControlServer.swift", encoding: .utf8)
        let start = source.range(of: "    let privateEditorState")!
        let end = source.range(of: "    let inputState", range: start.upperBound..<source.endIndex)!
        let context = JSContext()!
        context.exceptionHandler = { _, error in fatalError(error!.toString()) }
        context.evaluateScript("""
        const elements={};const $=id=>elements[id]||(elements[id]={value:"",elements:[],disabled:false,
          replaceChildren(){},append(){},addEventListener(){},showModal(){},close(){}});
        const document={createElement(){return {}}};let token="fixture",selected="private",calls=[];
        const snapshot={revision:"v1",configuration:{api:"openai",baseURL:"https://llm.example.ts.net/v1",model:"local",contextWindow:8192,systemPrompt:"Keep local"}};
        function api(path,options){calls.push({path,body:options?JSON.parse(options.body):null});return Promise.resolve(snapshot)}
        function refresh(){return Promise.resolve()}
        \(source[start.lowerBound..<end.lowerBound])
        editPrivateSettings({id:"private"});
        """)
        precondition(context.evaluateScript("privateEditorState.data.revision")!.toString() == "v1")
        precondition(context.evaluateScript("$('privateAPI').value==='openai' && $('privateURL').placeholder.endsWith('/v1') && $('privateURLLabel').textContent.includes('/v1')")!.toBool())
        context.evaluateScript("""
        selected="public";$("privateContext").value="4096";$("privateForm").onsubmit({preventDefault(){}});
        """)
        precondition(context.evaluateScript("calls[1].path")!.toString() == "/api/v1/sessions/private/private-settings")
        precondition(context.evaluateScript("calls[1].body.configuration.contextWindow===4096 && calls[1].body.revision==='v1'")!.toBool())
        precondition(context.evaluateScript("calls[1].body.configuration.api==='openai'")!.toBool())
        context.evaluateScript("""
        snapshot.configuration={baseURL:"http://127.0.0.1:11434",model:"local",contextWindow:8192,systemPrompt:"Keep local"};
        editPrivateSettings({id:"private"});
        """)
        precondition(context.evaluateScript("$('privateAPI').value==='ollama' && !$('privateURLLabel').textContent.includes('/v1')")!.toBool(),
                     "A host snapshot without an API means Ollama")
    }
}
