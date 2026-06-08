import Foundation

/// One turn in the conversation. Assistant turns accumulate streamed text plus
/// any tool activity the agent performed (rendered inline, Claude-Code style).
/// `Codable` so the transcript survives app restarts.
struct ChatTurn: Identifiable, Codable {
    var id = UUID()
    let role: Role
    var text: String = ""
    var tools: [ToolActivity] = []
    var streaming = false
    var error: String?

    enum Role: String, Codable { case user, assistant }

    var isEmpty: Bool { text.isEmpty && tools.isEmpty && error == nil }
}

/// A single tool/skill the agent invoked during an assistant turn. `output` fills
/// in when the result event arrives; `done` flips when the item completes.
struct ToolActivity: Identifiable, Codable {
    let id: String          // the function_call item id from the stream
    var name: String
    var arguments: String = ""
    var output: String?
    var done = false

    /// A short, friendly label for the collapsed row, e.g. "sonarr.search".
    var label: String { name.isEmpty ? "tool" : name }
}

/// Events decoded from the `/v1/responses` SSE stream. Intentionally tolerant —
/// the client maps the OpenAI Responses event zoo onto just what the UI needs and
/// ignores the rest, so minor server-shape drift doesn't break rendering.
/// A slash command / skill from the gateway's `/v1/commands` menu, for the "/"
/// autocomplete suggestions (mirrors what Telegram/Discord show).
struct HermesCommand: Identifiable, Hashable {
    let command: String       // e.g. "/help", "/sonarr"
    let description: String
    var kind: Kind = .command
    enum Kind: String { case command, skill }
    var id: String { command }
}

enum HermesStreamEvent {
    case responseCreated(id: String)
    case textDelta(String)
    /// The complete assistant text from the terminal `response.completed` event —
    /// used to fill the bubble if streamed deltas were missed (CRLF / shape drift).
    case finalText(String)
    case toolStarted(id: String, name: String)
    case toolArgumentsDelta(id: String, delta: String)
    case toolCompleted(id: String)
    case toolOutput(id: String, output: String)
    case completed
    case failed(String)
}
