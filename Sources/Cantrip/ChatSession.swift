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
    enum Role: String, Codable { case user, assistant, error }
    // Activities and thinking are runtime-only; transcripts skip them.
    private enum CodingKeys: String, CodingKey { case id, role, text, author }
}

/// Drives the conversation: routes queries to the selected backend,
/// accumulates streamed output, and exposes state to the UI.
@MainActor
final class ChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming = false
    @Published var statusText: String?
    @Published var focusRequested = false
    /// Image file paths pasted (⌘V) to attach to the next query.
    @Published var attachments: [String] = []
    /// Messages queued while a response is streaming (run in order after).
    @Published var queued: [String] = []
    /// Text grabbed from another app via ⌥⇧Space, attached to next query.
    @Published var selectionContext: SelectionContext?
    /// Called when the whole run (including queue) completes; AppDelegate
    /// uses it for background notifications.
    var onRunFinished: (() -> Void)?
    /// Orphans events from cancelled/superseded backend runs.
    private var streamGeneration = 0
    /// True when the last run died mid-task (timeout/failure) and can be
    /// picked up from the steps already taken. Shows the Resume button.
    @Published var canResume = false
    /// The user prompt whose run was interrupted; resume re-anchors on it.
    private var currentRunPrompt: String?
    /// One free automatic resume per user-initiated run; manual after that.
    private var autoResumeSpent = false
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
    /// Tab label — set from the first prompt.
    @Published var title = "New chat"
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
                Log.write("session \(id.uuidString.prefix(8)): private mode ON")
            } else {
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
        backend(for: settings.backend)
    }

    private func backend(for kind: BackendKind) -> Backend {
        switch kind {
        case .claudeCode: return claudeCode
        case .copilot: return copilot
        case .codex: return codex
        case .localModel: return localModel
        }
    }

    init(id: UUID = UUID()) {
        self.id = id
        self.workdir = UserDefaults.standard.string(forKey: "workdir-\(id.uuidString)")
            ?? AppSettings.shared.claudeWorkdir
        self.claudeCode = ClaudeCodeBackend(persistKey: "claudeSessionID-\(id.uuidString)")
        self.codex = CodexBackend(persistKey: "codexSessionID-\(id.uuidString)")
        shellObservation = shell.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        loadTranscript()
    }

    // MARK: - Transcript persistence (survives app restarts)

    private var transcriptURL: URL {
        SessionManager.chatsDir.appendingPathComponent("\(id.uuidString).json")
    }

    func deleteTranscript() {
        try? FileManager.default.removeItem(at: transcriptURL)
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
            title = String(first.text.prefix(34))
        }
        Log.write("transcript: restored \(messages.count) messages (\(id.uuidString.prefix(8)))")
    }

    /// UI entry point. While streaming: queues by default; `interrupt`
    /// kills and redirects; `inject` adds to the running turn's context
    /// (Claude backend) without interrupting.
    func submit(_ text: String, interrupt: Bool = false, inject: Bool = false) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard isStreaming else {
            councilMode ? sendCouncil(prompt) : send(prompt)
            return
        }
        if councilRunning, inject, !interrupt {
            queued.append(prompt) // per-member injection would diverge the seats
            return
        }
        if inject, !interrupt {
            if activeBackend.injectMidTurn(prompt) {
                messages.append(ChatMessage(role: .user, text: prompt))
                messages.append(ChatMessage(role: .assistant, text: ""))
                persistTranscript()
            } else {
                queued.append(prompt) // backend can't inject — queue it
            }
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
            finishStream(dequeue: false)
            councilMode ? sendCouncil(prompt) : send(prompt)
            return
        }
        if interrupt {
            Log.write("interrupt: redirecting in-flight request")
            streamGeneration += 1          // orphan the old stream's events
            // Prefer a graceful in-band interrupt (keeps the process and
            // session hot); fall back to killing the process.
            if !activeBackend.interruptTurn() { activeBackend.cancel() }
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
            finishStream(dequeue: false)
            if councilMode {
                sendCouncil(prompt)
            } else {
                send(prompt, interrupted: true, preamble: interruptContext)
            }
        } else {
            queued.append(prompt)
        }
    }

    private func send(_ text: String, interrupted: Bool = false,
                      preamble: String? = nil, isResume: Bool = false) {
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

        Log.write("send: \"\(prompt.prefix(80))\" via \(settings.backend.rawValue)")
        canResume = false
        if !isResume {
            // Fresh run: remember the prompt so an interrupted run can be
            // resumed, and re-arm the one free automatic resume.
            currentRunPrompt = prompt
            autoResumeSpent = false
        }
        let isFirstOfConversation = messages.isEmpty
        let previousTurns = completedConversationTurns()
        if title == "New chat" { title = String(prompt.prefix(34)) }
        messages.append(ChatMessage(role: .user, text: prompt))
        messages.append(ChatMessage(role: .assistant, text: ""))
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
                                       backendKind: settings.backend)

        UsageTracker.shared.recordQuery(backend: settings.backend)
        armWatchdog()
        streamGeneration += 1
        let generation = streamGeneration
        let request = BackendRequest(
            prompt: backendPrompt,
            userMessage: prompt,
            previousTurns: previousTurns
        )
        activeBackend.send(request, workdir: workdir) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.streamGeneration == generation else { return }
                self.handle(event)
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
                                backendKind: BackendKind?) -> String {
        var backendPrompt = prompt
        if isFirstOfConversation,
           let digest = UserDefaults.standard.string(forKey: "lastConversationDigest"),
           !digest.isEmpty {
            backendPrompt += "\n\n(Context — summary of my previous conversation, for continuity: \(digest))"
        }
        if settings.shareLocation, let location = LocationProvider.shared.contextLine {
            backendPrompt += "\n\n(Context: my current location is \(location), local time \(Date().formatted(date: .abbreviated, time: .shortened)). Use this if relevant to my request; otherwise ignore it and don't mention it.)"
        }
        if settings.fileRAGEnabled, let files = FileRAG.shared.injection() {
            backendPrompt += "\n\n(FILES — content excerpts from documents on my disk that match this query, found via the Spotlight index:\n\(files)\nUse them if relevant — you may open the full file at its path for more context. If they're unrelated to my request, ignore them and don't mention them.)"
        }
        if settings.shareCalendar, let agenda = CalendarProvider.shared.contextLine {
            backendPrompt += "\n\n(Context — my calendar for the next 48 hours:\n\(agenda.prefix(1500))\nUse this if relevant to my request; otherwise ignore it and don't mention it.)"
        }
        if let selection = selectionContext {
            backendPrompt += "\n\n(Selected text from \(selection.appName), which my request refers to:\n\"\"\"\n\(selection.text.prefix(4000))\n\"\"\")"
            selectionContext = nil
        }
        SpeechSynth.shared.stop()
        OverlayController.shared.clear()
        if !attachments.isEmpty, backendKind != .localModel {
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp",
                                          "heic", "tiff", "bmp", "svg"]
            for path in attachments {
                let ext = (path as NSString).pathExtension.lowercased()
                if imageExts.contains(ext) {
                    backendPrompt += "\n\n(Attached image: \(path) — view this image file; it is part of my request.)"
                } else {
                    backendPrompt += "\n\n(Attached file: \(path) — read/analyze this file; it is part of my request.)"
                }
            }
        }
        attachments.removeAll()
        if settings.attachScreen, backendKind != .localModel,
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
        if settings.memoryEnabled {
            MemoryStore.shared.ensureVault()
            let retrieved = MemoryStore.shared.retrieve(for: query).map {
                "\n\nRETRIEVED — memory snippets auto-matched to this query (verify before relying on them):\n\($0)"
            } ?? ""
            if backendKind == .localModel {
                backendPrompt += "\n\n(Memory from previous sessions:\n\(MemoryStore.shared.coreMemoryBlock())\(retrieved))"
            } else {
                backendPrompt += """


                (Persistent memory — three layers, all in \(settings.memoryPath):

                CORE — always loaded, maintain within caps:
                \(MemoryStore.shared.coreMemoryBlock())

                NOTES — procedures that worked; read relevant ones BEFORE acting: \(MemoryStore.shared.indexLine())

                SESSIONS — past conversations logged in \(settings.memoryPath)/sessions/ as daily markdown; grep them when I reference something from before.\(retrieved)

                \(isPrivate
                    ? "PRIVATE MODE: treat the memory vault as READ-ONLY this conversation. Do NOT create, update, or delete any notes, core memory files, or session logs, and don't record anything about this conversation anywhere."
                    : "Maintain memory silently as you work: new environment facts/conventions → edit MEMORY.md; new facts or preferences about me → edit USER.md; both must stay under their caps, so consolidate rather than append. After a task that took trial-and-error, write/update a concise procedure note. Don't mention the vault unless asked."))
                """
            }
        }
        return backendPrompt
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

    private func sendCouncil(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming else { return }
        // Shell/skill/instant prompts don't need a council.
        if prompt.hasPrefix("!") || prompt.hasPrefix("/")
            || (selectionContext == nil && InstantAnswers.answer(for: prompt) != nil) {
            send(prompt)
            return
        }
        // Councils are for planning and review — implementation is one
        // worker's job, and N models implementing in parallel is waste.
        if settings.councilScope == "planReview", Self.looksLikeExecution(prompt) {
            Log.write("council: execution prompt — routed to the worker (\(settings.backend.rawValue))")
            send(prompt)
            return
        }
        let members = settings.councilMembers.filter { $0.kind != nil }
        guard members.count >= 2 else { send(prompt); return }

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
        let isFirstOfConversation = messages.isEmpty
        let previousTurns = completedConversationTurns()
        if title == "New chat" { title = String(prompt.prefix(34)) }
        messages.append(ChatMessage(role: .user, text: prompt))
        isStreaming = true
        councilRunning = true
        councilAnswers = []
        councilFinished = []
        councilSynthesizing = false
        statusText = "Council of \(members.count) deliberating…"

        let composed = composeContext(onto: prompt, query: prompt,
                                      isFirstOfConversation: isFirstOfConversation,
                                      backendKind: nil)
        let roundPrompt = composed + """


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

        for (index, member) in members.enumerated() {
            let message = ChatMessage(role: .assistant, text: "", author: member.label)
            let messageID = message.id
            messages.append(message)
            councilAnswers.append((kind: member.kind ?? .claudeCode, messageID: messageID))
            if let kind = member.kind { UsageTracker.shared.recordQuery(backend: kind) }
            let request = BackendRequest(prompt: roundPrompt, userMessage: prompt,
                                         previousTurns: previousTurns)
            councilBackend(index: index, member: member)
                .send(request, workdir: workdir) { [weak self] event in
                    DispatchQueue.main.async {
                        guard let self, self.streamGeneration == generation else { return }
                        self.handleCouncilEvent(event, messageID: messageID,
                                                prompt: prompt, generation: generation)
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
            }
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
        messages.append(message)

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
                    }
                case .done:
                    self.streamGeneration += 1 // orphan chair double-terminals
                    self.councilRunning = false
                    self.finalizeRunningActivities(as: .succeeded)
                    self.finishStream()
                case .failure(let message):
                    self.streamGeneration += 1
                    self.councilRunning = false
                    self.messages.append(ChatMessage(role: .error,
                                                     text: "Synthesis failed: \(message)"))
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
        if title == "New chat" { title = "! " + String(command.prefix(30)) }
        messages.append(ChatMessage(role: .user, text: "! " + command))
        messages.append(ChatMessage(role: .assistant, text: "```\n"))
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
                    if text == "```\n" { text += "(no output)\n" }
                    text += "\n```"
                    if proc.terminationStatus != 0 {
                        text += "\nexit \(proc.terminationStatus)"
                    }
                    self.messages[idx].text = text
                }
                self.shellProcess = nil
                self.finishStream()
            }
        }

        do {
            try p.run()
            shellProcess = p
        } catch {
            messages.append(ChatMessage(role: .error,
                                        text: "Failed to run: \(error.localizedDescription)"))
            shellProcess = nil
            finishStream(dequeue: false)
        }
    }

    /// `/name args` — run a skill script, streaming stdout into the
    /// transcript as markdown (skills are expected to emit markdown).
    private func runScriptCommand(_ command: ScriptCommand, args: String) {
        guard !isStreaming else { return }
        Log.write("skill: /\(command.name) \(args.prefix(60))")
        canResume = false
        currentRunPrompt = nil // script runs aren't LLM-resumable
        if title == "New chat" { title = "/" + command.name }
        messages.append(ChatMessage(role: .user, text: "/\(command.name)\(args.isEmpty ? "" : " \(args)")"))
        messages.append(ChatMessage(role: .assistant, text: ""))
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
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.streamGeneration == generation else { return }
                if let idx = self.messages.lastIndex(where: { $0.role == .assistant }) {
                    if self.messages[idx].text.isEmpty {
                        self.messages[idx].text = "*(no output)*"
                    }
                    if proc.terminationStatus != 0 {
                        self.messages[idx].text += "\n\n`exit \(proc.terminationStatus)`"
                    }
                }
                self.shellProcess = nil
                self.finishStream()
            }
        }
        do {
            try p.run()
            shellProcess = p
        } catch {
            messages.append(ChatMessage(role: .error,
                                        text: "Failed to run /\(command.name): \(error.localizedDescription)"))
            finishStream(dequeue: false)
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
            statusText = currentActivity?.title ?? "Thinking…"
        case .done:
            finalizeRunningActivities(as: .succeeded)
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
        messages.append(ChatMessage(role: .error, text: errorText))
        guard resumable else {
            finishStream()
            return
        }
        if !autoResumeSpent {
            autoResumeSpent = true
            // Queue waits for the resumed run; no notification/speech for
            // an interruption we're about to retry silently.
            finishStream(dequeue: false, notify: false)
            Log.write("resume: run interrupted — auto-resuming")
            scheduleAutoResume()
        } else {
            finishStream(dequeue: false) // hold queue; notify — needs attention
            // Surface the Resume button only after the SIGTERM → SIGKILL
            // escalation window, so a fast click can't relaunch the CLI
            // session while the hung process is still dying.
            let generation = streamGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self, !self.isStreaming,
                      self.streamGeneration == generation else { return }
                self.canResume = true
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
        send("Continue from where you left off.", preamble: preamble, isResume: true)
    }

    /// Backends with native session state (--resume / exec resume) carry
    /// interrupted-turn context themselves; stateless ones need the
    /// harness to inject it.
    private var backendKeepsSession: Bool {
        switch settings.backend {
        case .claudeCode, .codex: return true
        case .copilot, .localModel: return false
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

    private func finishStream(dequeue: Bool = true, notify: Bool = true) {
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
            let next = queued.removeFirst()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.councilMode ? self.sendCouncil(next) : self.send(next)
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

    func cancel() {
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
        queued.removeAll()           // manual stop aborts the whole queue
        finalizeRunningActivities(as: .cancelled)
        finishStream(dequeue: false)
    }

    func newConversation() {
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
        codex.reset()
        localModel.reset()
        for backend in councilInstances.values { backend.reset() }
        councilInstances = [:]
        messages.removeAll()
        isStreaming = false
        statusText = nil
        canResume = false
        currentRunPrompt = nil
        autoResumeSpent = false
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
