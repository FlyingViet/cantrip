import Foundation
import Network

/// The host's side of `Scripts/cantrip-mcp`: every backend reaches servers that need a sign-in,
/// a credential or a tool limit through this relay, so backend configs hold a command and never
/// a secret. One Unix socket; each connection is one backend session talking to one server,
/// opened with a line `{"server": …, "tab": …, "backend": …}` and then newline-delimited
/// JSON-RPC both ways.
final class MCPRelay: @unchecked Sendable {
    static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["CANTRIP_MCP_SOCKET"], !override.isEmpty { return override }
        let preferred = CantripPaths.cache("mcp-relay.sock").path
        return preferred.utf8.count < 104 ? preferred : "/tmp/cantrip-\(getuid())/mcp-relay.sock"
    }

    struct Hello: Equatable {
        var server: String
        var tab: String?
        var backend: String?
    }

    /// What the relay needs from the host; tests supply their own.
    struct Environment {
        var server: (String) -> MCPServer?
        /// nil to allow, or why this tab or backend may not use the server.
        var refusal: (Hello, MCPServer) -> String? = { _, _ in nil }
        var secrets: MCPSecrets.Store = .keychain
        var signIns: MCPSignIns = .shared
        var transport: MCPOAuth.Transport = MCPOAuth.defaultTransport
        /// A server needs signing in again (or the keychain is locked).
        var onSignInProblem: (String, String) -> Void = { _, _ in }
    }

    let environment: Environment
    let path: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cantrip.mcp-relay")
    private var sessions: [ObjectIdentifier: Session] = [:]

    init(environment: Environment, path: String = MCPRelay.socketPath) {
        self.environment = environment
        self.path = path
    }

    func start() {
        queue.sync {
            listener?.cancel()
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.removeItem(atPath: path)
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
                let listener = try NWListener(using: parameters)
                let path = path
                listener.stateUpdateHandler = { state in
                    if case .ready = state { chmod(path, 0o600) }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: .global(qos: .userInitiated))
                self.listener = listener
            } catch {
                Log.write("mcp-relay: couldn't listen at \(path): \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            sessions.values.forEach { $0.close() }
            sessions = [:]
        }
    }

    private func accept(_ connection: NWConnection) {
        let session = Session(connection: connection, relay: self)
        queue.sync { sessions[ObjectIdentifier(session)] = session }
        session.start()
    }

    fileprivate func ended(_ session: Session) {
        queue.async { self.sessions[ObjectIdentifier(session)] = nil }
    }

    static func parseHello(_ line: Data) -> Hello? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let server = object["server"] as? String, !server.isEmpty else { return nil }
        func text(_ key: String) -> String? { (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return Hello(server: server, tab: text("tab"), backend: text("backend"))
    }

    // MARK: - JSON-RPC helpers

    static func errorReply(id: Any, message: String, code: Int = -32001) -> Data {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// `tools/list` results keep only the allowed tools.
    static func filterTools(_ message: Data, allowed: Set<String>) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
              var result = object["result"] as? [String: Any], let tools = result["tools"] as? [[String: Any]] else {
            return message
        }
        result["tools"] = tools.filter { allowed.contains($0["name"] as? String ?? "") }
        object["result"] = result
        return (try? JSONSerialization.data(withJSONObject: object)) ?? message
    }

    // MARK: - One backend session

    fileprivate final class Session: @unchecked Sendable {
        let connection: NWConnection
        weak var relay: MCPRelay?
        private var buffer = Data()
        private var hello: Hello?
        private var upstream: Upstream?
        private var refusal: String?
        private var allowedTools: Set<String>?
        /// IDs of the client's `tools/list` requests, whose replies get filtered.
        private var toolListIDs = Set<String>()
        private let lock = NSLock()
        private var closed = false

        init(connection: NWConnection, relay: MCPRelay) {
            self.connection = connection
            self.relay = relay
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer.subdata(in: self.buffer.startIndex..<newline)
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                    if !line.isEmpty { self.handle(line) }
                }
                if done || error != nil {
                    self.upstream?.finishInput()
                    return
                }
                self.receive()
            }
        }

        private func handle(_ line: Data) {
            guard let hello else { return begin(line) }

            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            let id = object?["id"]
            if let refusal {
                if let id { send(MCPRelay.errorReply(id: id, message: refusal)) }
                return
            }
            if let allowedTools, object?["method"] as? String == "tools/call",
               let name = (object?["params"] as? [String: Any])?["name"] as? String, !allowedTools.contains(name) {
                if let id { send(MCPRelay.errorReply(id: id, message: "Cantrip doesn't allow the tool \(name) on this server.")) }
                return
            }
            if allowedTools != nil, object?["method"] as? String == "tools/list", let id {
                lock.withLock { _ = toolListIDs.insert("\(id)") }
            }
            upstream?.send(line, id: id)
        }

        private func begin(_ line: Data) {
            guard let relay, let hello = MCPRelay.parseHello(line) else {
                return close()
            }
            self.hello = hello
            guard let server = relay.environment.server(hello.server) else {
                refusal = "Cantrip has no MCP server called \(hello.server). See Settings > MCP Servers."
                return
            }
            if let reason = relay.environment.refusal(hello, server) {
                refusal = reason
                return
            }
            if server.hasToolLimit, let tools = server.tools { allowedTools = Set(tools) }
            let deliver: (Data) -> Void = { [weak self] message in self?.fromUpstream(message) }
            let failed: (String) -> Void = { [weak self] reason in self?.upstreamEnded(reason) }
            do {
                if server.isRemote {
                    upstream = try HTTPUpstream(server: server, environment: relay.environment, deliver: deliver)
                } else {
                    upstream = try ProcessUpstream(server: server, secrets: relay.environment.secrets,
                                                   deliver: deliver, ended: failed)
                }
            } catch {
                refusal = error.localizedDescription
                if let failure = error as? MCPSecrets.Failure {
                    relay.environment.onSignInProblem(server.name, failure.localizedDescription)
                }
            }
        }

        private func fromUpstream(_ message: Data) {
            guard let allowedTools,
                  let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
                  let id = object["id"], lock.withLock({ toolListIDs.remove("\(id)") }) != nil else {
                return send(message)
            }
            send(MCPRelay.filterTools(message, allowed: allowedTools))
        }

        private func upstreamEnded(_ reason: String) {
            Log.write("mcp-relay: \(hello?.server ?? "?") ended: \(reason)")
            close()
        }

        func send(_ message: Data) {
            var line = message
            line.append(0x0A)
            connection.send(content: line, completion: .contentProcessed { _ in })
        }

        func close() {
            let wasOpen = lock.withLock { () -> Bool in
                defer { closed = true }
                return !closed
            }
            guard wasOpen else { return }
            upstream?.stop()
            connection.cancel()
            relay?.ended(self)
        }
    }
}

