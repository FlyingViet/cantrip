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
    enum Role: String, Codable { case user, assistant, error }
    // Activities and thinking are runtime-only; transcripts skip them.
    private enum CodingKeys: String, CodingKey { case id, role, text }
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
        switch settings.backend {
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
        guard isStreaming else { send(prompt); return }
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
            send(prompt, interrupted: true, preamble: interruptContext)
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
        if !attachments.isEmpty, settings.backend != .localModel {
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
        if settings.attachScreen, settings.backend != .localModel,
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
            let retrieved = MemoryStore.shared.retrieve(for: prompt).map {
                "\n\nRETRIEVED — memory snippets auto-matched to this query (verify before relying on them):\n\($0)"
            } ?? ""
            if settings.backend == .localModel {
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

    private func completedConversationTurns() -> [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var pendingUser: String?
        for message in messages {
            switch message.role {
            case .user:
                pendingUser = message.text
            case .assistant:
                guard let user = pendingUser, !message.text.isEmpty else { continue }
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
        processOverlayBlock()
        isStreaming = false
        statusText = nil
        // Session layer: log the completed exchange for future grep.
        if settings.memoryEnabled, !isPrivate,
           let userIdx = messages.lastIndex(where: { $0.role == .user }),
           let assistantIdx = messages.lastIndex(where: { $0.role == .assistant }),
           assistantIdx > userIdx, !messages[assistantIdx].text.isEmpty {
            MemoryStore.shared.logExchange(user: messages[userIdx].text,
                                           assistant: messages[assistantIdx].text,
                                           backend: settings.backend.rawValue)
        }
        // Drop empty assistant placeholder if nothing arrived.
        if let idx = messages.lastIndex(where: { $0.role == .assistant }),
           messages[idx].text.isEmpty,
           messages[idx].activities.isEmpty,
           messages[idx].thinking.isEmpty {
            messages.remove(at: idx)
        }
        persistTranscript()
        // Auto-run the next queued message.
        if dequeue, !queued.isEmpty {
            let next = queued.removeFirst()
            DispatchQueue.main.async { [weak self] in
                self?.send(next)
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
        claudeCode.reset()
        copilot.reset()
        codex.reset()
        localModel.reset()
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
