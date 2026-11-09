import Foundation

/// Appended to every agent session's system message: Cantrip's apps fold reasoning into a
/// collapsed row, so answers written only there never reach the user.
enum ReplyVisibility {
    static let guidance = """
    Cantrip's apps show your reasoning only as a collapsed "Reasoning" row that the user \
    doesn't read. Anything meant for the user (explanations, findings, comparisons) must be \
    visible reply text. Text you write just before a tool call reaches the user only as a short \
    summary once it runs past a sentence or two, so keep notes before a tool call to one or two \
    short sentences, and give full explanations in the reply that ends your turn (the one with no \
    tool call). When you ask the user to choose (ask_user), put everything they need to decide \
    inside the question itself: the key findings, what each choice means and which you \
    recommend, in plain text before the actual question (short paragraphs or "- " lists; the \
    question isn't rendered as Markdown, so no bold or headings). The question is the only part \
    they're sure to see. When the user asks for more detail, including as their answer to a \
    question you asked, answer in full first (a request for detail overrides brevity defaults) \
    and ask a follow-up only if a decision is still needed.

    When your reply recommends real-world places (clinics, restaurants, cafes, stores, venues, or \
    landmarks), end your reply with a fenced `places` JSON block so Cantrip can render an \
    interactive map card with place pins under your text:
    ```places
    {"near":"Santa Clara, CA","places":[{"name":"Concentra Urgent Care","query":"Concentra Urgent Care Santa Clara CA","category":"Urgent care clinic"}]}
    ```
    Include only real places you named in your reply (up to 8). Omit fields you do not know; \
    Cantrip resolves exact coordinates, addresses, hours, phone numbers, and websites via MapKit \
    and OpenStreetMap. Never invent ratings, price levels, hours, or coordinates.
    """
}

enum ToolActivityState: Equatable {
    case running
    case succeeded
    case failed
    case cancelled

    init(_ status: SubagentInfo.Status) {
        switch status {
        case .queued, .running, .idle: self = .running
        case .completed: self = .succeeded
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        }
    }
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
    /// tool_use parent IDs; Copilot subagent.started agent IDs).
    var children: [ToolActivity] = []
    /// Interactive MCP App view returned with the result (Copilot only).
    var app: MCPAppPayload?
    /// Set when this activity spawned a subagent (Copilot task, Claude Task).
    var subagent: SubagentInfo?
    /// The newest `[n/m]` counter a running command printed (Copilot streams command output).
    var buildStep: BuildStep?
    /// The command waits for a build slot, or just got one (`BuildQueue`'s lines in its output).
    var buildQueue: BuildQueueState?
    /// The newest transfer progress (bytes or percent) a running command printed, kept at whole
    /// percents so a transfer's card moves at most a hundred times.
    var transfer: TransferProgress?
    /// The end of `output` when it was too long to keep whole: where exit codes and results are.
    var outputTail: String?

    /// Every subagent in this activity tree, parents before their nested agents.
    var subagentActivities: [ToolActivity] {
        (subagent == nil ? [] : [self]) + children.flatMap(\.subagentActivities)
    }

    /// Ends this activity tree: unfinished steps and active subagents end as `state`.
    func finishing(as state: ToolActivityState, at date: Date = Date()) -> ToolActivity {
        var activity = self
        if activity.state == .running { activity.state = state }
        if let info = activity.subagent, info.isActive {
            activity.subagent?.status = SubagentInfo.Status(state)
            activity.subagent?.finishedAt = date
            activity.subagent?.canCancel = false
        }
        activity.children = activity.children.map { $0.finishing(as: state, at: date) }
        return activity
    }
}

/// A `[12/345]` step counter, as SwiftPM, Ninja and CMake print while they build. Newer SwiftPM
/// spaces it (`[12 / 345]`, thin spaces in a terminal, where each update ends in a carriage return).
struct BuildStep: Equatable, Codable {
    var current: Int
    var total: Int