/// Where a relayed session's messages go.
protocol Upstream: AnyObject {
    func send(_ message: Data, id: Any?)
    /// The backend closed its side.
    func finishInput()
    func stop()
}

/// A local server, run by the host with its keychain secrets in its environment.
final class ProcessUpstream: Upstream, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var pending = Data()

    init(server: MCPServer, secrets: MCPSecrets.Store, deliver: @escaping (Data) -> Void,
         ended: @escaping (String) -> Void) throws {
        guard let command = server.command else { throw MCPOAuth.Failure(kind: .discovery, message: "No command.") }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolPath.value(inherited: environment["PATH"])
        for (key, value) in server.env { environment[key] = value }
        for key in server.secretEnv {
            guard let value = try secrets.string(MCPSecrets.envAccount(server.name, key)) else {
                throw MCPSecrets.Failure.status(errSecItemNotFound)
            }
            environment[key] = value
        }
        process.executableURL = URL(fileURLWithPath: command.hasPrefix("/") ? command : "/usr/bin/env")
        process.arguments = command.hasPrefix("/") ? server.args : [command] + server.args
        process.environment = environment
        if let cwd = server.cwd { process.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath) }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.pending.append(data)
            while let newline = self.pending.firstIndex(of: 0x0A) {
                let line = self.pending.subdata(in: self.pending.startIndex..<newline)
                self.pending.removeSubrange(self.pending.startIndex...newline)
                if !line.isEmpty { deliver(line) }
            }
        }
        process.terminationHandler = { process in ended("exited with \(process.terminationStatus)") }
        try process.run()
    }

    func send(_ message: Data, id: Any?) {
        var line = message
        line.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: line)
    }

    func finishInput() { try? input.fileHandleForWriting.close() }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}

