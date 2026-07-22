import Foundation
import Network

/// Unix-socket server backing the `cantrip` CLI. Protocol: one JSON
/// request line in ({"text", "backend"?, "cwd"?}), streamed JSON lines
/// out ({"delta"} … {"done"} | {"error"}).
final class CLIServer {
    static let shared = CLIServer()
    private var listener: NWListener?
    /// Persistent CLI backends so consecutive invocations keep context.
    private var backends: [BackendKind: Backend] = [:]
    private init() {}

    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/cantrip.sock").path
    }

    func start() {
        try? FileManager.default.removeItem(atPath: Self.socketPath)
        do {
            let params = NWParameters()
            params.requiredLocalEndpoint = NWEndpoint.unix(path: Self.socketPath)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            Log.write("cli: listening at \(Self.socketPath)")
        } catch {
            Log.write("cli: listener failed: \(error.localizedDescription)")
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        var buffer = Data()

        func readMore() {
            connection.receive(minimumIncompleteLength: 1,
                               maximumLength: 1 << 20) { [weak self] data, _, done, _ in
                if let data { buffer.append(data) }
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    self?.handleRequest(line, on: connection)
                } else if done {
                    connection.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private func handleRequest(_ data: Data, on connection: NWConnection) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            send(["error": "bad request"], on: connection, close: true)
            return
        }
        let cwd = obj["cwd"] as? String ?? NSHomeDirectory()
        let kind = (obj["backend"] as? String).flatMap(Self.backendKind)
            ?? AppSettings.shared.backend
        Log.write("cli: query via \(kind.rawValue) (\(text.count) chars)")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let backend = self.backend(for: kind)
            let request = BackendRequest(prompt: text, userMessage: text,
                                         previousTurns: [])
            backend.send(request, workdir: cwd) { [weak self] event in
                switch event {
                case .textDelta(let delta):
                    self?.send(["delta": delta], on: connection, close: false)
                case .status(let status):
                    self?.send(["status": status], on: connection, close: false)
                case .activity(let activity):
                    if activity.state == .running {
                        self?.send(["status": activity.title], on: connection, close: false)
                    }
                case .done:
                    self?.send(["done": true], on: connection, close: true)
                case .failure(let message):
                    self?.send(["error": message], on: connection, close: true)
                }
            }
        }
    }

    private func backend(for kind: BackendKind) -> Backend {
        if let existing = backends[kind] { return existing }
        let fresh: Backend
        switch kind {
        case .claudeCode: fresh = ClaudeCodeBackend(persistKey: "cli-claudeSession")
        case .copilot: fresh = CopilotBackend()
        case .codex: fresh = CodexBackend(persistKey: "cli-codexSession")
        case .localModel: fresh = OpenAICompatibleBackend()
        }
        backends[kind] = fresh
        return fresh
    }

    private static func backendKind(_ raw: String) -> BackendKind? {
        switch raw.lowercased() {
        case "claude", "claudecode", "claude-code": return .claudeCode
        case "copilot", "gh": return .copilot
        case "codex", "openai": return .codex
        case "local", "hermes": return .localModel
        default: return BackendKind(rawValue: raw)
        }
    }

    private func send(_ object: [String: Any], on connection: NWConnection, close: Bool) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }
}