    private static let pattern = try! NSRegularExpression(pattern: #"(?:^|[\r\n])[ \t]*\[(\d{1,7})\s?/\s?(\d{1,7})\](?=\s|$)"#)
    private static let escapes = try! NSRegularExpression(pattern: #"\x{1B}\[[0-9;?]*[A-Za-z]"#)

    /// The newest counter in the end of `text`.
    static func latest(in text: String) -> BuildStep? {
        guard text.contains("/") else { return nil }
        var tail = String(text.suffix(4_000))
        if tail.contains("\u{1B}") {
            tail = escapes.stringByReplacingMatches(in: tail, range: NSRange(tail.startIndex..., in: tail), withTemplate: "")
        }
        let range = NSRange(tail.startIndex..., in: tail)
        guard let match = pattern.matches(in: tail, range: range).last,
              let current = Range(match.range(at: 1), in: tail).flatMap({ Int(tail[$0]) }),
              let total = Range(match.range(at: 2), in: tail).flatMap({ Int(tail[$0]) }),
              total >= 2, current <= total else { return nil }
        return BuildStep(current: current, total: total)
    }
}

/// How far a transfer says it is, read from what it prints: bytes of a total (`Transferred
/// 6102712320/29051813685 bytes`, tqdm's `555M/1.23G`, rclone's `555 MiB / 1.2 GiB`, `1.2 GB of
/// 4.7 GB`), curl's progress meter, or else a percentage (`45%`: wget, rsync, adb).
struct TransferProgress: Equatable, Codable {
    var fraction: Double
    var bytes: Int64?
    var totalBytes: Int64?

    var percent: Int { Int((fraction * 100).rounded(.down)) }

    /// Whether `new` moves a card showing `old`: another whole percent, or a new total.
    static func moves(_ old: TransferProgress?, to new: TransferProgress?) -> Bool {
        guard let new else { return false }
        guard let old else { return true }
        return old.percent != new.percent || old.totalBytes != new.totalBytes
    }

    private static let number = #"(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)"#
    private static let unit = #"(bytes|[kKMGTP]i?B|[kKMGTP]i?|B)"#
    private static let sizedPattern = try! NSRegularExpression(
        pattern: #"(?<![\w.,])"# + number + #"\s?"# + unit + #"?(?:\s*/\s*|\s+of\s+)"# + number + #"\s?"# + unit + #"(?![A-Za-z])"#)
    private static let curlSize = #"(\d+(?:\.\d+)?[kMGTP]?)"#
    /// `  45 1234M   45  555M    0     0  34.5M      0  0:00:35  0:00:16  0:00:19 34.9M`
    private static let curlPattern = try! NSRegularExpression(
        pattern: #"^\s*(\d{1,3})\s+"# + curlSize + #"\s+\d{1,3}\s+"# + curlSize + #"\s+\d{1,3}\s+"# + curlSize
            + #"\s+\S+\s+\S+\s+(?:--:--:--|\d+:\d\d:\d\d)"#)
    private static let percentPattern = try! NSRegularExpression(pattern: #"(?<![\d.])(\d{1,3}(?:\.\d+)?)\s?%"#)
    private static let escapes = try! NSRegularExpression(pattern: #"\x{1B}\[[0-9;?]*[A-Za-z]"#)

    /// The newest progress in the end of `text`. Sizes win over a nearby percentage, which can be
    /// one file's (rclone and tqdm print both).
    static func latest(in text: String) -> TransferProgress? {
        guard !text.isEmpty else { return nil }
        var tail = String(text.suffix(4_000))
        if tail.contains("\u{1B}") {
            tail = escapes.stringByReplacingMatches(in: tail, range: NSRange(tail.startIndex..., in: tail), withTemplate: "")
        }
        let lines = tail.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).suffix(60).map(String.init)
        for line in lines.suffix(12).reversed() {
            if let progress = sized(line) { return progress }
        }
        for line in lines.reversed() {
            if let progress = curl(line) ?? percentage(line) { return progress }
        }
        return nil
    }

    private static func groups(_ regex: NSRegularExpression, in line: String) -> [String]? {
        guard let match = regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).last else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }

    private static func make(_ done: Double, of total: Double) -> TransferProgress? {
        guard total > 0, done >= 0, done <= total * 1.001 else { return nil }
        return TransferProgress(fraction: min(1, done / total), bytes: Int64(done.rounded()), totalBytes: Int64(total.rounded()))
    }

    private static func sized(_ line: String) -> TransferProgress? {
        guard line.contains("/") || line.contains(" of "), let found = groups(sizedPattern, in: line),
              let done = Double(found[1].replacingOccurrences(of: ",", with: "")),
              let total = Double(found[3].replacingOccurrences(of: ",", with: "")) else { return nil }
        let totalUnit = found[4]
        let doneUnit = found[2].isEmpty ? totalUnit : found[2]
        return make(done * multiplier(doneUnit), of: total * multiplier(totalUnit))
    }

    /// curl counts in 1024s: `k`, `M`, `G`.
    private static func curl(_ line: String) -> TransferProgress? {
        guard let found = groups(curlPattern, in: line), let total = curlBytes(found[2]), total > 0,
              let received = curlBytes(found[3]), let sent = curlBytes(found[4]) else { return nil }
        return make(max(received, sent), of: total)
    }

    private static func curlBytes(_ text: String) -> Double? {
        guard let last = text.last else { return nil }
        let powers: [String: Double] = ["k": 1, "M": 2, "G": 3, "T": 4, "P": 5]
        let power = powers[String(last)]
        guard let value = Double(power == nil ? text : String(text.dropLast())) else { return nil }
        return value * pow(1024, power ?? 0)
    }

    private static func percentage(_ line: String) -> TransferProgress? {
        guard line.contains("%"), let found = groups(percentPattern, in: line), let value = Double(found[1]),
              value <= 100 else { return nil }
        return TransferProgress(fraction: value / 100)
    }

    /// `MiB`/`Gi` count in 1024s, `MB`/`M` in 1000s.
    static func multiplier(_ unit: String) -> Double {
        guard let first = unit.first, unit != "B", unit != "bytes" else { return 1 }
        let powers: [String: Double] = ["K": 1, "M": 2, "G": 3, "T": 4, "P": 5]
        let base: Double = unit.contains("i") ? 1024 : 1000
        return pow(base, powers[first.uppercased()] ?? 0)
    }
}

/// A command the backend moved to the background (or started there) has ended.
struct FinishedCommand: Equatable {
    /// The shell or task ID and the tool call that started it, whichever the backend knows.
    var ids: [String]
    var exitCode: Int?
    /// Nil when the backend didn't say how it ended.
    var state: ToolActivityState?
}

/// A command whose call returned before it finished.
enum BackgroundCommand {
    private static let patterns = [
        #"<command started in background with shellId: ([^\s>]+)>"#,
        #"<command with shellId: ([^\s>]+) is still running"#,
        #"[Rr]unning in background with ID: ([A-Za-z0-9_-]+)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// The shell or task it moved to: Copilot's async mode or a sync wait that timed out,
    /// Claude's run_in_background. Only the end of a result says so.
    static func shellID(in output: String) -> String? {
        guard output.contains("background") || output.contains("still running") else { return nil }
        let tail = String(output.suffix(800))
        for pattern in patterns {
            if let match = pattern.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)).last,
               let range = Range(match.range(at: 1), in: tail) {
                return String(tail[range])
            }
        }
        return nil
    }
}

enum SubagentCancelError: LocalizedError, Equatable {
    case notFound, finished, unsupported, sessionUnavailable, timedOut
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "That subagent isn't in this conversation."
        case .finished: return "That subagent has already finished."
        case .unsupported: return "This tab's backend can't stop a single subagent. Stop the whole reply instead."
        case .sessionUnavailable: return "This tab's Copilot session isn't running, so the subagent has already stopped."
        case .timedOut: return "Copilot didn't confirm the stop in time. Check the subagent's status."
        case .server(let message): return message
        }
    }
}

/// Live progress of a subagent, shown in Cantrip's subagent monitor.
struct SubagentInfo: Equatable, Codable {
    enum Status: String, Codable {
        /// Launched but not started: Copilot starts a background agent only
        /// once the main agent waits for it or ends its turn.
        case queued
        case running, idle, completed, failed, cancelled

