import Foundation
import SwiftUI
import Combine

struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    let role: Role
    var text: String
    var activities: [ToolActivity] = [] {
        didSet { recordSubagentEnds() }
    }
    /// UTF-8 length of `text` when each subagent (by activity ID) finished; its card sits there.
    var subagentEnds: [String: Int] = [:]
    /// Streamed reasoning (thinking deltas) — shown collapsed in the UI.
    var thinking: String = ""
    /// UTF-8 offsets in `thinking` where each reasoning block starts.
    var reasoningStarts: [Int] = []
    /// Tool calls and answer length at the last reasoning; a change starts a new block.
    var reasoningMark: ReasoningMark?
    /// Which model produced this (council mode) — shown as a caption.
    var author: String?
    /// Associates persisted transcript messages with their durable run.
    var runID: UUID?
    /// Interactive MCP App views returned by this reply's tool calls.
    var apps: [MCPAppPayload] = []
    /// A prompt's context size and its run's token use.
    var promptUsage: PromptUsage?
    /// Cantrip Home work handed to project tabs from this reply.
    var delegations: [CantripHomeDelegation] = []
    /// Cantrip Home only: a handed-off tab's result card (role `handoff`).
    var handoffResult: CantripHomeHandoffResult?
    /// A child tab's card in its parent (role `handoff`; `ChildTabs.swift`).
    var childResult: ChildTab?
    /// The ID of the prompt that started this message's thread (a prompt's own ID for itself).
    /// Nil for history from before threads were recorded: it gets no tag rather than a guess.
    var threadID: UUID?
    /// A Continue prompt: the earlier failed run it picks up (Continue on that run's message).
    var continuesRunID: UUID?
    /// `handoff`: a Home result card posted by Cantrip, never a model turn.
    /// `freshStart`: the Start Fresh divider; turns above it are never sent to the model.
    enum Role: String, Codable { case user, assistant, error, handoff, freshStart }
    struct ReasoningMark: Equatable {
        let activities: Int
        let textBytes: Int
    }
    // Activities and thinking are runtime-only; transcripts skip them.
    private enum CodingKeys: String, CodingKey {
        case id, role, text, author, runID, apps, promptUsage, delegations, handoffResult, freshStart, childResult
        case threadID, continuesRunID
    }
}

extension ChatMessage {
    /// Appends streamed reasoning. Reasoning after a new tool call or answer text is a new block.
    mutating func appendThinking(_ delta: String) {
        defer { thinking += delta }
        guard delta.contains(where: { !$0.isWhitespace }) else { return }
        let mark = ReasoningMark(activities: activities.count, textBytes: text.utf8.count)
        if reasoningStarts.isEmpty || reasoningMark != mark {
            reasoningStarts.append(thinking.utf8.count)
        }
        reasoningMark = mark
    }

    /// Notes where the reply had got to when each subagent ended; a revived agent is re-noted.
    private mutating func recordSubagentEnds() {
        for agent in activities.flatMap(\.subagentActivities) {
            guard let info = agent.subagent else { continue }
            if info.isActive {
                subagentEnds[agent.id] = nil
            } else if subagentEnds[agent.id] == nil {
                subagentEnds[agent.id] = text.utf8.count
            }
        }
    }

    /// Reply block a finished subagent's card follows (0 = before the text).
    func subagentTextBlock(_ activityID: String) -> Int {
        guard let end = subagentEnds[activityID] else { return 0 }
        return ReplyBlocks.block(atOffset: end, in: text)
    }

    /// `thinking` split into its blocks (usually one per model call).
    var reasoningBlocks: [String] {
        let bytes = Array(thinking.utf8)
        let starts = reasoningStarts.isEmpty ? [0] : reasoningStarts
        return starts.indices.compactMap { index in
            let end = index + 1 < starts.count ? starts[index + 1] : bytes.count
            guard starts[index] < end, end <= bytes.count else { return nil }
            let block = String(decoding: bytes[starts[index]..<end], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return block.isEmpty ? nil : block
        }
    }
}

extension ChatMessage {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let storedRole = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        runID = try container.decodeIfPresent(UUID.self, forKey: .runID)
        apps = (try? container.decodeIfPresent([MCPAppPayload].self, forKey: .apps)) ?? []
        promptUsage = try? container.decodeIfPresent(PromptUsage.self, forKey: .promptUsage)
        delegations = (try? container.decodeIfPresent(
            [CantripHomeDelegation].self, forKey: .delegations
        )) ?? []
        handoffResult = try? container.decodeIfPresent(
            CantripHomeHandoffResult.self, forKey: .handoffResult
        )
        childResult = try? container.decodeIfPresent(ChildTab.self, forKey: .childResult)
        threadID = try? container.decodeIfPresent(UUID.self, forKey: .threadID)
        continuesRunID = try? container.decodeIfPresent(UUID.self, forKey: .continuesRunID)
        if (try? container.decodeIfPresent(Bool.self, forKey: .freshStart)) == true {
            role = .freshStart
        } else {
            role = handoffResult == nil && childResult == nil ? storedRole : .handoff
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        // Result cards are saved as assistant messages and dividers as errors, so builds without
        // those roles still load the transcript; `handoffResult` / `freshStart` mark them.
        let storedRole: Role = switch role {
        case .handoff where handoffResult != nil || childResult != nil: .assistant
        case .freshStart: .error
        default: role
        }
        try container.encode(storedRole, forKey: .role)
        if role == .freshStart { try container.encode(true, forKey: .freshStart) }
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(runID, forKey: .runID)
        if !apps.isEmpty { try container.encode(apps, forKey: .apps) }
        try container.encodeIfPresent(promptUsage, forKey: .promptUsage)
        if !delegations.isEmpty { try container.encode(delegations, forKey: .delegations) }
        try container.encodeIfPresent(handoffResult, forKey: .handoffResult)
        try container.encodeIfPresent(childResult, forKey: .childResult)
        try container.encodeIfPresent(threadID, forKey: .threadID)
        try container.encodeIfPresent(continuesRunID, forKey: .continuesRunID)
    }
}

struct QueuedPrompt: Identifiable, Equatable {
    let id: UUID
    let text: String
    let includesAmbientContext: Bool

    init(id: UUID = UUID(), text: String, includesAmbientContext: Bool) {
        self.id = id
        self.text = text
        self.includesAmbientContext = includesAmbientContext
    }
}

/// Drives the conversation: routes queries to the selected backend,
/// accumulates streamed output, and exposes state to the UI.
@MainActor
final class ChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = [] {
        didSet { remoteMessageRevision = UUID() }
    }
    private(set) var remoteMessageRevision = UUID()
    private(set) var remoteQueueRevision = UUID()
    @Published var isStreaming = false
    @Published private(set) var isWaitingOnBackgroundWatchers = false
    @Published var statusText: String?
    @Published var focusRequested = false
    /// Image file paths pasted (⌘V) to attach to the next query.
    @Published var attachments: [String] = []
    /// Messages queued while a response is streaming (run in order after).
    @Published private(set) var queued: [QueuedPrompt] = [] {
        didSet {
            remoteQueueRevision = UUID()
            if !autoDeliveredItemIDs.isEmpty { autoDeliveredItemIDs.formIntersection(queued.map(\.id)) }
            scheduleQueueGrouping()
            scheduleQueuePlanning()
        }
    }
    /// Queued messages sent with Auto delivery (not commands, councils or very long messages): the
    /// only ones auto-fork may start in a child tab, once routing leaves them queued. An explicit
    /// Queue means "after this".
    private(set) var autoDeliveredItemIDs: Set<UUID> = []
    /// A queued message's plan changed, or Auto routing left one in the queue (auto-fork checks).
    var onQueuePlansChanged: ((ChatSession) -> Void)?
    @Published private(set) var deliveryStatus: String?
    /// Suggested plans for queued messages while this tab works (`QueuePlanning.swift`).
    @Published private(set) var queuePlans: [UUID: QueuePlan] = [:] {
        didSet { if queuePlans != oldValue { remoteQueueRevision = UUID() } }
    }
    private var planningTask: Task<Void, Never>?
    private var plannedKey = ""
    /// Set while a child tab's branch merges into this tab's checkout; the queue waits for it.
    var childMergeHold = false
    /// What this tab's model hears about other tabs with each message: its child tabs' status,
    /// replies to its `cantrip tab ask` questions and the tabs the message @mentions
    /// (SessionManager.tabContextNotes; the String is the message).
    static var tabContextProvider: ((ChatSession, String) -> String?)?
    @Published var pendingInputs: [InputRequestSnapshot] = [] {
        didSet { remoteMessageRevision = UUID() }
    }
    var inputRequests: [UUID: BackendInputRequest] = [:]
    @Published var inputReplyID: UUID?
    var inputExpiryTasks: [UUID: Task<Void, Never>] = [:]
    var onInputNeeded: ((InputRequestSnapshot) -> Void)?
    var onInputResolved: ((UUID) -> Void)?
    func deliveryStatusForInput(_ message: String) { deliveryStatus = message }
    private var routingTask: Task<Void, Never>?
    private var routingItemID: UUID?
    private var routingRevision = 0
    private var injectionTask: Task<Void, Never>?
    private var pendingInjections: Set<UUID> = []
    /// Which queued messages run together next, decided while the current turn works.
    private struct QueueGroupingPlan {
        let candidates: [QueuedPrompt]
        let group: [QueuedPrompt]
    }
    private var groupingPlan: QueueGroupingPlan?
    private var groupingTask: Task<Void, Never>?
    private var groupingTaskCandidates: [QueuedPrompt] = []
    private var groupingClassifying = false
    private var drainAfterGrouping = false
    private var groupingRevision = 0
    /// How long the queue must stay unchanged before grouping it during a turn.
    static var queueGroupingDelay: UInt64 = 1_500_000_000
    private var deferredInjectionDone = false
    /// Text grabbed from another app via ⌥⇧Space, attached to next query.
    @Published var selectionContext: SelectionContext?
    /// Called when the whole run (including queue) completes; AppDelegate
    /// uses it for background notifications.
    var onRunFinished: (() -> Void)?
    /// Called for every individual turn, including scheduled Home runs.
    var onTurnCompleted: ((UUID, String, String) -> Void)?
    /// Called when the Home background conversation starts a scheduled task or incident.
    var onCantripHomeRunStarted: ((UUID, CantripHomeAutomatedRun) -> Void)?
    private(set) var remoteCompletion: RemoteCompletion?
    private var preparationTask: Task<Void, Never>?
    /// Orphans events and preparation from cancelled/superseded backend runs.
    private var streamGeneration = 0 {
        didSet {
            cancelInputs()
            deviceLogin.cancel()
            preparationTask?.cancel()
            preparationTask = nil
            injectionTask?.cancel()
            injectionTask = nil
            pendingInjections.removeAll()
            deferredInjectionDone = false
        }
    }
    /// True when the last run died mid-task (timeout/failure) and can be
    /// picked up from the steps already taken. Shows the Resume button.
    @Published var canResume = false
    /// The user prompt whose run was interrupted; resume re-anchors on it.
    private var currentRunPrompt: String?
    /// Resuming a remotely originated run must retain its no-ambient-context
    /// boundary, including the automatic resume path.
    private var currentRunIncludesAmbientContext = true
    /// One free automatic resume per user-initiated run; manual after that.
    private var autoResumeSpent = false
    /// An interrupted run will resume by itself in a moment (handoffs keep waiting for it).
    private(set) var autoResumePending = false
    /// An interrupted run waits for the user's Resume (handoffs show that the tab needs them).
    private(set) var interruptionAwaitsResume = false
    /// Resumes after network failures in the current run, bounded by `networkRetryDelays`.
    private var networkRetries = 0
    /// The run Cantrip was in the middle of when it quit, until it continues or is replaced.
    private var restoredRun: RunJournal.RecoveredRun?
    private var drainWaitsForNetwork = false
    /// Delays before resuming after a connection error while the Mac still has a network path
    /// (DNS, VPN or upstream outages). Its length bounds network resumes per run.
    static var networkRetryDelays: [TimeInterval] = [10, 20, 40, 80, 160, 300]
    /// Relaunches a single run may resume after, so a run that crashes Cantrip can't loop.
    static let launchResumeLimit = 2
    /// Durable run identity survives backend retries and process restarts.
    private var currentRunID: UUID?
    var currentRunIdentifier: UUID? { currentRunID }
    private var lastJournalRunID: UUID?
    private var currentRunStartedAt: Date?
    var currentRunStart: Date? { currentRunStartedAt }
    private(set) var lastRunOutcome: LiveStatusRunOutcome?
    private var currentRunMode: RunJournal.Mode?
    private var currentRunBackend: BackendKind?
    /// The backend's own usage-limit report for the attempt that's about to fail, if it sent one.
    private var reportedUsageLimit: UsageLimitReport?
    private var currentAttempt = 0
    private var pendingTurnCompletion: (runID: UUID, status: String, summary: String)?
    private var runningBackendKind: BackendKind?
    /// The prompt whose line shows this run's context and token use.
    private var promptUsageMessageID: UUID?
    private var activityStartedAt: [String: Date] = [:]
    private var recordedArtifacts: Set<String> = []
    private var journal: RunJournal?
    private let makeJournal: (UUID) throws -> RunJournal
    @Published private(set) var journalError: String?
    private(set) var privateStorageError: String?
    /// Council mode: fan each prompt out to several backends in parallel,
    /// then have a chair synthesize the joint answer.
    @Published var councilMode = false {
        didSet {
            if isLocalPrivate, councilMode { councilMode = false }
            // Turning council off shouldn't leave seat processes idling.
            if !councilMode, !councilRunning {
                for backend in councilInstances.values { backend.cancel() }
            }
        }
    }
    private var councilRunning = false
    /// (member, its answer-message id) for the in-flight council round.
    private var councilAnswers: [(kind: BackendKind, messageID: UUID)] = []
    /// Seats whose terminal event arrived — a Set because backends can
    /// emit more than one terminal (Codex: stream error + process exit).
    /// Published so seat panes can show per-seat progress.
    @Published private(set) var councilFinished: Set<UUID> = []
    /// Once-latch: synthesis must start exactly once per round.
    private var councilSynthesizing = false

    let settings = AppSettings.shared
    let id: UUID
    /// A hidden, single-use session running one Home background job; never a tab.
    let isCantripHomeRun: Bool
    /// Set once a finished background run is torn down, so nothing writes its files again.
    private var cantripHomeRunDiscarded = false
    @Published private var automaticTitle = "New chat"
    @Published private(set) var tabMetadata = SessionTabMetadata()
    @Published var tabActionError: String?
    /// The scheduled task or incident the Home background conversation is running.
    private(set) var cantripHomeRunLabel: String?
    /// A hidden run's task model; nil follows Home's model selection.
    var cantripHomeModelOverride: SessionModelSelection? {
        didSet { applyModelSelection() }
    }
    /// The saved task a hidden run executes and its run notes; nil for incidents.
    private(set) var cantripHomeTask: (id: UUID, note: String?)?
    /// Home confirmations and refusals waiting to be appended to this run's reply.
    var cantripHomeNotices: [String] = []
    /// Refusals held while Home corrects its blocks; replaced if the correction saves blocks.
    var cantripHomeHeldFailures: [String] = []
    /// The reply as it stood before Cantrip asked for corrected blocks.
    var cantripHomeCorrection: (messageID: UUID, prefix: String)?
    /// Each run gets one correction turn.
    var cantripHomeCorrectionSpent = false
    /// Whether this Home session's backend lets Cantrip check each action before it runs.
    /// Codex runs commands itself; a Copilot Remote server may approve tools Cantrip never sees.
    var cantripHomeChecksActions: Bool {
        ![.codex, .copilotRemote].contains(runningBackendKind ?? effectiveBackendKind)
    }
    /// The approval mode the user chose for the backend running this Home session.
    var cantripHomeApproval: CantripHomeApproval {
        .chosen(for: runningBackendKind ?? effectiveBackendKind, settings: settings)
    }
    var title: String {
        if isCantripHome { return "Cantrip Home" }
        if isCantripHomeBackground { return "Cantrip Home background" }
        return tabMetadata.customTitle ?? (isLocalPrivate ? "Private Local" : automaticTitle)
    }
    /// Completion notifications name the background run, not its shared conversation.
    var notificationTitle: String {
        isCantripHomeBackground ? (cantripHomeRunLabel ?? title) : title
    }
    var isLocked: Bool {
        isLocalPrivate || isCantripHome || isCantripHomeBackground || tabMetadata.isLocked
    }
    var effectiveBackendKind: BackendKind { isLocalPrivate ? .localModel : settings.backend }
    /// Per-session working directory: backends, ! commands, and git
    /// actions all run here. A session becomes "the agent in this repo".
    @Published var workdir: String {
        didSet { UserDefaults.standard.set(workdir, forKey: TabDefaults.workdir(id)) }
    }
    /// Private mode: nothing this session touches disk on our side — no
    /// transcript, no session log, no continuity digest, and the memory
    /// vault becomes read-only for the agent.
    @Published var isPrivate = false {
        didSet {
            if isLocalPrivate, isPrivate {
                isPrivate = false
                tabActionError = "Private Local saves its conversation and uses only your configured self-hosted model server."
                return
            }
            mcpAppContext.removeAll()
            if isPrivate {
                cancelInputs()
                deleteTranscript()   // scrub anything already written
                journalError = nil
                Log.write("session \(id.uuidString.prefix(8)): private mode ON")
            } else {
                do {
                    journal = try makeJournal(id)
                    journalError = nil
                } catch {
                    reportJournalFailure(error)
                }
                persistTranscript()
            }
        }
    }
    /// Auto-cancel if the backend goes silent for this long. Generous so
    /// long downloads/builds under a tool call aren't killed.
    private let inactivityLimit: TimeInterval = 900
    private var watchdog: Timer?
    let claudeCode: ClaudeCodeBackend
    private let copilot: Backend
    private let copilotRemote = CopilotACPBackend()
    private let codex: CodexBackend
    private let antigravity: AntigravityBackend
    private let localModel = OpenAICompatibleBackend()
    /// Tests stand in for backends other than Copilot here.
    private let backendOverrides: [BackendKind: Backend]
    private let privateLocalModel = PrivateLocalBackend()
    private let deviceLogin = RemoteDeviceLogin()
    let shell = PersistentShell()
    private var shellObservation: AnyCancellable?

    var currentActivity: ToolActivity? {
        for message in messages.reversed() {
            if let activity = message.activities.last(where: { $0.state == .running }) {
                return activity
            }
        }
        return nil
    }

    private var hasActiveBackgroundWatcher: Bool {
        messages.contains { message in
            message.activities.contains { activity in
                activity.subagentActivities.contains {
                    $0.subagent?.isActive == true && $0.subagent?.keepsRunAvailable == true
                }
            }
        }
    }

    private var activeBackend: Backend {
        backend(for: runningBackendKind ?? effectiveBackendKind)
    }

    private func backend(for kind: BackendKind) -> Backend {
        if isLocalPrivate { return privateLocalModel }
        if let override = backendOverrides[kind] { return override }
        switch kind {
        case .claudeCode: return claudeCode
        case .copilot: return copilot
        case .copilotRemote: return copilotRemote
        case .codex: return codex
        case .antigravity: return antigravity
        case .localModel: return localModel
        }
    }

