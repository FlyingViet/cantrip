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
            default: body = #"{"error":"unexpected request"}"#
            }
            let data = Data((body + "\n").utf8)
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header + data, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }
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
        for address in ["http://llm.example", "http://192.168.1.94:11434", "http://127.0.0.1.evil",
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
                        "https://192.168.1.34:11434", "https://ollama.lan", "https://llm.example.ts.net",
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

    @MainActor
    private static func testPrivateLocalAPI(chat: ChatSession, manager: SessionManager,
                                           configuration: PrivateLocalConfiguration) async throws {
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
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
        const snapshot={revision:"v1",configuration:{baseURL:"http://127.0.0.1:11434",model:"local",contextWindow:8192,systemPrompt:"Keep local"}};
        function api(path,options){calls.push({path,body:options?JSON.parse(options.body):null});return Promise.resolve(snapshot)}
        function refresh(){return Promise.resolve()}
        \(source[start.lowerBound..<end.lowerBound])
        editPrivateSettings({id:"private"});
        """)
        precondition(context.evaluateScript("privateEditorState.data.revision")!.toString() == "v1")
        context.evaluateScript("""
        selected="public";$("privateContext").value="4096";$("privateForm").onsubmit({preventDefault(){}});
        """)
        precondition(context.evaluateScript("calls[1].path")!.toString() == "/api/v1/sessions/private/private-settings")
        precondition(context.evaluateScript("calls[1].body.configuration.contextWindow===4096 && calls[1].body.revision==='v1'")!.toBool())
    }
}