        init(_ state: ToolActivityState) {
            switch state {
            case .running: self = .running
            case .succeeded: self = .completed
            case .failed: self = .failed
            case .cancelled: self = .cancelled
            }
        }
    }

    /// Copilot agent/task ID (the cancel target); Claude: the Task tool-use ID.
    var agentID: String
    var name: String
    var agentType: String
    var summary: String
    var model: String?
    var effort: String?
    var background = false
    var status: Status = .running
    var startedAt = Date()
    var finishedAt: Date?
    var intent: String?
    var latestMessage: String?
    var tokens = 0
    var toolCalls: Int?
    var error: String?
    /// The backend can stop this agent on its own (Copilot SDK sessions, Claude background agents).
    var canCancel = false
    /// Complete reasoning blocks, oldest first (Copilot forwards subagent blocks whole).
    var reasoning: [String] = []
    /// Steps in blocks dropped from `reasoning`, so step numbers stay stable.
    var reasoningStepOffset = 0

    static let reasoningLimit = 12

    var isActive: Bool { status == .queued || status == .running || status == .idle }
    var isBackgroundWatcher: Bool {
        // Copilot's `task` agent, or Claude Code's general-purpose one (both can run commands).
        background && ["task", "general-purpose"].contains(agentType) && name.lowercased().hasPrefix("watch-")
    }
    /// A background agent the root launched for a request Auto ran in parallel.
    var isParallelRequest: Bool {
        background && name.lowercased().hasPrefix("side-")
    }
    /// Detached agents keep the run available after the root idles; Cantrip wakes the root when they finish.
    var keepsRunAvailable: Bool { isBackgroundWatcher || isParallelRequest }

