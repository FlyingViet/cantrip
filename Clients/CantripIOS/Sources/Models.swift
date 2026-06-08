import Foundation

/// One turn in the conversation. Assistant turns accumulate streamed text plus
/// any tool activity the agent performed (rendered inline, Claude-Code style).
/// `Codable` so the transcript survives app restarts.
struct ChatTurn: Identifiable, Codable {
    var id = UUID()
    let role: Role
    var text: String = ""
    var tools: [ToolActivity] = []
    var actions: [ChatAction] = []
    var streaming = false
    var error: String?

    enum Role: String, Codable { case user, assistant }

    /// Parse a confirmation prompt's choices into tappable actions. Gated on the
    /// "fallback: reply `/x`, …" marker Hermes emits, so normal replies (and the
    /// /help command list) don't sprout buttons.
    static func parseActions(_ text: String) -> [ChatAction] {
        let lines = text.components(separatedBy: .newlines)
        guard let fallback = lines.first(where: {
            $0.range(of: "fallback: reply", options: .caseInsensitive) != nil
        }) else { return [] }
        let cmds = matches(in: fallback, pattern: "/[a-zA-Z_][a-zA-Z0-9_-]*")
        guard !cmds.isEmpty else { return [] }
        // Pair each command with the bullet label above it (• **Label**), else
        // a capitalized command name.
        let labels = matches(in: text, pattern: "[•\\-\\*]\\s*\\*\\*([^*]+)\\*\\*", group: 1)
        return cmds.enumerated().map { i, cmd in
            let label = i < labels.count ? labels[i].trimmingCharacters(in: .whitespaces)
                                         : cmd.dropFirst().capitalized
            return ChatAction(label: String(label), command: cmd)
        }
    }

    private static func matches(in text: String, pattern: String, group: Int = 0) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let r = m.range(at: group)
            return r.location != NSNotFound ? ns.substring(with: r) : nil
        }
    }

    var isEmpty: Bool { text.isEmpty && tools.isEmpty && error == nil }
}

/// A tappable choice parsed from a confirmation prompt (e.g. /new's "Approve
/// Once / Always Approve / Cancel"). Tapping sends `command` as the next turn.
struct ChatAction: Identifiable, Codable, Hashable {
    let label: String
    let command: String
    var id: String { command }
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
