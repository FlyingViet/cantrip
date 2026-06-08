import Foundation

enum HermesError: LocalizedError {
    case badResponse, http(Int)
    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from the gateway."
        case .http(let c): return c == 401 ? "Unauthorized — check the API key." : "Gateway returned HTTP \(c)."
        }
    }
}

/// Talks to the Hermes gateway's OpenAI-compatible API server. Uses the stateful
/// `/v1/responses` endpoint so the conversation lives server-side (chained via
/// `previous_response_id`) — we send only the new turn and stream the reply,
/// surfacing tool/skill activity as it happens.
struct HermesClient {
    let baseURL: URL
    let apiKey: String
    let sessionKey: String
    let model: String

    /// Quick reachability + auth check for the settings screen.
    func health() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 8
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<500).contains(http.statusCode)   // any HTTP answer = reachable
    }

    /// Stream a user turn. `previousResponseId` chains server-side history. Yields
    /// decoded events; keep the `responseCreated` id for the next turn.
    func stream(input: String, previousResponseId: String?) -> AsyncThrowingStream<HermesStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("v1/responses"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 1800     // agentic runs can be long
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                    req.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
                    var body: [String: Any] = ["model": model, "input": input, "stream": true, "store": true]
                    if let prev = previousResponseId { body["previous_response_id"] = prev }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw HermesError.badResponse }
                    guard (200..<300).contains(http.statusCode) else { throw HermesError.http(http.statusCode) }

                    var eventType = ""
                    var dataBuffer = ""
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            if !dataBuffer.isEmpty {
                                for ev in Self.decode(eventType: eventType, data: dataBuffer) { continuation.yield(ev) }
                            }
                            eventType = ""; dataBuffer = ""
                            continue
                        }
                        if line.hasPrefix("event:") {
                            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let chunk = String(line.dropFirst(5)).drop(while: { $0 == " " })
                            if chunk == "[DONE]" { continuation.yield(.completed); continuation.finish(); return }
                            dataBuffer += (dataBuffer.isEmpty ? "" : "\n") + chunk
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - SSE event decoding (tolerant)

    private static func decode(eventType rawType: String, data: String) -> [HermesStreamEvent] {
        guard let d = data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        // Some servers omit the `event:` line and carry the type inside the JSON.
        let type = rawType.isEmpty ? (obj["type"] as? String ?? "") : rawType

        switch type {
        case "response.created", "response.in_progress":
            if let resp = obj["response"] as? [String: Any], let id = resp["id"] as? String {
                return [.responseCreated(id: id)]
            }
        case "response.output_text.delta":
            if let delta = obj["delta"] as? String { return [.textDelta(delta)] }
        case "response.output_item.added":
            if let item = obj["item"] as? [String: Any], (item["type"] as? String) == "function_call" {
                let id = item["id"] as? String ?? item["call_id"] as? String ?? UUID().uuidString
                return [.toolStarted(id: id, name: item["name"] as? String ?? "tool")]
            }
        case "response.function_call_arguments.delta":
            if let id = obj["item_id"] as? String ?? obj["id"] as? String, let delta = obj["delta"] as? String {
                return [.toolArgumentsDelta(id: id, delta: delta)]
            }
        case "response.output_item.done":
            if let item = obj["item"] as? [String: Any] {
                let kind = item["type"] as? String ?? ""
                let id = item["id"] as? String ?? item["call_id"] as? String ?? ""
                if kind == "function_call" { return [.toolCompleted(id: id)] }
                if kind == "function_call_output" {
                    let callId = item["call_id"] as? String ?? id
                    return [.toolOutput(id: callId, output: stringify(item["output"]))]
                }
            }
        case "response.completed":
            return [.completed]
        case "response.failed", "error", "response.error":
            let msg = ((obj["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                ?? (obj["error"] as? [String: Any])?["message"] as? String
                ?? obj["message"] as? String ?? "Run failed"
            return [.failed(msg)]
        default:
            break
        }
        return []
    }

    /// Tool output may be a string or an array of content parts — flatten to text.
    private static func stringify(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let arr = value as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let parts = value as? [Any] {
            return parts.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}
