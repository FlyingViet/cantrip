import Foundation
import SwiftUI

struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    let role: Role
    var text: String
    var activities: [ToolActivity] = []
    enum Role: String, Codable { case user, assistant, error }
    // Activities are runtime-only; persisted transcripts skip them.
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
        if let data = try? JSONEncoder().encode(messages) {
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

    /// UI entry point. While streaming: queues by default, or interrupts
    /// the in-flight run and redirects when `interrupt` is true.
    func submit(_ text: String, interrupt: Bool = false) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard isStreaming else { send(prompt); return }
        if interrupt {
            Log.write("interrupt: redirecting in-flight request")
            streamGeneration += 1          // orphan the old stream's events
            activeBackend.cancel()
            finalizeRunningActivities(as: .cancelled)
            statusText = nil
            finishStream(dequeue: false)
            send(prompt, interrupted: true)
        } else {
            queued.append(prompt)
        }
    }

    private func send(_ text: String, interrupted: Bool = false) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming else { return }

        // "!" prefix: run a raw shell command directly, no LLM.
        if prompt.hasPrefix("!"), prompt.count > 1 {
            runShellCommand(String(prompt.dropFirst()).trimmingCharacters(in: .whitespaces))
            return
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
        let isFirstOfConversation = messages.isEmpty
        let previousTurns = completedConversationTurns()
        if title == "New chat" { title = String(prompt.prefix(34)) }
        messages.append(ChatMessage(role: .user, text: prompt))
        messages.append(ChatMessage(role: .assistant, text: ""))
        isStreaming = true
        statusText = "Thinking…"

        // Attach context (shown to the backend, not in the UI).
        var backendPrompt = prompt
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

    /// Re-armed on every backend event; fires only if the stream goes
    /// completely silent, so long tool runs are fine.
    private func armWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: inactivityLimit,
                                        repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isStreaming else { return }
                Log.write("watchdog: no backend activity for \(Int(self.inactivityLimit))s — force-cancelling")
                self.activeBackend.cancel()
                self.finalizeRunningActivities(as: .failed)
                self.messages.append(ChatMessage(
                    role: .error,
                    text: "No response for \(Int(self.inactivityLimit / 60)) minutes — request cancelled."))
                self.finishStream()
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
        case .status(let status):
            statusText = status
        case .activity(let activity):
            updateActivity(activity)
            statusText = currentActivity?.title ?? "Thinking…"
        case .done:
            finalizeRunningActivities(as: .succeeded)
            finishStream()
        case .failure(let message):
            finalizeRunningActivities(as: .failed)
            messages.append(ChatMessage(role: .error, text: message))
            finishStream()
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

    private func finishStream(dequeue: Bool = true) {
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
           messages[idx].activities.isEmpty {
            messages.remove(at: idx)
        }
        persistTranscript()
        // Auto-run the next queued message.
        if dequeue, !queued.isEmpty {
            let next = queued.removeFirst()
            DispatchQueue.main.async { [weak self] in
                self?.send(next)
            }
        } else {
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
        activeBackend.cancel()
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
            for activityIndex in messages[messageIndex].activities.indices
                where messages[messageIndex].activities[activityIndex].state == .running {
                messages[messageIndex].activities[activityIndex].state = state
            }
        }
    }
}