    mutating func addReasoning(_ block: String) {
        guard reasoning.last != block else { return }
        reasoning.append(block)
        if reasoning.count > Self.reasoningLimit {
            let dropped = Array(reasoning.prefix(reasoning.count - Self.reasoningLimit))
            reasoningStepOffset += ReasoningStep.steps(from: dropped).count
            reasoning.removeFirst(dropped.count)
        }
    }

    var displayName: String {
        if !name.isEmpty { return name }
        if !agentType.isEmpty { return agentType.replacingOccurrences(of: "-", with: " ").capitalized }
        return "Subagent"
    }

    func elapsed(now: Date = Date()) -> TimeInterval {
        max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }

    static func tokenLabel(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: return "\(tokens) tokens"
        case ..<1_000_000: return String(format: "%.1fk tokens", Double(tokens) / 1_000)
        default: return String(format: "%.1fM tokens", Double(tokens) / 1_000_000)
        }
    }

    static func clipped(_ text: String, limit: Int = 400) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}

/// One titled reasoning step, as Cantrip Agent lists a reply's reasoning.
struct ReasoningStep: Equatable {
    let title: String
    /// Everything after the title; the whole text when the title had to be shortened.
    let text: String

    static let titleLimit = 100

    /// `number` is the step's 1-based position in the whole reply or subagent run.
    func snapshot(number: Int) -> [String: Any] { ["title": title, "text": text, "number": number] }

    /// A line that is only `**Title**` starts a step (GPT reasoning summaries);
    /// otherwise each block is one step titled by its first sentence.
    static func steps(from blocks: [String]) -> [ReasoningStep] {
        blocks.flatMap(sections).compactMap { heading, body in
            if let heading { return ReasoningStep(title: heading, text: body) }
            return body.isEmpty ? nil : titled(body)
        }
    }

