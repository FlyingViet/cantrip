import XCTest
@testable import Hermes

/// Serves canned Ollama responses to `DirectLocalClient` and records what it sent.
final class DirectLocalStubProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var chunks: [Data]
        var delay: TimeInterval = 0
    }

    static var replies: [String: Reply] = [:]
    static var requests: [URLRequest] = []
    static var bodies: [String: Data] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.withLock { replies = [:]; requests = []; bodies = [:] }
    }

    static func json(_ object: Any, status: Int = 200) -> Reply {
        Reply(status: status, chunks: [try! JSONSerialization.data(withJSONObject: object)])
    }

    static func lines(_ objects: [Any], delay: TimeInterval = 0) -> Reply {
        Reply(headers: ["Content-Type": "application/x-ndjson"], chunks: objects.map {
            try! JSONSerialization.data(withJSONObject: $0) + Data("\n".utf8)
        }, delay: delay)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let reply: Reply? = Self.lock.withLock {
            Self.requests.append(request)
            if let body { Self.bodies[path] = body }
            return Self.replies[path]
        }
        guard let reply, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks {
            if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DirectLocalTests: XCTestCase {
    private let model = "fixture-model:latest"
    private var base = DirectLocalConfiguration(baseURL: "http://127.0.0.1:11434", model: "fixture-model:latest")

    override func setUp() {
        super.setUp()
        DirectLocalStubProtocol.reset()
    }

    private func client() -> DirectLocalClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectLocalStubProtocol.self]
        return DirectLocalClient(configuration: configuration)
    }

    private func stubInstalledModel() {
        DirectLocalStubProtocol.replies["/api/tags"] = DirectLocalStubProtocol.json(["models": [
            ["name": model, "model": model],
            ["name": "other:latest"],
            ["name": "big-model:cloud"],
            ["name": "forwarded:latest", "remote_model": "x", "remote_host": "https://example.com"],
        ]])
        DirectLocalStubProtocol.replies["/api/show"] = DirectLocalStubProtocol.json([
            "model_info": ["general.architecture": "fixturearch"], "capabilities": ["completion"],
        ])
    }

    private func tempStore() -> DirectLocalStore {
        DirectLocalStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("direct-local-tests-\(UUID().uuidString)"),
            defaults: UserDefaults(suiteName: "direct-local-tests-\(UUID().uuidString)")!)
    }

    // MARK: Configuration

    func testAddressRules() throws {
        var configuration = DirectLocalConfiguration()
        XCTAssertEqual(configuration.baseURL, "http://127.0.0.1:11434", "defaults to Ollama on loopback")
        XCTAssertEqual(try configuration.endpoint("/api/tags").absoluteString, "http://127.0.0.1:11434/api/tags")
        configuration.baseURL = "http://localhost:11234/"
        XCTAssertEqual(try configuration.endpoint("/api/chat").absoluteString, "http://127.0.0.1:11234/api/chat",
                       "localhost becomes 127.0.0.1 and a trailing slash is dropped")
        configuration.baseURL = "http://[::1]:11434"
        XCTAssertNoThrow(try configuration.endpoint("/api/tags"))
        configuration.baseURL = "https://models.example.com/ollama/"
        XCTAssertEqual(try configuration.endpoint("/api/tags").absoluteString,
                       "https://models.example.com/ollama/api/tags", "an HTTPS proxy keeps its base path")
        for bad in ["http://192.168.0.20:11434", "http://example.com", "ftp://127.0.0.1:21",
                    "http://user:pass@127.0.0.1:11434", "http://127.0.0.1:11434/?key=x",
                    "http://127.0.0.1:11434/#x", "http://127.0.0.1:11434/a/../b", "http://127.0.0.1:0", "not a url"] {
            configuration.baseURL = bad
            XCTAssertThrowsError(try configuration.endpoint("/api/tags"), bad)
        }
    }

    func testSettingsRules() {
        var configuration = base
        XCTAssertNoThrow(try configuration.validate())
        configuration.contextWindow = 511
        XCTAssertThrowsError(try configuration.validate())
        configuration.contextWindow = 131_073
        XCTAssertThrowsError(try configuration.validate())
        configuration.contextWindow = 8192
        configuration.systemPrompt = String(repeating: "x", count: 8001)
        XCTAssertThrowsError(try configuration.validate())
        configuration.systemPrompt = ""
        XCTAssertNoThrow(try configuration.validate())
        for bad in ["", "gpt-oss:120b-cloud", "has space", "http://evil/model"] {
            configuration.model = bad
            XCTAssertThrowsError(try configuration.validate(), bad)
        }
        configuration.model = ""
        XCTAssertNoThrow(try configuration.validate(requireModel: false), "the server can be set before a model")
        XCTAssertTrue(DirectLocalConfiguration.isCloudModel("qwen3-coder:480b-cloud"))
        XCTAssertFalse(DirectLocalConfiguration.isCloudModel("cloudlike-name:latest"))
    }

    // MARK: Stream

    func testStreamLines() throws {
        XCTAssertEqual(try DirectLocalStream.events(fromLine: ""), [])
        XCTAssertEqual(try DirectLocalStream.events(fromLine: #"{"message":{"role":"assistant","content":"Hi"},"done":false}"#),
                       [.content("Hi")])
        XCTAssertEqual(try DirectLocalStream.events(fromLine: #"{"message":{"thinking":"Hmm","content":""},"done":false}"#),
                       [.thinking("Hmm")])
        XCTAssertEqual(try DirectLocalStream.events(fromLine: #"{"message":{"content":""},"done":true,"done_reason":"stop"}"#),
                       [.done])
        XCTAssertEqual(try DirectLocalStream.events(fromLine: #"{"error":"model is loading"}"#), [.failure("model is loading")])
        XCTAssertEqual(try DirectLocalStream.events(fromLine: #"{"error":{"message":"Not enough free memory","type":"out_of_memory"}}"#),
                       [.failure("Not enough free memory")], "OpenAI-style error objects (mlx-serve) keep their message")
        XCTAssertThrowsError(try DirectLocalStream.events(
            fromLine: #"{"message":{"content":"","tool_calls":[{"function":{"name":"x"}}]},"done":false}"#))
        XCTAssertThrowsError(try DirectLocalStream.events(fromLine: "not json"))
    }

    func testModelFilteringAndLocalProof() {
        XCTAssertEqual(DirectLocalClient.localModelNames([
            ["name": "b:latest"], ["name": "a:latest"], ["name": "a:latest"], ["name": "x:cloud"],
            ["name": "remote:latest", "remote_host": "https://example.com"], ["model": "c:latest"],
        ]), ["a:latest", "b:latest", "c:latest"])
        XCTAssertTrue(DirectLocalClient.isLocalModel(["model_info": ["general.architecture": "llama"]]))
        XCTAssertFalse(DirectLocalClient.isLocalModel(["model_info": [:]]), "architecture is required")
        XCTAssertFalse(DirectLocalClient.isLocalModel(["model_info": ["general.architecture": "llama"], "remote_model": "x"]))
    }

    // MARK: History

    func testHistoryKeepsNewestTurnsWithinTheContext() {
        var configuration = base
        configuration.contextWindow = 512   // 1,536 characters minus the system prompt; floor 1,000
        let long = String(repeating: "a", count: 1500)
        let conversation = [
            DirectLocalMessage(role: .user, content: "first " + long),
            DirectLocalMessage(role: .assistant, content: "old reply"),
            DirectLocalMessage(role: .user, content: "second"),
            DirectLocalMessage(role: .assistant, content: "", error: "Stopped."),
            DirectLocalMessage(role: .assistant, content: "failed", error: "The local server stopped"),
            DirectLocalMessage(role: .user, content: "latest"),
        ]
        let messages = DirectLocalHistory.chatMessages(conversation, configuration: configuration)
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertEqual(messages.dropFirst().compactMap { $0["content"] }, ["second", "latest"],
                       "newest turns that fit, without a leading reply")
        XCTAssertEqual(messages.last?["content"], "latest")
        XCTAssertFalse(messages.contains { $0["content"] == "failed" }, "failed replies are left out")
        XCTAssertFalse(messages.contains { $0["content"]?.hasPrefix("first") == true }, "older turns past the budget are dropped")
        XCTAssertNotEqual(messages.dropFirst().first?["role"], "assistant", "history never starts with a reply")
        configuration.systemPrompt = ""
        XCTAssertEqual(DirectLocalHistory.chatMessages([DirectLocalMessage(role: .user, content: "hi")],
                                                       configuration: configuration),
                       [["role": "user", "content": "hi"]], "no empty system message")
    }

    // MARK: Store

    func testStoreKeepsSettingsAndConversationOnThisMac() throws {
        let store = tempStore()
        XCTAssertEqual(store.loadConfiguration(), DirectLocalConfiguration(), "defaults when nothing is saved")
        try store.saveConfiguration(base)
        XCTAssertEqual(store.loadConfiguration(), base)
        var bad = base
        bad.baseURL = "http://example.com"
        XCTAssertThrowsError(try store.saveConfiguration(bad))
        XCTAssertEqual(store.loadConfiguration(), base, "an invalid address is never saved")

        let messages = [
            DirectLocalMessage(role: .user, content: "hello"),
            DirectLocalMessage(role: .assistant, content: "partial", model: model, streaming: true),
        ]
        try store.saveConversation(messages)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.conversationURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "only this user can read it")
        let loaded = store.loadConversation()
        XCTAssertEqual(loaded.map(\.content), ["hello", "partial"])
        XCTAssertEqual(loaded.last?.streaming, false)
        XCTAssertNotNil(loaded.last?.error, "a reply cut off by a quit is marked interrupted")
    }

    // MARK: Client

    func testModelsListsOnlyLocalModelsAndSendsNoCredentials() async throws {
        stubInstalledModel()
        let names = try await client().models(base)
        XCTAssertEqual(names, ["fixture-model:latest", "other:latest"])
        let request = try XCTUnwrap(DirectLocalStubProtocol.requests.last)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/tags")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testChatStreamsAfterProvingTheModelIsLocal() async throws {
        stubInstalledModel()
        DirectLocalStubProtocol.replies["/api/chat"] = DirectLocalStubProtocol.lines([
            ["message": ["role": "assistant", "content": "", "thinking": "Let me see."], "done": false],
            ["message": ["role": "assistant", "content": "Hello"], "done": false],
            ["message": ["role": "assistant", "content": " there"], "done": false],
            ["message": ["role": "assistant", "content": ""], "done": true],
        ])
        let events = EventLog()
        try await client().chat(base, messages: [["role": "user", "content": "hi"]]) { events.append($0) }
        XCTAssertEqual(events.values, [.thinking("Let me see."), .content("Hello"), .content(" there"), .done])
        XCTAssertEqual(DirectLocalStubProtocol.requests.map { $0.url?.path ?? "" }, ["/api/tags", "/api/show", "/api/chat"],
                       "the model is confirmed installed and local before any text is sent")
        let body = try XCTUnwrap(DirectLocalStubProtocol.bodies["/api/chat"])
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["model"] as? String, model)
        XCTAssertEqual(sent["stream"] as? Bool, true)
        XCTAssertEqual((sent["options"] as? [String: Any])?["num_ctx"] as? Int, 8192)
        XCTAssertNil(sent["tools"], "no tools are offered")
    }

    func testServerErrorsAreExplained() async throws {
        stubInstalledModel()
        DirectLocalStubProtocol.replies["/api/chat"] = DirectLocalStubProtocol.json(
            ["error": ["message": "Not enough free memory to load model", "type": "out_of_memory", "code": 503]], status: 503)
        do {
            try await client().chat(base, messages: [["role": "user", "content": "hi"]]) { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 503"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Not enough free memory"), error.localizedDescription)
        }
        DirectLocalStubProtocol.replies["/api/chat"] = DirectLocalStubProtocol.lines([
            ["message": ["content": "Half"], "done": false],
        ])
        do {
            try await client().chat(base, messages: [["role": "user", "content": "hi"]]) { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("disconnected"), error.localizedDescription)
        }
        DirectLocalStubProtocol.replies["/api/show"] = DirectLocalStubProtocol.json(["remote_model": "x", "model_info": [:]])
        do {
            try await client().verify(base)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not allowed"), error.localizedDescription)
        }
        var missing = base
        missing.model = "not-installed:latest"
        do {
            try await client().verify(missing)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't installed"), error.localizedDescription)
        }
        DirectLocalStubProtocol.replies = [:]
        do {
            _ = try await client().models(base)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Couldn't reach"), error.localizedDescription)
        }
    }

    // MARK: Chat

    @MainActor
    func testConversationStreamsAndSurvivesARelaunch() async throws {
        stubInstalledModel()
        DirectLocalStubProtocol.replies["/api/chat"] = DirectLocalStubProtocol.lines([
            ["message": ["content": "Local "], "done": false],
            ["message": ["content": "reply"], "done": false],
            ["message": ["content": ""], "done": true],
        ])
        let store = tempStore()
        try store.saveConfiguration(base)
        let makeClient = { self.client() }
        let chat = DirectLocalChat(store: store, makeClient: makeClient)
        XCTAssertTrue(chat.isConfigured)
        XCTAssertFalse(chat.send("   "), "blank messages aren't sent")
        XCTAssertTrue(chat.send("Hello local"))
        XCTAssertTrue(chat.isReplying)
        try await waitUntil { !chat.isReplying }
        XCTAssertEqual(chat.messages.map(\.content), ["Hello local", "Local reply"])
        XCTAssertNil(chat.messages.last?.error)
        XCTAssertEqual(chat.messages.last?.model, model)

        let relaunched = DirectLocalChat(store: store, makeClient: makeClient)
        XCTAssertEqual(relaunched.messages.map(\.content), ["Hello local", "Local reply"], "kept on this Mac")
        XCTAssertEqual(relaunched.configuration, base)
        relaunched.clear()
        XCTAssertTrue(DirectLocalChat(store: store, makeClient: makeClient).messages.isEmpty, "clear deletes it")
    }

    @MainActor
    func testStopKeepsWhatArrived() async throws {
        stubInstalledModel()
        DirectLocalStubProtocol.replies["/api/chat"] = DirectLocalStubProtocol.lines((0..<40).map { index in
            ["message": ["content": "word\(index) "], "done": false] as [String: Any]
        } + [["message": ["content": ""], "done": true]], delay: 0.05)
        let store = tempStore()
        try store.saveConfiguration(base)
        let chat = DirectLocalChat(store: store, makeClient: { self.client() })
        XCTAssertTrue(chat.send("Long answer please"))
        try await waitUntil { !(chat.messages.last?.content.isEmpty ?? true) }
        chat.stop()
        try await waitUntil { !chat.isReplying }
        XCTAssertEqual(chat.messages.last?.error, "Stopped.")
        XCTAssertFalse(chat.messages.last?.content.contains("word39") ?? true, "the reply stopped early")
        XCTAssertEqual(DirectLocalChat(store: store, makeClient: { self.client() }).messages.last?.error, "Stopped.")
    }

    @MainActor
    func testFailuresStayInTheConversation() async throws {
        stubInstalledModel()
        DirectLocalStubProtocol.replies["/api/chat"] = DirectLocalStubProtocol.json(
            ["error": ["message": "Not enough free memory to load model"]], status: 503)
        let store = tempStore()
        try store.saveConfiguration(base)
        let chat = DirectLocalChat(store: store, makeClient: { self.client() })
        chat.send("Hi")
        try await waitUntil { !chat.isReplying }
        XCTAssertTrue(chat.messages.last?.error?.contains("Not enough free memory") == true)
        XCTAssertEqual(chat.messages.first?.content, "Hi", "your message is kept to resend")
    }

    @MainActor
    func testModelsLoadForTheDraftSettings() async {
        stubInstalledModel()
        let chat = DirectLocalChat(store: tempStore(), makeClient: { self.client() })
        var draft = DirectLocalConfiguration(baseURL: "http://127.0.0.1:11434")
        let models = await chat.loadModels(for: draft)
        XCTAssertEqual(models, ["fixture-model:latest", "other:latest"])
        XCTAssertEqual(chat.installedModels, models)
        draft.baseURL = "http://example.com"
        _ = await chat.loadModels(for: draft)
        XCTAssertTrue(chat.installedModels.isEmpty)
        XCTAssertNotNil(chat.modelsError)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DirectLocalStreamEvent] = []
    func append(_ event: DirectLocalStreamEvent) { lock.withLock { events.append(event) } }
    var values: [DirectLocalStreamEvent] { lock.withLock { events } }
}
