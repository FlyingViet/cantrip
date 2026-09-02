import Foundation

enum HermesError: LocalizedError {
    case badResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from the gateway."
        case .http(let code):
            if code == 401 {
                return "Unauthorized — check the API key."
            }
            if code == 429 {
                return "The gateway is busy. The request will retry without duplication."
            }
            return "Gateway returned HTTP \(code)."
        }
    }

    var isRetryable: Bool {
        guard case .http(let code) = self else { return false }
        return code == 408 || code == 429 || code >= 500
    }
}

/// Talks to the Hermes gateway's durable runs API. Run creation is idempotent;
/// event streaming is best-effort while pollable status remains authoritative.
struct HermesClient {
    let baseURL: URL
    let apiKey: String
    let sessionKey: String
    let model: String

    /// Authenticated probe used by Settings and execution-lane discovery.
    /// `/health` is public, so it cannot verify the API key.
    func models() async throws -> Set<String> {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        req.timeoutInterval = 8
        authorize(&req)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HermesError.http(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else {
            throw HermesError.badResponse
        }
        return Set(entries.compactMap { $0["id"] as? String })
    }

    /// Fetch the slash-command + skill menu for "/" autocomplete suggestions.
    func commands() async -> [HermesCommand] {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/commands"))
        req.timeoutInterval = 12
        authorize(&req)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["commands"] as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let cmd = d["command"] as? String else { return nil }
            let kind = HermesCommand.Kind(rawValue: d["kind"] as? String ?? "command") ?? .command
            return HermesCommand(command: cmd, description: d["description"] as? String ?? "", kind: kind)
        }
    }

    func startRun(_ pending: PendingHermesRun) async throws -> ActiveHermesRun {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/runs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(pending.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        authorize(&request)

        let history = pending.history.map {
            ["role": $0.role, "content": $0.content]
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": model,
                "input": pending.input,
                "instructions": Self.responseInstructions(showSteps: pending.showSteps),
                "conversation_history": history,
                "session_id": pending.sessionID,
            ]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HermesError.http(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runID = object["run_id"] as? String,
              !runID.isEmpty else {
            throw HermesError.badResponse
        }
        return ActiveHermesRun(
            runID: runID,
            idempotencyKey: pending.idempotencyKey,
            assistantTurnID: pending.assistantTurnID,
            sessionID: pending.sessionID,
            executionLane: pending.executionLane,
            startedAt: pending.startedAt
        )
    }

    func runStatus(_ runID: String) async throws -> HermesRunStatus {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/runs/\(runID)")
        )
        request.timeoutInterval = 15
        authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HermesError.http(http.statusCode)
        }
        return try JSONDecoder().decode(HermesRunStatus.self, from: data)
    }

    func streamRunEvents(
        _ runID: String
    ) -> AsyncThrowingStream<HermesStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(
                        url: baseURL.appendingPathComponent(
                            "v1/runs/\(runID)/events"
                        )
                    )
                    request.timeoutInterval = 1800
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    authorize(&request)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw HermesError.badResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw HermesError.http(http.statusCode)
                    }

                    var dataBuffer = ""
                    func flush() {
                        guard !dataBuffer.isEmpty else { return }
                        for event in Self.decodeRunEvent(data: dataBuffer) {
                            continuation.yield(event)
                        }
                        dataBuffer = ""
                    }
                    func process(_ raw: String) {
                        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                        if line.isEmpty {
                            flush()
                        } else if line.hasPrefix("data:") {
                            let chunk = String(
                                String(line.dropFirst(5)).drop(while: { $0 == " " })
                            )
                            dataBuffer += (dataBuffer.isEmpty ? "" : "\n") + chunk
                        }
                    }

                    var lineBytes = [UInt8]()
                    for try await byte in bytes {
                        if byte == 0x0A {
                            process(String(decoding: lineBytes, as: UTF8.self))
                            lineBytes.removeAll(keepingCapacity: true)
                        } else {
                            lineBytes.append(byte)
                        }
                    }
                    if !lineBytes.isEmpty {
                        process(String(decoding: lineBytes, as: UTF8.self))
                    }
                    flush()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func approveRun(_ runID: String, choice: String) async throws {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/runs/\(runID)/approval")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["choice": choice]
        )
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HermesError.http(http.statusCode)
        }
    }

    func stopRun(_ runID: String) async throws {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/runs/\(runID)/stop")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        authorize(&request)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HermesError.http(http.statusCode)
        }
    }

    private func authorize(_ request: inout URLRequest) {
        guard !apiKey.isEmpty else { return }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private static func responseInstructions(showSteps: Bool) -> String {
        let format = "Format replies in Markdown: tables for structured/comparative/numeric data, bullet lists and short headings where they aid scanning. When an image genuinely helps, include it with Markdown image syntax using a real public image URL; otherwise omit images."
        let answerOnly = "Respond with only your final answer. Do not narrate your process or what you are about to do."
        return showSteps ? format : "\(format) \(answerOnly)"
    }

    static func decodeRunEvent(data: String) -> [HermesStreamEvent] {
        guard let bytes = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes)
                as? [String: Any],
              let event = object["event"] as? String else {
            return []
        }
        switch event {
        case "message.delta":
            return (object["delta"] as? String).map { [.textDelta($0)] } ?? []
        case "tool.started":
            let name = object["tool"] as? String ?? "tool"
            return [.toolStarted(id: "run-tool-\(UUID().uuidString)", name: name)]
        case "tool.completed":
            return [.toolCompleted(id: "run-tool-unmatched")]
        case "approval.request":
            let choices = object["choices"] as? [String]
                ?? ["once", "session", "deny"]
            return [
                .approvalRequested(
                    HermesRunApproval(
                        command: object["command"] as? String,
                        description: object["description"] as? String,
                        choices: choices
                    )
                )
            ]
        case "approval.responded":
            return [.approvalResponded]
        case "run.completed":
            let output = object["output"] as? String ?? ""
            return output.isEmpty
                ? [.completed]
                : [.finalText(output), .completed]
        case "run.failed":
            return [.failed(object["error"] as? String ?? "Run failed.")]
        case "run.cancelled":
            return [.failed("Run cancelled.")]
        default:
            return []
        }
    }

}
