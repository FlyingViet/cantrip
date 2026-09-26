import Foundation

enum ToolActivityState: Equatable {
    case running
    case succeeded
    case failed
    case cancelled
}

struct ToolFileChange: Identifiable, Equatable {
    let id: String
    let path: String
    let diff: String
}

struct ToolActivity: Identifiable, Equatable {
    let id: String
    var title: String
    var toolName: String
    var state: ToolActivityState
    var input: String?
    var output: String?
    var fileChanges: [ToolFileChange]
    var terminalCommand: String?
    /// Steps run inside this activity by a subagent (Claude Code Task
    /// tool events carry parent_tool_use_id; Copilot doesn't expose this).
    var children: [ToolActivity] = []
}

struct BackendUsage {
    let backend: String
    let costUSD: Double
    let inputTokens: Int
    let outputTokens: Int
}

struct BackendApproval {
    let tool: String
    let decision: String
    let decidedBy: String
}

struct InputRequestSnapshot: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case approval, question, secret, login, localAction }
    let id: UUID
    let kind: Kind
    let source: String
    let title: String
    let detail: String
    var choices: [String] = []
    var allowsFreeform = false
    var url: String?
    var code: String?
    let expiresAt: Double
}

struct InputRequestAnswer: Codable {
    enum Decision: String, Codable { case approve, deny, submit, cancel }
    let decision: Decision
    var text: String?
}

enum InputRequestError: LocalizedError, Equatable {
    case unavailable, invalidAnswer
    var errorDescription: String? {
        switch self {
        case .unavailable: return "This input request expired, was cancelled, or was already answered. Refresh the tab."
        case .invalidAnswer: return "Choose a valid response for this request. Passwords must use the secure input field."
        }
    }
}

/// Callbacks and secrets are runtime-only. ChatSession records only non-secret question/answer turns.
final class BackendInputRequest {
    let snapshot: InputRequestSnapshot
    private let lock = NSLock()
    private var handler: ((InputRequestAnswer) -> Void)?
    private var resolvedCallback: (() -> Void)?
    var onResolved: (() -> Void)? {
        get { lock.withLock { resolvedCallback } }
        set { lock.withLock { resolvedCallback = newValue } }
    }

    init(kind: InputRequestSnapshot.Kind, source: String, title: String, detail: String,
         choices: [String] = [], allowsFreeform: Bool = false, url: String? = nil, code: String? = nil,
         lifetime: TimeInterval = 600, handler: @escaping (InputRequestAnswer) -> Void) {
        snapshot = InputRequestSnapshot(id: UUID(), kind: kind, source: String(source.prefix(160)),
            title: String(title.prefix(240)), detail: detail,
            choices: choices, allowsFreeform: allowsFreeform, url: url, code: code,
            expiresAt: Date().addingTimeInterval(lifetime).timeIntervalSince1970)
        self.handler = handler
    }

    var isPending: Bool { lock.withLock { handler != nil } }

    func respond(_ answer: InputRequestAnswer) throws {
        guard Date().timeIntervalSince1970 < snapshot.expiresAt else { cancel(); throw InputRequestError.unavailable }
        guard answer.text?.utf8.count ?? 0 <= 8192 else { throw InputRequestError.invalidAnswer }
        if answer.decision == .cancel || answer.decision == .deny {
            guard answer.text == nil else { throw InputRequestError.invalidAnswer }
        } else {
            switch snapshot.kind {
            case .approval, .login, .localAction:
                guard answer.decision == .approve, answer.text == nil else { throw InputRequestError.invalidAnswer }
            case .question:
                guard answer.decision == .submit, let text = answer.text, !text.isEmpty,
                      snapshot.allowsFreeform || snapshot.choices.contains(text) else { throw InputRequestError.invalidAnswer }
            case .secret:
                guard answer.decision == .submit, let text = answer.text, !text.isEmpty,
                      !text.contains("\n"), !text.contains("\r"), !text.contains("\0") else { throw InputRequestError.invalidAnswer }
            }
        }
        guard let callback = lock.withLock({ let value = handler; handler = nil; return value }) else {
            throw InputRequestError.unavailable
        }
        callback(answer)
        onResolved?()
    }

