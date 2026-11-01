import Foundation

/// A connection to `codex app-server --listen stdio://`: newline-delimited JSON-RPC 2.0. Codex
/// sends notifications (items, deltas, token usage, rate limits) and requests (approvals for a
/// command, a file change or an MCP tool call) that Cantrip must answer. Tabs keep one per
/// session; the model list and the usage screen open a short-lived one.
final class CodexAppServer: @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        var code: Int?
        var errorDescription: String? { message }
    }

    /// Notifications (`method`, `params`).
    var onNotification: ((String, [String: Any]) -> Void)?
    /// Requests from Codex (`id`, `method`, `params`); answer with `respond` or `respondError`.
    var onServerRequest: ((Any, String, [String: Any]) -> Void)?
    /// The process ended (status, the tail of its standard error).
    var onExit: ((Int32, String) -> Void)?

    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var buffer = Data()
    private var errorTail = Data()
    private(set) var isRunning = false

    /// `executable` is the signed `codex` binary (`ToolLocator.codex`); `arguments` follow
    /// `app-server` (`-c` overrides such as MCP servers).
    init(executable: String, arguments: [String] = [], environment: [String: String], directory: URL) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"] + arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.receive(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.withLock {
                self.errorTail.append(data)
                if self.errorTail.count > 8_000 { self.errorTail = self.errorTail.suffix(4_000) }
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.output.fileHandleForReading.readabilityHandler = nil
            self.errors.fileHandleForReading.readabilityHandler = nil
            let (waiting, tail) = self.lock.withLock { () -> ([(Result<[String: Any], Error>) -> Void], String) in
                self.isRunning = false
                let waiting = Array(self.pending.values)
                self.pending.removeAll()
                return (waiting, String(decoding: self.errorTail, as: UTF8.self))
            }
            let failure = Failure(message: "Codex stopped (status \(process.terminationStatus)).")
            waiting.forEach { $0(.failure(failure)) }
            self.onExit?(process.terminationStatus, tail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try process.run()
        lock.withLock { isRunning = true }
    }

    func terminate() {
        let process = process
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.close()
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    // MARK: - Messages

    private func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        lock.withLock {
            guard isRunning else { return }
            try? input.fileHandleForWriting.write(contentsOf: data)
        }
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 120,
                 completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let id: Int? = lock.withLock {
            guard isRunning else { return nil }
            defer { nextID += 1 }
            pending[nextID] = completion
            return nextID
        }
        guard let id else { return completion(.failure(Failure(message: "Codex isn't running."))) }
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let waiting = self?.lock.withLock({ self?.pending.removeValue(forKey: id) }) else { return }
            waiting(.failure(Failure(message: "Codex didn't answer \(method) in \(Int(timeout)) seconds.")))
        }
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 120) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            request(method, params, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    func notify(_ method: String, _ params: [String: Any] = [:]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func respond(id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respondError(id: Any, code: Int = -32601, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// `initialize` then `initialized`, as every client must before anything else.
    func handshake() async throws {
        _ = try await request("initialize", ["clientInfo": ["name": "cantrip", "title": "Cantrip", "version": "1"]], timeout: 30)
        notify("initialized")
    }

    private func receive(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer.subdata(in: buffer.startIndex..<newline))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        for line in lines where !line.isEmpty {
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(message)
        }
    }

    func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        if let method, let id = message["id"] {
            if let onServerRequest { onServerRequest(id, method, params) } else {
                respondError(id: id, message: "Cantrip doesn't handle \(method).")
            }
            return
        }
        if let method {
            onNotification?(method, params)
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue,
              let waiting = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
        if let error = message["error"] as? [String: Any] {
            waiting(.failure(Failure(message: error["message"] as? String ?? "Codex refused the request.",
                                     code: (error["code"] as? NSNumber)?.intValue)))
        } else {
            waiting(.success(message["result"] as? [String: Any] ?? [:]))
        }
    }

    // MARK: - One-off reads

    /// Starts a short-lived app server, runs `body`, and stops it (the model list, usage).
    static func withServer<T>(executable: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                              _ body: (CodexAppServer) async throws -> T) async throws -> T {
        var env = environment
        env["PATH"] = ToolPath.value(inherited: env["PATH"])
        let server = CodexAppServer(executable: executable, environment: env,
                                    directory: FileManager.default.homeDirectoryForCurrentUser)
        try server.start()
        defer { server.terminate() }
        try await server.handshake()
        return try await body(server)
    }
}
