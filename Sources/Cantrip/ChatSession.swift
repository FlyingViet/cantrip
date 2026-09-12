import Foundation
import SwiftUI
import Combine

struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    let role: Role
    var text: String
    var activities: [ToolActivity] = []
    /// Streamed reasoning (thinking deltas) — shown collapsed in the UI.
    var thinking: String = ""
    /// Which model produced this (council mode) — shown as a caption.
    var author: String?
    /// Associates persisted transcript messages with their durable run.
    var runID: UUID?
    enum Role: String, Codable { case user, assistant, error }
    // Activities and thinking are runtime-only; transcripts skip them.
    private enum CodingKeys: String, CodingKey { case id, role, text, author, runID }
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
    @Published var statusText: String?
    @Published var focusRequested = false
    /// Image file paths pasted (⌘V) to attach to the next query.
    @Published var attachments: [String] = []
    /// Messages queued while a response is streaming (run in order after).
    @Published private(set) var queued: [QueuedPrompt] = [] {
        didSet { remoteQueueRevision = UUID() }
    }
    @Published private(set) var deliveryStatus: String?
    private var routingTask: Task<Void, Never>?
    private var routingItemID: UUID?
    private var routingRevision = 0
    /// Text grabbed from another app via ⌥⇧Space, attached to next query.
    @Published var selectionContext: SelectionContext?
    /// Called when the whole run (including queue) completes; AppDelegate
    /// uses it for background notifications.
    var onRunFinished: (() -> Void)?
    private var preparationTask: Task<Void, Never>?
    /// Orphans events and preparation from cancelled/superseded backend runs.
    private var streamGeneration = 0 {
        didSet {
            preparationTask?.cancel()
            preparationTask = nil
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
    /// Durable run identity survives backend retries and process restarts.
    private var currentRunID: UUID?
    private var lastJournalRunID: UUID?
    private var currentRunStartedAt: Date?
    private var currentRunMode: RunJournal.Mode?
    private var currentRunBackend: BackendKind?
    private var currentAttempt = 0
    private var runningBackendKind: BackendKind?
    private var activityStartedAt: [String: Date] = [:]
    private var recordedArtifacts: Set<String> = []
    private var journal: RunJournal?
    private let makeJournal: (UUID) throws -> RunJournal
    @Published private(set) var journalError: String?
    /// Council mode: fan each prompt out to several backends in parallel,
    /// then have a chair synthesize the joint answer.
    @Published var councilMode = false {
        didSet {
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
    @Published private var automaticTitle = "New chat"
    @Published private(set) var tabMetadata = SessionTabMetadata()
    @Published var tabActionError: String?
    var title: String { tabMetadata.customTitle ?? automaticTitle }
    var isLocked: Bool { tabMetadata.isLocked }
    /// Per-session working directory: backends, ! commands, and git
    /// actions all run here. A session becomes "the agent in this repo".
    @Published var workdir: String {
        didSet { UserDefaults.standard.set(workdir, forKey: "workdir-\(id.uuidString)") }
    }
    /// Private mode: nothing this session touches disk on our side — no
    /// transcript, no session log, no continuity digest, and the memory
    /// vault becomes read-only for the agent.
    @Published var isPrivate = false {
        didSet {
            if isPrivate {
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
    private let claudeCode: ClaudeCodeBackend
    private let copilot = CopilotBackend()
    private let copilotRemote = CopilotACPBackend()
    private let codex: CodexBackend
    private let localModel = OpenAICompatibleBackend()
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

    private var activeBackend: Backend {
        backend(for: runningBackendKind ?? settings.backend)
    }

    private func backend(for kind: BackendKind) -> Backend {
        switch kind {
        case .claudeCode: return claudeCode
        case .copilot: return copilot
        case .copilotRemote: return copilotRemote
        case .codex: return codex
        case .localModel: return localModel
        }
    }

    init(id: UUID = UUID(), makeJournal: @escaping (UUID) throws -> RunJournal = { try RunJournal(sessionID: $0) }) {
        self.id = id
        self.makeJournal = makeJournal
        self.workdir = UserDefaults.standard.string(forKey: "workdir-\(id.uuidString)")
            ?? AppSettings.shared.claudeWorkdir
        self.claudeCode = ClaudeCodeBackend(persistKey: "claudeSessionID-\(id.uuidString)")
        self.codex = CodexBackend(persistKey: "codexSessionID-\(id.uuidString)")
        do {
            journal = try makeJournal(id)
        } catch {
            reportJournalFailure(error)
        }
        shellObservation = shell.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        loadTranscript()
        tabMetadata = SessionTabMetadata.load(id: id)
        restoreDurableState()
    }

    // MARK: - Transcript persistence (survives app restarts)

    private var transcriptURL: URL {
        SessionManager.chatsDir.appendingPathComponent("\(id.uuidString).json")
    }

    func deleteTranscript() {
        SessionTabMetadata.remove(id: id)
        try? FileManager.default.removeItem(at: transcriptURL)
        do {
            try journal?.remove()
        } catch {
            Log.write("run-journal: could not delete \(id.uuidString.prefix(8)): \(error.localizedDescription)")
        }
        journal = nil
        UserDefaults.standard.removeObject(forKey: "claudeSessionID-\(id.uuidString)")
        UserDefaults.standard.removeObject(forKey: "codexSessionID-\(id.uuidString)")
        UserDefaults.standard.removeObject(forKey: "workdir-\(id.uuidString)")
        // Council scratch sessions: scan for this session's keys so no
        // seat count or key scheme can strand them.
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix("councilClaude-\(id.uuidString)")
            || key.hasPrefix("councilCodex-\(id.uuidString)") {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func persistTranscript() {
        guard !isPrivate else { return }
        tabMetadata.save(id: id)
        // Thinking/activities don't persist, so assistant messages whose
        // only content was runtime-only would reload as invisible husks.
        let persistable = messages.filter {
            !($0.role == .assistant && $0.text.isEmpty)
        }
        if let data = try? JSONEncoder().encode(persistable) {
            try? data.write(to: transcriptURL)
        }
    }

    private func loadTranscript() {
        guard let data = try? Data(contentsOf: transcriptURL),
              let restored = try? JSONDecoder().decode([ChatMessage].self, from: data),
              !restored.isEmpty else { return }
        messages = Array(restored.suffix(30))
        if let first = messages.first(where: { $0.role == .user }) {
            automaticTitle = String(first.text.prefix(34))
        }
        Log.write("transcript: restored \(messages.count) messages (\(id.uuidString.prefix(8)))")
    }

    func updateTab(name: String? = nil, isLocked: Bool? = nil) throws {
        var updated = tabMetadata
        if let name { try updated.rename(name) }
        if let isLocked { updated.isLocked = isLocked }
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
        queueItemID: UUID? = nil
    ) -> UUID {
        if currentRunID != nil {
            cancelRun(reason: "superseded by a new run")
        }
        let runID = UUID()
        currentRunID = runID
        lastJournalRunID = runID
        currentRunStartedAt = Date()
        currentRunMode = mode
        currentRunBackend = backend
        currentAttempt = 1
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
        event.queueItemID = queueItemID
        appendRunEvent(event, durable: queueItemID != nil)
        return message.id
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
        clearCurrentRun()
    }

    private func cancelRun(reason: String) {
        guard let runID = currentRunID else { return }
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
        clearCurrentRun()
    }

    private func clearCurrentRun() {
        currentRunID = nil
        currentRunStartedAt = nil
        currentRunMode = nil
        currentRunBackend = nil
        currentAttempt = 0
        runningBackendKind = nil
        activityStartedAt.removeAll()
        recordedArtifacts.removeAll()
        currentRunPrompt = nil
        canResume = false
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

    func removeQueued(at index: Int) {
        guard queued.indices.contains(index) else { return }
        let item = queued.remove(at: index)
        if routingItemID == item.id {
            invalidateRouting()
            deliveryStatus = "Removed queued message."
        }
        recordQueueEvent(.queueRemoved, item: item)
    }

    private func removeQueued(_ item: QueuedPrompt) {
        guard let index = queued.firstIndex(where: { $0.id == item.id }) else { return }
        queued.remove(at: index)
        if routingItemID == item.id { invalidateRouting() }
        recordQueueEvent(.queueRemoved, item: item)
    }

    private func clearQueue() {
        invalidateRouting()
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
            } else {
                messages.append(ChatMessage(
                    id: recovered.id,
                    role: ChatMessage.Role(rawValue: recovered.role) ?? .assistant,
                    text: recovered.text,
                    activities: activities,
                    author: recovered.author,
                    runID: run.id
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
        recordInterruption("Cantrip exited before the run reached a terminal state.")
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
        receive(text, mode: mode, includesAmbientContext: true)
    }

    var supportsRemoteImages: Bool {
        settings.backend != .localModel && runningBackendKind != .localModel
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

    private var routerProvider: MessageRouter.Provider {
        let kind = settings.backend == .localModel ? .localModel : runningBackendKind ?? settings.backend
        switch kind {
        case .copilot:
            return .copilot(command: settings.copilotPath.isEmpty ? "copilot" : settings.copilotPath)
        case .claudeCode:
            return .claude(command: settings.claudePath.isEmpty ? "claude" : settings.claudePath)
        case .localModel:
            return .local(baseURL: settings.localBaseURL, model: settings.localModel,
                          apiKey: settings.localAPIKey)
        case .codex, .copilotRemote:
            return .unavailable("this backend does not expose isolated tool-free routing; use a manual override.")
        }
    }

    private func receive(_ text: String, mode: MessageDeliveryMode, includesAmbientContext: Bool) {
        var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        invalidateRouting()
        deliveryStatus = nil
        let wasBusy = isStreaming || !queued.isEmpty
        // Bind staged attachments to this message before asynchronous routing.
        // A queued/remote send must never consume somebody else's next draft.
        if includesAmbientContext, wasBusy, !prompt.hasPrefix("!"), !prompt.hasPrefix("/") {
            prompt = consumeStagedContext(onto: prompt, backendKind: runningBackendKind ?? settings.backend)
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
        let supportsInjection = runningBackendKind == .claudeCode && preparationTask == nil
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
                    decision, message: snapshot.message, supportsInjection: supportsInjection
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
                break
            case .inject:
                if self.activeBackend.injectMidTurn(item.text) {
                    self.appendRunMessage(ChatMessage(role: .user, text: item.text), queueItemID: item.id)
                    self.appendRunMessage(ChatMessage(role: .assistant, text: ""))
                    self.removeQueued(item)
                    self.persistTranscript()
                } else {
                    self.deliveryStatus = "Queued: the backend's live input channel was unavailable."
                }
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
            if !queued.isEmpty {
                enqueue(prompt, includesAmbientContext: includesAmbientContext)
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
            guard preparationTask == nil else {
                enqueue(prompt, includesAmbientContext: includesAmbientContext)
                return
            }
            if activeBackend.injectMidTurn(prompt) {
                appendRunMessage(ChatMessage(role: .user, text: prompt))
                appendRunMessage(ChatMessage(role: .assistant, text: ""))
                persistTranscript()
            } else { enqueue(prompt, includesAmbientContext: includesAmbientContext) }
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
            if !backendKeepsSession, let steps = interruptedStepSummary() {
                interruptContext = "(Context — steps my interrupted request had already taken:\n\(steps))"
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

    private func send(_ text: String, interrupted: Bool = false,
                      preamble: String? = nil, isResume: Bool = false,
                      includesAmbientContext: Bool = true,
                      consumesStagedContext: Bool = true,
                      queuedItem: QueuedPrompt? = nil) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming else { return }

        // "!" prefix: run a raw shell command directly, no LLM.
        if prompt.hasPrefix("!"), prompt.count > 1 {
            runShellCommand(String(prompt.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
        }

        // "/" prefix: user-defined script command (skill), no LLM.
        if prompt.hasPrefix("/"), prompt.count > 1 {
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

        // Instant answers: math, unit conversion, app launch — no LLM.
        if selectionContext == nil, let instant = InstantAnswers.answer(for: prompt) {
            Log.write("instant: \"\(prompt.prefix(60))\"")
            messages.append(ChatMessage(role: .user, text: prompt))
            messages.append(ChatMessage(role: .assistant, text: instant))
            persistTranscript()
            return
        }

        let backendKind = isResume ? (currentRunBackend ?? settings.backend) : settings.backend
        Log.write("send: \"\(prompt.prefix(80))\" via \(backendKind.rawValue)")
        canResume = false
        if !isResume {
            // Fresh run: remember the prompt so an interrupted run can be
            // resumed, and re-arm the one free automatic resume.
            beginRun(
                prompt: prompt,
                mode: .single,
                backends: [settings.backendLabel(backendKind)],
                backend: backendKind,
                includesAmbientContext: includesAmbientContext,
                queueItemID: queuedItem?.id
            )
            currentRunPrompt = prompt
            currentRunIncludesAmbientContext = includesAmbientContext
            autoResumeSpent = false
        }
        runningBackendKind = backendKind
        let isFirstOfConversation = messages.isEmpty
        let previousTurns = completedConversationTurns()
        if automaticTitle == "New chat" { automaticTitle = String(prompt.prefix(34)) }
        appendRunMessage(ChatMessage(role: .user, text: prompt))
        appendRunMessage(ChatMessage(role: .assistant, text: ""))
        isStreaming = true
        statusText = "Thinking…"

        // Attach context (shown to the backend, not in the UI).
        var backendPrompt = prompt
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
                                       consumesStagedContext: consumesStagedContext)

        UsageTracker.shared.recordQuery(backend: backendKind)
        armWatchdog()
        streamGeneration += 1
        let generation = streamGeneration
        prepareMemory(onto: backendPrompt, query: prompt, backendKind: backendKind,
                      generation: generation) { [weak self] prepared in
            guard let self else { return }
            let request = BackendRequest(
                prompt: prepared,
                userMessage: prompt,
                previousTurns: previousTurns
            )
            self.backend(for: backendKind).send(request, workdir: self.workdir) { [weak self] event in
                DispatchQueue.main.async {
                    guard let self, self.streamGeneration == generation else { return }
                    self.handle(event)
                }
            }
        }
    }

    private func prepareMemory(onto prompt: String, query: String, backendKind: BackendKind?,
                               generation: Int, completion: @escaping (String) -> Void) {
        let memoryEnabled = settings.memoryEnabled
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
            let block = memoryEnabled ? await MemoryStore.contextBlock(
                query: query, path: path, isPrivate: privacy, isLocal: backendKind == .localModel
            ) : ""
            guard !Task.isCancelled, self.streamGeneration == generation,
                  self.isStreaming else { return }
            self.preparationTask = nil
            guard self.isPrivate == privacy, self.workdir == directory,
                  self.settings.backend == configuredBackend,
                  self.settings.memoryEnabled == memoryEnabled, self.settings.memoryPath == path else {
                self.cancel(keepQueue: true)
                self.deliveryStatus = "Preparation cancelled because session settings changed. Send again to use the new settings."
                return
            }
            self.statusText = "Thinking…"
            completion(prompt + block)
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
                                consumesStagedContext: Bool = true) -> String {
        var backendPrompt = prompt
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

    private func consumeStagedContext(onto prompt: String, backendKind: BackendKind?) -> String {
        var result = prompt
        if let selection = selectionContext {
            result += "\n\n(Selected text from \(selection.appName), which my request refers to:\n\"\"\"\n\(selection.text.prefix(4000))\n\"\"\")"
            selectionContext = nil
        }
        if backendKind != .localModel {
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg"]
            for path in attachments {
                let isImage = imageExts.contains((path as NSString).pathExtension.lowercased())
                result += isImage
                    ? "\n\n(Attached image: \(path) — view this image file; it is part of my request.)"
                    : "\n\n(Attached file: \(path) — read/analyze this file; it is part of my request.)"
            }
        }
        attachments.removeAll()
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
            // Key by seat AND model so replacing a seat never resumes a
            // different model's scratch session.
            let b = ClaudeCodeBackend(persistKey: "councilClaude-\(id.uuidString)-\(index)-\(member.model)")
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
            let b = CodexBackend(persistKey: "councilCodex-\(id.uuidString)-\(index)-\(member.model)")
            b.modelOverride = member.model.isEmpty ? nil : member.model
            b.readOnly = true
            fresh = b
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
        if automaticTitle == "New chat" { automaticTitle = String(prompt.prefix(34)) }
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
                shell.mirror(activity)
                recordActivity(activity, messageID: messageID)
            }
        case .usage(let usage):
            recordUsage(usage)
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
        if let thinking { messages[idx].thinking += thinking }
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
                        self.shell.mirror(activity)
                        self.recordActivity(activity, messageID: messageID)
                    }
                case .usage(let usage):
                    self.recordUsage(usage)
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
        for message in messages {
            switch message.role {
            case .user:
                pendingUser = message.text
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
            }
        }
        return turns
    }

    private var shellProcess: Process?

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
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
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
                messages[idx].thinking += delta
            }
            statusText = currentActivity?.title ?? "Thinking…"
        case .status(let status):
            statusText = status
        case .activity(let activity):
            updateActivity(activity)
            shell.mirror(activity)
            if let message = messages.last(where: { $0.role == .assistant }) {
                recordActivity(activity, messageID: message.id)
            }
            statusText = currentActivity?.title ?? "Thinking…"
        case .usage(let usage):
            recordUsage(usage)
        case .approval(let approval):
            recordApproval(approval)
        case .done:
            finalizeRunningActivities(as: .succeeded)
            let summary = messages.last(where: { $0.role == .assistant })?.text ?? ""
            completeRun(status: "succeeded", summary: summary)
            finishStream()
        case .failure(let message):
            handleRunInterruption(errorText: message)
        }
    }

    // MARK: - Resume after an interrupted run

    /// A run died mid-flight (watchdog timeout or backend failure).
    /// Record the error, then — if the run had actually started work —
    /// auto-resume once, or surface the Resume button after that.
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
        let resumable = currentRunPrompt != nil && lastRunHadProgress
        recordInterruption(errorText)
        appendRunMessage(ChatMessage(role: .error, text: errorText))
        guard resumable else {
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
            // Surface the Resume button only after the SIGTERM → SIGKILL
            // escalation window, so a fast click can't relaunch the CLI
            // session while the hung process is still dying.
            finishStream(dequeue: false) { [weak self] in
                guard let self else { return }
                let generation = self.streamGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                    guard let self, !self.isStreaming,
                          self.streamGeneration == generation else { return }
                    self.canResume = true
                }
            }
        }
    }

    /// Whether the interrupted run got anywhere (tool steps or partial
    /// text). A run that died before doing anything isn't "resumable" —
    /// there are no previous steps to pick up from.
    private var lastRunHadProgress: Bool {
        guard let message = messages.last(where: { $0.role == .assistant }) else {
            return false
        }
        return !message.activities.isEmpty || !message.text.isEmpty
    }

    /// Delay so the killed backend process fully dies before the
    /// replacement launches — must outlast the backends' 3s SIGTERM →
    /// SIGKILL escalation so a hung process can't race the new stream.
    private func scheduleAutoResume() {
        let generation = streamGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, !self.isStreaming,
                  self.streamGeneration == generation else { return }
            self.performResume(auto: true)
        }
    }

    /// Manual entry point (Resume button).
    func resumeInterrupted() {
        performResume(auto: false)
    }

    private func performResume(auto: Bool) {
        guard !isStreaming, let original = currentRunPrompt else { return }
        canResume = false
        var preamble = "(My previous request was interrupted mid-run and cancelled."
            + " Original request: \"\(original.prefix(1000))\""
        if let steps = interruptedStepSummary() {
            preamble += "\nSteps already taken before the interruption:\n\(steps)"
        }
        preamble += "\nResume that task from where it left off: verify which steps already completed, then continue — don't redo finished work or start over.)"
        Log.write("resume: \(auto ? "auto" : "manual") resume of interrupted run")
        recordResumeAttempt(reason: auto ? "automatic-resume" : "manual-resume")
        send(
            "Continue from where you left off.",
            preamble: preamble,
            isResume: true,
            includesAmbientContext: currentRunIncludesAmbientContext
        )
    }

    /// Backends with native session state (--resume / exec resume) carry
    /// interrupted-turn context themselves; stateless ones need the
    /// harness to inject it.
    private var backendKeepsSession: Bool {
        switch currentRunBackend ?? settings.backend {
        case .claudeCode, .codex: return true
        // copilotRemote keeps its ACP session while the app runs, but an
        // interrupted turn's context isn't replayable — inject like the
        // other stateless backends.
        case .copilot, .copilotRemote, .localModel: return false
        }
    }

    /// Work log of the interrupted turn, for backends without native
    /// session resume (Copilot, local models). Claude Code and Codex
    /// already recover full detail via --resume/exec resume.
    private func interruptedStepSummary() -> String? {
        // Only the interrupted turn itself — an earlier turn's steps
        // would misrepresent what "was already done" for this task.
        guard let message = messages.last(where: { $0.role == .assistant }),
              !message.activities.isEmpty else { return nil }
        let lines = message.activities.suffix(30).map { activity in
            "- [\(stateLabel(activity.state))] \(activity.toolName): \(activity.title)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
        processOverlayBlock()
        isStreaming = false
        statusText = nil
        // Session layer: log the completed exchange for future grep.
        if settings.memoryEnabled, !isPrivate,
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
            MemoryStore.shared.logExchange(user: messages[userIdx].text,
                                           assistant: messages[assistantIdx].text,
                                           backend: backendTag)
        }
        // Drop empty assistant placeholder if nothing arrived.
        if let idx = messages.lastIndex(where: { $0.role == .assistant }),
           messages[idx].text.isEmpty,
           messages[idx].activities.isEmpty,
           messages[idx].thinking.isEmpty {
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
        } else if notify {
            // Whole run complete: speak the reply / notify if hidden.
            if settings.voiceMode,
               let reply = messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) {
                SpeechSynth.shared.speak(reply.text)
            }
            onRunFinished?()
        }
    }

    private func drainQueue() {
        guard !isStreaming, journalError == nil, let next = queued.first else { return }
        councilMode
            ? sendCouncil(next.text, includesAmbientContext: next.includesAmbientContext,
                          consumesStagedContext: false, queuedItem: next)
            : send(next.text, includesAmbientContext: next.includesAmbientContext,
                   consumesStagedContext: false, queuedItem: next)
        removeQueued(next)
        deliveryStatus = "Sent the next queued message."
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

    private func cancel(keepQueue: Bool) {
        invalidateRouting()
        deliveryStatus = nil
        streamGeneration += 1        // orphan any in-flight events
        SpeechSynth.shared.stop()
        shellProcess?.terminate()
        shellProcess = nil
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

    func newConversation() {
        guard !isLocked else {
            tabActionError = SessionTabError.locked.localizedDescription
            return
        }
        invalidateRouting()
        deliveryStatus = nil
        // Continuity: stash a digest of this conversation for the next one.
        if messages.count >= 2, !isPrivate {
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
        claudeCode.reset()
        copilot.reset()
        copilotRemote.reset()
        codex.reset()
        localModel.reset()
        for backend in councilInstances.values { backend.reset() }
        councilInstances = [:]
        messages.removeAll()
        isStreaming = false
        statusText = nil
        canResume = false
        currentRunPrompt = nil
        currentRunIncludesAmbientContext = true
        autoResumeSpent = false
        if let runID = currentRunID ?? lastJournalRunID {
            appendRunEvent(RunJournal.Event(
                sessionID: id,
                runID: runID,
                kind: .conversationReset
            ), durable: true)
        }
        clearQueue()
        clearCurrentRun()
        persistTranscript()
    }

    private func updateActivity(_ activity: ToolActivity) {
        guard let messageIndex = messages.lastIndex(where: { $0.role == .assistant }) else {
            return
        }
        if let activityIndex = messages[messageIndex].activities.firstIndex(
            where: { $0.id == activity.id }
        ) {
            messages[messageIndex].activities[activityIndex] = activity
        } else {
            messages[messageIndex].activities.append(activity)
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
        var activity = activity
        if activity.state == .running {
            activity.state = state
        }
        activity.children = activity.children.map { finalize($0, as: state) }
        return activity
    }
}