    func cancel() {
        let callback = lock.withLock { let value = handler; handler = nil; return value }
        callback?(InputRequestAnswer(decision: .cancel))
        if callback != nil { onResolved?() }
    }
}

/// Events streamed from a backend while answering a query.
enum BackendEvent {
    case textDelta(String)         // partial assistant text
    case thinkingDelta(String)     // partial reasoning (extended thinking)
    case status(String)            // transient status, e.g. "Thinking"
    case activity(ToolActivity)    // tool lifecycle and file-change details
    case usage(BackendUsage)       // token/cost accounting for this run
    case approval(BackendApproval) // harness policy decision for a tool
    case inputRequired(BackendInputRequest)
    case done                      // stream finished successfully
    case failure(String)           // error message
}

struct BackendRequest {
    let prompt: String
    let userMessage: String
    let previousTurns: [ConversationTurn]
}

enum MidTurnDelivery {
    case accepted(messageID: String?)
    case notSent
    case uncertain(String)
}

protocol Backend {
    /// Send a query, executing in `workdir`. Events arrive on an arbitrary
    /// queue; the caller hops to main. Continuity is the backend's job.
    func send(
        _ request: BackendRequest,
        workdir: String,
        onEvent: @escaping (BackendEvent) -> Void
    )
    /// Cancel any in-flight request.
    func cancel()
    /// Start a fresh conversation.
    func reset()
    /// Add a user message into the CURRENTLY RUNNING turn's context
    /// without interrupting. Returns false if unsupported/no live turn
    /// (caller should queue instead).
    func injectMidTurn(_ text: String) -> Bool
    var supportsMidTurnInjection: Bool { get }
    /// Completion confirms transport acceptance, not model consumption.
    func injectMidTurn(_ text: String, completion: @escaping (MidTurnDelivery) -> Void)
    /// Gracefully abort the CURRENT turn in-band, keeping the process and
    /// session alive for the next message (Claude control protocol).
    /// Returns false if unsupported/no live process (caller should
    /// hard-cancel instead).
    func interruptTurn() -> Bool
}

extension Backend {
    func injectMidTurn(_ text: String) -> Bool { false }
    var supportsMidTurnInjection: Bool { false }
    func injectMidTurn(_ text: String, completion: @escaping (MidTurnDelivery) -> Void) {
        completion(injectMidTurn(text) ? .accepted(messageID: nil) : .notSent)
    }
    func interruptTurn() -> Bool { false }
}

enum ToolActivityFactory {
    static func start(
        id: String,
        toolName: String,
        arguments: Any?,
        intentionSummary: String? = nil
    ) -> ToolActivity {
        let args = arguments as? [String: Any]
        let description = string(
            in: args,
            keys: ["subject", "title", "description", "summary"]
        )
        let changes = fileChanges(toolName: toolName, arguments: arguments)
        let terminalCommand = terminalCommand(toolName: toolName, arguments: args)
        let title = firstNonEmpty(intentionSummary, description)
            ?? fallbackTitle(
                toolName: toolName,
                arguments: args,
                fileChanges: changes
            )

        return ToolActivity(
            id: id,
            title: title,
            toolName: displayName(toolName),
            state: .running,
            input: detailText(arguments),
            output: nil,
            fileChanges: changes,
            terminalCommand: terminalCommand
        )
    }

    static func complete(
        _ activity: ToolActivity?,
        id: String,
        toolName: String? = nil,
        success: Bool,
        output: Any?
    ) -> ToolActivity {
        var completed = activity ?? start(
            id: id,
            toolName: toolName ?? "Tool",
            arguments: nil
        )
        completed.state = success ? .succeeded : .failed
        completed.output = detailText(output)
        return completed
    }