/// A remote server over streamable HTTP, with its sign-in or credential headers added.
final class HTTPUpstream: Upstream, @unchecked Sendable {
    let server: MCPServer
    let environment: MCPRelay.Environment
    let deliver: (Data) -> Void
    private let url: URL
    private var staticHeaders: [String: String]
    private var sessionID: String?
    private var protocolVersion: String?
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    init(server: MCPServer, environment: MCPRelay.Environment, deliver: @escaping (Data) -> Void) throws {
        guard let text = server.url, let url = URL(string: text), ["https", "http"].contains(url.scheme ?? "") else {
            throw MCPOAuth.Failure(kind: .discovery, message: "\(server.name) has no valid address.")
        }
        guard url.scheme == "https" || ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else {
            throw MCPOAuth.Failure(kind: .discovery, message: "\(server.name) must use HTTPS.")
        }
        self.server = server
        self.environment = environment
        self.deliver = deliver
        self.url = url
        var headers = server.headers
        for name in server.secretHeaders {
            guard let value = try environment.secrets.string(MCPSecrets.headerAccount(server.name, name)) else {
                throw MCPSecrets.Failure.status(errSecItemNotFound)
            }
            headers[name] = value
        }
        staticHeaders = headers
    }

    /// The `initialize` request in flight: everything after it waits for its session ID.
    private var initializing: Task<Void, Never>?

    func send(_ message: Data, id: Any?) {
        let isInitialize = ((try? JSONSerialization.jsonObject(with: message)) as? [String: Any])?["method"] as? String == "initialize"
        let gate = lock.withLock { initializing }
        let task = Task { [weak self] in
            if !isInitialize { await gate?.value }
            guard let self else { return }
            do {
                try await self.post(message, retryAuthorization: true)
            } catch {
                let text = error.localizedDescription
                if let failure = error as? MCPOAuth.Failure, failure.kind == .needsSignIn {
                    self.environment.onSignInProblem(self.server.name, text)
                } else if error is MCPSecrets.Failure {
                    self.environment.onSignInProblem(self.server.name, text)
                }
                if let id { self.deliver(MCPRelay.errorReply(id: id, message: "\(self.server.name): \(text)")) }
            }
        }
        lock.withLock {
            tasks.append(task)
            if isInitialize { initializing = task }
        }
    }

    private func post(_ message: Data, retryAuthorization: Bool) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = message
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in staticHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let (session, version) = lock.withLock { (sessionID, protocolVersion) }
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        if server.oauth {
            let token = try await environment.signIns.accessToken(for: server.name, force: !retryAuthorization)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await environment.transport(request)
        if response.statusCode == 401, server.oauth, retryAuthorization {
            return try await post(message, retryAuthorization: false)
        }
        if let id = response.value(forHTTPHeaderField: "Mcp-Session-Id") { lock.withLock { sessionID = id } }
        switch response.statusCode {
        case 202, 204: return
        case 200..<300: break
        case 401, 403:
            throw MCPOAuth.Failure(kind: server.oauth ? .needsSignIn : .exchange,
                                   message: server.oauth ? "\(server.name) refused the sign-in. Connect it again in Cantrip."
                                                         : "\(server.name) refused the credentials (HTTP \(response.statusCode)).")
        default:
            throw MCPOAuth.Failure(kind: .exchange, message: "HTTP \(response.statusCode)")
        }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let messages = type.contains("text/event-stream") ? Self.events(in: data) : [data]
        for message in messages where !message.isEmpty {
            noteVersion(message)
            deliver(message)
        }
    }

    /// The protocol version the server chose, sent on later requests.
    private func noteVersion(_ message: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
              let version = (object["result"] as? [String: Any])?["protocolVersion"] as? String else { return }
        lock.withLock { protocolVersion = version }
    }

    /// The `data:` payloads of a server-sent-events body, one per event.
    static func events(in body: Data) -> [Data] {
        let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return text.components(separatedBy: "\n\n").compactMap { block in
            let data = block.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).drop { $0 == " " } }
                .joined(separator: "\n")
            return data.isEmpty ? nil : Data(data.utf8)
        }
    }

    func finishInput() {
        // A backend closing its side ends the server's session (DELETE is optional; best effort).
        let session = lock.withLock { sessionID }
        guard let session else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        let transport = environment.transport
        Task { _ = try? await transport(request) }
    }

    func stop() {
        lock.withLock { tasks }.forEach { $0.cancel() }
    }
}