    init(id: UUID = UUID(), copilotBackend: Backend = CopilotBackend(),
         cantripHomeRun: Bool = false, backendOverrides: [BackendKind: Backend] = [:],
         makeJournal: @escaping (UUID) throws -> RunJournal = { try RunJournal(sessionID: $0) }) {
        self.id = id
        self.backendOverrides = backendOverrides
        self.isCantripHomeRun = cantripHomeRun
        self.copilot = copilotBackend
        self.makeJournal = makeJournal
        self.lastRunOutcome = Self.loadLastRunOutcome(id: id)
        self.workdir = UserDefaults.standard.string(forKey: TabDefaults.workdir(id))
            ?? AppSettings.shared.claudeWorkdir
        self.claudeCode = ClaudeCodeBackend(persistKey: TabDefaults.claudeSession(id))
        self.codex = CodexBackend(persistKey: TabDefaults.codexSession(id))
        self.antigravity = AntigravityBackend(persistKey: TabDefaults.antigravitySession(id))
        (copilotBackend as? CopilotBackend)?.tabID = id
        claudeCode.tabID = id
        codex.tabID = id
        do {
            journal = try makeJournal(id)
        } catch {
            reportJournalFailure(error)
        }
        shellObservation = shell.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        loadTranscript()
        tabMetadata = SessionTabMetadata.load(id: id)
        applyModelSelection()
        restoreDurableState()
        if isLocalPrivate, !FileManager.default.fileExists(atPath: transcriptURL.path) { persistTranscript() }
        // Home's safety rules are enforced by Cantrip for whichever backend runs it.
        let guardrail: CantripHomeGuardrail? = isCantripHome ? .attended
            : isCantripHomeBackground ? .unattended
            // A child tab keeps Cantrip's blocked list too (it must not quit Cantrip, for one).
            : ChildTabStore.shared.isActiveChild(id) ? .attended : nil
        let guarded: [CantripHomeGuardedBackend?] = [
            copilotBackend as? CantripHomeGuardedBackend, copilotRemote, claudeCode, antigravity, localModel
        ]
        for backend in guarded { backend?.guardrail = guardrail }
        // Remember which agent files folders this session used (Home runs hand them to the log).
        if let copilot = copilotBackend as? CopilotBackend {
            copilot.onAgentSession = { [weak self] cliSessionID in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !self.isPrivate, !self.isLocalPrivate else { return }
                        SessionOutputFolders.shared.record(cliSessionID, for: self.id)
                    }
                }
            }
        }
    }

    // MARK: - Tab lists

    private var tabPreviewCache: (key: String, value: String?)?

    /// When this tab last ran, for tab lists: the current run's start while it works, else when
    /// its latest run finished (or, before any recorded run, when its transcript last changed).
    var lastActivityDate: Date? {
        if isStreaming, let currentRunStartedAt { return currentRunStartedAt }
        if let finished = lastRunOutcome?.finishedAt { return finished }
        return (try? transcriptURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// One line about the latest reply for tab lists: its "Outcome:" paragraph or closing words.
    func tabPreview() -> String? {
        guard let reply = messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) else {
            return nil
        }
        let key = "\(reply.id.uuidString):\(reply.text.utf8.count)"
        if let cached = tabPreviewCache, cached.key == key { return cached.value }
        let line = CantripHomeDelegations.briefOutcome(TabMentions.plain(reply.text), limit: 140)
            .split(whereSeparator: \.isNewline).joined(separator: " ")
        let value = line.isEmpty ? nil : line
        tabPreviewCache = (key, value)
        return value
    }

    // MARK: - Transcript persistence (survives app restarts)

    private var transcriptURL: URL {
        // Background runs live outside chats/, so they never appear in tabs or archives.
        (isCantripHomeRun ? CantripHomeStore.runsDirectory : SessionManager.chatsDir)
            .appendingPathComponent("\(id.uuidString).json")
    }

    /// Tears down a finished background run: its backend process, transcript, journal and
    /// per-session defaults. Its report already lives in Home's background log.
    func discardCantripHomeRun() {
        guard isCantripHomeRun, !cantripHomeRunDiscarded else { return }
        cantripHomeRunDiscarded = true
        watchdog?.invalidate()
        watchdog = nil
        cancelInputs()
        resetBackendConversations()
        deleteTranscript()
    }

    func deleteTranscript() {
        SessionTabMetadata.remove(id: id)
        SessionOutputFolders.shared.remove(id)
        try? FileManager.default.removeItem(at: transcriptURL)
        do {
            try journal?.remove()
        } catch {
            Log.write("run-journal: could not delete \(id.uuidString.prefix(8)): \(error.localizedDescription)")
        }
        journal = nil
        lastRunOutcome = nil
        TabDefaults.removeAll(for: id)
    }

    func persistTranscript() {
        guard !isPrivate, privateStorageError == nil, !cantripHomeRunDiscarded else { return }
        tabMetadata.save(id: id)
        // Thinking/activities don't persist, so assistant messages whose
        // only content was runtime-only would reload as invisible husks.
        let persistable = messages.filter {
            !($0.role == .assistant && $0.text.isEmpty && $0.apps.isEmpty
              && $0.delegations.isEmpty)
        }
        do {
            if isLocalPrivate {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: SessionManager.chatsDir.path)
            }
            let data = try JSONEncoder().encode(persistable)
            try data.write(to: transcriptURL, options: .atomic)
            if isLocalPrivate {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcriptURL.path)
            }
        } catch {
            if isLocalPrivate {
                privateStorageError = "Private Local history could not be saved. Check the Mac's disk and file permissions before reopening this tab."
            }
            reportJournalFailure(error)
        }
    }

    private func loadTranscript() {
        if isLocalPrivate, FileManager.default.fileExists(atPath: transcriptURL.path) {
            do { messages = try JSONDecoder().decode([ChatMessage].self, from: Data(contentsOf: transcriptURL)) }
            catch {
                let message = "Private Local history could not be read. It has not been overwritten. Repair or restore the transcript on the Mac before reopening Cantrip."
                privateStorageError = message
                messages = [ChatMessage(role: .error, text: message)]
                Log.write("private-local: transcript read failed code=\((error as NSError).code)")
            }
            return
        }
        guard let data = try? Data(contentsOf: transcriptURL),
              let restored = try? JSONDecoder().decode([ChatMessage].self, from: data),
              !restored.isEmpty else { return }
        messages = Array(restored.suffix(30))
        if let first = messages.first(where: { $0.role == .user }) {
            automaticTitle = String(TabMentions.plain(first.text).prefix(34))
        }
        Log.write("transcript: restored \(messages.count) messages (\(id.uuidString.prefix(8)))")
    }

    func updateTab(name: String? = nil, isLocked: Bool? = nil) throws {
        if isLocalPrivate, isLocked == false {
            throw SessionModelSettingsError(409, "Private Local is a permanent tab and cannot be unlocked or closed.")
        }
        var updated = tabMetadata
        if let name { try updated.rename(name) }
        if let isLocked { updated.isLocked = isLocked }
        try saveTabMetadata(updated)
    }

    /// Files the tab under a section; `SessionManager.setSection` validates and positions it.
    func saveSection(_ sectionID: UUID?) throws {
        var updated = tabMetadata
        updated.sectionID = sectionID
        try saveTabMetadata(updated)
    }

    func saveModelSelection(_ selection: SessionModelSelection?, for backend: BackendKind? = nil) throws {
        var updated = tabMetadata
        updated.setModelSettings(selection, for: backend ?? modelSettingsBackend)
        try saveTabMetadata(updated)
        applyModelSelection()
    }

    private func applyModelSelection() {
        // Background runs use their task's model, or whatever the user picked for Home.
        func selection(for kind: BackendKind) -> SessionModelSelection? {
            isCantripHomeBackground
                ? (kind == modelSettingsBackend ? cantripHomeModelOverride : nil)
                    ?? SessionTabMetadata.load(id: Self.cantripHomeID).modelSettings(for: kind)
                : tabMetadata.modelSettings(for: kind)
        }
        if let backend = copilot as? CopilotBackend {
            let copilotSelection = selection(for: .copilot)
            backend.modelOverride = copilotSelection?.model
            backend.effortOverride = copilotSelection?.effort
            backend.contextTierOverride = copilotSelection?.contextTier
        }
        let claudeSelection = selection(for: .claudeCode)
        // A tab's "CLI default" is Claude Code's own default model, and an empty effort sends none.
        claudeCode.modelOverride = claudeSelection.map { $0.model.isEmpty ? "default" : $0.model }
        claudeCode.effortOverride = claudeSelection?.effort
    }

    private func saveTabMetadata(_ updated: SessionTabMetadata) throws {
        if !isPrivate {
            // New, empty tabs need a transcript file to participate in tab
            // restoration. Renaming existing tabs must not rewrite their history.
            if !FileManager.default.fileExists(atPath: transcriptURL.path) {
                try JSONEncoder().encode(messages).write(to: transcriptURL, options: .atomic)
            }
            updated.save(id: id)
        }
        tabMetadata = updated
    }

    // MARK: - Durable run state

    private func appendRunEvent(_ event: RunJournal.Event, durable: Bool = false) {
        guard !isPrivate else { return }
        guard let journal else {
            reportJournalFailure(CocoaError(.fileNoSuchFile))
            return
        }
        journal.enqueue(event, durable: durable) { [weak self, weak journal] result in
            guard case .failure(let error) = result else { return }
            Task { @MainActor in
                guard let self, self.journal === journal, !self.isPrivate else { return }
                self.reportJournalFailure(error)
            }
        }
    }

    private func reportJournalFailure(_ error: Error) {
        guard journalError == nil else { return }
        Log.write("run-journal: write failed code=\((error as NSError).code)")
        let message = "Run history could not be saved on the Mac. Recovery may be incomplete; queued work will not start automatically."
        journalError = message
        messages.append(ChatMessage(role: .error, text: message))
    }

    func flushJournal() async throws {
        guard !isPrivate else { return }
        if let privateStorageError { throw SessionModelSettingsError(500, privateStorageError) }
        guard let journal else { throw CocoaError(.fileNoSuchFile) }
        do { try await journal.flush() }
        catch {
            if self.journal === journal, !isPrivate { reportJournalFailure(error) }
            throw error
        }
    }

    @discardableResult
    private func beginRun(
        prompt: String,
        mode: RunJournal.Mode,
        backends: [String],
        backend: BackendKind?,
        includesAmbientContext: Bool,
        queueItemID: UUID? = nil,
        additionalQueueItemIDs: [UUID] = []
    ) -> UUID {
        autoResumePending = false
        interruptionAwaitsResume = false
        networkRetries = 0
        restoredRun = nil
        if currentRunID != nil {
            cancelRun(reason: "superseded by a new run")
        }
        let runID = UUID()
        remoteCompletion = nil
        currentRunID = runID
        lastJournalRunID = runID
        currentRunStartedAt = Date()
        currentRunMode = mode
        currentRunBackend = backend
        reportedUsageLimit = nil
        currentAttempt = 1
        promptUsageMessageID = nil
        activityStartedAt.removeAll()
        recordedArtifacts.removeAll()

        var event = RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: .turnStarted
        )
        event.prompt = prompt
        event.mode = mode
        event.backends = backends
        event.backend = backend?.rawValue
        event.workdir = workdir
        event.includesAmbientContext = includesAmbientContext
        event.queueItemID = queueItemID
        event.queueItemIDs = additionalQueueItemIDs.isEmpty ? nil : additionalQueueItemIDs
        appendRunEvent(event, durable: true)
        return runID
    }

    private func recordResumeAttempt(reason: String) {
        guard let runID = currentRunID else { return }
        currentAttempt += 1
        var event = RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: .attempt
        )
        event.attemptNumber = currentAttempt
        event.reason = reason
        appendRunEvent(event, durable: true)
    }

    @discardableResult
    private func appendRunMessage(_ message: ChatMessage, queueItemID: UUID? = nil) -> UUID {
        var message = message
        message.runID = message.runID ?? currentRunID
        message.threadID = message.threadID ?? threadID(forNew: message)
        messages.append(message)
        guard let runID = message.runID else { return message.id }

        var event = RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: .messageStarted
        )
        event.messageID = message.id
        event.role = message.role.rawValue
        event.text = message.text
        event.author = message.author
        event.threadID = message.threadID
        event.queueItemID = queueItemID
        appendRunEvent(event, durable: queueItemID != nil)
        return message.id
    }

    /// A prompt starts its own thread; a reply, error or question joins the thread of the
    /// message it follows. Late background results and answers to questions set theirs first.
    func threadID(forNew message: ChatMessage) -> UUID? {
        switch message.role {
        case .user: return message.id
        case .assistant, .error: return currentThreadID
        case .handoff, .freshStart: return nil
        }
    }

    /// A prompt Cantrip answered itself, without a run.
    private func appendLocalExchange(prompt: String, reply: String) {
        var question = ChatMessage(role: .user, text: prompt)
        question.threadID = question.id
        var answer = ChatMessage(role: .assistant, text: reply)
        answer.threadID = question.id
        messages += [question, answer]
        persistTranscript()
    }

    /// The thread the latest prompt or reply belongs to.
    var currentThreadID: UUID? {
        messages.last { $0.role == .user || $0.role == .assistant }?.threadID
    }

    private func recordOutput(
        _ text: String,
        messageID: UUID,
        author: String? = nil
    ) {
        guard !text.isEmpty, let runID = currentRunID else { return }
        var event = RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: .output
        )
        event.messageID = messageID
        event.role = ChatMessage.Role.assistant.rawValue
        event.text = text
        event.author = author
        event.channel = "text"
        appendRunEvent(event)
    }

    private func recordActivity(_ activity: ToolActivity, messageID: UUID) {
        guard let runID = currentRunID else { return }
        let now = Date()
        if activity.state == .running, activityStartedAt[activity.id] == nil {
            activityStartedAt[activity.id] = now
        }

        var event = RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: .toolActivity
        )
        event.messageID = messageID
        event.activity = journalActivity(activity)
        if activity.state != .running, let started = activityStartedAt.removeValue(
            forKey: activity.id
        ) {
            event.durationMS = max(0, Int(now.timeIntervalSince(started) * 1_000))
        }
        appendRunEvent(event, durable: activity.state != .running)

        for change in activity.fileChanges {
            let key = "\(messageID.uuidString)|\(activity.id)|\(change.id)"
            guard recordedArtifacts.insert(key).inserted else { continue }
            var artifactEvent = RunJournal.Event(
                sessionID: id,
                runID: runID,
                kind: .artifact
            )
            artifactEvent.messageID = messageID
            artifactEvent.artifact = RunJournal.Artifact(
                path: change.path,
                kind: "diff",
                content: change.diff
            )
            appendRunEvent(artifactEvent)
        }
    }

    private func recordUsage(_ usage: BackendUsage) {
        if let backend = BackendKind(rawValue: usage.backend) {
            UsageTracker.shared.recordCost(
                backend: backend,
                costUSD: usage.costUSD,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens
            )
        }
        guard let runID = currentRunID else { return }
        var event = RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: .usage
        )
        event.usage = RunJournal.Usage(
            backend: usage.backend,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            costUSD: usage.costUSD
        )
        appendRunEvent(event, durable: true)
    }

    private func updatePromptUsage(_ update: (inout PromptUsage, _ typedCharacters: Int) -> Void) {
        guard let promptUsageMessageID,
              let index = messages.firstIndex(where: { $0.id == promptUsageMessageID }) else { return }
        var usage = messages[index].promptUsage ?? PromptUsage()
        update(&usage, messages[index].text.count)
        if usage != messages[index].promptUsage { messages[index].promptUsage = usage }
    }

    private func recordApproval(_ approval: BackendApproval) {
        guard let runID = currentRunID else { return }
        var event = RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: .approval
        )
        event.tool = approval.tool
        event.decision = approval.decision
        event.decidedBy = approval.decidedBy
        appendRunEvent(event, durable: true)
    }

    private func recordInterruption(_ reason: String) {
        remoteCompletion = nil
        guard let runID = currentRunID else { return }
        var event = RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: .interruption
        )
        event.attemptNumber = currentAttempt
        event.reason = reason
        appendRunEvent(event, durable: true)
    }

    private func completeRun(status: String, summary: String = "") {
        guard let runID = currentRunID else { return }
        let finishedAt = Date()
        if !isPrivate, !isLocalPrivate {
            if status == "succeeded" {
                recordLastRunOutcome(.init(status: .done, finishedAt: finishedAt))
            } else if status == "failed" {
                recordLastRunOutcome(.init(status: .failed, finishedAt: finishedAt))
            }
        }
        // A background run's report moves to Home's background log when it finishes.
        remoteCompletion = status == "succeeded" && !isPrivate && !isLocalPrivate
            ? RemoteCompletion(id: runID,
                               sessionID: isCantripHomeRun ? Self.cantripHomeBackgroundID : id,
                               title: notificationTitle,
                               summary: RemoteCompletion.preview(summary), completedAt: finishedAt)
            : nil
        var event = RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: .result
        )
        event.status = status
        event.durationMS = currentRunStartedAt.map {
            max(0, Int(Date().timeIntervalSince($0) * 1_000))
        }
        event.summaryDigest = RunJournal.digest(summary)
        appendRunEvent(event, durable: true)
        pendingTurnCompletion = (runID, status, summary)
        clearCurrentRun()
    }

    private func cancelRun(reason: String) {
        remoteCompletion = nil
        guard let runID = currentRunID else { return }
        if reason != "superseded by a new run", !isPrivate, !isLocalPrivate {
            recordLastRunOutcome(.init(status: .stopped, finishedAt: Date()))
        }
        var event = RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: .cancelled
        )
        event.reason = reason
        event.durationMS = currentRunStartedAt.map {
            max(0, Int(Date().timeIntervalSince($0) * 1_000))
        }
        appendRunEvent(event, durable: true)
        onTurnCompleted?(runID, "cancelled", reason)
        clearCurrentRun()
    }

    private func clearCurrentRun() {
        currentRunID = nil
        currentRunStartedAt = nil
        currentRunMode = nil
        currentRunBackend = nil
        reportedUsageLimit = nil
        currentAttempt = 0
        runningBackendKind = nil
        activityStartedAt.removeAll()
        recordedArtifacts.removeAll()
        currentRunPrompt = nil
        canResume = false
        interruptionAwaitsResume = false
    }

    private static func loadLastRunOutcome(id: UUID) -> LiveStatusRunOutcome? {
        guard let data = UserDefaults.standard.data(forKey: TabDefaults.lastRunOutcome(id)) else { return nil }
        return try? JSONDecoder().decode(LiveStatusRunOutcome.self, from: data)
    }

    private func recordLastRunOutcome(_ outcome: LiveStatusRunOutcome) {
        lastRunOutcome = outcome
        if let data = try? JSONEncoder().encode(outcome) {
            UserDefaults.standard.set(data, forKey: TabDefaults.lastRunOutcome(id))
        }
    }

    private func clearLastRunOutcome() {
        lastRunOutcome = nil
        UserDefaults.standard.removeObject(forKey: TabDefaults.lastRunOutcome(id))
    }

    @discardableResult
    private func enqueue(_ text: String, includesAmbientContext: Bool) -> QueuedPrompt {
        let item = QueuedPrompt(
            text: text,
            includesAmbientContext: includesAmbientContext
        )
        queued.append(item)
        recordQueueEvent(.queueAdded, item: item)
        return item
    }

    @discardableResult
    func removeQueued(id: UUID) -> QueuedPrompt? {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return nil }
        let item = queued[index]
        removeQueued(at: index)
        return item
    }

    // MARK: - Child tabs

    /// The request this tab is working on now.
    var currentTaskPrompt: String? { currentRunPrompt }

    /// Whether queued messages here can move into child tabs.
    var supportsChildTabs: Bool {
        !SessionManager.isCantripHomeReserved(self) && !isLocalPrivate && !isPrivate
            && !ChildTabStore.shared.isActiveChild(id)
    }

    /// A child tab's first turn: the queued request as written, with its brief hidden.
    func startChildTask(_ text: String, preamble: String) {
        send(text, preamble: preamble, includesAmbientContext: false, consumesStagedContext: false)
    }

    /// Runs this tab's tools under Cantrip's blocked list and the child-tab resource rules.
    func configureAsChildTab(label: String, policy: @escaping CopilotBackend.ChildPolicy) {
        let guarded: [CantripHomeGuardedBackend?] = [
            copilot as? CantripHomeGuardedBackend, copilotRemote, claudeCode, antigravity, localModel
        ]
        for backend in guarded {
            backend?.guardrail = .attended
            backend?.guardrailLabel = label
        }
        (copilot as? CopilotBackend)?.childPolicy = policy
        claudeCode.childPolicy = policy
    }

    func clearChildTabPolicy() {
        let guarded: [CantripHomeGuardedBackend?] = [
            copilot as? CantripHomeGuardedBackend, copilotRemote, claudeCode, antigravity, localModel
        ]
        for backend in guarded { backend?.guardrail = nil }
        (copilot as? CopilotBackend)?.childPolicy = nil
        claudeCode.childPolicy = nil
    }

    /// After a child tab's merge held the queue.
    func resumeQueueAfterChildMerge() {
        guard !isStreaming, !childMergeHold else { return }
        drainQueue()
    }

    /// This queued message was sent with Auto delivery: auto-fork may start it in a child tab.
    func noteAutoDelivered(_ itemID: UUID) {
        guard queued.contains(where: { $0.id == itemID }) else { return }
        autoDeliveredItemIDs.insert(itemID)
        onQueuePlansChanged?(self)
    }

    /// Whether Auto routing is still deciding, or a delivery is in flight, for this queued message.
    func isDeliveringQueued(_ itemID: UUID) -> Bool {
        routingItemID == itemID || pendingInjections.contains(itemID)
    }

    /// Replaces a queued message's plan (auto-fork explains why it waits).
    func adjustQueuePlan(_ itemID: UUID, _ plan: QueuePlan) {
        guard queued.contains(where: { $0.id == itemID }) else { return }
        queuePlans[itemID] = plan
    }

    /// Plans as the planner would set them (tests).
    func applyQueuePlans(_ plans: [UUID: QueuePlan]) {
        let live = Set(queued.map(\.id))
        queuePlans = queuePlans.merging(plans) { $1 }.filter { live.contains($0.key) }
        onQueuePlansChanged?(self)
    }

    /// A child tab's request comes back to run here (Run in This Tab Instead): first in the
    /// queue, or now if this tab is idle. It isn't auto-forked again.
    func returnFromChildTab(_ text: String) {
        let item = QueuedPrompt(text: text, includesAmbientContext: false)
        queued.insert(item, at: 0)
        recordQueueEvent(.queueAdded, item: item)
        deliveryStatus = "Moved back from its child tab; it runs next in this tab."
        if !isStreaming { drainQueue() }
    }

    /// While a turn runs, suggest a plan for each queued message (one router call per change).
    private func scheduleQueuePlanning() {
        let live = Set(queued.map(\.id))
        if queuePlans.keys.contains(where: { !live.contains($0) }) {
            queuePlans = queuePlans.filter { live.contains($0.key) }
        }
        guard isStreaming, supportsChildTabs, !queued.isEmpty, !councilMode else { return }
        if case .unavailable = routerProvider { return }
        let items = Array(queued.prefix(QueuePlanningPolicy.maxCandidates))
        let key = items.map(\.id.uuidString).joined(separator: ",")
        guard key != plannedKey else { return }
        plannedKey = key
        planningTask?.cancel()
        let currentTask = currentRunPrompt ?? ""
        let recent = messages.filter { ($0.role == .user || $0.role == .assistant) && !$0.text.isEmpty }
            .suffix(4).map { MessageRoutingSnapshot.Turn(role: $0.role.rawValue, text: $0.text) }
        let workdir = self.workdir
        let activityRepo = ChildTabRepositories.recentRepository(in: self)
        let children = ChildTabStore.shared.running.filter { $0.parentID == id }
        let provider = routerProvider
        planningTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.queueGroupingDelay)
            guard !Task.isCancelled else { return }
            let context = await Task.detached(priority: .utility) { () -> (changed: [String], repos: [String]) in
                let repo = ChildTabGit.toplevel(workdir) ?? activityRepo
                return (repo.map { ChildTabGit.changedFiles($0) } ?? [], ChildTabRepositories.names())
            }.value
            let snapshot = QueuePlanningSnapshot(
                currentTask: currentTask, recentConversation: Array(recent), changedFiles: context.changed,
                repositories: context.repos,
                childTabs: children.enumerated().map { .init(number: $0.offset + 1, title: $0.element.title, touches: $0.element.touches) },
                messages: items.enumerated().map { .init(number: $0.offset + 1, text: $0.element.text) }
            )
            do {
                let decision = try await MessageRouter.planQueue(snapshot, provider: provider)
                guard let self, !Task.isCancelled else { return }
                let plans = QueuePlanningPolicy.plans(decision, items: items, repositories: context.repos,
                                                      childTitles: children.map(\.title))
                let live = Set(self.queued.map(\.id))
                self.queuePlans = self.queuePlans.merging(plans) { $1 }.filter { live.contains($0.key) }
                self.onQueuePlansChanged?(self)
            } catch is CancellationError {
                return
            } catch {
                Log.write("queue-planning: \(error.localizedDescription)")
                guard let self, !Task.isCancelled else { return }
                self.plannedKey = ""
            }
        }
    }

    func removeQueued(at index: Int) {
        guard queued.indices.contains(index) else { return }
        let item = queued.remove(at: index)
        if routingItemID == item.id {
            invalidateRouting()
            deliveryStatus = "Removed queued message."
        }
        recordQueueEvent(.queueRemoved, item: item)
    }

    /// Sends a queued message now instead of after the current work. A live Copilot turn takes it
    /// at once: a step it was blocked on (a command or sync agent) moves to the background, and
    /// background agents keep running. Returns why it could not be sent.
    @discardableResult
    func sendQueuedNow(id: UUID) -> String? {
        guard let item = queued.first(where: { $0.id == id }) else {
            return "This message is no longer queued. It may have started or been removed on another device."
        }
        guard !pendingInjections.contains(id) else { return nil }
        if routingItemID == id { invalidateRouting() }
        guard isStreaming else {
            if let journalError { return refuseSendNow(journalError) }
            // Starting a new run would supersede the interrupted one waiting to continue.
            guard !autoResumePending else {
                moveQueuedToFront(item)
                return refuseSendNow(
                    "Cantrip is continuing an interrupted task first. This message is next in the queue."
                )
            }
            // A child tab's branch is merging into this checkout; it goes first once that's done.
            guard !childMergeHold else {
                moveQueuedToFront(item)
                return refuseSendNow("A child tab's work is merging into this tab's checkout. This message is next in the queue.")
            }
            invalidateGrouping()
            Log.write("queue: sending a queued message now")
            startQueued([item])
            return nil
        }
        guard pendingInputs.isEmpty else {
            return refuseSendNow("Answer the question above first, then send this message.")
        }
        let joinsTurn = activeBackend.canSteerTurns && currentRunMode == .single
            && !councilRunning && !item.text.hasPrefix("!") && !item.text.hasPrefix("/")
        guard joinsTurn else {
            // Commands, councils and backends without a live input channel can't join the turn.
            Log.write("queue: redirecting to a queued message sent now")
            submit(item.text, interrupt: true, inject: false,
                   includesAmbientContext: item.includesAmbientContext,
                   consumesStagedContext: false, queuedItem: item)
            removeQueued(item)
            deliveryStatus = "Stopped the current task to send your message now."
            return nil
        }
        // The turn is still starting, or has finished and is being saved.
        guard preparationTask == nil, activeBackend.supportsMidTurnInjection else {
            moveQueuedToFront(item)
            return refuseSendNow(
                "The current task is starting or saving. This message is next in the queue; try Send now again in a moment."
            )
        }
        Log.write("queue: sending a queued message into the current turn now")
        injectQueued(item, sendNow: true)
        return nil
    }

    private func moveQueuedToFront(_ item: QueuedPrompt) {
        guard let index = queued.firstIndex(where: { $0.id == item.id }), index > 0 else { return }
        queued.remove(at: index)
        queued.insert(item, at: 0)
    }

    private func refuseSendNow(_ reason: String) -> String {
        deliveryStatus = reason
        return reason
    }

    private func removeQueued(_ item: QueuedPrompt) {
        guard let index = queued.firstIndex(where: { $0.id == item.id }) else { return }
        queued.remove(at: index)
        if routingItemID == item.id { invalidateRouting() }
        recordQueueEvent(.queueRemoved, item: item)
    }

    private func clearQueue() {
        invalidateRouting()
        invalidateGrouping()
        guard !queued.isEmpty else { return }
        queued.removeAll()
        guard let runID = currentRunID ?? lastJournalRunID else { return }
        appendRunEvent(RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: .queueCleared
        ), durable: true)
    }

    private func recordQueueEvent(
        _ kind: RunJournal.EventKind,
        item: QueuedPrompt
    ) {
        guard let runID = currentRunID ?? lastJournalRunID else { return }
        var event = RunJournal.Event(
            sessionID: id,
            runID: runID,
            kind: kind
        )
        event.queueItem = RunJournal.QueueItem(
            id: item.id,
            text: item.text,
            includesAmbientContext: item.includesAmbientContext
        )
        appendRunEvent(event, durable: true)
    }

    private func restoreDurableState() {
        guard let state = journal?.recoveryState() else { return }
        queued = state.queued.map {
            QueuedPrompt(
                id: $0.id,
                text: $0.text,
                includesAmbientContext: $0.includesAmbientContext
            )
        }
        lastJournalRunID = state.lastRunID
        guard let run = state.activeRun else { return }
        restoredRun = run

        currentRunID = run.id
        lastJournalRunID = run.id
        currentRunStartedAt = run.startedAt
        currentRunMode = run.mode
        currentRunBackend = run.backend.flatMap(BackendKind.init(rawValue:))
            ?? run.backends.compactMap(BackendKind.init(rawValue:)).first
        currentAttempt = run.attemptNumber
        currentRunPrompt = run.prompt
        currentRunIncludesAmbientContext = run.includesAmbientContext
        autoResumeSpent = run.attemptNumber > 1
        workdir = run.workdir

        for recovered in run.messages {
            let activities = recovered.activities.map(restoredActivity)
            if let index = messages.firstIndex(where: { $0.id == recovered.id }) {
                messages[index].text = recovered.text
                messages[index].activities = activities
                messages[index].author = recovered.author
                messages[index].runID = run.id
                messages[index].threadID = messages[index].threadID ?? recovered.threadID
            } else {
                messages.append(ChatMessage(
                    id: recovered.id,
                    role: ChatMessage.Role(rawValue: recovered.role) ?? .assistant,
                    text: recovered.text,
                    activities: activities,
                    author: recovered.author,
                    runID: run.id,
                    threadID: recovered.threadID
                ))
            }
        }
        if !messages.contains(where: { $0.runID == run.id && $0.role == .user }) {
            messages.append(ChatMessage(role: .user, text: run.prompt, runID: run.id))
        }

        let interruptionMessage = "Run interrupted when Cantrip exited. Its partial output, completed steps, and queue were restored."
        for message in messages where message.runID == run.id {
            for activity in message.activities {
                recordActivity(activity, messageID: message.id)
            }
        }
        recordInterruption(RunJournal.exitInterruptionReason)
        if !messages.contains(where: { $0.runID == run.id && $0.text == interruptionMessage }) {
            appendRunMessage(ChatMessage(
                role: .error,
                text: interruptionMessage,
                runID: run.id
            ))
        }
        canResume = run.mode == .single && currentRunBackend != nil
        persistTranscript()
        Log.write(
            "run-journal: restored \(run.mode.rawValue) run \(run.id.uuidString.prefix(8))"
                + " with \(run.messages.count) messages and \(queued.count) queued"
        )
    }

    private func journalActivity(_ activity: ToolActivity) -> RunJournal.Activity {
        RunJournal.Activity(
            id: activity.id,
            title: activity.title,
            toolName: activity.toolName,
            state: journalState(activity.state),
            input: activity.input,
            output: activity.output,
            fileChanges: activity.fileChanges.map {
                RunJournal.FileChange(id: $0.id, path: $0.path, diff: $0.diff)
            },
            terminalCommand: activity.terminalCommand,
            children: activity.children.map(journalActivity)
        )
    }

    private func restoredActivity(_ activity: RunJournal.Activity) -> ToolActivity {
        ToolActivity(
            id: activity.id,
            title: activity.title,
            toolName: activity.toolName,
            state: restoredActivityState(activity.state),
            input: activity.input,
            output: activity.output,
            fileChanges: activity.fileChanges.map {
                ToolFileChange(id: $0.id, path: $0.path, diff: $0.diff)
            },
            terminalCommand: activity.terminalCommand,
            children: activity.children.map(restoredActivity)
        )
    }

    private func restoredActivityState(_ state: String) -> ToolActivityState {
        switch state {
        case "succeeded": return .succeeded
        case "cancelled": return .cancelled
        case "failed": return .failed
        default: return .failed
        }
    }

    private func journalState(_ state: ToolActivityState) -> String {
        switch state {
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    func submit(_ text: String, mode: MessageDeliveryMode = .auto) {
        if mode == .auto, let request = chatInputRequest {
            do { try submitInputReply(text, id: request.id) }
            catch { deliveryStatusForInput(error.localizedDescription) }
            return
        }
        receive(text, mode: mode, includesAmbientContext: true)
    }

    func submitCantripHomeTask(
        id: UUID, title: String, scheduleSummary: String, prompt: String, note: String? = nil
    ) {
        guard isCantripHomeBackground, !isStreaming, queued.isEmpty else { return }
        // The transcript shows only a short label; the agent still receives the full saved prompt.
        let schedule = scheduleSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Run notes change every run, so they go at the end of the message with the other
        // per-run context.
        cantripHomeTask = (id, note)
        send(
            Self.cantripHomeScheduledTaskPrefix + "\(title)\n\n\(prompt)",
            displayText: Self.cantripHomeScheduledTaskPrefix + title
                + (schedule.isEmpty ? "" : "\n\(schedule) · running saved instructions"),
            preamble: """
            (This is execution of saved Cantrip Home task \(id.uuidString), not a request to
            create another task. Run it now and report the result.)
            """
        )
    }

    func submitCantripHomeIncident(id: UUID, prompt: String) -> Bool {
        guard isCantripHomeBackground else { return false }
        let marker = "[incident:\(id.uuidString.lowercased())]"
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 12_000,
              text.lowercased().contains(marker) else { return false }
        if messages.contains(where: { $0.text.lowercased().contains(marker) })
            || queued.contains(where: { $0.text.lowercased().contains(marker) }) {
            return true
        }
        // send() adds the untrusted-evidence preamble for direct and queued incidents alike.
        if isStreaming || !queued.isEmpty || shell.isRunning {
            enqueue(text, includesAmbientContext: false)
            deliveryStatus = "Queued an automated ingestion investigation."
        } else {
            send(text, includesAmbientContext: false)
        }
        return true
    }

    func submitInputReply(_ text: String, id: UUID) throws {
        let prompt = consumeStagedContext(onto: text, backendKind: runningBackendKind ?? settings.backend, consume: false)
        try respondInChat(id: id, text: prompt)
        attachments.removeAll()
        selectionContext = nil
    }

    func recordInputConversation(_ request: InputRequestSnapshot, answer: String) {
        let question = request.detail.isEmpty ? request.title : "\(request.title)\n\n\(request.detail)"
        var echo = ChatMessage(role: .assistant, text: question)
        // Same ID as the request, so its image previews keep their IDs and cached copies.
        if !messages.contains(where: { $0.id == request.id }) { echo.id = request.id }
        // The answer and what follows join the thread that asked.
        let thread = currentThreadID
        echo.threadID = thread
        appendRunMessage(echo)
        var reply = ChatMessage(role: .user, text: answer)
        reply.threadID = thread
        appendRunMessage(reply)
        appendRunMessage(ChatMessage(role: .assistant, text: ""))
        persistTranscript()
    }

    var supportsRemoteImages: Bool {
        !isLocalPrivate && settings.backend != .localModel && runningBackendKind != .localModel
    }

    /// Remote clients share the live session but must not consume context
    /// staged by the person at the Mac or capture ambient Mac data.
    func submitRemote(_ text: String, mode: MessageDeliveryMode = .auto) {
        receive(text, mode: mode, includesAmbientContext: false)
    }

    private func invalidateRouting() {
        if routingItemID != nil {
            deliveryStatus = "Queued: routing was superseded; current work was not interrupted."
        }
        routingRevision += 1
        routingTask?.cancel()
        routingTask = nil
        routingItemID = nil
    }

    /// The tool-free router for this tab's backend (Auto routing, plans, Done when checks).
    var routerProvider: MessageRouter.Provider {
        let kind = settings.backend == .localModel ? .localModel : runningBackendKind ?? settings.backend
        switch kind {
        case .copilot:
            return .copilot(command: ToolLocator.shared.copilotCommand(configured: settings.copilotPath))
        case .claudeCode:
            return .claude(command: settings.claudePath.isEmpty ? "claude" : settings.claudePath)
        case .localModel:
            return .local(baseURL: settings.localBaseURL, model: settings.localModel,
                          apiKey: settings.localAPIKey)
        case .codex, .copilotRemote, .antigravity:
            return .unavailable("this backend does not expose isolated tool-free routing; use a manual override.")
        }
    }

    private func receive(_ text: String, mode: MessageDeliveryMode, includesAmbientContext: Bool) {
        if let privateStorageError {
            tabActionError = privateStorageError
            return
        }
        var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        invalidateRouting()
        deliveryStatus = nil
        let wasBusy = isStreaming || !queued.isEmpty || autoResumePending
        if !pendingInputs.isEmpty, mode != .interrupt {
            enqueue(prompt, includesAmbientContext: includesAmbientContext)
            deliveryStatus = "Queued. Answer the input request above to continue the current task."
            return
        }
        if isLocalPrivate, mode == .auto, isStreaming {
            enqueue(prompt, includesAmbientContext: false)
            deliveryStatus = "Queued locally. Private Local never uses cloud message routing."
            return
        }
        // Bind staged attachments to this message before asynchronous routing.
        // A queued/remote send must never consume somebody else's next draft.
        if !isLocalPrivate, includesAmbientContext, wasBusy, !prompt.hasPrefix("!"), !prompt.hasPrefix("/") {
            prompt = consumeStagedContext(onto: prompt, backendKind: runningBackendKind ?? settings.backend)
        }
        if mode == .auto, isStreaming, isWaitingOnBackgroundWatchers,
           currentRunMode == .single, !councilRunning,
           !prompt.hasPrefix("!"), !prompt.hasPrefix("/"), prompt.count <= 6_000,
           activeBackend.supportsMidTurnInjection, preparationTask == nil {
            injectWhileWaitingOnWatchers(
                prompt,
                includesAmbientContext: includesAmbientContext
            )
            return
        }
        guard mode == .auto, isStreaming else {
            submit(prompt, interrupt: mode == .interrupt, inject: mode == .inject,
                   includesAmbientContext: includesAmbientContext,
                   consumesStagedContext: !wasBusy)
            return
        }
        let item = enqueue(prompt, includesAmbientContext: includesAmbientContext)
        guard currentRunMode == .single, !councilRunning,
              !prompt.hasPrefix("!"), !prompt.hasPrefix("/"), prompt.count <= 6_000 else {
            deliveryStatus = "Queued: commands, councils, and large messages run in order."
            return
        }
        let supportsInjection = activeBackend.supportsMidTurnInjection && preparationTask == nil
        let supportsParallel = supportsInjection && activeBackend.supportsParallelSubagents
        let snapshot = MessageRoutingSnapshot(
            message: text.trimmingCharacters(in: .whitespacesAndNewlines),
            currentTask: currentRunPrompt ?? "",
            recentConversation: messages.suffix(6).map {
                .init(role: $0.role.rawValue, text: $0.text)
            },
            activity: currentActivity.map {
                "\($0.toolName): \($0.title)\n\($0.terminalCommand ?? "")"
            } ?? statusText ?? "",
            pendingMessages: queued.filter { $0.id != item.id }.map(\.text),
            supportsInjection: supportsInjection
        )
        let generation = streamGeneration
        let revision = routingRevision
        let provider = routerProvider
        let originalBackend = settings.backend
        let originalWorkdir = workdir
        let originalPrivacy = isPrivate
        routingItemID = item.id
        autoDeliveredItemIDs.insert(item.id)
        deliveryStatus = "Deciding how to deliver your message..."
        routingTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.flushJournal() }
            catch {
                guard self.routingRevision == revision else { return }
                self.reportJournalFailure(error)
                self.invalidateRouting()
                self.deliveryStatus = "Queued: run history could not be saved."
                return
            }
            guard !Task.isCancelled, self.routingRevision == revision,
                  self.streamGeneration == generation else { return }
            let resolution: MessageRoutingResolution
            do {
                let decision = try await MessageRouter.classify(snapshot, provider: provider)
                resolution = MessageRoutingPolicy.resolve(
                    decision, message: snapshot.message, supportsInjection: supportsInjection,
                    supportsParallel: supportsParallel
                )
            } catch is CancellationError {
                return
            } catch {
                resolution = .queued(error.localizedDescription)
                Log.write("message-router: \(error.localizedDescription)")
            }
            guard !Task.isCancelled, self.routingRevision == revision else { return }
            self.routingTask = nil
            self.routingItemID = nil
            guard self.settings.backend == originalBackend, self.workdir == originalWorkdir,
                  self.isPrivate == originalPrivacy,
                  MessageRoutingPolicy.canApply(
                    originalGeneration: generation, currentGeneration: self.streamGeneration,
                    originalRevision: revision, currentRevision: self.routingRevision,
                    isStreaming: self.isStreaming,
                    stillQueued: self.queued.contains(where: { $0.id == item.id })
                  ) else {
                self.deliveryStatus = self.queued.contains(where: { $0.id == item.id })
                    ? "Queued: the task changed while routing; no interruption was applied."
                    : "Message no longer waiting; the late routing decision was ignored."
                return
            }
            self.deliveryStatus = resolution.explanation
            if let runID = self.currentRunID {
                var event = RunJournal.Event(sessionID: self.id, runID: runID, kind: .messageRouted)
                event.queueItemID = item.id
                event.reason = resolution.explanation
                self.appendRunEvent(event, durable: true)
            }
            switch resolution.action {
            case .queue:
                self.scheduleQueueGrouping()
                // Routing is done; auto-fork can look at it now.
                self.onQueuePlansChanged?(self)
            case .inject:
                self.injectQueued(item)
            case .parallel:
                self.injectQueued(item, parallel: true)
            case .redirect:
                self.submit(item.text, interrupt: true, inject: false,
                            includesAmbientContext: item.includesAmbientContext,
                            consumesStagedContext: false, queuedItem: item)
                self.removeQueued(item)
            case .cancel:
                self.appendRunMessage(ChatMessage(role: .user, text: item.text), queueItemID: item.id)
                self.removeQueued(item)
                self.cancel(keepQueue: true)
                self.deliveryStatus = resolution.explanation
            }
        }
    }

    private func submit(_ text: String, interrupt: Bool, inject: Bool,
                        includesAmbientContext: Bool, consumesStagedContext: Bool = true,
                        queuedItem: QueuedPrompt? = nil) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard isStreaming else {
            // Messages wait behind an interrupted run that is about to continue, unless redirected,
            // and behind a child tab's merge into this checkout (a few seconds).
            if !queued.isEmpty || (autoResumePending && !interrupt) || childMergeHold {
                enqueue(prompt, includesAmbientContext: includesAmbientContext)
                if autoResumePending {
                    deliveryStatus = "Queued: Cantrip finishes the interrupted task first."
                } else if childMergeHold {
                    deliveryStatus = "Queued: a child tab's work is merging into this tab's checkout."
                }
                drainQueue()
                return
            }
            councilMode
                ? sendCouncil(prompt, includesAmbientContext: includesAmbientContext,
                              consumesStagedContext: consumesStagedContext)
                : send(prompt, includesAmbientContext: includesAmbientContext,
                       consumesStagedContext: consumesStagedContext)
            return
        }
        if councilRunning, inject, !interrupt {
            enqueue(prompt, includesAmbientContext: includesAmbientContext)
            return
        }
        if inject, !interrupt {
            let item = enqueue(prompt, includesAmbientContext: includesAmbientContext)
            guard preparationTask == nil else {
                deliveryStatus = "Queued: context preparation is still running."
                return
            }
            injectQueued(item)
            return
        }
        if interrupt, councilRunning {
            Log.write("interrupt: redirecting in-flight council")
            streamGeneration += 1
            cancelCouncilBackends()
            activeBackend.cancel()         // chair, if synthesis had started
            councilRunning = false
            finalizeRunningActivities(as: .cancelled)
            statusText = nil
            cancelRun(reason: "redirected by user")
            finishStream(dequeue: false, notify: false, waitForJournal: false)
            councilMode
                ? sendCouncil(prompt, includesAmbientContext: includesAmbientContext,
                              consumesStagedContext: consumesStagedContext, queuedItem: queuedItem)
                : send(prompt, includesAmbientContext: includesAmbientContext,
                       consumesStagedContext: consumesStagedContext, queuedItem: queuedItem)
            return
        }
        if interrupt {
            Log.write("interrupt: redirecting in-flight request")
            streamGeneration += 1          // orphan the old stream's events
            // Prefer a graceful in-band interrupt (keeps the process and
            // session hot); fall back to killing the process.
            if !activeBackend.interruptTurn() { activeBackend.cancel() }
            shellProcess?.terminate()
            shellProcess = nil
            finalizeRunningActivities(as: .cancelled)
            statusText = nil
            // Stateless backends (Copilot, local) get a fresh process with
            // no session memory of the interrupted turn — carry its work
            // log into the redirect so partial progress isn't lost.
            // Compute BEFORE finishStream/send mutate the transcript.
            var interruptContext: String?
            if !backendKeepsSession {
                let context = [interruptedStepSummary(), interruptedUserContext()].compactMap { $0 }
                if !context.isEmpty {
                    interruptContext = "(Context — my interrupted request:\n\(context.joined(separator: "\n\n")))"
                }
            }
            cancelRun(reason: "redirected by user")
            finishStream(dequeue: false, notify: false, waitForJournal: false)
            if councilMode {
                sendCouncil(prompt, includesAmbientContext: includesAmbientContext,
                            consumesStagedContext: consumesStagedContext, queuedItem: queuedItem)
            } else {
                send(prompt, interrupted: true, preamble: interruptContext,
                     includesAmbientContext: includesAmbientContext,
                     consumesStagedContext: consumesStagedContext, queuedItem: queuedItem)
            }
        } else {
            enqueue(prompt, includesAmbientContext: includesAmbientContext)
        }
    }

    private func injectQueued(_ item: QueuedPrompt, parallel: Bool = false, sendNow: Bool = false) {
        guard activeBackend.supportsMidTurnInjection, currentRunMode == .single else {
            deliveryStatus = "Queued: the backend's live input channel is unavailable."
            return
        }
        let generation = streamGeneration
        let privacy = isPrivate
        let predecessor = injectionTask
        let wasWaiting = isWaitingOnBackgroundWatchers
        pendingInjections.insert(item.id)
        deliveryStatus = sendNow ? "Sending now..."
            : parallel ? "Saving your request before starting it..." : "Saving context before delivery..."
        injectionTask = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            var claimed = false
            var dispatched = false
            var queueIndex = 0
            defer {
                self.pendingInjections.remove(item.id)
                if self.streamGeneration == generation, self.pendingInjections.isEmpty,
                   self.deferredInjectionDone {
                    self.deferredInjectionDone = false
                    self.handle(.done)
                }
            }
            do {
                try await self.flushJournal()
                guard !Task.isCancelled, self.streamGeneration == generation,
                      self.isPrivate == privacy, self.isStreaming,
                      self.queued.contains(where: { $0.id == item.id }) else { return }
                guard self.activeBackend.supportsMidTurnInjection,
                      !parallel || self.activeBackend.supportsParallelSubagents else {
                    self.deliveryStatus = parallel
                        ? "Queued: background agents became unavailable; it runs after the current task."
                        : "Queued: the task finished before context could be sent."
                    return
                }
                // The durable message claims the queue ID before crossing the process
                // boundary. Recovery keeps the context, but cannot blindly send it twice.
                queueIndex = self.queued.firstIndex(where: { $0.id == item.id }) ?? 0
                claimed = true
                self.appendRunMessage(ChatMessage(role: .user, text: item.text), queueItemID: item.id)
                self.appendRunMessage(ChatMessage(role: .assistant, text: ""))
                self.removeQueued(item)
                self.recordInjection(item, status: "submitting")
                try await self.flushJournal()
                guard !Task.isCancelled, self.streamGeneration == generation,
                      self.isPrivate == privacy, self.isStreaming else { return }
                self.deliveryStatus = sendNow ? "Sending now..."
                    : parallel ? "Handing your request to a background agent..."
                    : "Sending context to the current task..."
                dispatched = true
                // The root takes the message now, so new messages no longer bypass the queue.
                if sendNow { self.isWaitingOnBackgroundWatchers = false }
                let text = parallel ? MessageRoutingPolicy.parallelDelivery(item.text) : item.text
                let result = await withCheckedContinuation { continuation in
                    let resume = { (result: MidTurnDelivery) in continuation.resume(returning: result) }
                    sendNow ? self.activeBackend.sendNowMidTurn(text, completion: resume)
                        : self.activeBackend.injectMidTurn(text, completion: resume)
                }
                guard self.streamGeneration == generation, self.isPrivate == privacy else { return }
                switch result {
                case .accepted(let messageID):
                    self.recordInjection(item, status: "accepted", nativeMessageID: messageID)
                    self.deliveryStatus = sendNow
                        ? self.sentNowStatus(rootWasIdle: wasWaiting)
                        : parallel ? "Running in parallel; the reply will appear in this chat."
                        : "Context accepted; it will be applied at the next opportunity."
                case .notSent:
                    self.recordInjection(item, status: "not_sent")
                    // A message sent now runs next once the task ends.
                    self.queued.insert(item, at: sendNow ? 0 : min(queueIndex, self.queued.count))
                    self.recordQueueEvent(.queueAdded, item: item)
                    if sendNow, wasWaiting, self.isStreaming { self.isWaitingOnBackgroundWatchers = true }
                    self.deliveryStatus = sendNow
                        ? "Queued: the task changed before your message could be sent; it runs next."
                        : parallel ? "Queued: the task finished before the request could start in parallel."
                        : "Queued: the task finished before context could be sent."
                case .uncertain(let message):
                    self.recordInjection(item, status: "uncertain", reason: message)
                    let notice = "\(parallel ? "Parallel request" : "Context") delivery uncertain; not resent. \(message)"
                    self.deliveryStatus = notice
                    self.appendRunMessage(ChatMessage(role: .error, text: notice))
                }
                self.persistTranscript()
                try await self.flushJournal()
            } catch {
                guard self.streamGeneration == generation else { return }
                if claimed, !dispatched, !self.queued.contains(where: { $0.id == item.id }) {
                    self.queued.insert(item, at: sendNow ? 0 : min(queueIndex, self.queued.count))
                    self.recordQueueEvent(.queueAdded, item: item)
                }
                self.reportJournalFailure(error)
                self.deliveryStatus = "Context delivery paused: run history could not be saved."
            }
        }
    }

    private func sentNowStatus(rootWasIdle: Bool) -> String {
        if rootWasIdle { return "Sent now. Background work keeps running." }
        return runningBackendKind == .copilot
            ? "Sent now. Anything the task was waiting on keeps running in the background."
            : "Sent now. It's applied as soon as the current step finishes."
    }

    private func injectWhileWaitingOnWatchers(
        _ prompt: String,
        includesAmbientContext: Bool
    ) {
        let item = QueuedPrompt(
            text: prompt,
            includesAmbientContext: includesAmbientContext
        )
        let generation = streamGeneration
        let privacy = isPrivate
        let predecessor = injectionTask
        appendRunMessage(ChatMessage(role: .user, text: prompt))
        let assistantID = appendRunMessage(ChatMessage(role: .assistant, text: ""))
        pendingInjections.insert(item.id)
        isWaitingOnBackgroundWatchers = false
        deliveryStatus = "Sending while the background task continues..."
        recordInjection(item, status: "submitting")
        injectionTask = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            var dispatched = false
            defer {
                self.pendingInjections.remove(item.id)
                if self.streamGeneration == generation, self.pendingInjections.isEmpty,
                   self.deferredInjectionDone {
                    self.deferredInjectionDone = false
                    self.handle(.done)
                }
            }
            do {
                try await self.flushJournal()
                guard !Task.isCancelled, self.streamGeneration == generation,
                      self.isPrivate == privacy, self.isStreaming else {
                    self.isWaitingOnBackgroundWatchers =
                        self.isStreaming && self.hasActiveBackgroundWatcher
                    self.markWatcherInjectionFailure(
                        assistantID,
                        "The background task state changed before this message could be sent. Send again."
                    )
                    return
                }
                dispatched = true
                let result = await withCheckedContinuation { continuation in
                    self.activeBackend.injectMidTurn(item.text) { result in
                        continuation.resume(returning: result)
                    }
                }
                guard self.streamGeneration == generation, self.isPrivate == privacy else {
                    return
                }
                switch result {
                case .accepted(let messageID):
                    self.recordInjection(
                        item,
                        status: "accepted",
                        nativeMessageID: messageID
                    )
                    self.deliveryStatus = "Sent while the background task continues."
                case .notSent:
                    self.recordInjection(item, status: "not_sent")
                    self.isWaitingOnBackgroundWatchers =
                        self.isStreaming && self.hasActiveBackgroundWatcher
                    self.markWatcherInjectionFailure(
                        assistantID,
                        "The background task is still running, but the main thread was not ready. Send again."
                    )
                case .uncertain(let message):
                    self.recordInjection(item, status: "uncertain", reason: message)
                    self.markWatcherInjectionFailure(
                        assistantID,
                        "Message delivery is uncertain; it was not resent. \(message)"
                    )
                }
                self.persistTranscript()
                try await self.flushJournal()
            } catch {
                guard self.streamGeneration == generation else {
                    self.markWatcherInjectionFailure(
                        assistantID,
                        "The run changed before this message could be confirmed."
                    )
                    return
                }
                self.reportJournalFailure(error)
                if !dispatched {
                    self.isWaitingOnBackgroundWatchers =
                        self.isStreaming && self.hasActiveBackgroundWatcher
                }
                self.markWatcherInjectionFailure(
                    assistantID,
                    "Could not send while the background task continued because run history was unavailable."
                )
            }
        }
    }

    private func markWatcherInjectionFailure(_ assistantID: UUID, _ message: String) {
        if let index = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[index].text = message
        }
        deliveryStatus = message
    }

    private func recordInjection(_ item: QueuedPrompt, status: String,
                                 nativeMessageID: String? = nil, reason: String? = nil) {
        guard let runID = currentRunID else { return }
        var event = RunJournal.Event(sessionID: id, runID: runID, kind: .steeringDelivery)
        event.queueItemID = item.id
        event.status = status
        event.nativeMessageID = nativeMessageID
        event.reason = reason
        appendRunEvent(event, durable: true)
    }

    private func send(_ text: String, displayText: String? = nil, interrupted: Bool = false,
                      preamble: String? = nil, isResume: Bool = false,
                      includesAmbientContext: Bool = true,
                      consumesStagedContext: Bool = true,
                      queuedItem: QueuedPrompt? = nil,
                      combinedItems: [QueuedPrompt] = [],
                      continuing: (runID: UUID, prompt: String)? = nil) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming else { return }
        if !isLocalPrivate, prompt == "/login github" {
            beginRun(prompt: "Sign in to GitHub on the Mac", mode: .shell, backends: ["GitHub device login"],
                     backend: nil, includesAmbientContext: false, queueItemID: queuedItem?.id)
            appendRunMessage(ChatMessage(role: .user, text: "/login github"))
            appendRunMessage(ChatMessage(role: .assistant, text: ""))
            isStreaming = true
            streamGeneration += 1
            let generation = streamGeneration
            prepareMemory(onto: "", query: "", backendKind: nil, generation: generation) { [weak self] _ in
                guard let self else { return }
                self.deviceLogin.start(workdir: self.workdir) { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.streamGeneration == generation else {
                            if case .inputRequired(let request) = event { request.cancel() }
                            return
                        }
                        self.handle(event)
                    }
                }
            }
            return
        }

        // "!" prefix: run a raw shell command directly, no LLM.
        if !isLocalPrivate, prompt.hasPrefix("!"), prompt.count > 1 {
            runShellCommand(String(prompt.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
        }

        // "/" prefix: user-defined script command (skill), no LLM.
        if !isLocalPrivate, prompt.hasPrefix("/"), prompt.count > 1 {
            let parts = String(prompt.dropFirst())
                .split(separator: " ", maxSplits: 1)
            if let first = parts.first,
               let command = CommandRegistry.shared.command(named: String(first)) {
                runScriptCommand(command,
                                 args: parts.count > 1 ? String(parts[1]) : "")
                return
            }
            // Unknown /command falls through to the LLM.
        }

        // Backend commands Cantrip handles itself (/model on Copilot, /clear on Claude) or that
        // would bypass Cantrip or break remotely (see BackendCommandPolicy): never sent on.
        if !isLocalPrivate, let invocation = SlashInvocation(prompt),
           let family = BackendCommandCatalog.family(for: effectiveBackendKind),
           let rule = BackendCommandPolicy.rule(
               family: family, name: invocation.name,
               discovered: BackendCommandCatalog.shared.cachedList(for: self)?.command(named: invocation.name)) {
            Log.write("command: /\(invocation.name) handled by Cantrip (\(rule.availability.rawValue))")
            // This command's own queue entry must not count as "queued work" below.
            if let queuedItem { removeQueued(queuedItem) }
            if rule.action == "startFresh", (try? startFresh()) != nil { return }
            let reply: String
            switch rule.action {
            case "modelSettings": reply = modelCommandReply(invocation.input)
            case "startFresh": reply = startFreshUnavailableReason ?? "This tab couldn't start fresh."
            default: reply = "`/\(invocation.name)` doesn't run from Cantrip. \(rule.note)"
            }
            appendLocalExchange(prompt: prompt, reply: reply)
            return
        }

        // Instant answers: math, unit conversion, app launch — no LLM.
        if !isLocalPrivate, selectionContext == nil, let instant = InstantAnswers.answer(for: prompt) {
            Log.write("instant: \"\(prompt.prefix(60))\"")
            appendLocalExchange(prompt: prompt, reply: instant)
            return
        }

        var preamble = preamble
        var includesAmbientContext = includesAmbientContext
        let automatedRun = isCantripHomeBackground && !isResume
            ? Self.cantripHomeAutomatedRun(for: prompt) : nil
        // Child tabs' status, replies to this tab's questions to other tabs and the tabs this
        // message @mentions: short lines; the model reads a tab's conversation itself when it
        // needs more (TabInsight, TabMentions).
        if !isLocalPrivate, !isPrivate, !isResume, automatedRun == nil, !isCantripHomeBackground,
           SlashInvocation(prompt) == nil, let notes = Self.tabContextProvider?(self, prompt) {
            preamble = notes + (preamble.map { "\n\n" + $0 } ?? "")
        }
        if isCantripHomeBackground, !isResume { cantripHomeRunLabel = automatedRun?.label }
        if let automatedRun {
            preamble = preamble ?? automatedRun.preamble
            if automatedRun.isIncident { includesAmbientContext = false }
            // Each scheduled task or incident starts from a clean model context; the
            // transcript remains as the background log.
            if automatedRun.isIncident { cantripHomeTask = nil }
            applyModelSelection()
            if let backend = copilot as? CopilotBackend {
                CantripHomeTaskTools.configure(backend, taskRun: cantripHomeTask != nil)
            }
            resetBackendConversations()
        }

        var backendKind = isLocalPrivate ? .localModel
            : isResume ? (currentRunBackend ?? settings.backend) : settings.backend
        // The chosen backend is still at its usage limit: start on the fallback instead of failing first.
        var limitNotice: String?
        if !isLocalPrivate, !isResume, let until = BackendLimitTracker.shared.limitedUntil(backendKind),
           let fallback = BackendFallback.target(for: backendKind, configured: settings.limitFallbackBackend,
                                                 homeRun: isCantripHomeRun) {
            limitNotice = "\(backendKind.rawValue) is at its usage limit until \(BackendFallback.untilLabel(until))."
                + " Using \(settings.backendLabel(fallback))."
            backendKind = fallback
        }
        if !isLocalPrivate { Log.write("send: \"\(prompt.prefix(80))\" via \(backendKind.rawValue)") }
        canResume = false
        if !isResume {
            // Fresh run: remember the prompt so an interrupted run can be
            // resumed, and re-arm the one free automatic resume.
            // A Continue run keeps the failed run's request, so it can be continued in turn.
            beginRun(
                prompt: continuing?.prompt ?? prompt,
                mode: .single,
                backends: [settings.backendLabel(backendKind)],
                backend: backendKind,
                includesAmbientContext: includesAmbientContext,
                queueItemID: queuedItem?.id,
                additionalQueueItemIDs: combinedItems.map(\.id)
            )
            currentRunPrompt = continuing?.prompt ?? prompt
            currentRunIncludesAmbientContext = includesAmbientContext
            autoResumeSpent = false
            cantripHomeCorrectionSpent = false
            cantripHomeCorrection = nil
            cantripHomeHeldFailures = []
        }
        runningBackendKind = backendKind
        let isFirstOfConversation = messages.isEmpty && automatedRun == nil
        let previousTurns = automatedRun == nil ? completedConversationTurns() : []
        if automaticTitle == "New chat" { automaticTitle = String(TabMentions.plain(prompt).prefix(34)) }
        // A combined turn shows each queued message as the user wrote it, in one run.
        var shownTexts = [displayText ?? prompt]
        if let queuedItem, !combinedItems.isEmpty {
            shownTexts = ([queuedItem] + combinedItems).map(\.text)
        }
        for shown in shownTexts {
            var message = ChatMessage(role: .user, text: shown)
            message.continuesRunID = continuing?.runID
            promptUsageMessageID = appendRunMessage(message)
        }
        appendRunMessage(ChatMessage(role: .assistant, text: ""))
        isStreaming = true
        statusText = "Thinking…"
        if let limitNotice { deliveryStatus = limitNotice }
        if let automatedRun, let runID = currentRunID {
            onCantripHomeRunStarted?(runID, automatedRun)
        }

        // Attach context (shown to the backend, not in the UI). A slash command goes to the
        // backend exactly as typed: anything appended would become the command's argument.
        let isSlashCommand = !isLocalPrivate && SlashInvocation(prompt) != nil
        var backendPrompt = prompt
        var taskHead: String?
        // Attended Home on a backend that keeps Home's protocol in its system instructions sends
        // only this turn's data with each message.
        let homeCarrier = isCantripHome && !councilMode
            ? backend(for: backendKind) as? CantripHomeProtocolCarrier : nil
        if isCantripHome {
            (copilot as? CantripHomeProtocolCarrier)?.homeProtocol = nil
            claudeCode.homeProtocol = nil
        }
        homeCarrier?.homeProtocol = cantripHomeChatProtocol
        if !isSlashCommand, automatedRun?.isIncident == false, let run = cantripHomeTask,
           let task = CantripHomeStore.shared.tasks.first(where: { $0.id == run.id }) {
            // Static protocol, then memory, then this task, then everything that changes per run.
            writeCantripHomeTaskTabs()
            taskHead = cantripHomeTaskStaticInstructions
                .trimmingCharacters(in: .newlines)
            let ambient = composeContext(onto: "", query: prompt, isFirstOfConversation: false,
                                         backendKind: backendKind,
                                         includesAmbientContext: includesAmbientContext,
                                         consumesStagedContext: consumesStagedContext,
                                         includesHomeInstructions: false)
            backendPrompt = "\n\n" + (preamble.map { $0 + "\n\n" } ?? "") + prompt
                + CantripHomeTaskContext.workspaceData(for: task, in: CantripHomeStore.shared.tasks)
                + (run.note.map { "\n\n" + $0 } ?? "") + ambient
        } else if !isSlashCommand {
            if let preamble {
                backendPrompt = preamble + "\n\n" + backendPrompt
            }
            if interrupted {
                backendPrompt = "(I interrupted your previous in-progress response — treat this message as a course correction or update to that task, not a brand-new topic.) " + backendPrompt
            }
            backendPrompt = composeContext(onto: backendPrompt, query: prompt,
                                           isFirstOfConversation: isFirstOfConversation,
                                           backendKind: backendKind,
                                           includesAmbientContext: includesAmbientContext,
                                           consumesStagedContext: consumesStagedContext,
                                           compactHome: homeCarrier != nil)
        }

        UsageTracker.shared.recordQuery(backend: backendKind)
        armWatchdog()
        streamGeneration += 1
        let generation = streamGeneration
        prepareMemory(onto: backendPrompt, query: prompt, backendKind: backendKind,
                      generation: generation, includeMemory: !isSlashCommand,
                      taskHead: taskHead) { [weak self] prepared in
            guard let self else { return }
            if self.isLocalPrivate {
                do {
                    let configuration = try self.privateLocalConfiguration()
                    try configuration.validate()
                    self.privateLocalModel.configuration = configuration
                } catch {
                    self.handle(.failure(error.localizedDescription))
                    return
                }
            }
            let request = BackendRequest(
                prompt: prepared,
                userMessage: prompt,
                previousTurns: previousTurns
            )
            if self.isCantripHomeRun, [.codex, .copilotRemote].contains(backendKind) {
                // Fail closed: an unattended run needs a backend Cantrip can check per action.
                self.handle(.failure(
                    "Cantrip Home background runs need Copilot, Claude Code or a local model so Cantrip "
                        + "can check each action before it runs. Codex and Copilot Remote can't be checked "
                        + "per command; choose another backend to run scheduled tasks and incidents."
                ))
                return
            }
            let backend = self.backend(for: backendKind)
            (backend as? CantripHomeGuardedBackend)?.guardrailLabel = self.notificationTitle
            backend.send(request, workdir: self.workdir) { [weak self] event in
                DispatchQueue.main.async {
                    guard let self, self.streamGeneration == generation else {
                        if case .inputRequired(let request) = event { request.cancel() }
                        return
                    }
                    self.handle(event)
                }
            }
        }
    }

    /// With `taskHead`, memory goes between that static head and `prompt`, and retrieved
    /// snippets go last, so a scheduled-task run's message starts with a shared prefix.
    private func prepareMemory(onto prompt: String, query: String, backendKind: BackendKind?,
                               generation: Int, includeMemory: Bool = true, taskHead: String? = nil,
                               completion: @escaping (String) -> Void) {
        let memoryEnabled = settings.memoryEnabled && !isLocalPrivate && includeMemory
        let path = settings.memoryPath
        let privacy = isPrivate
        let directory = workdir
        let configuredBackend = settings.backend
        statusText = "Preparing context..."
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.flushJournal() }
            catch {
                guard self.streamGeneration == generation else { return }
                self.reportJournalFailure(error)
                self.finishStream(dequeue: false, notify: false, waitForJournal: false)
                return
            }
            var block = ""
            var parts = (stable: "", retrieved: "")
            if memoryEnabled, taskHead != nil {
                parts = await MemoryStore.contextParts(query: query, path: path)
            } else if memoryEnabled {
                block = await MemoryStore.contextBlock(
                    query: query, path: path, isPrivate: privacy, isLocal: backendKind == .localModel
                )
            }
            guard !Task.isCancelled, self.streamGeneration == generation,
                  self.isStreaming else { return }
            self.preparationTask = nil
            guard self.isPrivate == privacy, self.workdir == directory,
                  (self.isLocalPrivate || self.settings.backend == configuredBackend),
                  (self.isLocalPrivate || (self.settings.memoryEnabled && includeMemory) == memoryEnabled),
                  self.settings.memoryPath == path else {
                self.cancel(keepQueue: true)
                self.deliveryStatus = "Preparation cancelled because session settings changed. Send again to use the new settings."
                return
            }
            self.statusText = "Thinking…"
            if let taskHead {
                completion(taskHead + parts.stable + prompt + parts.retrieved)
            } else {
                completion(prompt + block)
            }
        }
    }

    /// Everything Cantrip knows that the model should too: continuity
    /// digest, location, file RAG, calendar, grabbed selection,
    /// attachments, screenshots, and the memory-vault protocol. Consumes
    /// per-turn state (selection, attachments) — call exactly once per
    /// user turn, and share the result between council members.
    private func composeContext(onto prompt: String, query: String,
                                isFirstOfConversation: Bool,
                                backendKind: BackendKind?,
                                includesAmbientContext: Bool = true,
                                consumesStagedContext: Bool = true,
                                includesHomeInstructions: Bool = true,
                                compactHome: Bool = false) -> String {
        if isLocalPrivate { return prompt }
        var backendPrompt = prompt
        if includesHomeInstructions, isCantripHome || isCantripHomeBackground {
            // A task run's later turns (a resume) repeat only the shared task protocol.
            backendPrompt += isCantripHomeBackground && cantripHomeTask != nil
                ? cantripHomeTaskStaticInstructions
                : compactHome ? cantripHomeChatTurnContext(query: query) : cantripHomeInstructions
        }
        if isFirstOfConversation,
           let digest = UserDefaults.standard.string(forKey: "lastConversationDigest"),
           !digest.isEmpty {
            backendPrompt += "\n\n(Context — summary of my previous conversation, for continuity: \(digest))"
        }
        if includesAmbientContext, settings.shareLocation,
           let location = LocationProvider.shared.contextLine {
            backendPrompt += "\n\n(Context: my current location is \(location), local time \(Date().formatted(date: .abbreviated, time: .shortened)). Use this if relevant to my request; otherwise ignore it and don't mention it.)"
        }
        if includesAmbientContext, settings.fileRAGEnabled,
           let files = FileRAG.shared.injection() {
            backendPrompt += "\n\n(FILES — content excerpts from documents on my disk that match this query, found via the Spotlight index:\n\(files)\nUse them if relevant — you may open the full file at its path for more context. If they're unrelated to my request, ignore them and don't mention them.)"
        }
        if includesAmbientContext, settings.shareCalendar,
           let agenda = CalendarProvider.shared.contextLine {
            backendPrompt += "\n\n(Context — my calendar for the next 48 hours:\n\(agenda.prefix(1500))\nUse this if relevant to my request; otherwise ignore it and don't mention it.)"
        }
        if includesAmbientContext, consumesStagedContext {
            backendPrompt = consumeStagedContext(onto: backendPrompt, backendKind: backendKind)
        }
        if includesAmbientContext {
            SpeechSynth.shared.stop()
            OverlayController.shared.clear()
        }
        if includesAmbientContext, settings.attachScreen, backendKind != .localModel,
           !ScreenCapture.shared.lastCaptures.isEmpty {
            let captures = ScreenCapture.shared.lastCaptures
            let list = captures.map { capture in
                "display \(capture.index)\(capture.isMain ? " (main)" : "") — \(capture.path)"
            }.joined(separator: "; ")
            backendPrompt += """


            (Context: screenshots of \(captures.count == 1 ? "my screen" : "ALL my displays"), taken just before I asked this: \(list). View whichever image(s) help answer my request — e.g. questions about what I'm working on or what's on my screen. If I have multiple displays, check the others too before saying something isn't visible.

            IMPORTANT — on-screen tooltips: if you are teaching me where to click or look in the UI visible in that screenshot, you MUST first view the screenshot image, then end your reply with a fenced code block whose language tag is exactly `overlay`, like this:

            ```overlay
            [{"x":0.42,"y":0.13,"label":"Crossfader"},{"x":0.66,"y":0.31,"label":"LOOP button","display":2}]
            ```

            x/y are fractions 0–1 of that screenshot's width/height (origin top-left), centered on the exact UI element; "display" is the screenshot's display number (omit for display 1); up to 5 entries; labels under 8 words. My launcher renders this block as numbered tooltips floating directly on my real screen, so refer to them by number (1, 2, …) in your text. NEVER describe tooltips in prose or write "Tooltip:" text — the block is the only way they appear. If the relevant app isn't visible in the screenshot, say so instead of guessing coordinates.)
            """
        }
        return backendPrompt
    }

    private func consumeStagedContext(onto prompt: String, backendKind: BackendKind?, consume: Bool = true) -> String {
        var result = prompt
        if let selection = selectionContext {
            result += "\n\n(Selected text from \(selection.appName), which my request refers to:\n\"\"\"\n\(selection.text.prefix(4000))\n\"\"\")"
            if consume { selectionContext = nil }
        }
        for key in mcpAppContext.keys.sorted() {
            guard let entry = mcpAppContext[key] else { continue }
            result += "\n\n(Context from the \(entry.server) app view shown in this chat, which my request may refer to:\n\(entry.text)\n)"
        }
        if consume { mcpAppContext.removeAll() }
        if backendKind != .localModel {
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg"]
            for path in attachments {
                let isImage = imageExts.contains((path as NSString).pathExtension.lowercased())
                result += isImage
                    ? "\n\n(Attached image: \(path) — view this image file; it is part of my request.)"
                    : "\n\n(Attached file: \(path) — read/analyze this file; it is part of my request.)"
            }
        }
        if consume { attachments.removeAll() }
        return result
    }

    // MARK: - Council mode (multi-model orchestration)

    /// Fan the prompt out to every council seat in parallel — each seat
    /// is its own backend instance with its own model and scratch session,
    /// so the same backend can hold multiple seats (e.g. two Copilot
    /// models). When every answer is in, the session's own backend chairs
    /// a synthesis round and delivers the joint verdict.
    private var councilInstances: [String: Backend] = [:]

    private func councilBackend(index: Int, member: CouncilMember) -> Backend {
        let key = "\(index)|\(member.id)"
        if let existing = councilInstances[key] { return existing }
        let fresh: Backend
        switch member.kind ?? .claudeCode {
        case .claudeCode:
            let b = ClaudeCodeBackend(persistKey: TabDefaults.councilClaude(id, seat: index, model: member.model))
            b.modelOverride = member.model.isEmpty ? nil : member.model
            b.readOnly = true   // advisors deliberate; only the worker executes
            fresh = b
        case .copilot:
            let b = CopilotBackend()
            b.modelOverride = member.model.isEmpty ? nil : member.model
            b.readOnly = true
            fresh = b
        case .copilotRemote:
            let b = CopilotACPBackend()
            // No per-session model override in ACP; readOnly makes the
            // seat decline every tool-permission request instead.
            b.readOnly = true
            fresh = b
        case .codex:
            let b = CodexBackend(persistKey: TabDefaults.councilCodex(id, seat: index, model: member.model))
            b.modelOverride = member.model.isEmpty ? nil : member.model
            b.readOnly = true
            fresh = b
        case .antigravity:
            fresh = AntigravityBackend(
                persistKey: TabDefaults.councilAntigravity(id, seat: index, model: member.model),
                readOnly: true,
                modelOverride: member.model.isEmpty ? nil : member.model
            )
        case .localModel:
            let b = OpenAICompatibleBackend()
            b.modelOverride = member.model.isEmpty ? nil : member.model
            b.readOnly = true
            fresh = b
        }
        councilInstances[key] = fresh
        return fresh
    }

    private func cancelCouncilBackends() {
        for backend in councilInstances.values { backend.cancel() }
    }

    private func sendCouncil(
        _ text: String,
        includesAmbientContext: Bool = true,
        consumesStagedContext: Bool = true,
        queuedItem: QueuedPrompt? = nil
    ) {
        if isLocalPrivate {
            send(text, includesAmbientContext: false, consumesStagedContext: false, queuedItem: queuedItem)
            return
        }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming else { return }
        // Shell/skill/instant prompts don't need a council.
        if prompt.hasPrefix("!") || prompt.hasPrefix("/")
            || (selectionContext == nil && InstantAnswers.answer(for: prompt) != nil) {
            send(
                prompt,
                includesAmbientContext: includesAmbientContext,
                consumesStagedContext: consumesStagedContext,
                queuedItem: queuedItem
            )
            return
        }
        // Councils are for planning and review — implementation is one
        // worker's job, and N models implementing in parallel is waste.
        if settings.councilScope == "planReview", Self.looksLikeExecution(prompt) {
            Log.write("council: execution prompt — routed to the worker (\(settings.backend.rawValue))")
            send(
                prompt,
                includesAmbientContext: includesAmbientContext,
                consumesStagedContext: consumesStagedContext,
                queuedItem: queuedItem
            )
            return
        }
        let members = settings.councilMembers.filter { $0.kind != nil }
        guard members.count >= 2 else {
            send(
                prompt,
                includesAmbientContext: includesAmbientContext,
                consumesStagedContext: consumesStagedContext,
                queuedItem: queuedItem
            )
            return
        }

        // Seats removed/reordered since the last round: kill their live
        // backend processes so nothing leaks.
        let activeKeys = Set(members.enumerated().map { "\($0.offset)|\($0.element.id)" })
        for (key, backend) in councilInstances where !activeKeys.contains(key) {
            backend.cancel()
            councilInstances.removeValue(forKey: key)
        }

        Log.write("council: \(members.map(\.label).joined(separator: " + ")) → \"\(prompt.prefix(60))\"")
        canResume = false
        currentRunPrompt = nil   // council rounds aren't single-backend resumable
        beginRun(
            prompt: prompt,
            mode: .council,
            backends: members.map(\.label) + ["Chair: \(settings.backend.rawValue)"],
            backend: nil,
            includesAmbientContext: includesAmbientContext,
            queueItemID: queuedItem?.id
        )
        let isFirstOfConversation = messages.isEmpty
        let previousTurns = completedConversationTurns()
        if automaticTitle == "New chat" { automaticTitle = String(TabMentions.plain(prompt).prefix(34)) }
        appendRunMessage(ChatMessage(role: .user, text: prompt))
        isStreaming = true
        councilRunning = true
        councilAnswers = []
        councilFinished = []
        councilSynthesizing = false
        statusText = "Council of \(members.count) deliberating…"

        let composed = composeContext(onto: prompt, query: prompt,
                                      isFirstOfConversation: isFirstOfConversation,
                                      backendKind: nil,
                                      includesAmbientContext: includesAmbientContext,
                                      consumesStagedContext: consumesStagedContext)
        let councilInstructions = """


        (You are one of \(members.count) AI advisors — \(members.map(\.label).joined(separator: ", ")) — \
        each answering this same request independently and in parallel. This is a \
        READ-ONLY deliberation: analyze, plan, or review. If you have read-only \
        tools, you may inspect files and state; if tools are unavailable, reason \
        from the provided context without complaining about it. Do NOT modify \
        anything or run commands with side effects; a single worker implements \
        later, after the chair's verdict. Give your OWN best, complete answer; \
        be substantive and take positions rather than hedging.)
        """

        armWatchdog()
        streamGeneration += 1
        let generation = streamGeneration

        prepareMemory(onto: composed, query: prompt, backendKind: nil,
                      generation: generation) { [weak self] prepared in
            guard let self else { return }
            self.statusText = "Council of \(members.count) deliberating…"
            for (index, member) in members.enumerated() {
                let message = ChatMessage(role: .assistant, text: "", author: member.label)
                let messageID = message.id
                self.appendRunMessage(message)
                self.councilAnswers.append((kind: member.kind ?? .claudeCode, messageID: messageID))
                if let kind = member.kind { UsageTracker.shared.recordQuery(backend: kind) }
                let request = BackendRequest(prompt: prepared + councilInstructions, userMessage: prompt,
                                             previousTurns: previousTurns)
                self.councilBackend(index: index, member: member)
                    .send(request, workdir: self.workdir) { [weak self] event in
                        DispatchQueue.main.async {
                            guard let self, self.streamGeneration == generation else { return }
                            self.handleCouncilEvent(event, messageID: messageID,
                                                    prompt: prompt, generation: generation)
                        }
                    }
            }
        }
    }

    private func handleCouncilEvent(_ event: BackendEvent, messageID: UUID,
                                    prompt: String, generation: Int) {
        armWatchdog()
        switch event {
        case .inputRequired(let request):
            request.cancel()
        case .textDelta(let delta):
            appendCouncil(text: delta, to: messageID)
            recordOutput(delta, messageID: messageID)
        case .thinkingDelta(let delta):
            appendCouncil(thinking: delta, to: messageID)
        case .status:
            break // council status is the X/N counter, not per-member
        case .activity(let activity):
            if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                if let aIdx = messages[idx].activities.firstIndex(where: { $0.id == activity.id }) {
                    messages[idx].activities[aIdx] = activity
                } else {
                    messages[idx].activities.append(activity)
                }
                attachApp(from: activity, toMessageAt: idx)
                shell.mirror(activity)
                recordActivity(activity, messageID: messageID)
            }
        case .usage(let usage):
            recordUsage(usage)
        case .context, .backgroundWake, .usageLimit:
            break // several models share the prompt
        case .approval(let approval):
            recordApproval(approval)
        case .done:
            councilMemberFinished(messageID: messageID, prompt: prompt)
        case .failure(let message):
            appendCouncil(text: "\n\n_(this advisor failed: \(message.prefix(300)))_",
                          to: messageID)
            councilMemberFinished(messageID: messageID, prompt: prompt)
        }
    }

    private func appendCouncil(text: String? = nil, thinking: String? = nil, to id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        if let text { messages[idx].text += text }
        if let thinking { messages[idx].appendThinking(thinking) }
    }

    private func councilMemberFinished(messageID: UUID, prompt: String) {
        // Set-based dedup: a backend can emit several terminal events for
        // one run (e.g. a stream error followed by process exit).
        guard councilFinished.insert(messageID).inserted else { return }
        let total = councilAnswers.count
        statusText = "Council: \(councilFinished.count)/\(total) answered…"
        guard councilFinished.count >= total, !councilSynthesizing else { return }
        councilSynthesizing = true
        startSynthesis(prompt: prompt)
    }

    private func startSynthesis(prompt: String) {
        // New generation: orphans any straggler events from the member
        // round (late duplicate terminals, lingering processes).
        streamGeneration += 1
        let generation = streamGeneration
        let answers: [(label: String, text: String)] = councilAnswers.compactMap { entry in
            guard let message = messages.first(where: { $0.id == entry.messageID }) else { return nil }
            return (message.author ?? entry.kind.rawValue, message.text)
        }
        let chairLabel = settings.backendLabel(settings.backend)
        statusText = "Chair (\(chairLabel)) synthesizing…"
        var message = ChatMessage(role: .assistant, text: "")
        message.author = "Verdict · \(chairLabel)"
        let messageID = message.id
        appendRunMessage(message)

        var synthesisPrompt = """
        (COUNCIL SYNTHESIS — you are the chair. The user asked:
        "\(prompt.prefix(2000))"

        \(answers.count) AI advisors answered independently. Produce the council's \
        joint, conclusive answer, matched to the kind of task: for a decision, plan, \
        or review — state points where the advisors agree as settled; where they \
        disagree, adjudicate explicitly and justify the call; end with one clear \
        recommendation. For research or investigation — merge the findings into one \
        comprehensive picture: combine complementary discoveries, flag facts the \
        advisors contradict each other on (say which said what), and preserve unique \
        findings noting which advisor surfaced them. Either way, do NOT summarize \
        each answer in turn — deliver one unified result. If one of the answers is \
        your own, give it no special weight. Do NOT start implementing anything — \
        deliver the verdict; implementation happens separately when the user says \
        to proceed.
        """
        for answer in answers {
            synthesisPrompt += "\n\n=== ANSWER from \(answer.label) ===\n\(answer.text.prefix(8000))"
        }
        synthesisPrompt += "\n)"

        UsageTracker.shared.recordQuery(backend: settings.backend)
        let request = BackendRequest(prompt: synthesisPrompt, userMessage: prompt,
                                     previousTurns: [])
        activeBackend.send(request, workdir: workdir) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.streamGeneration == generation else { return }
                self.armWatchdog()
                switch event {
                case .inputRequired(let request):
                    self.receiveInput(request)
                case .textDelta(let delta):
                    self.appendCouncil(text: delta, to: messageID)
                    self.recordOutput(delta, messageID: messageID)
                case .thinkingDelta(let delta):
                    self.appendCouncil(thinking: delta, to: messageID)
                case .status:
                    break
                case .activity(let activity):
                    if let idx = self.messages.firstIndex(where: { $0.id == messageID }) {
                        if let aIdx = self.messages[idx].activities.firstIndex(
                            where: { $0.id == activity.id }) {
                            self.messages[idx].activities[aIdx] = activity
                        } else {
                            self.messages[idx].activities.append(activity)
                        }
                        self.attachApp(from: activity, toMessageAt: idx)
                        self.shell.mirror(activity)
                        self.recordActivity(activity, messageID: messageID)
                    }
                case .usage(let usage):
                    self.recordUsage(usage)
                case .context, .backgroundWake, .usageLimit:
                    break
                case .approval(let approval):
                    self.recordApproval(approval)
                case .done:
                    self.streamGeneration += 1 // orphan chair double-terminals
                    self.councilRunning = false
                    self.finalizeRunningActivities(as: .succeeded)
                    let summary = self.messages.first(where: { $0.id == messageID })?.text ?? ""
                    self.completeRun(status: "succeeded", summary: summary)
                    self.finishStream()
                case .failure(let message):
                    self.streamGeneration += 1
                    self.councilRunning = false
                    self.appendRunMessage(ChatMessage(
                        role: .error,
                        text: "Synthesis failed: \(message)"
                    ))
                    self.completeRun(status: "failed", summary: message)
                    self.finishStream()
                }
            }
        }
    }

    /// Councils deliberate; workers execute. Route obvious execution
    /// prompts straight to the worker so N advisors don't burn tokens
    /// re-planning something already decided. Review/planning wording
    /// wins over execution wording when both appear.
    static func looksLikeExecution(_ prompt: String) -> Bool {
        let p = prompt.lowercased()
        // Whole-word matching — "commit" must not match "committee",
        // "push" not "pushback", "go" not "good idea?".
        func hasWord(_ needle: String) -> Bool {
            p.range(of: "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b",
                    options: .regularExpression) != nil
        }
        // A prompt that OPENS with an execution verb is a go-signal even
        // when it mentions "the plan" ("implement the plan").
        let strongStarts = ["implement", "go ahead", "proceed", "apply ",
                            "build ", "execute", "ship "]
        if strongStarts.contains(where: p.hasPrefix) { return true }
        let deliberation = ["review", "plan", "planning", "compare", "should",
                            "what do you think", "opinion", "evaluate", "assess",
                            "critique", "pros and cons", "which approach",
                            "design", "how would", "what's the best", "discuss",
                            "audit", "look over", "thoughts", "risk", "tradeoff",
                            // Research is deliberation: parallel seats
                            // surface different findings to compare.
                            "research", "investigate", "explore", "look into",
                            "dig into", "find out", "learn about", "read up",
                            "summarize", "explain", "understand"]
        if deliberation.contains(where: hasWord) { return false }
        // Questions are deliberation by nature.
        if p.hasSuffix("?") { return false }
        let execution = ["implement", "go ahead", "proceed", "do it", "apply",
                         "make the change", "make those changes", "build it",
                         "fix it", "ship it", "execute", "write the code",
                         "commit", "push", "run it", "rebuild", "refactor",
                         "add the", "create the", "update the", "delete the"]
        if execution.contains(where: hasWord) { return true }
        // Short whole-phrase affirmatives right after a verdict are
        // go-signals ("yes", "ok do that", "sounds good").
        if p.count < 25 {
            let trimmed = p.trimmingCharacters(in: CharacterSet(charactersIn: " .!,"))
            let affirmatives = ["yes", "ok", "okay", "sure", "sounds good",
                                "lgtm", "approved", "go", "go for it", "do that"]
            if affirmatives.contains(trimmed) { return true }
            if affirmatives.contains(where: { trimmed.hasPrefix($0 + " ") || trimmed.hasPrefix($0 + ",") }) {
                return true
            }
        }
        return false
    }

    private func completedConversationTurns() -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var pendingUser: String?
        var previous: ChatMessage?
        for message in messages {
            // Result cards hold tab output for the user, not Home's own words.
            if message.role == .handoff { continue }
            defer { previous = message }
            switch message.role {
            case .user:
                // Queued messages combined into one run are one turn.
                if let pending = pendingUser, let runID = message.runID,
                   previous?.role == .user, previous?.runID == runID {
                    pendingUser = pending + "\n\n" + message.text
                } else {
                    pendingUser = message.text
                }
            case .assistant:
                guard let user = pendingUser, !message.text.isEmpty else { continue }
                // Council rounds put several assistant messages after one
                // user turn: individual seat answers (author set) stay out
                // of history — the chair's Verdict IS the turn's answer.
                if let author = message.author, !author.hasPrefix("Verdict") { continue }
                turns.append(ConversationTurn(user: user, assistant: message.text))
                pendingUser = nil
            case .error:
                pendingUser = nil
            case .freshStart:
                // Start Fresh: nothing above the divider reaches the model.
                turns.removeAll()
                pendingUser = nil
            case .handoff:
                continue
            }
        }
        return turns
    }

    /// The user's words for the turn whose last user message is at `index`: queued messages
    /// combined into one run are consecutive user messages sharing its run ID.
    func turnUserText(endingAt index: Int) -> String {
        var texts = [messages[index].text]
        guard let runID = messages[index].runID else { return texts[0] }
        var probe = index - 1
        while probe >= 0 {
            let message = messages[probe]
            probe -= 1
            if message.role == .handoff { continue }
            guard message.role == .user, message.runID == runID else { break }
            texts.insert(message.text, at: 0)
        }
        return texts.joined(separator: "\n\n")
    }

    private var shellProcess: Process?
    private var shellAskpass: RemoteAskpass?

    /// `!command` — run directly via the login shell, streaming output
    /// into the transcript as a code block.
    private func runShellCommand(_ command: String) {
        guard !command.isEmpty, !isStreaming else { return }
        Log.write("shell: \(command.prefix(100))")
        canResume = false
        currentRunPrompt = nil // shell runs aren't LLM-resumable
        beginRun(
            prompt: "! " + command,
            mode: .shell,
            backends: ["Shell"],
            backend: nil,
            includesAmbientContext: false
        )
        if automaticTitle == "New chat" { automaticTitle = "! " + String(command.prefix(30)) }
        appendRunMessage(ChatMessage(role: .user, text: "! " + command))
        let assistantID = appendRunMessage(ChatMessage(role: .assistant, text: "```\n"))
        isStreaming = true
        statusText = "Running: \(command.prefix(40))…"
        armWatchdog()
        streamGeneration += 1
        let generation = streamGeneration

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: workdir)
        p.standardInput = FileHandle.nullDevice
        do {
            let broker = try RemoteAskpass(process: p) { [weak self] request in
                Task { @MainActor in
                    guard let self, self.streamGeneration == generation else { request.cancel(); return }
                    self.receiveInput(request)
                }
            }
            p.environment = ProcessInfo.processInfo.environment.merging(broker.environment) { _, new in new }
            shellAskpass = broker
        } catch {
            handleRunInterruption(errorText: "Could not prepare secure command input. The command was not started.")
            return
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self, self.streamGeneration == generation else { return }
                self.armWatchdog()
                if let idx = self.messages.lastIndex(where: { $0.role == .assistant }) {
                    // Keep runaway output bounded in the transcript.
                    if self.messages[idx].text.count < 30_000 {
                        self.messages[idx].text += chunk
                        self.recordOutput(chunk, messageID: assistantID)
                    }
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.streamGeneration == generation else { return }
                if let idx = self.messages.lastIndex(where: { $0.role == .assistant }) {
                    var text = self.messages[idx].text
                    var suffix = ""
                    if text == "```\n" { suffix += "(no output)\n" }
                    suffix += "\n```"
                    if proc.terminationStatus != 0 {
                        suffix += "\nexit \(proc.terminationStatus)"
                    }
                    text += suffix
                    self.messages[idx].text = text
                    self.recordOutput(suffix, messageID: assistantID)
                }
                self.shellProcess = nil
                self.shellAskpass?.stop()
                self.shellAskpass = nil
                let summary = self.messages.last(where: { $0.role == .assistant })?.text ?? ""
                self.completeRun(
                    status: proc.terminationStatus == 0 ? "succeeded" : "failed",
                    summary: summary
                )
                self.finishStream()
            }
        }

        startJournaledProcess(p, output: pipe.fileHandleForReading, generation: generation,
                              failurePrefix: "Failed to run")
    }

    /// `/name args` — run a skill script, streaming stdout into the
    /// transcript as markdown (skills are expected to emit markdown).
    private func runScriptCommand(_ command: ScriptCommand, args: String) {
        guard !isStreaming else { return }
        Log.write("skill: /\(command.name) \(args.prefix(60))")
        canResume = false
        currentRunPrompt = nil // script runs aren't LLM-resumable
        let displayPrompt = "/\(command.name)\(args.isEmpty ? "" : " \(args)")"
        beginRun(
            prompt: displayPrompt,
            mode: .script,
            backends: ["Skill: /\(command.name)"],
            backend: nil,
            includesAmbientContext: false
        )
        if automaticTitle == "New chat" { automaticTitle = "/" + command.name }
        appendRunMessage(ChatMessage(role: .user, text: displayPrompt))
        let assistantID = appendRunMessage(ChatMessage(role: .assistant, text: ""))
        isStreaming = true
        statusText = "Running /\(command.name)…"
        armWatchdog()
        streamGeneration += 1
        let generation = streamGeneration

        let p = Process()
        p.executableURL = URL(fileURLWithPath: command.path)
        p.arguments = args.isEmpty ? [] : args.components(separatedBy: " ")
        p.currentDirectoryURL = URL(fileURLWithPath: workdir)
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ToolPath.value(inherited: env["PATH"])
        env["CANTRIP_WORKDIR"] = workdir
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self, self.streamGeneration == generation else { return }
                self.armWatchdog()
                if let idx = self.messages.lastIndex(where: { $0.role == .assistant }),
                   self.messages[idx].text.count < 30_000 {
                    self.messages[idx].text += chunk
                    self.recordOutput(chunk, messageID: assistantID)
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.streamGeneration == generation else { return }
                if let idx = self.messages.lastIndex(where: { $0.role == .assistant }) {
                    var suffix = ""
                    if self.messages[idx].text.isEmpty {
                        suffix = "*(no output)*"
                    }
                    if proc.terminationStatus != 0 {
                        suffix += "\n\n`exit \(proc.terminationStatus)`"
                    }
                    self.messages[idx].text += suffix
                    self.recordOutput(suffix, messageID: assistantID)
                }
                self.shellProcess = nil
                let summary = self.messages.last(where: { $0.role == .assistant })?.text ?? ""
                self.completeRun(
                    status: proc.terminationStatus == 0 ? "succeeded" : "failed",
                    summary: summary
                )
                self.finishStream()
            }
        }
        startJournaledProcess(p, output: pipe.fileHandleForReading, generation: generation,
                              failurePrefix: "Failed to run /\(command.name)")
    }

    private func startJournaledProcess(_ process: Process, output: FileHandle,
                                       generation: Int, failurePrefix: String) {
        Task { [weak self] in
            guard let self else { output.readabilityHandler = nil; return }
            do { try await self.flushJournal() }
            catch {
                output.readabilityHandler = nil
                guard self.streamGeneration == generation else { return }
                self.reportJournalFailure(error)
                self.finishStream(dequeue: false, notify: false, waitForJournal: false)
                return
            }
            guard self.streamGeneration == generation, self.isStreaming else {
                output.readabilityHandler = nil
                return
            }
            do {
                try process.run()
                self.shellProcess = process
            } catch {
                output.readabilityHandler = nil
                let errorText = "\(failurePrefix): \(error.localizedDescription)"
                self.appendRunMessage(ChatMessage(role: .error, text: errorText))
                self.completeRun(status: "failed", summary: errorText)
                self.finishStream(dequeue: false)
            }
        }
    }

    /// Re-armed on every backend event; fires only if the stream goes
    /// completely silent, so long tool runs are fine.
    private func armWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: inactivityLimit,
                                        repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStreaming else { return }
                if self.hasActiveBackgroundWatcher {
                    Log.write("watchdog: background watcher still active — keeping the run available")
                    self.armWatchdog()
                    return
                }
                Log.write("watchdog: no backend activity for \(Int(self.inactivityLimit))s — force-cancelling")
                if let shell = self.shellProcess { // hung !/command runs too
                    shell.terminate()
                    self.shellProcess = nil
                    // Close the transcript's still-open ``` block, if any
                    // (an odd number of fences means one is unclosed).
                    if let idx = self.messages.lastIndex(where: { $0.role == .assistant }),
                       self.messages[idx].text.components(separatedBy: "```").count.isMultiple(of: 2) {
                        self.messages[idx].text += "\n```"
                    }
                }
                self.handleRunInterruption(
                    errorText: "No response for \(Int(self.inactivityLimit / 60)) minutes — request cancelled.")
            }
        }
    }

    private func handle(_ event: BackendEvent) {
        armWatchdog()
        switch event {
        case .inputRequired(let request):
            receiveInput(request)
        case .textDelta(let delta):
            Log.write("ui: textDelta(\(delta.count) chars)")
            if let idx = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[idx].text += delta
                recordOutput(
                    delta,
                    messageID: messages[idx].id,
                    author: messages[idx].author
                )
            }
            statusText = currentActivity?.title
        case .thinkingDelta(let delta):
            if let idx = messages.lastIndex(where: { $0.role == .assistant }),
               // Skip a block-separator landing at the top of a fresh
               // bubble (e.g. right after a mid-turn injection).
               !(messages[idx].thinking.isEmpty
                 && delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                messages[idx].appendThinking(delta)
            }
            statusText = currentActivity?.title ?? "Thinking…"
        case .status(let status):
            statusText = status
            if BackgroundWaitStatus.isWaiting(status) {
                isWaitingOnBackgroundWatchers = true
            } else if BackgroundWaitStatus.isResuming(status) {
                isWaitingOnBackgroundWatchers = false
            }
        case .activity(let activity):
            updateActivity(activity)
            shell.mirror(activity)
            if let message = messages.last(where: { $0.activities.contains { $0.id == activity.id } }) {
                recordActivity(activity, messageID: message.id)
            }
            statusText = currentActivity?.title ?? "Thinking…"
        case .usage(let usage):
            recordUsage(usage)
            updatePromptUsage { promptUsage, _ in promptUsage.apply(usage) }
        case .context(let context):
            updatePromptUsage { $0.apply(context, typedCharacters: $1) }
        case .approval(let approval):
            recordApproval(approval)
        case .backgroundWake(let ids):
            openBackgroundResultBubble(for: ids)
        case .usageLimit(let report):
            reportedUsageLimit = report
        case .done:
            reportedUsageLimit = nil
            isWaitingOnBackgroundWatchers = false
            if !pendingInjections.isEmpty {
                deferredInjectionDone = true
                return
            }
            if continueWithCantripHomeCorrection() { return }
            finalizeRunningActivities(as: .succeeded)
            let summary = messages.last(where: { $0.role == .assistant })?.text ?? ""
            completeRun(status: "succeeded", summary: summary)
            finishStream()
        case .failure(let message):
            isWaitingOnBackgroundWatchers = false
            handleRunInterruption(errorText: message)
        }
    }

    /// Saves Home's blocks as soon as the backend finishes. When Cantrip refuses one for a
    /// reason a corrected block could fix, it asks the same backend once, inside this run and
    /// reply, so a weaker model or CLI still lands its task, record, handoff or artifact.
    private func continueWithCantripHomeCorrection() -> Bool {
        guard isCantripHome || isCantripHomeBackground, !isCantripHomeBackgroundLog else { return false }
        let canCorrect = !cantripHomeCorrectionSpent && !councilRunning && !isLocalPrivate
            && currentRunID != nil && runningBackendKind != nil
        let failures = runCantripHomeBlockPass(lintBlocking: canCorrect)
        guard canCorrect, !failures.isEmpty, let kind = runningBackendKind,
              let index = messages.lastIndex(where: { $0.role == .assistant }) else {
            cantripHomeNotices += failures.map(\.notice)
            return false
        }
        cantripHomeCorrectionSpent = true
        cantripHomeHeldFailures = failures.map(\.notice)
        cantripHomeCorrection = (messages[index].id, messages[index].text)
        messages[index].text += "\n\n"
        Log.write("home: asking \(kind.rawValue) to correct \(failures.count) block(s): "
            + failures.map { "\($0.kind.rawValue): \($0.message.prefix(100))" }.joined(separator: "; "))
        let prompt = CantripHomeProtocol.correctionPrompt(failures)
        statusText = "Checking Home changes…"
        armWatchdog()
        streamGeneration += 1
        let generation = streamGeneration
        let backend = backend(for: kind)
        (backend as? CantripHomeGuardedBackend)?.guardrailLabel = notificationTitle
        backend.send(
            BackendRequest(prompt: prompt, userMessage: prompt, previousTurns: completedConversationTurns()),
            workdir: workdir
        ) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.streamGeneration == generation else {
                    if case .inputRequired(let request) = event { request.cancel() }
                    return
                }
                self.handle(event)
            }
        }
        return true
    }

    // MARK: - Resume after an interrupted run

    /// A run died mid-flight (watchdog timeout or backend failure). Record the error, then pause
    /// on it until the user taps Continue there. Tabs nobody watches (child tabs, Home handoffs)
    /// wait out network drops and auto-resume once instead, then pause the same way.
    private func handleRunInterruption(errorText: String) {
        // Orphan any late events from the dead run (a backend can emit a
        // trailing .done/.failure after the first failure) and make sure
        // its process is really gone before a resume relaunches it.
        streamGeneration += 1
        if councilRunning {
            cancelCouncilBackends()
            councilRunning = false
        }
        activeBackend.cancel()
        finalizeRunningActivities(as: .failed)
        if let correction = cantripHomeCorrection {
            // The reply already finished and its valid blocks are saved; only Cantrip's block
            // correction failed. Never resume (that would repeat the request's side effects):
            // keep the reply and its original refusals.
            Log.write("home: block correction failed: \(errorText.prefix(160))")
            completeRun(status: "succeeded", summary: correction.prefix)
            finishStream()
            return
        }
        let resumable = currentRunPrompt != nil && lastRunHadProgress
        let fallback = usageLimitFallback(after: errorText)
        recordInterruption(errorText)
        appendRunMessage(ChatMessage(role: .error, text: fallback.map {
            errorText + "\n\nContinuing this task with \(settings.backendLabel($0)) (Settings ▸ Usage limit fallback)."
        } ?? errorText))
        if let fallback {
            Log.write("resume: \(runningBackendKind?.rawValue ?? "backend") hit its usage limit — continuing on \(fallback.rawValue)")
            currentRunBackend = fallback
            interruptionAwaitsResume = false
            finishStream(dequeue: false, notify: false) { [weak self] in
                self?.scheduleAutoResume(reason: "usage-limit-fallback")
            }
            return
        }
        if !runsUnattended, !isCantripHomeBackground, currentRunPrompt != nil, currentRunMode == .single,
           journalError == nil {
            // Retrying by itself could land after queued messages that already started; the user
            // picks the moment instead, and the queue waits behind the failed task until then.
            Log.write("resume: run failed — waiting for Continue on its message")
            pauseUntilContinued()
            return
        }
        if waitForNetworkThenResume(after: errorText) { return }
        guard resumable else {
            completeRun(status: "failed", summary: errorText)
            finishStream()
            return
        }
        if isCantripHomeRun, autoResumeSpent || journalError != nil {
            // A hidden background run has no Resume button: it ends here as failed.
            completeRun(status: "failed", summary: errorText)
            finishStream()
            return
        }
        if !autoResumeSpent {
            autoResumeSpent = true
            // Queue waits for the resumed run; no notification/speech for
            // an interruption we're about to retry silently.
            Log.write("resume: run interrupted — auto-resuming")
            finishStream(dequeue: false, notify: false) { [weak self] in
                self?.scheduleAutoResume()
            }
        } else {
            pauseUntilContinued()
        }
    }

    /// Ends the failed run waiting for Continue (or Resume); the queue stays put.
    private func pauseUntilContinued() {
        interruptionAwaitsResume = true
        // Surface Continue only after the SIGTERM → SIGKILL escalation window, so a fast click
        // can't relaunch the CLI session while the hung process is still dying.
        finishStream(dequeue: false) { [weak self] in
            guard let self else { return }
            let generation = self.streamGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self, !self.isStreaming,
                      self.streamGeneration == generation else { return }
                self.canResume = true
                if !self.queued.isEmpty, !self.runsUnattended {
                    self.deliveryStatus = Self.pausedQueueStatus
                }
            }
        }
    }

    static let pausedQueueStatus = "Queued messages wait for the task that stopped on an error."
        + " Tap Continue on it, or Send now on a queued message to skip it."

    /// Nobody is watching this tab's runs: a child tab, or a tab working on a Home handoff.
    private var runsUnattended: Bool {
        currentRunPrompt?.hasPrefix("(Handed off by") == true
            || ChildTabStore.shared.isActiveChild(id)
            || CantripHomeDelegations.shared.allHandoffs.contains { $0.isActive && $0.tabID == id }
    }

    /// A failed run that stopped on the user's watch holds the queue until Continue or Send now.
    private var queueHeldByFailedRun: Bool {
        interruptionAwaitsResume && !runsUnattended
    }

    /// Whether the interrupted run got anywhere (tool steps or partial
    /// text). A run that died before doing anything isn't "resumable" —
    /// there are no previous steps to pick up from.
    private var lastRunHadProgress: Bool {
        messages.contains { message in
            message.runID == currentRunID && message.role == .assistant
                && (!message.activities.isEmpty || !message.text.isEmpty)
        }
    }

    /// The backend reported its plan's usage limit: remember that for every tab, and return the
    /// backend this run continues on (Settings' usage limit fallback), or nil to fail as usual.
    /// The backend's structured report decides; matching the error's wording is the last resort
    /// for CLIs that don't send one.
    private func usageLimitFallback(after errorText: String) -> BackendKind? {
        let report = reportedUsageLimit
        reportedUsageLimit = nil
        guard !isLocalPrivate, report != nil || UsageLimit.isLimitError(errorText),
              let limited = runningBackendKind ?? currentRunBackend, limited != .localModel else { return nil }
        if report == nil { Log.write("usage-limit: \(limited.rawValue) matched by wording only: \(errorText.prefix(120))") }
        BackendLimitTracker.shared.markLimited(limited, message: errorText, report: report)
        guard currentRunPrompt != nil, currentRunMode == .single, !councilMode, journalError == nil else { return nil }
        return BackendFallback.target(for: limited, configured: settings.limitFallbackBackend,
                                      homeRun: isCantripHomeRun)
    }

    /// Error text a dropped or flaky connection produces (Node, URLSession and DNS failures).
    static func isNetworkError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["fetch failed", "enotfound", "econnreset", "econnrefused", "etimedout", "eai_again",
                "enetunreach", "ehostunreach", "enetdown", "getaddrinfo", "socket hang up",
                "network error", "network is unreachable", "network connection", "offline",
                "connection reset", "connection was lost", "could not connect to the server", "und_err"]
            .contains { lowered.contains($0) }
    }

    /// A dropped network ends a run with an error that isn't the task's fault. Rather than failing
    /// the run (and starting the queue behind it, which would fail too), wait until the network is
    /// back, then continue the same run. Returns false when this failure isn't a network one.
    private func waitForNetworkThenResume(after errorText: String) -> Bool {
        let offline = !NetworkMonitor.shared.isOnline
        // A local model server needs no internet, and hidden Home runs have their own retry.
        let localModel = isLocalPrivate || (runningBackendKind ?? currentRunBackend) == .localModel
        guard offline || Self.isNetworkError(errorText), !localModel,
              !isCantripHomeRun, !isCantripHomeBackground,
              networkRetries < Self.networkRetryDelays.count,
              currentRunPrompt != nil, currentRunMode == .single, !councilMode,
              journalError == nil else { return false }
        let delay = offline ? 0 : Self.networkRetryDelays[networkRetries]
        networkRetries += 1
        interruptionAwaitsResume = false
        Log.write("resume: run interrupted by the network (\(offline ? "offline" : "connection error"));"
                  + " resuming when it's back, attempt \(networkRetries)")
        finishStream(dequeue: false, notify: false) { [weak self] in
            guard let self else { return }
            // Set only once the resume is really scheduled (a failed journal flush skips this).
            self.autoResumePending = true
            let generation = self.streamGeneration
            self.deliveryStatus = offline
                ? "Offline. Cantrip continues this task when the network is back."
                : "Connection problem. Cantrip continues this task in \(Int(delay)) seconds."
            self.resumeWhenOnline(generation: generation, after: delay)
        }
        return true
    }

    private func resumeWhenOnline(generation: Int, after delay: TimeInterval, reason: String? = nil,
                                  waitsForNetwork: Bool = true) {
        let resume = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isStreaming, self.streamGeneration == generation,
                      self.autoResumePending else { return }
                // The network dropped again during the delay: keep waiting.
                guard !waitsForNetwork || NetworkMonitor.shared.isOnline else {
                    self.deliveryStatus = "Offline. Cantrip continues this task when the network is back."
                    return self.resumeWhenOnline(generation: generation, after: 0, reason: reason)
                }
                self.autoResumePending = false
                self.deliveryStatus = nil
                self.performResume(auto: true, reason: reason)
            }
        }
        waitsForNetwork ? NetworkMonitor.shared.whenOnline(resume) : resume()
    }

    /// Cantrip relaunched while there was work in this tab: the run it was in the middle of
    /// and messages queued behind it.
    var hasRestoredWork: Bool {
        guard !isPrivate, !isCantripHomeBackground, journalError == nil else { return false }
        return (restoredRun != nil && canResume) || !queued.isEmpty
    }

    /// After a relaunch, continues the run Cantrip quit in the middle of, then the queue behind
    /// it, instead of leaving both waiting for the user. Waits for the network when offline.
    /// The tab shows the pending resume at once; the work itself starts after `delay`.
    func continueAfterLaunch(after delay: TimeInterval = 0) {
        guard hasRestoredWork, !isStreaming, !autoResumePending else { return }
        if let run = restoredRun, canResume, currentRunID == run.id {
            // A run that had failed was waiting for Continue; relaunching doesn't retry it.
            guard !run.stoppedOnFailure || runsUnattended else {
                Log.write("resume: run \(run.id.uuidString.prefix(8)) stopped on an error; waiting for Continue")
                interruptionAwaitsResume = true
                return
            }
            guard run.launchResumes < Self.launchResumeLimit else {
                Log.write("resume: run \(run.id.uuidString.prefix(8)) already resumed after"
                          + " \(run.launchResumes) relaunches; waiting for Resume")
                return
            }
            restoredRun = nil
            canResume = false
            autoResumePending = true
            deliveryStatus = "Continuing the task that was running when Cantrip quit…"
            Log.write("resume: continuing run \(run.id.uuidString.prefix(8)) after relaunch")
            let localModel = isLocalPrivate || currentRunBackend == .localModel
            resumeWhenOnline(generation: streamGeneration, after: delay,
                             reason: RunJournal.launchResumeReason, waitsForNetwork: !localModel)
        } else if !canResume {
            let generation = streamGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.streamGeneration == generation, !self.isStreaming else { return }
                Log.write("queue: sending \(self.queued.count) message(s) queued before Cantrip relaunched")
                self.drainQueue()
            }
        }
    }

    /// Delay so the killed backend process fully dies before the
    /// replacement launches — must outlast the backends' 3s SIGTERM →
    /// SIGKILL escalation so a hung process can't race the new stream.
    private func scheduleAutoResume(reason: String? = nil) {
        let generation = streamGeneration
        // Set only once a resume is really scheduled (a failed journal flush skips this).
        autoResumePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self else { return }
            self.autoResumePending = false
            guard !self.isStreaming, self.streamGeneration == generation else {
                // Nothing resumes after all; handoffs re-read the tab and settle.
                self.objectWillChange.send()
                return
            }
            self.performResume(auto: true, reason: reason)
        }
    }

    /// Manual entry point (Resume button).
    func resumeInterrupted() {
        performResume(auto: false)
    }

    /// Error messages that offer Continue: each failed run's last message, when nothing in that
    /// run came after it. The current run continues as itself; an earlier one (queued work went
    /// ahead of it, or a new message replaced it) continues as a new run.
    var continuableMessageIDs: Set<UUID> {
        guard !isStreaming, !autoResumePending, !isCantripHomeBackground, journalError == nil else { return [] }
        let start = (messages.lastIndex { $0.role == .freshStart }).map { $0 + 1 } ?? 0
        // A run already continued as a new run offers Continue on that run's message instead.
        let continued = Set(messages.compactMap(\.continuesRunID))
        var last: [UUID: ChatMessage] = [:]
        var lastError: [UUID: UUID] = [:]
        for message in messages[start...] {
            guard let run = message.runID, !continued.contains(run),
                  !(message.role == .assistant && message.text.isEmpty && message.activities.isEmpty) else { continue }
            last[run] = message
            if message.role == .error { lastError[run] = message.id }
        }
        return Set(last.compactMap { run, message in
            if run == currentRunID, interruptionAwaitsResume || restoredRun != nil {
                // Same-run resume, once the dying backend process is gone. A run restored after
                // relaunches keeps its one exit notice, with earlier resumes after it.
                return canResume ? lastError[run] : nil
            }
            guard message.role == .error, let original = originalPrompt(ofRun: run), !original.hasPrefix("!"),
                  original != "/login github" else { return nil }
            return message.id
        })
    }

    /// Continue on a failed run's message (`continuableMessageIDs`). Returns why it can't.
    @discardableResult
    func continueFailedRun(from messageID: UUID, includesAmbientContext: Bool) -> String? {
        guard !isStreaming else { return "Wait for the current task to finish, then tap Continue." }
        guard continuableMessageIDs.contains(messageID),
              let run = messages.first(where: { $0.id == messageID })?.runID else {
            return "That task can't be continued anymore."
        }
        let localModel = isLocalPrivate || (run == currentRunID ? currentRunBackend : settings.backend) == .localModel
        guard localModel || NetworkMonitor.shared.isOnline else {
            return "The Mac is offline. Tap Continue once the network is back."
        }
        if run == currentRunID, canResume {
            performResume(auto: false)
            return nil
        }
        guard let original = originalPrompt(ofRun: run) else { return "That task can't be continued anymore." }
        Log.write("resume: continuing earlier failed run \(run.uuidString.prefix(8)) as a new run")
        send(Self.resumePrompt, preamble: resumePreamble(original: original, runs: runChain(endingAt: run)),
             includesAmbientContext: includesAmbientContext, consumesStagedContext: false,
             continuing: (run, original))
        return nil
    }

    /// The run and the earlier failed runs it continued, oldest first.
    private func runChain(endingAt run: UUID) -> [UUID] {
        var chain = [run]
        while chain.count < 20,
              let earlier = messages.first(where: { $0.runID == chain[0] && $0.role == .user })?.continuesRunID,
              !chain.contains(earlier) {
            chain.insert(earlier, at: 0)
        }
        return chain
    }

    /// The request a run (or the run it continued) started with.
    private func originalPrompt(ofRun run: UUID) -> String? {
        // A shell or script run leaves the last model request in `currentRunPrompt`.
        if run == currentRunID, currentRunMode == .single, let currentRunPrompt { return currentRunPrompt }
        let first = runChain(endingAt: run).first.flatMap { root in
            messages.first { $0.runID == root && $0.role == .user }
        }
        guard let first, first.continuesRunID == nil, first.text != Self.resumePrompt else { return nil }
        return first.text
    }

    private func resumePreamble(original: String, runs: [UUID]) -> String {
        var preamble = "(My previous request was interrupted mid-run and cancelled."
            + " Original request: \"\(original.prefix(1000))\""
        if let steps = interruptedStepSummary(runs: runs) {
            preamble += "\nSteps already taken before the interruption:\n\(steps)"
        }
        if let context = interruptedUserContext(runs: runs) { preamble += "\n\n\(context)" }
        preamble += "\nResume that task from where it left off: verify which steps already completed, then continue — don't redo finished work or start over.)"
        return preamble
    }

    private func performResume(auto: Bool, reason: String? = nil) {
        guard !isStreaming, let original = currentRunPrompt else { return }
        canResume = false
        interruptionAwaitsResume = false
        let preamble = resumePreamble(original: original, runs: currentRunID.map(runChain(endingAt:)) ?? [])
        Log.write("resume: \(auto ? "auto" : "manual") resume of interrupted run")
        recordResumeAttempt(reason: reason ?? (auto ? "automatic-resume" : "manual-resume"))
        send(
            Self.resumePrompt,
            preamble: preamble,
            isResume: true,
            includesAmbientContext: currentRunIncludesAmbientContext
        )
    }

    /// Backends with native session state (--resume / exec resume) carry
    /// interrupted-turn context themselves; stateless ones need the
    /// harness to inject it.
    private var backendKeepsSession: Bool {
        if isLocalPrivate { return false }
        switch currentRunBackend ?? settings.backend {
        case .claudeCode, .codex, .antigravity: return true
        // copilotRemote keeps its ACP session while the app runs, but an
        // interrupted turn's context isn't replayable — inject like the
        // other stateless backends.
        case .copilot, .copilotRemote, .localModel: return false
        }
    }

    /// Work log of the interrupted turn, for backends without native
    /// session resume (Copilot, local models). Claude Code and Codex
    /// already recover full detail via --resume/exec resume.
    private func interruptedStepSummary(runs: [UUID]? = nil) -> String? {
        // Only the interrupted turn itself (and the failed runs it continues) — an earlier
        // turn's steps would misrepresent what "was already done" for this task.
        let runs = runs ?? currentRunID.map { [$0] } ?? []
        let activities = messages.filter {
            $0.runID.map(runs.contains) == true && $0.role == .assistant
        }.flatMap(\.activities)
        let lines = activities.suffix(30).map { activity in
            "- [\(stateLabel(activity.state))] \(activity.toolName): \(activity.title)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func interruptedUserContext(runs: [UUID]? = nil) -> String? {
        let runs = runs ?? currentRunID.map { [$0] } ?? []
        let instructions = messages.filter { $0.runID.map(runs.contains) == true && $0.role == .user }
            .dropFirst().map(\.text).filter { $0 != Self.resumePrompt }
        guard !instructions.isEmpty else { return nil }
        return "Additional user context recorded during this run (delivery may already have occurred; "
            + "verify completed work instead of replaying instructions):\n"
            + instructions.joined(separator: "\n\n")
    }

    private func stateLabel(_ state: ToolActivityState) -> String {
        switch state {
        case .succeeded: return "done"
        case .running: return "in progress"
        case .failed: return "interrupted"
        case .cancelled: return "cancelled"
        }
    }

    /// Extract a ```overlay JSON block from the final assistant message,
    /// render it as on-screen tooltips, and strip it from the transcript.
    private func processOverlayBlock() {
        guard let idx = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        var text = messages[idx].text
        var hints: [OverlayHint]?
        // Strip every ```overlay block; render the last one found.
        while let start = text.range(of: "```overlay"),
              let end = text.range(of: "```", range: start.upperBound..<text.endIndex) {
            let json = String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            text.removeSubrange(start.lowerBound..<end.upperBound)
            if let data = json.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([OverlayHint].self, from: data) {
                hints = parsed
            } else {
                Log.write("overlay: failed to parse block: \(json.prefix(120))")
            }
        }
        guard hints != nil || messages[idx].text != text else { return }
        messages[idx].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hints { OverlayController.shared.show(hints) }
    }

    private func finishStream(dequeue: Bool = true, notify: Bool = true,
                              waitForJournal: Bool = true, then: (() -> Void)? = nil) {
        watchdog?.invalidate()
        watchdog = nil
        streamGeneration += 1
        let generation = streamGeneration
        guard waitForJournal, !isPrivate else {
            finishStreamAfterJournal(dequeue: dequeue, notify: notify)
            then?()
            return
        }
        statusText = "Saving run..."
        Task { [weak self] in
            guard let self else { return }
            do { try await self.flushJournal() }
            catch {
                guard self.streamGeneration == generation else { return }
                self.reportJournalFailure(error)
            }
            guard self.streamGeneration == generation else { return }
            self.finishStreamAfterJournal(dequeue: dequeue && self.journalError == nil,
                                          notify: notify && self.journalError == nil)
            if self.journalError == nil { then?() }
        }
    }

    private func finishStreamAfterJournal(dequeue: Bool, notify: Bool) {
        if routingItemID != nil {
            invalidateRouting()
            deliveryStatus = "Queued: the task ended before routing finished."
        }
        watchdog?.invalidate()
        watchdog = nil
        councilRunning = false
        councilAnswers = []
        councilFinished = []
        councilSynthesizing = false
        if !isLocalPrivate { processOverlayBlock() }
        let reply = processCantripHomeBlocks()
        if let completion = pendingTurnCompletion {
            var visibleSummary = messages.last(where: { $0.role == .assistant })?.text
                ?? completion.summary
            // A closing "Summary:" section ends where Cantrip's own block notices begin.
            if let reply, CantripHomeDelegations.summarySection(reply) != nil {
                visibleSummary = reply
            }
            pendingTurnCompletion = nil
            onTurnCompleted?(completion.runID, completion.status, visibleSummary)
        }
        isStreaming = false
        isWaitingOnBackgroundWatchers = false
        statusText = nil
        // Session layer: log the completed exchange for future grep.
        if settings.memoryEnabled, !isPrivate, !isLocalPrivate,
           let userIdx = messages.lastIndex(where: { $0.role == .user }),
           let assistantIdx = messages.lastIndex(where: { $0.role == .assistant }),
           assistantIdx > userIdx, !messages[assistantIdx].text.isEmpty {
            // Council verdicts record WHO deliberated, not just the chair.
            // (History's header parser splits on " · ", so labels drop it.)
            let backendTag: String
            if let author = messages[assistantIdx].author, author.hasPrefix("Verdict") {
                let seats = settings.councilMembers
                    .map { $0.label.replacingOccurrences(of: " · ", with: " ") }
                    .joined(separator: " + ")
                backendTag = "Council [\(seats)] chaired by \(settings.backend.rawValue)"
            } else {
                backendTag = settings.backend.rawValue
            }
            MemoryStore.shared.logExchange(user: turnUserText(endingAt: userIdx),
                                           assistant: messages[assistantIdx].text,
                                           backend: backendTag)
        }
        // Drop empty assistant placeholder if nothing arrived.
        if let idx = messages.lastIndex(where: { $0.role == .assistant }),
           messages[idx].text.isEmpty,
           messages[idx].activities.isEmpty,
           messages[idx].thinking.isEmpty,
           messages[idx].delegations.isEmpty {
            messages.remove(at: idx)
        }
        persistTranscript()
        // Auto-run the next queued message (through the council when on).
        if dequeue, !queued.isEmpty {
            let generation = streamGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.streamGeneration == generation else { return }
                self.drainQueue()
            }
        } else if notify, !isLocalPrivate {
            // Whole run complete: speak the reply / notify if hidden.
            if settings.voiceMode,
               let reply = messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) {
                SpeechSynth.shared.speak(reply.text)
            }
            onRunFinished?()
        }
    }

    /// Queued messages the router may group, starting with the next one; empty when
    /// the next message runs alone (commands, councils, private or automated tabs).
    private func queueGroupingCandidates() -> [QueuedPrompt] {
        guard !councilMode, !isLocalPrivate, !isCantripHomeBackground, queued.count >= 2 else { return [] }
        if case .unavailable = routerProvider { return [] }
        // Home handoffs keep their own turn so stopping one never stops another request.
        let handoffs = Set(CantripHomeDelegations.shared.allHandoffs
            .filter { $0.isActive && $0.tabID == id }.map(\.prompt))
        let excluded = Set(queued.indices.filter {
            queued[$0].id == routingItemID || pendingInjections.contains(queued[$0].id)
                || handoffs.contains(queued[$0].text)
        })
        return QueueGroupingPolicy.candidateIndices(queued.map(\.text), excluded: excluded)
            .map { queued[$0] }
    }

    /// While a turn runs, decide in the background which queued messages go together,
    /// so the next turn starts without waiting for the router.
    private func scheduleQueueGrouping() {
        guard isStreaming, !drainAfterGrouping else { return }
        let candidates = queueGroupingCandidates()
        guard candidates.count >= 2 else {
            if groupingTask != nil { invalidateGrouping() }
            return
        }
        if groupingPlan?.candidates == candidates
            || (groupingTask != nil && groupingTaskCandidates == candidates) { return }
        startQueueGrouping(candidates, delay: Self.queueGroupingDelay)
    }

    private func startQueueGrouping(_ candidates: [QueuedPrompt], delay: UInt64) {
        groupingTask?.cancel()
        groupingRevision += 1
        let revision = groupingRevision
        groupingTaskCandidates = candidates
        groupingClassifying = false
        groupingTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled, self.groupingRevision == revision else { return }
            self.groupingClassifying = true
            let snapshot = QueueGroupingSnapshot(
                recentConversation: self.messages
                    .filter { ($0.role == .user || $0.role == .assistant) && !$0.text.isEmpty }
                    .suffix(6).map { .init(role: $0.role.rawValue, text: $0.text) },
                messages: candidates.map(\.text)
            )
            var group = [candidates[0]]
            do {
                let decision = try await MessageRouter.groupQueue(snapshot, provider: self.routerProvider)
                group = QueueGroupingPolicy.group(decision, candidateTexts: candidates.map(\.text))
                    .map { candidates[$0] }
            } catch is CancellationError {
                return
            } catch {
                Log.write("queue-grouping: \(error.localizedDescription); running messages one at a time")
            }
            guard !Task.isCancelled, self.groupingRevision == revision else { return }
            self.groupingTask = nil
            self.groupingTaskCandidates = []
            self.groupingClassifying = false
            self.groupingPlan = QueueGroupingPlan(candidates: candidates, group: group)
            guard self.drainAfterGrouping else { return }
            self.drainAfterGrouping = false
            // A child tab's merge started meanwhile: the queue resumes once it's done.
            guard !self.isStreaming, self.journalError == nil, !self.childMergeHold else { return }
            // Messages added meanwhile run later. A removed or edited message, or a change
            // that rules out grouping (such as council mode), means deciding again.
            let current = self.queueGroupingCandidates()
            guard self.queued.first == group[0], group.allSatisfy({ current.contains($0) }) else {
                return self.drainQueue()
            }
            self.startQueued(group)
        }
    }

    private func invalidateGrouping() {
        groupingRevision += 1
        groupingTask?.cancel()
        groupingTask = nil
        groupingTaskCandidates = []
        groupingClassifying = false
        groupingPlan = nil
        if drainAfterGrouping {
            drainAfterGrouping = false
            deliveryStatus = nil
        }
    }

    /// Starts the next queued message, together with any later ones the router judged
    /// related to it. Grouping is normally decided while the previous turn was running.
    private func drainQueue() {
        guard !isStreaming, journalError == nil, !queued.isEmpty, !drainAfterGrouping, !childMergeHold else { return }
        // An interrupted run continues before anything queued behind it.
        guard !autoResumePending else { return }
        // So does a failed one waiting for Continue; Send now on a message skips it.
        guard !queueHeldByFailedRun else {
            deliveryStatus = Self.pausedQueueStatus
            return
        }
        // Sending while offline would fail each queued message in turn; wait for the network.
        if !isLocalPrivate, settings.backend != .localModel, !NetworkMonitor.shared.isOnline {
            deliveryStatus = "Offline. Queued messages are sent when the network is back."
            guard !drainWaitsForNetwork else { return }
            drainWaitsForNetwork = true
            NetworkMonitor.shared.whenOnline { [weak self] in
                guard let self else { return }
                self.drainWaitsForNetwork = false
                if self.deliveryStatus?.hasPrefix("Offline.") == true { self.deliveryStatus = nil }
                self.drainQueue()
            }
            return
        }
        let candidates = queueGroupingCandidates()
        guard candidates.count >= 2 else { return startQueued([queued[0]]) }
        if let plan = groupingPlan, plan.candidates == candidates {
            return startQueued(plan.group)
        }
        drainAfterGrouping = true
        deliveryStatus = "Checking which queued messages belong together..."
        // A decision already in progress for this exact queue is reused; anything else restarts now.
        if !(groupingTask != nil && groupingClassifying && groupingTaskCandidates == candidates) {
            startQueueGrouping(candidates, delay: 0)
        }
    }

    private func startQueued(_ group: [QueuedPrompt]) {
        guard let next = group.first else { return }
        let rest = Array(group.dropFirst())
        if rest.isEmpty {
            councilMode
                ? sendCouncil(next.text, includesAmbientContext: next.includesAmbientContext,
                              consumesStagedContext: false, queuedItem: next)
                : send(next.text, includesAmbientContext: next.includesAmbientContext,
                       consumesStagedContext: false, queuedItem: next)
            removeQueued(next)
            deliveryStatus = "Sent the next queued message."
        } else {
            Log.write("queue-grouping: running \(group.count) related queued messages together")
            // Ambient Mac context only when every message came from the Mac itself.
            send(QueueGroupingPolicy.combinedPrompt(group.map(\.text)),
                 includesAmbientContext: group.allSatisfy(\.includesAmbientContext),
                 consumesStagedContext: false, queuedItem: next, combinedItems: rest)
            for item in group { removeQueued(item) }
            deliveryStatus = "Sent \(group.count) related queued messages together."
        }
        if !isStreaming, !queued.isEmpty {
            let generation = streamGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.streamGeneration == generation else { return }
                self.drainQueue()
            }
        }
    }

    func cancel() {
        cancel(keepQueue: false)
    }

    /// Stops only the running turn; queued prompts (other handoffs) still run after it.
    func stopCurrentRun() {
        cancel(keepQueue: true)
        guard !queued.isEmpty else { return }
        let generation = streamGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStreaming, self.streamGeneration == generation else { return }
            self.drainQueue()
        }
    }

    private func cancel(keepQueue: Bool) {
        deviceLogin.cancel()
        invalidateRouting()
        deliveryStatus = nil
        autoResumePending = false
        restoredRun = nil
        streamGeneration += 1        // orphan any in-flight events
        SpeechSynth.shared.stop()
        shellProcess?.terminate()
        shellProcess = nil
        shellAskpass?.stop()
        shellAskpass = nil
        if councilRunning {
            cancelCouncilBackends()
            councilRunning = false
        }
        // Mid-run: graceful in-band interrupt when the backend supports it
        // (the process and session stay alive). Otherwise — including idle
        // teardown from tab close / force hide — kill the process so no
        // orphaned backend lingers.
        if !(isStreaming && activeBackend.interruptTurn()) {
            activeBackend.cancel()
        }
        if !keepQueue { clearQueue() } // only explicit Stop aborts the whole queue
        finalizeRunningActivities(as: .cancelled)
        cancelRun(reason: "cancelled by user")
        // Stop/redirect takes effect immediately. Its remote acknowledgement
        // still waits for the journal, and no success notification is emitted.
        finishStream(dequeue: false, notify: false, waitForJournal: false)
    }

    private func resetBackendConversations() {
        claudeCode.reset()
        copilot.reset()
        copilotRemote.reset()
        codex.reset()
        antigravity.reset()
        localModel.reset()
        privateLocalModel.reset()
    }

    func newConversation() {
        guard !isLocked else {
            tabActionError = SessionTabError.locked.localizedDescription
            return
        }
        invalidateRouting()
        deliveryStatus = nil
        mcpAppContext.removeAll()
        // Continuity: stash a digest of this conversation for the next one.
        if messages.count >= 2, !isPrivate, !isLocalPrivate {
            let topics = messages.filter { $0.role == .user }.suffix(3)
                .map { String($0.text.prefix(100)) }
                .joined(separator: " | ")
            let lastAnswer = messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })
                .map { String($0.text.suffix(300)) } ?? ""
            UserDefaults.standard.set(
                "Recent topics: \(topics). End of last answer: …\(lastAnswer)",
                forKey: "lastConversationDigest")
        }
        streamGeneration += 1   // orphan any in-flight events (incl. the
        // .done that Copilot/Codex/local emit from their kill paths —
        // without this, a mid-council reset ghost-starts a synthesis).
        councilRunning = false
        councilAnswers = []
        councilFinished = []
        councilSynthesizing = false
        resetBackendConversations()
        for backend in councilInstances.values { backend.reset() }
        councilInstances = [:]
        TabDefaults.removeCouncilSeats(for: id)
        messages.removeAll()
        isStreaming = false
        statusText = nil
        canResume = false
        currentRunPrompt = nil
        currentRunIncludesAmbientContext = true
        autoResumeSpent = false
        autoResumePending = false
        interruptionAwaitsResume = false
        restoredRun = nil
        networkRetries = 0
        if let runID = currentRunID ?? lastJournalRunID {
            appendRunEvent(RunJournal.Event(
                sessionID: id,
                runID: runID,
                kind: .conversationReset
            ), durable: true)
        }
        clearQueue()
        clearCurrentRun()
        clearLastRunOutcome()
        persistTranscript()
    }

    // MARK: - Start fresh

    static let freshStartCaption = "Started fresh — earlier messages aren't sent to the model"

    /// Cantrip Home keeps its own continuity; every other tab can start fresh.
    var supportsStartFresh: Bool { !SessionManager.isCantripHomeReserved(self) }

    /// Commands the Copilot Remote server announced for this tab's ACP session.
    var copilotRemoteCommands: (commands: [[String: Any]], endpoint: String)? {
        copilotRemote.availableCommands
    }

    /// `/model [id] [effort]` on Copilot: this tab's model settings, same rules as the model menu.
    func modelCommandReply(_ input: String) -> String {
        if let reason = modelSettingsUnavailableReason { return reason }
        let tabCatalog = modelCatalog
        let catalog = tabCatalog.models
        let current = modelSelection
        let parts = input.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let requested = parts.first else {
            let name = current.model.isEmpty
                ? (tabCatalog.fileDefaultModel.map { "\($0) (the Mac's default)" } ?? "the Mac's default model")
                : current.model
            var lines = ["This tab uses **\(name)**\(current.effort.isEmpty ? "" : " with \(current.effort) effort"). "
                         + "Change it in this tab's model settings, or send `/model <model> [effort]`."]
            if !catalog.isEmpty {
                lines.append("")
                lines += catalog.map { model in
                    let efforts = (model.reasoningEfforts ?? []).joined(separator: ", ")
                    return "- `\(model.id)`" + (efforts.isEmpty ? "" : " (effort: \(efforts))")
                }
            }
            return lines.joined(separator: "\n")
        }
        let model: String
        if ["default", "mac", "reset"].contains(requested.lowercased()) {
            model = ""
        } else if let match = catalog.first(where: { $0.id.lowercased() == requested.lowercased() }) {
            model = match.id
        } else {
            let name = modelSettingsBackend == .claudeCode ? "Claude Code" : "Copilot"
            return "`\(requested)` isn't in the Mac's \(name) model list. Send `/model` to see the choices."
        }
        let info = tabCatalog.info(model)
        let effort = parts.count > 1 ? parts[1].lowercased() : ""
        let tier = info?.contextTiers?.contains(current.contextTier) == true ? current.contextTier : ""
        let selection = model.isEmpty && effort.isEmpty
            ? nil : SessionModelSelection(model: model, effort: effort, contextTier: tier)
        do {
            try updateModelSettings(selection, revision: modelSettingsRevision)
        } catch {
            return error.localizedDescription
        }
        let label = model.isEmpty ? "the Mac's default model" : "**\(model)**"
        return "This tab now uses \(label)\(effort.isEmpty ? "" : " with \(effort) effort"). Your next message uses it."
    }

    var startFreshUnavailableReason: String? {
        guard supportsStartFresh else {
            return "Cantrip Home keeps its own conversation. Start fresh in a project tab instead."
        }
        if isStreaming || !queued.isEmpty || shell.isRunning || autoResumePending {
            return "Wait for this tab and its queued work to finish before starting fresh."
        }
        return nil
    }

    /// Keeps the tab and its visible history, but the next prompt starts a new model session that
    /// gets none of the earlier turns: a divider marks where the model's context begins again.
    func startFresh() throws {
        if let reason = startFreshUnavailableReason { throw SessionModelSettingsError(409, reason) }
        invalidateRouting()
        deliveryStatus = nil
        mcpAppContext.removeAll()
        streamGeneration += 1
        councilRunning = false
        councilAnswers = []
        councilFinished = []
        councilSynthesizing = false
        // Drops each backend's native session (Copilot's runtime and resume target, Claude/Codex
        // session IDs), so nothing is resumed with the old context.
        resetBackendConversations()
        for backend in councilInstances.values { backend.reset() }
        councilInstances = [:]
        TabDefaults.removeCouncilSeats(for: id)
        autoResumeSpent = false
        restoredRun = nil
        networkRetries = 0
        if let runID = currentRunID ?? lastJournalRunID {
            appendRunEvent(RunJournal.Event(sessionID: id, runID: runID, kind: .conversationReset),
                           durable: true)
        }
        clearCurrentRun()
        if !messages.isEmpty, messages.last?.role != .freshStart {
            messages.append(ChatMessage(role: .freshStart, text: Self.freshStartCaption))
            persistTranscript()
        }
        Log.write("tab: started fresh (\(id.uuidString.prefix(8)))")
    }

    /// The latest message when it's a model error repeating the previous error with no finished
    /// turn between them: the tab is likely stuck on its earlier context, so clients offer
    /// Start Fresh and Change Model on that row.
    var repeatedErrorMessageID: UUID? {
        guard supportsStartFresh, !isStreaming,
              let last = messages.lastIndex(where: { !($0.role == .assistant && $0.text.isEmpty) }),
              messages[last].role == .error, Self.isModelError(messages[last].text) else { return nil }
        let key = Self.errorKey(messages[last].text)
        var promptAfter = false
        for message in messages[..<last].reversed() {
            switch message.role {
            case .error:
                return Self.errorKey(message.text) == key ? messages[last].id : nil
            case .user:
                promptAfter = true
            case .assistant where !message.text.isEmpty && promptAfter:
                return nil // a reply followed by a new prompt: that turn finished
            case .freshStart:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// A failure reported by the model or its API, not Cantrip, the network or a local tool.
    static func isModelError(_ text: String) -> Bool {
        guard !isNetworkError(text) else { return false }
        let lowered = text.lowercased()
        return lowered.contains("execution failed") || lowered.contains("model")
            || lowered.range(of: #"\b[45]\d\d\b"#, options: .regularExpression) != nil
    }

    /// Error text without the parts that change on every attempt (request IDs, token counts).
    static func errorKey(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\([^)]*request[ _-]?id[^)]*\)"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map { word in
                word.count >= 6 && word.contains(where: \.isNumber) ? "#" : String(word)
            }
            .joined(separator: " ")
    }

    /// Finished background work (a watch-*/side-* agent or shell) woke the idle root: its result
    /// gets its own bubble in the thread that started the work, instead of joining whichever
    /// reply is open. Other tabs split only when that reply belongs to a different thread.
    private func openBackgroundResultBubble(for ids: [String]) {
        // A message still on its way to the root (its empty reply is last) takes what comes next,
        // as before: splitting now would leave that reply empty and put its answer under a tag.
        guard pendingInjections.isEmpty, let last = messages.last,
              !(last.role == .assistant && last.text.isEmpty && last.activities.isEmpty) else { return }
        let thread = backgroundThreadID(for: ids)
        let open = messages.last { $0.role == .assistant }?.threadID
        guard isCantripHome || thread != nil && thread != open else { return }
        // The end of the run reads only the last reply: settle the closed one's blocks now.
        if isCantripHome { cantripHomeNotices += runCantripHomeBlockPass(lintBlocking: false).map(\.notice) }
        if !isLocalPrivate { processOverlayBlock() }
        Log.write("thread: background result opens its own bubble (\(ids.joined(separator: ", ").prefix(80)))")
        appendRunMessage(ChatMessage(role: .assistant, text: "", threadID: thread ?? currentThreadID))
    }

    /// The thread of the reply that started a background agent or shell. An agent or tool call ID
    /// is matched exactly first; a shell ID only as a whole value in the call's input or result.
    func backgroundThreadID(for ids: [String]) -> UUID? {
        let wanted = Set(ids.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return nil }
        func tree(_ activity: ToolActivity, _ test: (ToolActivity) -> Bool) -> Bool {
            test(activity) || activity.children.contains { tree($0, test) }
        }
        func thread(where test: (ToolActivity) -> Bool) -> UUID? {
            messages.last { $0.threadID != nil && $0.activities.contains { tree($0, test) } }?.threadID
        }
        if let exact = thread(where: { activity in
            wanted.contains(activity.id) || activity.subagent.map { wanted.contains($0.agentID) } == true
        }) { return exact }
        let shells = wanted.compactMap { id in
            try? NSRegularExpression(pattern: "\"shellId\"\\s*:\\s*\"\(NSRegularExpression.escapedPattern(for: id))\""
                + "|shellId: \(NSRegularExpression.escapedPattern(for: id))(?=[\\s>]|$)")
        }
        return thread { activity in
            let text = (activity.input ?? "") + "\n" + (activity.output ?? "")
            let range = NSRange(text.startIndex..., in: text)
            return shells.contains { $0.firstMatch(in: text, range: range) != nil }
        }
    }

    private func updateActivity(_ activity: ToolActivity) {
        guard let messageIndex = messages.lastIndex(where: {
            $0.activities.contains { $0.id == activity.id }
        }) ?? messages.lastIndex(where: { $0.role == .assistant }) else {
            return
        }
        if let activityIndex = messages[messageIndex].activities.firstIndex(
            where: { $0.id == activity.id }
        ) {
            messages[messageIndex].activities[activityIndex] = activity
        } else {
            messages[messageIndex].activities.append(activity)
        }
        attachApp(from: activity, toMessageAt: messageIndex)
    }

    private func attachApp(from activity: ToolActivity, toMessageAt index: Int) {
        guard let app = activity.app, !isLocalPrivate, settings.copilotMCPApps,
              !messages[index].apps.contains(where: { $0.id == app.id }) else { return }
        messages[index].apps.append(app)
    }

    // MARK: - MCP App views

    /// Latest `ui/update-model-context` per view, added to the next prompt.
    private var mcpAppContext: [String: (server: String, text: String)] = [:]

    func setMCPAppContext(_ app: MCPAppPayload, text: String?) {
        mcpAppContext[app.id] = text.map { (app.serverName.isEmpty ? "MCP" : app.serverName, $0) }
    }

    /// A view's approved `ui/message`: always a literal prompt for the model,
    /// never a `!`/`/` command or an answer to pending input, and without
    /// ambient Mac data. The label also shows where the message came from.
    func submitMCPAppMessage(_ text: String, from app: MCPAppPayload) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        receive(MCPAppHost.chatMessage(trimmed, server: app.serverName),
                mode: .auto, includesAmbientContext: false)
    }

    /// Completion runs on the main actor.
    func mcpAppRequest(_ app: MCPAppPayload, method: String, params: [String: Any],
                       completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let backend = copilot as? CopilotBackend else {
            completion(.failure(MCPAppRequestError.sessionUnavailable))
            return
        }
        backend.mcpAppRequest(serverName: app.serverName, method: method, params: params) { result in
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func finalizeRunningActivities(as state: ToolActivityState) {
        for messageIndex in messages.indices {
            for activityIndex in messages[messageIndex].activities.indices {
                let finalized = finalize(
                    messages[messageIndex].activities[activityIndex],
                    as: state
                )
                messages[messageIndex].activities[activityIndex] = finalized
                shell.mirror(finalized)
                if messages[messageIndex].runID == currentRunID {
                    recordActivity(finalized, messageID: messages[messageIndex].id)
                }
            }
        }
    }

    private func finalize(
        _ activity: ToolActivity,
        as state: ToolActivityState
    ) -> ToolActivity {
        activity.finishing(as: state)
    }

    // MARK: - Subagents

    /// The subagent with this agent ID, searched newest message first.
    func subagent(agentID: String) -> SubagentInfo? {
        guard !agentID.isEmpty else { return nil }
        for message in messages.reversed() {
            for activity in message.activities {
                if let info = activity.subagentActivities
                    .last(where: { $0.subagent?.agentID == agentID })?.subagent {
                    return info
                }
            }
        }
        return nil
    }

    /// Stops one subagent while the rest of the reply keeps going. Completion
    /// runs on the main actor: `true` = stopped, `false` = it had already finished.
    func cancelSubagent(agentID: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let info = subagent(agentID: agentID) else {
            completion(.failure(SubagentCancelError.notFound))
            return
        }
        guard info.isActive else {
            completion(.failure(SubagentCancelError.finished))
            return
        }
        guard info.canCancel, let backend = activeBackend as? SubagentCancelling else {
            completion(.failure(SubagentCancelError.unsupported))
            return
        }
        Log.write("session \(id.uuidString.prefix(8)): stopping subagent \(agentID.prefix(8))")
        backend.cancelSubagent(agentID: agentID) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(true) = result { self?.markSubagentCancelled(agentID: agentID) }
                completion(result)
            }
        }
    }

    /// Also covers a stop confirmed after the turn ended (no more parser events).
    private func markSubagentCancelled(agentID: String) {
        func cancelled(_ activity: ToolActivity) -> ToolActivity {
            if let info = activity.subagent, info.agentID == agentID {
                // The turn can end (finalizing it as done) before the stop is confirmed.
                guard info.isActive || info.status == .completed else { return activity }
                var stopped = activity.finishing(as: .cancelled)
                stopped.subagent?.status = .cancelled
                stopped.subagent?.canCancel = false
                return stopped
            }
            var activity = activity
            activity.children = activity.children.map(cancelled)
            return activity
        }
        for messageIndex in messages.indices {
            for activityIndex in messages[messageIndex].activities.indices {
                let current = messages[messageIndex].activities[activityIndex]
                let updated = cancelled(current)
                guard updated != current else { continue }
                messages[messageIndex].activities[activityIndex] = updated
                if messages[messageIndex].runID == currentRunID {
                    recordActivity(updated, messageID: messages[messageIndex].id)
                }
            }
        }
    }
}