    private static func sections(_ block: String) -> [(heading: String?, body: String)] {
        var sections: [(heading: String?, lines: [Substring])] = [(nil, [])]
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let inner = trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), !inner.isEmpty, !inner.contains("**") {
                sections.append((inner, []))
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }
        return sections.map {
            ($0.heading, $0.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func titled(_ text: String) -> ReasoningStep {
        var end = text.endIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "\n" { end = index; break }
            if ".!?".contains(text[index]), next == text.endIndex || text[next].isWhitespace {
                end = next
                break
            }
            index = next
        }
        var title = text[..<end].trimmingCharacters(in: .whitespaces)
        if title.hasSuffix("."), !title.hasSuffix("..") { title.removeLast() }
        guard title.count > titleLimit else {
            return ReasoningStep(title: title, text: text[end...].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let prefix = title.prefix(titleLimit)
        let words = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
        let short = words.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        return ReasoningStep(title: short + "…", text: text)
    }
}

struct BackendUsage {
    let backend: String
    let costUSD: Double
    let inputTokens: Int
    let outputTokens: Int
    /// Part of `inputTokens` read from the prompt cache.
    var cachedInputTokens = 0
    /// Model calls this usage covers (Claude reports a whole turn at once).
    var modelCalls = 1
}

/// What the model had in its context window for the prompt being answered.
/// Nil fields are unknown; each event carries only what the backend reported.
struct BackendContextUsage: Equatable {
    /// Tokens in context for this model call (system, tools and conversation).
    var tokens: Int?
    var limit: Int?
    var systemTokens: Int?
    var toolTokens: Int?
    var conversationTokens: Int?
    /// Characters of the message actually sent for this prompt, including context Cantrip added.
    var messageCharacters: Int?
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
    /// Remote only: `detail` with Mac images rewritten to paired previews, and those images.
    var displayText: String?
    var images: [PreviewImage]?

    struct PreviewImage: Codable, Equatable {
        let id: String
        let altText: String
    }
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
    case context(BackendContextUsage) // root agent's context window for this prompt
    case approval(BackendApproval) // harness policy decision for a tool
    case inputRequired(BackendInputRequest)
    /// The root agent was idle and finished background work (agent or shell IDs) woke it.
    case backgroundWake([String])
    /// A background command ended (Copilot's shell notification, Claude's task notification).
    case commandFinished(FinishedCommand)
    /// The backend's own error code says its plan is used up for now. Sent just before the
    /// run's `.failure`, so Cantrip switches backends without reading the error's wording.
    case usageLimit(UsageLimitReport)
    /// The backend is still working but has nothing to show (a long command's progress tick).
    /// It only keeps the run's inactivity watchdog from firing.
    case heartbeat
    case done                      // stream finished successfully
    case failure(String)           // error message
}

/// A usage limit as the backend reported it in a structured field, not in prose.
struct UsageLimitReport: Equatable {
    /// The backend's code for it, for the log: "quota/quota_exceeded", "rate_limit", ...
    let code: String
    /// When the limit lifts, if the backend says.
    let resetsAt: Date?
    /// The model quota that's used up (`BackendLimitTracker.modelScope`), such as Claude's weekly
    /// Opus limit or Antigravity's Argon group; nil when the whole backend is (a shared quota).
    var scope: String? = nil
}

struct BackendRequest {
    let prompt: String
    let userMessage: String
    let previousTurns: [ConversationTurn]
    /// The earlier-turn messages already chosen for a stateless backend; nil lets it choose.
    var replay: [ConversationContextMessage]? = nil
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
    /// The backend can take live messages into a turn once it is running, even while
    /// `supportsMidTurnInjection` is still false (the turn is starting or saving).
    var canSteerTurns: Bool { get }
    /// The live turn can hand a request to a background agent and report its result later.
    var supportsParallelSubagents: Bool { get }
    /// Completion confirms transport acceptance, not model consumption.
    func injectMidTurn(_ text: String, completion: @escaping (MidTurnDelivery) -> Void)
    /// Like `injectMidTurn`, for a message the user pushed ahead of the current work. Copilot also
    /// moves a step the turn is blocked on (a command or sync agent) to the background.
    func sendNowMidTurn(_ text: String, completion: @escaping (MidTurnDelivery) -> Void)
    /// Gracefully abort the CURRENT turn in-band, keeping the process and
    /// session alive for the next message (Claude control protocol).
    /// Returns false if unsupported/no live process (caller should
    /// hard-cancel instead).
    func interruptTurn() -> Bool
}

extension Backend {
    func injectMidTurn(_ text: String) -> Bool { false }
    var supportsMidTurnInjection: Bool { false }
    var canSteerTurns: Bool { false }
    var supportsParallelSubagents: Bool { false }
    func injectMidTurn(_ text: String, completion: @escaping (MidTurnDelivery) -> Void) {
        completion(injectMidTurn(text) ? .accepted(messageID: nil) : .notSent)
    }
    func sendNowMidTurn(_ text: String, completion: @escaping (MidTurnDelivery) -> Void) {
        injectMidTurn(text, completion: completion)
    }
    func interruptTurn() -> Bool { false }
}

/// Status lines for a run kept open only by detached background agents.
enum BackgroundWaitStatus {
    /// `other` counts background work that is neither a watch-* nor a side-* agent, such as a
    /// command moved to the background.
    static func waiting(watchers: Int, parallel: Int, other: Int = 0) -> String {
        switch (watchers, parallel, other) {
        case (_, 0, 0): return watchers == 1 ? "Background watcher running" : "\(watchers) background watchers running"
        case (0, _, 0): return parallel == 1 ? "Parallel request running" : "\(parallel) parallel requests running"
        default:
            let total = watchers + parallel + other
            return total == 1 ? "Background task running" : "\(total) background tasks running"
        }
    }

    static func resuming(parallel: Bool) -> String {
        parallel ? "Parallel request finished; replying..." : "Watcher finished; resuming..."
    }

    static func isWaiting(_ status: String) -> Bool {
        ["Background watcher running", "Parallel request running", "Background task running"].contains(status)
            || [" background watchers running", " parallel requests running", " background tasks running"]
                .contains { status.hasSuffix($0) }
    }

    static func isResuming(_ status: String) -> Bool {
        status == resuming(parallel: false) || status == resuming(parallel: true)
    }
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
            keys: ["subject", "title", "description", "Description", "Instruction", "summary", "toolSummary"]
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
        if let text = output as? String, text.count > outputLimit {
            completed.outputTail = String(text.suffix(4_000))
        }
        return completed
    }

    static let outputLimit = 20_000

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
                  "file_path", "filePath", "path", "Path", "AbsolutePath", "notebook_path", "TargetFile"
              ]) else {
            return []
        }