    static func detailText(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : clipped(trimmed)
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value,
               options: [.prettyPrinted, .sortedKeys]
           ),
           let text = String(data: data, encoding: .utf8) {
            return clipped(text)
        }
        return clipped(String(describing: value))
    }

    private static func fileChanges(toolName: String, arguments: Any?) -> [ToolFileChange] {
        let lowerName = toolName.lowercased()
        let args = arguments as? [String: Any]

        let patch = arguments as? String
            ?? string(in: args, keys: ["patch", "input", "content"])
        if lowerName.contains("patch"), let patch {
            return parsePatch(patch)
        }

        guard let args,
              let path = string(in: args, keys: [
                  "file_path", "filePath", "path", "notebook_path"
              ]) else {
            return []
        }

        if lowerName.contains("edit"),
           let replacement = string(in: args, keys: [
               "new_string", "newString", "new_source"
           ]) {
            let original = string(in: args, keys: ["old_string", "oldString"]) ?? ""
            return [ToolFileChange(
                id: "\(path)#edit",
                path: path,
                diff: replacementDiff(path: path, original: original, replacement: replacement)
            )]
        }

        if lowerName.contains("write") || lowerName.contains("create"),
           let content = string(in: args, keys: ["content", "file_text"]) {
            let added = content.components(separatedBy: "\n").map { "+\($0)" }
            return [ToolFileChange(
                id: "\(path)#write",
                path: path,
                diff: (["--- /dev/null", "+++ \(path)"] + added).joined(separator: "\n")
            )]
        }

        return []
    }

    private static func parsePatch(_ patch: String) -> [ToolFileChange] {
        let headers = [
            "*** Add File: ",
            "*** Update File: ",
            "*** Delete File: "
        ]
        var changes: [ToolFileChange] = []
        var path: String?
        var lines: [String] = []

        func flush() {
            guard let path else { return }
            let diff = lines.joined(separator: "\n")
            changes.append(ToolFileChange(
                id: "\(path)#\(changes.count)",
                path: path,
                diff: diff.isEmpty ? "Changed \(path)" : diff
            ))
            lines.removeAll(keepingCapacity: true)
        }

        for line in patch.components(separatedBy: "\n") {
            if let header = headers.first(where: { line.hasPrefix($0) }) {
                flush()
                path = String(line.dropFirst(header.count))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("*** Move to: ") {
                lines.append(line)
                continue
            }
            guard path != nil,
                  line != "*** Begin Patch",
                  line != "*** End Patch" else {
                continue
            }
            lines.append(line)
        }
        flush()
        return changes
    }

    private static func replacementDiff(
        path: String,
        original: String,
        replacement: String
    ) -> String {
        let removed = original.components(separatedBy: "\n").map { "-\($0)" }
        let added = replacement.components(separatedBy: "\n").map { "+\($0)" }
        return (["--- \(path)", "+++ \(path)"] + removed + added)
            .joined(separator: "\n")
    }

    private static func fallbackTitle(
        toolName: String,
        arguments: [String: Any]?,
        fileChanges: [ToolFileChange]
    ) -> String {
        let lowerName = toolName.lowercased()
        if lowerName.contains("bash") || lowerName.contains("shell") {
            return "Running a command"
        }
        if lowerName.contains("edit") || lowerName.contains("patch")
            || lowerName.contains("write") {
            if let path = string(in: arguments, keys: ["file_path", "path"])
                ?? fileChanges.first?.path {
                return "Editing \((path as NSString).lastPathComponent)"
            }
            return "Editing files"
        }
        if lowerName.contains("read") || lowerName.contains("view") {
            return "Reading a file"
        }
        if lowerName.contains("search") || lowerName.contains("grep")
            || lowerName.contains("glob") {
            return "Searching"
        }
        return "Using \(displayName(toolName))"
    }

    private static func displayName(_ toolName: String) -> String {
        let shortName = toolName.split(separator: ".").last.map(String.init) ?? toolName
        switch shortName.lowercased() {
        case "bash", "shell", "run_shell", "exec_command", "command_execution":
            return "Shell"
        case "apply_patch", "edit", "write":
            return "Edit"
        case "read", "view":
            return "Read"
        default:
            return shortName
        }
    }

    private static func terminalCommand(
        toolName: String,
        arguments: [String: Any]?
    ) -> String? {
        let name = toolName.split(separator: ".").last.map(String.init)?
            .lowercased() ?? toolName.lowercased()
        guard name == "bash" || name == "shell" || name == "run_shell"
                || name == "exec_command" || name == "command_execution" else {
            return nil
        }
        return string(in: arguments, keys: ["command", "cmd", "script"])
    }

    private static func string(
        in dictionary: [String: Any]?,
        keys: [String]
    ) -> String? {
        guard let dictionary else { return nil }
        for key in keys {
            if let value = dictionary[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private static func clipped(_ text: String, limit: Int = 20_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… output truncated"
    }
}
