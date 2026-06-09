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

    /// Fetch the slash-command + skill menu for "/" autocomplete suggestions.
    func commands() async -> [HermesCommand] {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/commands"))
        req.timeoutInterval = 12
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
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

    /// Stream a user turn. `previousResponseId` chains server-side history. Yields
    /// decoded events; keep the `responseCreated` id for the next turn.
    func stream(input: String, previousResponseId: String?, showSteps: Bool = false) -> AsyncThrowingStream<HermesStreamEvent, Error> {
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
                    // App-only formatting + verbosity directives (sent as Responses-API
                    // `instructions` → gateway ephemeral system prompt; doesn't affect
                    // Telegram/Discord, which can't render tables).
                    let format = "Format replies in Markdown: tables for structured/comparative/numeric data, bullet lists and short headings where they aid scanning. When an image genuinely helps (a poster, cover/album art, chart, map, or icon), include it with Markdown image syntax using a real public image URL; otherwise omit images."
                    let answerOnly = "Respond with only your final answer. Do not narrate your process, your steps, or what you're about to do — no running commentary, no 'Let me…' / 'Got it…' lines. Just the result."
                    body["instructions"] = showSteps ? format : "\(format) \(answerOnly)"
                    if let prev = previousResponseId { body["previous_response_id"] = prev }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw HermesError.badResponse }
                    guard (200..<300).contains(http.statusCode) else { throw HermesError.http(http.statusCode) }

                    var eventType = ""
                    var dataBuffer = ""
                    func flush() {
                        if !dataBuffer.isEmpty {
                            for ev in Self.decode(eventType: eventType, data: dataBuffer) { continuation.yield(ev) }
                        }
                        eventType = ""; dataBuffer = ""
                    }
                    func process(_ raw: String) {
                        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw   // tolerate CRLF
                        if line.isEmpty { flush(); return }
                        if line.hasPrefix("event:") {
                            flush()   // a new event begins — dispatch the previous
                            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let chunk = String(String(line.dropFirst(5)).drop(while: { $0 == " " }))
                            if chunk == "[DONE]" { flush(); continuation.yield(.completed); return }
                            dataBuffer += (dataBuffer.isEmpty ? "" : "\n") + chunk
                        }
                    }
                    // Read raw bytes and split on \n ourselves. `URLSession.bytes.lines`
                    // did NOT reliably surface SSE lines / blank separators here, which
                    // dropped every event → empty replies. This is byte-exact.
                    var lineBytes = [UInt8]()
                    for try await byte in bytes {
                        if byte == 0x0A {
                            process(String(decoding: lineBytes, as: UTF8.self))
                            lineBytes.removeAll(keepingCapacity: true)
                        } else {
                            lineBytes.append(byte)
                        }
                    }
                    if !lineBytes.isEmpty { process(String(decoding: lineBytes, as: UTF8.self)) }
                    flush()   // dispatch the final event (response.completed) at stream end
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
            // Pull the finalized assistant text as a fallback (fills the bubble
            // if streamed deltas were somehow missed).
            if let resp = obj["response"] as? [String: Any], let out = resp["output"] as? [[String: Any]] {
                let text = out.compactMap { item -> String? in
                    guard (item["type"] as? String) == "message",
                          let content = item["content"] as? [[String: Any]] else { return nil }
                    return content.compactMap { $0["text"] as? String }.joined()
                }.joined()
                if !text.isEmpty { return [.finalText(text), .completed] }
            }
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
