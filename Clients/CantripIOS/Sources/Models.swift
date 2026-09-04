import Foundation

enum ExecutionLane: String, CaseIterable, Codable, Identifiable, Sendable {
    case copilot
    case local
    case cantrip

    static let defaultLane: ExecutionLane = .copilot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copilot: "Copilot"
        case .local: "Private Local"
        case .cantrip: "Cantrip Remote"
        }
    }

    var badgeTitle: String {
        switch self {
        case .copilot: "Coding · Copilot"
        case .local: "Private · Local"
        case .cantrip: "Remote · Cantrip"
        }
    }

    var detail: String {
        switch self {
        case .copilot:
            "Uses the Copilot shim. Requests may leave your Mac."
        case .local:
            "Uses the explicitly configured local-private inference route."
        case .cantrip:
            "Controls an existing Cantrip session through its Remote server."
        }
    }

    var systemImage: String {
        switch self {
        case .copilot: "chevron.left.forwardslash.chevron.right"
        case .local: "lock.shield.fill"
        case .cantrip: "antenna.radiowaves.left.and.right"
        }
    }

    var modelAlias: String {
        switch self {
        case .copilot: "copilot-coding"
        case .local: "local-private"
        case .cantrip: "cantrip-remote"
        }
    }

    var isPrivate: Bool { self == .local }
}

enum SpeechInputEngine: String, CaseIterable, Identifiable {
    case apple
    case parakeet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple Speech"
        case .parakeet: "Parakeet"
        }
    }
}

struct HermesConversationMessage: Codable, Equatable, Sendable {
    let role: String
    let content: String
}

struct PendingHermesRun: Codable, Equatable, Sendable {
    let idempotencyKey: String
    let assistantTurnID: UUID
    let input: String
    let history: [HermesConversationMessage]
    let sessionID: String
    let executionLane: ExecutionLane
    let showSteps: Bool
    let startedAt: Date
}

struct ActiveHermesRun: Codable, Equatable, Sendable {
    let runID: String
    let idempotencyKey: String
    let assistantTurnID: UUID
    let sessionID: String
    let executionLane: ExecutionLane
    let startedAt: Date
}

struct HermesRunApproval: Codable, Equatable, Sendable {
    let command: String?
    let description: String?
    let choices: [String]
}

struct HermesRunStatus: Decodable, Equatable, Sendable {
    let runID: String
    let status: String
    let output: String?
    let error: String?
    let approval: HermesRunApproval?

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case status
        case output
        case error
        case approval
    }

    var isTerminal: Bool {
        ["completed", "failed", "cancelled"].contains(status)
    }
}

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
    var executionLane: ExecutionLane?
    var approval: HermesRunApproval?
    var thinking: String?
    var author: String?

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
    case textDelta(String)
    case finalText(String)
    case toolStarted(id: String, name: String)
    case toolCompleted(id: String)
    case approvalRequested(HermesRunApproval)
    case approvalResponded
    case completed
    case failed(String)
}
