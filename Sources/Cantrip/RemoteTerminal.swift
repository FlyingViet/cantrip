import Foundation

/// `/api/v1/sessions/{id}/terminal`: the tab's persistent shell (the panel's terminal mode) for
/// paired clients. It is the same shell the Mac shows, so `cd`, exports and history carry across
/// devices, and the agent's own commands appear in it too.
///
/// - `GET ?from=<end>&epoch=<epoch>` returns the output after the client's place (all of it,
///   with `reset`, when that place was cleared or trimmed).
/// - `POST {"command"}` runs a line (while a command runs, the line goes to its input).
/// - `POST terminal/interrupt` sends Control-C (or stops the agent when only its command runs),
///   `terminal/clear` empties the output and `terminal/restart` restarts the shell.
///
/// Every reply is a `TabTerminalSnapshot` tailing from the request's `from`/`epoch`.
struct TabTerminalSnapshot: Encodable, Equatable {
    let epoch: String
    /// Scalar offset of `text` in the shell's output; `end` is where the next poll starts.
    let start: Int
    let end: Int
    let text: String
    /// The client replaces its output with `text` instead of appending.
    let reset: Bool
    let isRunning: Bool
    let agentCommandRunning: Bool
    let history: [String]
    let workdir: String
}

struct TabTerminalError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum TabTerminalRemote {
    static let maximumCommandLength = 8_192
    static let historyLimit = 50

    static func snapshot(_ session: ChatSession, from: Int?, epoch: String?) -> TabTerminalSnapshot {
        let shell = session.shell
        let tail = shell.tail(from: from, epoch: epoch)
        return .init(epoch: shell.epoch, start: tail.start, end: shell.outputEnd, text: tail.text,
                     reset: tail.reset, isRunning: shell.isRunning,
                     agentCommandRunning: shell.hasAgentCommandRunning,
                     history: Array(shell.commandHistory.suffix(historyLimit)), workdir: session.workdir)
    }

    /// Applies `action` (nil runs `json["command"]`) and returns the snapshot after it.
    static func perform(_ action: String?, json: [String: Any]?, session: ChatSession,
                        from: Int?, epoch: String?) throws -> TabTerminalSnapshot {
        guard !session.isLocalPrivate else {
            throw TabTerminalError(status: 409, message: "Shell commands and tools are disabled in Private Local.")
        }
        let body = json ?? [:]
        switch action {
        case nil:
            guard Set(body.keys) == ["command"], let raw = body["command"] as? String else {
                throw TabTerminalError(status: 400, message: "Send the command to run as {\"command\": \"…\"}.")
            }
            let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, !command.contains("\n"), !command.contains("\r") else {
                throw TabTerminalError(status: 400, message: "Send one command line at a time.")
            }
            guard command.utf8.count <= maximumCommandLength else {
                throw TabTerminalError(status: 400, message: "That command is too long for the terminal.")
            }
            session.shell.run(command, workdir: session.workdir)
            Log.write("terminal: a paired client ran a command in tab \(session.id.uuidString.prefix(8))")
        case "interrupt"?, "clear"?, "restart"?:
            guard body.isEmpty else {
                throw TabTerminalError(status: 400, message: "This terminal action takes no request body.")
            }
            if action == "clear" {
                session.shell.clear()
            } else if action == "restart" {
                session.shell.restart()
            } else if session.shell.isRunning {
                session.shell.interrupt()
            } else if session.shell.hasAgentCommandRunning {
                session.cancel()
            }
        default:
            throw TabTerminalError(status: 404, message: "Unknown terminal action.")
        }
        return snapshot(session, from: from, epoch: epoch)
    }
}