        if lowerName == "multi_replace_file_content",
           let chunks = args["ReplacementChunks"] as? [[String: Any]] {
            var diffs: [String] = []
            for chunk in chunks {
                let original = chunk["TargetContent"] as? String ?? ""
                let replacement = chunk["ReplacementContent"] as? String ?? ""
                if !original.isEmpty || !replacement.isEmpty {
                    diffs.append(replacementDiff(path: path, original: original, replacement: replacement))
                }
            }
            if !diffs.isEmpty {
                return [ToolFileChange(
                    id: "\(path)#edit",
                    path: path,
                    diff: diffs.joined(separator: "\n")
                )]
            }
        }

        if lowerName.contains("edit") || lowerName.contains("replace_file"),
           let replacement = string(in: args, keys: [
               "new_string", "newString", "new_source", "ReplacementContent", "Replacement"
           ]) {
            let original = string(in: args, keys: ["old_string", "oldString", "TargetContent", "Target"]) ?? ""
            return [ToolFileChange(
                id: "\(path)#edit",
                path: path,
                diff: replacementDiff(path: path, original: original, replacement: replacement)
            )]
        }

        if lowerName.contains("write") || lowerName.contains("create"),
           let content = string(in: args, keys: ["content", "Content", "file_text", "CodeContent"]) {
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
        if lowerName.contains("bash") || lowerName.contains("shell")
            || lowerName == "run_command" {
            return "Running a command"
        }
        if lowerName.contains("edit") || lowerName.contains("patch")
            || lowerName.contains("write") || lowerName.contains("replace_file") {
            if let path = string(in: arguments, keys: ["file_path", "filePath", "path", "Path", "AbsolutePath", "TargetFile"])
                ?? fileChanges.first?.path {
                return "Editing \((path as NSString).lastPathComponent)"
            }
            return "Editing files"
        }
        if lowerName == "read_url_content" {
            return "Reading URL"
        }
        if lowerName == "list_dir" {
            if let dir = string(in: arguments, keys: ["DirectoryPath", "path", "Path", "AbsolutePath"]) {
                let name = (dir as NSString).lastPathComponent
                if !name.isEmpty, name != "/" {
                    return "Listing \(name)"
                }
            }
            return "Listing directory"
        }
        if lowerName.contains("read") || lowerName.contains("view") {
            if let path = string(in: arguments, keys: ["file_path", "filePath", "path", "Path", "AbsolutePath", "TargetFile"]) {
                let name = (path as NSString).lastPathComponent
                if !name.isEmpty, name != "/" {
                    return "Reading \(name)"
                }
            }
            return "Reading a file"
        }
        if lowerName.contains("search") || lowerName.contains("grep")
            || lowerName.contains("glob") || lowerName == "find_by_name" {
            if let query = string(in: arguments, keys: ["Query", "query", "Pattern", "pattern"]) {
                let singleLine = query.components(separatedBy: .newlines).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !singleLine.isEmpty {
                    let clippedQuery = singleLine.count > 48 ? String(singleLine.prefix(48)) + "…" : singleLine
                    return "Searching for \(clippedQuery)"
                }
            }
            return "Searching"
        }
        return "Using \(displayName(toolName))"
    }

    private static func displayName(_ toolName: String) -> String {
        let shortName = toolName.split(separator: ".").last.map(String.init) ?? toolName
        switch shortName.lowercased() {
        case "bash", "shell", "run_shell", "exec_command", "command_execution", "run_command":
            return "Shell"
        case "apply_patch", "edit", "edit_file", "write", "write_file", "write_to_file", "replace_file_content", "multi_replace_file_content":
            return "Edit"
        case "read", "read_file", "view", "view_file", "list_dir":
            return "Read"
        case "read_url_content":
            return "Fetch"
        case "search_web", "grep_search", "find_by_name":
            return "Search"
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
                || name == "exec_command" || name == "command_execution"
                || name == "run_command" else {
            return nil
        }
        return string(in: arguments, keys: ["command", "cmd", "script", "CommandLine"])
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

    private static func clipped(_ text: String, limit: Int = outputLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… output truncated"
    }
}
