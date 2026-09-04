import SwiftUI
import MarkdownUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var turns: [ChatTurn] = []
    @Published var sending = false
    @Published private(set) var runStatusText: String?
    @Published private(set) var activeLane: ExecutionLane
    @Published private(set) var remoteIsStreaming = false
    @Published var remoteDeliveryMode: CantripDeliveryMode = .queue

    let env: HermesEnv
    let remote: CantripRemoteModel
    let voice: VoiceController
    private var conversationID: String
    private var gatewayIdentity: String?
    private var pendingRun: PendingHermesRun?
    private var activeRun: ActiveHermesRun?
    private var observationTask: Task<Void, Never>?
    private var observationGeneration = 0
    private var remoteSessionID: String?
    private var remoteMessageIDs: [String: UUID] = [:]
    private var remoteSpeechBaseline: Set<String> = []
    private var remoteSpeechTargetID: String?
    private var remoteSpeechActive = false
    private var spokenReplyTurnID: UUID?

    var isWorking: Bool {
        sending || remoteIsStreaming
    }

    init(env: HermesEnv, remote: CantripRemoteModel, voice: VoiceController) {
        self.env = env
        self.remote = remote
        self.voice = voice
        activeLane = env.executionLane
        conversationID = UUID().uuidString
        if activeLane == .cantrip {
            gatewayIdentity = nil
        } else {
            let snapshot = ChatStore.load(for: activeLane)
            turns = snapshot.turns
            gatewayIdentity = env.gatewayIdentity
            if let storedGateway = snapshot.gatewayIdentity,
               storedGateway != env.gatewayIdentity {
                turns = []
            } else {
                conversationID = snapshot.conversationID ?? UUID().uuidString
                pendingRun = snapshot.pendingRun
                activeRun = snapshot.activeRun
            }
        }
        sending = pendingRun != nil || activeRun != nil
        if sending {
            runStatusText = "Reconnecting to the run on your Mac…"
        }
        voice.onFinalTranscript = { [weak self] text in self?.send(text, spoken: true) }
        Task { [weak self] in
            guard let self else { return }
            if self.activeLane == .cantrip {
                self.syncRemoteTranscript()
            } else {
                self.resumeActiveRun()
            }
        }
    }

    func send(_ raw: String, spoken: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Paused → drop every send (text, voice, skill, button) so we never fire
        // an unintentional request at the agent.
        guard !UserDefaults.standard.bool(forKey: "hermes.paused") else { return }
        guard !text.isEmpty else { return }
        if activeLane == .cantrip {
            sendRemote(text, spoken: spoken)
            return
        }
        guard !sending else { return }
        let lane = activeLane
        guard lane != .local || env.isAvailable(.local) else {
            appendLocalFailure(
                "The local-private route is not configured on the gateway.",
                for: text,
                lane: lane
            )
            return
        }
        guard let client = env.client(for: lane) else {
            appendLocalFailure(
                env.configurationIssue ?? "Configure the gateway before sending.",
                for: text,
                lane: lane
            )
            return
        }

        turns.append(ChatTurn(role: .user, text: text, executionLane: lane))
        let assistant = ChatTurn(
            role: .assistant,
            streaming: true,
            executionLane: lane
        )
        turns.append(assistant)
        let pending = PendingHermesRun(
            idempotencyKey: "ios-\(UUID().uuidString)",
            assistantTurnID: assistant.id,
            input: text,
            history: conversationHistory(),
            sessionID: conversationID,
            executionLane: lane,
            showSteps: UserDefaults.standard.bool(forKey: "hermes.showSteps"),
            startedAt: Date()
        )
        pendingRun = pending
        sending = true
        runStatusText = "Sending to your Mac…"
        persist()

        // Speak the reply aloud sentence-by-sentence as it streams when this turn
        // was voice-initiated or we're in hands-free voice mode.
        let speakReply = spoken || voice.handsFree
        spokenCount = 0
        speechTableHeader = nil
        spokenReplyTurnID = speakReply ? assistant.id : nil
        if speakReply {
            voice.beginReply()
        }

        startObservation {
            await self.dispatchAndObserve(pending, client: client)
        }
    }

    private func sendRemote(_ text: String, spoken: Bool) {
        guard !sending, !remote.isMutating else { return }
        guard remote.isConfigured else {
            appendRemoteFailure("Configure Cantrip Remote in Settings.", for: text)
            return
        }
        guard remote.selectedSessionID != nil else {
            appendRemoteFailure("Choose or create a Cantrip session first.", for: text)
            return
        }

        let speakReply = spoken || voice.handsFree
        remoteSpeechBaseline = Set(
            remote.selectedSession?.transcript.map(\.id) ?? []
        )
        remoteSpeechTargetID = nil
        remoteSpeechActive = speakReply
        spokenCount = 0
        speechTableHeader = nil
        if speakReply { voice.beginReply() }

        turns.append(
            ChatTurn(role: .user, text: text, executionLane: .cantrip)
        )
        turns.append(
            ChatTurn(
                role: .assistant,
                streaming: true,
                executionLane: .cantrip
            )
        )
        sending = true
        runStatusText = "Sending to Cantrip…"

        Task { [weak self] in
            guard let self else { return }
            let sent = await self.remote.send(
                text,
                mode: self.remoteDeliveryMode
            )
            self.sending = false
            if sent {
                self.syncRemoteTranscript()
            } else {
                if let index = self.turns.lastIndex(where: {
                    $0.role == .assistant && $0.streaming
                }) {
                    self.turns[index].streaming = false
                    self.turns[index].error = self.remote.errorMessage
                        ?? "Cantrip did not accept the prompt."
                }
                self.remoteIsStreaming = false
                self.runStatusText = nil
                self.finishRemoteSpeech()
            }
        }
    }

    private func appendRemoteFailure(_ message: String, for input: String) {
        turns.append(
            ChatTurn(role: .user, text: input, executionLane: .cantrip)
        )
        turns.append(
            ChatTurn(
                role: .assistant,
                error: message,
                executionLane: .cantrip
            )
        )
    }

    func syncRemoteTranscript() {
        guard activeLane == .cantrip else { return }
        let session = remote.selectedSession
        if remoteSessionID != session?.id {
            let changedExistingSession = remoteSessionID != nil
            remoteSessionID = session?.id
            remoteMessageIDs.removeAll()
            if changedExistingSession, remoteSpeechActive {
                voice.stopSpeaking()
                remoteSpeechActive = false
            }
        }

        let transcript = session?.transcript ?? []
        let lastAssistantID = transcript.last(where: {
            $0.role != "user" && $0.role != "error"
        })?.id
        turns = transcript.map { message in
            let id = remoteMessageIDs[message.id] ?? UUID()
            remoteMessageIDs[message.id] = id
            let isError = message.role == "error"
            return ChatTurn(
                id: id,
                role: message.role == "user" ? .user : .assistant,
                text: isError ? "" : message.text,
                tools: message.activities.map {
                    ToolActivity(
                        id: $0.id,
                        name: $0.toolName,
                        arguments: $0.title,
                        output: $0.state == "running" ? nil : $0.state.capitalized,
                        done: $0.state != "running"
                    )
                },
                streaming: session?.isStreaming == true
                    && message.id == lastAssistantID,
                error: isError ? message.text : nil,
                executionLane: .cantrip,
                thinking: message.thinking.isEmpty ? nil : message.thinking,
                author: message.author
            )
        }

        remoteIsStreaming = session?.isStreaming ?? false
        if remoteIsStreaming {
            runStatusText = session?.status ?? "Cantrip is working…"
        } else {
            runStatusText = nil
        }

        guard remoteSpeechActive else { return }
        if remoteSpeechTargetID == nil {
            remoteSpeechTargetID = transcript.last(where: {
                $0.role != "user"
                    && $0.role != "error"
                    && !remoteSpeechBaseline.contains($0.id)
            })?.id
        }
        if let targetID = remoteSpeechTargetID,
           let targetUUID = remoteMessageIDs[targetID],
           let index = turnIndex(targetUUID) {
            speakReady(at: index)
        }
        if !remoteIsStreaming, !remote.isMutating {
            finishRemoteSpeech()
        }
    }

    private func finishRemoteSpeech() {
        guard remoteSpeechActive else { return }
        if let targetID = remoteSpeechTargetID,
           let targetUUID = remoteMessageIDs[targetID],
           let index = turnIndex(targetUUID) {
            speakReady(at: index, force: true)
        }
        remoteSpeechActive = false
        remoteSpeechBaseline.removeAll()
        remoteSpeechTargetID = nil
        voice.finishReply()
    }

    private func appendLocalFailure(
        _ message: String,
        for input: String,
        lane: ExecutionLane
    ) {
        turns.append(ChatTurn(role: .user, text: input, executionLane: lane))
        turns.append(
            ChatTurn(
                role: .assistant,
                error: message,
                executionLane: lane
            )
        )
        ChatStore.save(
            turns: turns,
            conversationID: conversationID,
            gatewayIdentity: gatewayIdentity,
            pendingRun: pendingRun,
            activeRun: activeRun,
            for: lane
        )
    }

    func resumeActiveRun() {
        guard activeLane != .cantrip else {
            syncRemoteTranscript()
            return
        }
        guard observationTask == nil else { return }
        guard let resumableLane = activeRun?.executionLane
                ?? pendingRun?.executionLane else {
            return
        }
        guard let client = env.client(for: resumableLane) else {
            runStatusText = env.configurationIssue
                ?? "Configure the gateway to reconnect to this run."
            return
        }
        if let pendingRun {
            startObservation {
                await self.dispatchAndObserve(pendingRun, client: client)
            }
        } else if let activeRun {
            startObservation {
                await self.observe(
                    activeRun,
                    client: client,
                    triesEventStream: false
                )
            }
        }
    }

    func setAppActive(_ active: Bool) {
        if active {
            if pendingRun != nil || activeRun != nil {
                runStatusText = "Reconnecting to the run on your Mac…"
            }
            resumeActiveRun()
        } else {
            suspendRunObservation()
        }
    }

    private func startObservation(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        guard observationTask == nil else { return }
        observationGeneration += 1
        let generation = observationGeneration
        observationTask = Task { [weak self] in
            await operation()
            guard let self, self.observationGeneration == generation else {
                return
            }
            self.observationTask = nil
        }
    }

    private func suspendRunObservation() {
        guard activeLane != .cantrip else { return }
        cancelObservation()
        persist()
    }

    private func cancelObservation() {
        observationGeneration += 1
        observationTask?.cancel()
        observationTask = nil
    }

    private func dispatchAndObserve(
        _ pending: PendingHermesRun,
        client: HermesClient
    ) async {
        while !Task.isCancelled, pendingRun?.idempotencyKey == pending.idempotencyKey {
            do {
                let run = try await client.startRun(pending)
                pendingRun = nil
                activeRun = run
                runStatusText = "Running on your Mac · safe to close the app"
                persist()
                await observe(
                    run,
                    client: client,
                    triesEventStream: true
                )
                return
            } catch is CancellationError {
                return
            } catch let error as HermesError {
                if error.isRetryable {
                    runStatusText = "Waiting to reconnect · the request will not be duplicated"
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                finishRun(
                    pending.assistantTurnID,
                    error: error.localizedDescription
                )
                return
            } catch {
                runStatusText = "Waiting to reconnect · the request will not be duplicated"
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func observe(
        _ run: ActiveHermesRun,
        client: HermesClient,
        triesEventStream: Bool
    ) async {
        if triesEventStream {
            do {
                var terminalError: String?
                var completed = false
                for try await event in client.streamRunEvents(run.runID) {
                    switch event {
                    case .completed:
                        completed = true
                    case .failed(let message):
                        terminalError = message
                    default:
                        apply(event, to: run.assistantTurnID)
                        if shouldSpeakReply(for: run.assistantTurnID),
                           let index = turnIndex(run.assistantTurnID) {
                            speakReady(at: index)
                        }
                    }
                    if completed || terminalError != nil {
                        break
                    }
                }
                if completed || terminalError != nil {
                    finishRun(
                        run.assistantTurnID,
                        error: terminalError
                    )
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                // The gateway intentionally drops a disconnected event queue.
                // Polling remains authoritative and never restarts the run.
            }
        }
        await poll(run, client: client)
    }

    private func poll(
        _ run: ActiveHermesRun,
        client: HermesClient
    ) async {
        while !Task.isCancelled, activeRun?.runID == run.runID {
            if Date().timeIntervalSince(run.startedAt) > 86_400 {
                finishRun(
                    run.assistantTurnID,
                    error: "This run exceeded the 24-hour recovery window."
                )
                return
            }
            do {
                let status = try await client.runStatus(run.runID)
                let hadApproval = turnIndex(run.assistantTurnID).map {
                    turns[$0].approval != nil
                } ?? false
                if let approval = status.approval,
                   status.status == "waiting_for_approval" {
                    setApproval(approval, on: run.assistantTurnID)
                    runStatusText = "Waiting for your approval"
                    persist()
                } else {
                    clearApproval(on: run.assistantTurnID)
                    runStatusText = Self.statusText(for: status.status)
                    if hadApproval {
                        persist()
                    }
                }
                switch status.status {
                case "completed":
                    finishRun(
                        run.assistantTurnID,
                        output: status.output
                    )
                    return
                case "failed", "cancelled":
                    finishRun(
                        run.assistantTurnID,
                        error: status.error ?? "Run \(status.status)."
                    )
                    return
                default:
                    break
                }
            } catch is CancellationError {
                return
            } catch let error as HermesError {
                if case .http(404) = error {
                    finishRun(
                        run.assistantTurnID,
                        error: "The saved run result expired before it could be recovered."
                    )
                    return
                }
                runStatusText = "Reconnecting · the run is still on your Mac"
            } catch {
                runStatusText = "Reconnecting · the run is still on your Mac"
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Barge-in: stop the in-flight reply + its speech and start listening for a
    /// new prompt — for talking over a long answer you've already read.
    func interruptAndListen() {
        stop()
        voice.startListening()
    }

    func enterVoiceMode() {
        voice.handsFree = true
        resumeVoiceModeIfIdle()
    }

    func leaveVoiceMode() {
        voice.handsFree = false
        spokenReplyTurnID = nil
        remoteSpeechActive = false
        remoteSpeechBaseline.removeAll()
        remoteSpeechTargetID = nil
        voice.stopListening(finalize: false)
        voice.stopSpeaking()
    }

    func resumeVoiceModeIfIdle() {
        guard voice.handsFree,
              !isWorking,
              !voice.isListening,
              !voice.isSpeaking,
              !voice.isPreparingRecognition else {
            return
        }
        voice.startListening()
    }

    func approveRun(_ choice: String, for turnID: UUID) {
        guard let run = activeRun,
              run.assistantTurnID == turnID,
              let client = env.client(for: run.executionLane) else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.approveRun(run.runID, choice: choice)
                self.clearApproval(on: turnID)
                if let index = self.turnIndex(turnID) {
                    self.turns[index].error = nil
                }
                self.runStatusText = "Running on your Mac · safe to close the app"
                self.persist()
            } catch {
                if let index = self.turnIndex(turnID) {
                    self.turns[index].error = (error as? LocalizedError)?
                        .errorDescription ?? error.localizedDescription
                }
                self.persist()
            }
        }
    }

    private func persist() {
        guard activeLane != .cantrip else { return }
        ChatStore.save(
            turns: turns,
            conversationID: conversationID,
            gatewayIdentity: gatewayIdentity,
            pendingRun: pendingRun,
            activeRun: activeRun,
            for: activeLane
        )
    }

    private func conversationHistory(
        maxCharacters: Int = 24_000,
        maxPairs: Int = 12
    ) -> [HermesConversationMessage] {
        var pairs: [(String, String)] = []
        var pendingUser: String?
        for turn in turns {
            switch turn.role {
            case .user:
                pendingUser = turn.text
            case .assistant:
                guard let user = pendingUser,
                      turn.error == nil,
                      !turn.text.isEmpty else {
                    pendingUser = nil
                    continue
                }
                pairs.append((user, turn.text))
                pendingUser = nil
            }
        }

        guard let anchor = pairs.first else { return [] }
        var selected: [(String, String)] = []
        var characters = anchor.0.count + anchor.1.count
        for pair in pairs.dropFirst().suffix(max(0, maxPairs - 1)).reversed() {
            let pairCount = pair.0.count + pair.1.count
            if characters + pairCount > maxCharacters {
                break
            }
            selected.append(pair)
            characters += pairCount
        }
        let boundedPairs = [anchor] + selected.reversed()
        return boundedPairs.flatMap { pair in
            [
                HermesConversationMessage(role: "user", content: pair.0),
                HermesConversationMessage(role: "assistant", content: pair.1),
            ]
        }
    }

    private func finishRun(
        _ assistantTurnID: UUID,
        output: String? = nil,
        error: String? = nil
    ) {
        guard let index = turnIndex(assistantTurnID) else { return }
        let speakReply = shouldSpeakReply(for: assistantTurnID)
        if let output, !output.isEmpty {
            turns[index].text = output
        }
        turns[index].streaming = false
        turns[index].approval = nil
        turns[index].error = error
        if turns[index].text.isEmpty, error == nil {
            turns[index].error = "The run completed without a response."
        }
        turns[index].actions = ChatTurn.parseActions(turns[index].text)
        pendingRun = nil
        activeRun = nil
        sending = false
        runStatusText = nil
        persist()
        if speakReply {
            if turns[index].error == nil {
                speakReady(at: index, force: true)
            }
            voice.finishReply()
        }
        if spokenReplyTurnID == assistantTurnID {
            spokenReplyTurnID = nil
        }
    }

    private func shouldSpeakReply(for assistantTurnID: UUID) -> Bool {
        spokenReplyTurnID == assistantTurnID
    }

    private func setApproval(_ approval: HermesRunApproval, on turnID: UUID) {
        guard let index = turnIndex(turnID) else { return }
        turns[index].approval = approval
    }

    private func clearApproval(on turnID: UUID) {
        guard let index = turnIndex(turnID) else { return }
        turns[index].approval = nil
    }

    private func turnIndex(_ id: UUID) -> Int? {
        turns.firstIndex { $0.id == id }
    }

    private static func statusText(for status: String) -> String {
        switch status {
        case "queued": "Queued on your Mac · safe to close the app"
        case "waiting_for_approval": "Waiting for your approval"
        case "stopping": "Stopping on your Mac…"
        default: "Running on your Mac · safe to close the app"
        }
    }

    // How many characters of the current reply have already been queued for
    // speech, so we only speak each new sentence once.
    private var spokenCount = 0

    /// Enqueue any newly-completed sentences/paragraphs of the streaming reply for
    /// speech. `force` flushes whatever remains (called once the reply ends).
    private func speakReady(at idx: Int, force: Bool = false) {
        guard turns.indices.contains(idx) else { return }
        let full = Array(turns[idx].text)
        guard full.count > spokenCount else { return }
        let tail = Array(full[spokenCount...])
        let cut = force ? tail.count : (Self.lastSpeakableCut(tail) ?? 0)
        guard cut > 0 else { return }
        let chunk = cleanForSpeech(String(tail[0..<cut]))
        if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { voice.enqueue(chunk) }
        spokenCount += cut
    }

    /// Offset just past the last sentence (`. ! ?`) or paragraph (newline) break.
    /// Sentence breaks inside a table row are NOT cuts: a "." inside a cell
    /// ("Morning clouds. Sunny after.") would otherwise split the row into two
    /// fragments that each look like (misaligned) table rows to
    /// tableRowToSpeech — heard as skipped/doubled words. A row only ships
    /// once its newline arrives.
    private static func lastSpeakableCut(_ chars: [Character]) -> Int? {
        var cut: Int? = nil
        var lineHasPipe = false
        for i in chars.indices {
            let c = chars[i]
            if c == "|" { lineHasPipe = true }
            if c == "\n" {
                cut = i + 1                                   // paragraph / "thinking break"
                lineHasPipe = false
            } else if c == "." || c == "!" || c == "?" {
                if !lineHasPipe, i + 1 >= chars.count || chars[i + 1] == " " || chars[i + 1] == "\n" { cut = i + 1 }
            }
        }
        return cut
    }

    /// The first table row of the reply being spoken — column names used to
    /// label later cells. Per-reply state because table rows stream in across
    /// separate speech chunks. nil = not currently inside a table.
    private var speechTableHeader: [String]? = nil

    /// Rewrite markdown for the EAR (on-screen reply untouched): table rows
    /// become labeled sentences via `tableRowToSpeech` (the symbols vanish,
    /// the content reads); horizontal rules are dropped whole (nothing to say,
    /// and a punctuation-only chunk can crash the neural decode); bullet/
    /// numbered items keep their text but lose the marker; markdown links keep
    /// their title; bare URLs vanish; →/~/digit-ranges become words.
    private func cleanForSpeech(_ s: String) -> String {
        var out: [String] = []
        for rawLine in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.lazy.filter({ $0 == "|" }).count >= 2 {
                if let spoken = tableRowToSpeech(line) { out.append(spoken) }
            } else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    speechTableHeader = nil          // left the table block
                }
                out.append(line)
            }
        }
        var t = out.joined(separator: "\n")
        t = t.replacingOccurrences(of: #"(?m)^\s*[-_*=·•~\s]{2,}$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*(?:[-*+•·‣◦]|\d{1,3}[.)])\s+"#, with: "", options: .regularExpression)
        for tok in ["**", "__", "*", "`", "#", ">"] { t = t.replacingOccurrences(of: tok, with: "") }
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        // Symbols → words, so the voice says what the symbols mean instead of
        // skipping (or worse, vocalizing) them.
        t = t.replacingOccurrences(of: "→", with: " to ")
        t = t.replacingOccurrences(of: "~", with: "about ")
        // En-dash ranges only ("10–20 mph") — a plain hyphen would also catch
        // ISO dates (2026-06-10 → "2026 to 06 to 10").
        t = t.replacingOccurrences(of: #"(?<=\d)\s*–\s*(?=\d)"#, with: " to ", options: .regularExpression)
        return t
    }

    /// One markdown table row → one spoken sentence. The first content row is
    /// remembered as the header; later rows pair each cell with its column:
    /// "| High | ~75°F | ~79°F |" → "High: Santa Clara ~75°F, Mountain View ~79°F."
    /// Separator rows (|---|---|) say nothing. Falls back to comma-joined
    /// cells when the shape doesn't line up.
    private func tableRowToSpeech(_ line: String) -> String? {
        var parts = line.components(separatedBy: "|")
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), !parts.isEmpty { parts.removeFirst() }
        if trimmed.hasSuffix("|"), !parts.isEmpty { parts.removeLast() }
        let cells = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !cells.isEmpty else { return nil }
        if cells.allSatisfy({ $0.isEmpty || $0.allSatisfy { "-: ".contains($0) } }) {
            return nil                                   // |---|---| separator
        }
        guard let header = speechTableHeader else {
            speechTableHeader = cells
            let named = cells.filter { !$0.isEmpty }
            return named.isEmpty ? nil : named.joined(separator: ", ") + "."
        }
        let label = cells[0]
        var pieces: [String] = []
        for i in 1..<cells.count where !cells[i].isEmpty {
            let h = i < header.count ? header[i] : ""
            pieces.append(h.isEmpty ? cells[i] : "\(h) \(cells[i])")
        }
        if pieces.isEmpty { return label.isEmpty ? nil : label + "." }
        return (label.isEmpty ? "" : label + ": ") + pieces.joined(separator: ", ") + "."
    }

    func stop() {
        if activeLane == .cantrip {
            guard remoteIsStreaming, !remote.isMutating else { return }
            remoteSpeechActive = false
            remoteSpeechBaseline.removeAll()
            remoteSpeechTargetID = nil
            voice.stopSpeaking()
            runStatusText = "Stopping Cantrip…"
            Task { [weak self] in
                guard let self else { return }
                _ = await self.remote.stop()
                self.syncRemoteTranscript()
            }
            return
        }
        guard sending else { return }
        spokenReplyTurnID = nil
        voice.stopSpeaking()
        cancelObservation()
        runStatusText = "Stopping on your Mac…"
        let savedActiveRun = activeRun
        let savedPendingRun = pendingRun
        let lane = savedActiveRun?.executionLane
            ?? savedPendingRun?.executionLane
            ?? activeLane
        guard let client = env.client(for: lane) else {
            runStatusText = "Could not reach the gateway to stop this run."
            return
        }
        startObservation { [self] in
            do {
                let run: ActiveHermesRun
                if let savedActiveRun {
                    run = savedActiveRun
                } else if let savedPendingRun {
                    run = try await client.startRun(savedPendingRun)
                    pendingRun = nil
                    activeRun = run
                    persist()
                } else {
                    sending = false
                    runStatusText = nil
                    return
                }
                try await client.stopRun(run.runID)
                runStatusText = "Stopping on your Mac…"
                await poll(run, client: client)
            } catch {
                runStatusText = "Stop failed; reconnecting to the run on your Mac…"
                if let savedActiveRun {
                    await observe(
                        savedActiveRun,
                        client: client,
                        triesEventStream: false
                    )
                } else if let savedPendingRun {
                    await dispatchAndObserve(savedPendingRun, client: client)
                }
            }
        }
    }

    func newConversation() {
        if activeLane == .cantrip {
            guard !remote.isMutating else { return }
            Task { [weak self] in
                guard let self else { return }
                _ = await self.remote.newConversation()
                self.syncRemoteTranscript()
            }
            return
        }
        guard !sending else { return }
        turns.removeAll()
        conversationID = UUID().uuidString
        pendingRun = nil
        activeRun = nil
        ChatStore.clear(for: activeLane)
    }

    func switchLane(to lane: ExecutionLane) {
        guard lane != activeLane, !sending else { return }
        if activeLane == .cantrip {
            remoteSpeechActive = false
            voice.stopSpeaking()
        } else {
            persist()
        }
        activeLane = lane
        remoteIsStreaming = false
        runStatusText = nil
        if lane == .cantrip {
            pendingRun = nil
            activeRun = nil
            gatewayIdentity = nil
            conversationID = UUID().uuidString
            syncRemoteTranscript()
            return
        }
        let snapshot = ChatStore.load(for: lane)
        turns = snapshot.turns
        gatewayIdentity = env.gatewayIdentity
        if let storedGateway = snapshot.gatewayIdentity,
           storedGateway != gatewayIdentity {
            turns = []
            conversationID = UUID().uuidString
            pendingRun = nil
            activeRun = nil
        } else {
            conversationID = snapshot.conversationID ?? UUID().uuidString
            pendingRun = snapshot.pendingRun
            activeRun = snapshot.activeRun
        }
        sending = pendingRun != nil || activeRun != nil
        if sending {
            runStatusText = "Reconnecting to the run on your Mac…"
            resumeActiveRun()
        } else {
            runStatusText = nil
        }
    }

    func gatewayDidChange() {
        guard activeLane != .cantrip else { return }
        guard !sending, gatewayIdentity != env.gatewayIdentity else { return }
        turns.removeAll()
        conversationID = UUID().uuidString
        gatewayIdentity = env.gatewayIdentity
        pendingRun = nil
        activeRun = nil
        runStatusText = nil
        ChatStore.clear(for: activeLane)
    }

    private func apply(_ ev: HermesStreamEvent, to turnID: UUID) {
        guard let index = turnIndex(turnID) else { return }
        switch ev {
        case .textDelta(let t):
            turns[index].text += t
        case .finalText(let t):
            turns[index].text = t
        case .toolStarted(let id, let name):
            turns[index].tools.append(ToolActivity(id: id, name: name))
        case .toolCompleted(let id):
            if let i = toolIndex(id, in: index) {
                turns[index].tools[i].done = true
            }
        case .approvalRequested(let approval):
            turns[index].approval = approval
            persist()
        case .approvalResponded:
            turns[index].approval = nil
            persist()
        case .completed:
            break
        case .failed(let m):
            turns[index].error = m
        }
    }

    /// Run events currently omit call IDs on completion, so fall back to the
    /// most recent unfinished tool when no exact ID exists.
    private func toolIndex(_ id: String, in idx: Int) -> Int? {
        if let i = turns[idx].tools.firstIndex(where: { $0.id == id }) { return i }
        return turns[idx].tools.lastIndex(where: { !$0.done })
    }
}

struct ChatView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var env: HermesEnv
    @ObservedObject private var remote: CantripRemoteModel
    @StateObject private var voice: VoiceController
    @StateObject private var vm: ChatViewModel
    @ObservedObject private var router = AppRouter.shared
    @State private var input = ""
    @State private var composerRevision = UUID()
    @State private var showSettings = false
    @State private var showVoiceMode = false
    @State private var showSkills = false
    @State private var commands: [HermesCommand] = []
    /// When paused, the app sends nothing — guards against unintentional requests
    /// (stray taps, ambient voice) that would otherwise burn the agent's budget.
    @AppStorage("hermes.paused") private var paused = false

    /// Filtered "/" suggestions: shown while the user is typing a command name
    /// (starts with "/", no space yet).
    private var suggestions: [HermesCommand] {
        guard input.hasPrefix("/"), !input.contains(" ") else { return [] }
        let q = input.lowercased()
        return Array(commands.filter { $0.command.lowercased().hasPrefix(q) }.prefix(6))
    }

    init(env: HermesEnv, remote: CantripRemoteModel) {
        _env = ObservedObject(wrappedValue: env)
        _remote = ObservedObject(wrappedValue: remote)
        let v = VoiceController()
        _voice = StateObject(wrappedValue: v)
        _vm = StateObject(
            wrappedValue: ChatViewModel(env: env, remote: remote, voice: v)
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if vm.activeLane == .cantrip {
                    remoteControls
                    Divider()
                }
                transcriptList
                inputBar
            }
            .navigationTitle("Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Hermes")
                            .font(.headline)
                        ExecutionLanePicker(env: env, remote: remote)
                            .disabled(vm.sending)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { paused.toggle() } label: {
                            Label(paused ? "Resume agent" : "Pause agent",
                                  systemImage: paused ? "play.circle" : "pause.circle")
                        }
                        Divider()
                        Button { showSkills = true } label: { Label("Skills", systemImage: "wand.and.stars") }
                            .disabled(paused || vm.activeLane == .cantrip)
                        Button { showVoiceMode = true } label: { Label("Voice mode", systemImage: "waveform") }
                            .disabled(paused || !destinationReady)
                        Divider()
                        Button(role: .destructive) { vm.newConversation() } label: {
                            Label("New conversation", systemImage: "square.and.pencil")
                        }
                        .disabled(newConversationDisabled)
                    } label: {
                        Image(systemName: paused ? "pause.circle.fill" : "line.3.horizontal")
                            .foregroundStyle(paused ? Color.orange : Color.accentColor)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .disabled(vm.sending)
                }
            }
            .sheet(
                isPresented: $showSettings,
                onDismiss: {
                    vm.gatewayDidChange()
                    reloadCommands()
                }
            ) {
                SettingsView(env: env, remote: remote, voice: voice)
            }
            .sheet(isPresented: $showSkills) {
                SkillsView(client: env.client) { skill in
                    showSkills = false
                    vm.send(skill.command)        // run it → returns to chat showing the interaction
                }
            }
            .fullScreenCover(
                isPresented: $showVoiceMode,
                onDismiss: vm.leaveVoiceMode
            ) {
                VoiceModeView(
                    voice: voice,
                    vm: vm,
                    onClose: { showVoiceMode = false }
                )
            }
        }
        .onAppear {
            voice.requestAuth()
            vm.setAppActive(scenePhase == .active)
            if router.startVoiceMode { showVoiceMode = true; router.startVoiceMode = false }   // cold launch from the Action Button
        }
        .onChange(of: router.startVoiceMode) { _, start in
            if start { showVoiceMode = true; router.startVoiceMode = false }                    // foreground launch from the intent
        }
        .onChange(of: input) { _, v in
            if v.hasPrefix("/"), commands.isEmpty { reloadCommands() }   // retry if the first load failed (e.g. key set late)
        }
        .onChange(of: paused) { _, isPaused in
            if isPaused {                              // halt anything that could fire a request
                voice.stopListening(finalize: false)
                voice.stopSpeaking()
                showVoiceMode = false
            }
        }
        .onChange(of: env.executionLane) { _, lane in
            vm.switchLane(to: lane)
            reloadCommands()
        }
        .onChange(of: remote.transcriptRevision) { _, _ in
            vm.syncRemoteTranscript()
        }
        .onChange(of: remote.selectedSessionID) { _, _ in
            vm.syncRemoteTranscript()
        }
        .onChange(of: scenePhase) { _, phase in
            vm.setAppActive(phase == .active)
            if phase == .active, showVoiceMode {
                vm.resumeVoiceModeIfIdle()
            }
        }
        .task {
            await env.refreshGateway()
            reloadCommands()
        }
    }

    /// Load the command/skill menu for "/" suggestions. Only overwrites on a
    /// non-empty result, so a transient failure (e.g. a 401 before the key is
    /// entered) doesn't wipe a good list — and it can be retried safely.
    private func reloadCommands() {
        guard vm.activeLane != .cantrip else {
            commands = []
            return
        }
        Task {
            if let c = await env.client?.commands(),
               !c.isEmpty,
               vm.activeLane != .cantrip {
                commands = c
            }
        }
    }

    private var newConversationDisabled: Bool {
        if vm.activeLane == .cantrip {
            return remote.selectedSessionID == nil
                || remote.isMutating
                || remote.selectedSession?.isStreaming == true
        }
        return vm.turns.isEmpty || vm.sending
    }

    private var destinationReady: Bool {
        if vm.activeLane == .cantrip {
            return remote.isConfigured && remote.selectedSessionID != nil
        }
        return env.isConfigured
    }

    private var remoteControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(remote.isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Menu {
                    if remote.sessions.isEmpty {
                        Text("No sessions")
                    } else {
                        ForEach(remote.sessions) { session in
                            Button {
                                Task {
                                    await remote.selectSession(session.id)
                                    vm.syncRemoteTranscript()
                                }
                            } label: {
                                Label(
                                    session.title,
                                    systemImage: session.id == remote.selectedSessionID
                                        ? "checkmark.circle.fill"
                                        : "rectangle.stack"
                                )
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(remote.selectedSession?.title ?? "Choose Session")
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .font(.callout.weight(.semibold))
                }
                .disabled(!remote.isConfigured || remote.sessions.isEmpty)

                Spacer(minLength: 0)

                if remote.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await remote.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!remote.isConfigured || remote.isRefreshing)
                .accessibilityLabel("Refresh Cantrip sessions")

                Button {
                    Task {
                        _ = await remote.createSession()
                        vm.syncRemoteTranscript()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!remote.isConfigured || remote.isMutating)
                .accessibilityLabel("Create Cantrip session")

                if remote.selectedSession != nil {
                    Menu {
                        if remote.selectedSession?.canResume == true {
                            Button {
                                Task {
                                    _ = await remote.resume()
                                    vm.syncRemoteTranscript()
                                }
                            } label: {
                                Label("Resume", systemImage: "play")
                            }
                        }
                        if remote.selectedSession?.isStreaming == true {
                            Button(role: .destructive) {
                                vm.stop()
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                        }
                        Button {
                            vm.newConversation()
                        } label: {
                            Label("New Conversation", systemImage: "square.and.pencil")
                        }
                        .disabled(remote.selectedSession?.isStreaming == true)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(remote.isMutating)
                    .accessibilityLabel("Cantrip session actions")
                }
            }

            if remote.selectedSession != nil {
                HStack(spacing: 8) {
                    Picker("Delivery", selection: $vm.remoteDeliveryMode) {
                        ForEach(CantripDeliveryMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Cantrip prompt delivery mode")

                    if let status = remote.selectedSession?.status, !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if let error = remote.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.turns.isEmpty { emptyState }
                    ForEach(vm.turns) { turn in
                        TurnView(
                            turn: turn,
                            onAction: { vm.send($0.command) },
                            onApproval: { vm.approveRun($0, for: turn.id) }
                        )
                        .id(turn.id)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)   // open at the most recent message + stay pinned to newest
            .onChange(of: vm.turns.last?.text) { _, _ in
                if let id = vm.turns.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 56)).foregroundStyle(.tint)
            if vm.activeLane == .cantrip, !remote.isConfigured {
                Text("Connect to Cantrip").font(.title3.weight(.semibold))
                Text("Open Settings and enter Cantrip's Remote URL and pairing token.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open Settings") { showSettings = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            } else if vm.activeLane == .cantrip {
                Text("Choose a Cantrip session").font(.title3.weight(.semibold))
                Text("Select an existing session above or create a new one, then type or use voice as usual.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Create Session") {
                    Task {
                        _ = await remote.createSession()
                        vm.syncRemoteTranscript()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(remote.isMutating)
                .padding(.top, 4)
            } else if env.isConfigured {
                Text("Talk to Hermes").font(.title3.weight(.semibold))
                Text("Type, or tap the mic to start a voice conversation. Toggle hands-free to keep the loop going.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("Connect your gateway").font(.title3.weight(.semibold))
                Text("Open Settings and enter your Hermes gateway URL + API key to start.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open Settings") { showSettings = true }.buttonStyle(.borderedProminent).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 80).padding(.horizontal, 30)
    }

    private var emptyStateIcon: String {
        if vm.activeLane == .cantrip {
            return remote.isConfigured
                ? "rectangle.stack.badge.plus"
                : "antenna.radiowaves.left.and.right.slash"
        }
        return env.isConfigured ? "waveform.circle.fill" : "gearshape.circle.fill"
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if paused {
                pausedBar
            } else {
            if !suggestions.isEmpty { suggestionList }
            voiceStatus
            HStack(spacing: 10) {
                Button { showVoiceMode = true } label: { Image(systemName: "infinity") }
                    .buttonStyle(.bordered)
                    .disabled(!destinationReady)
                    .help("Voice mode")

                TextField(
                    vm.activeLane == .cantrip ? "Message Cantrip…" : "Message Hermes…",
                    text: $input,
                    axis: .vertical
                )
                    .id(composerRevision)
                    .textFieldStyle(.plain).lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    .disabled(!destinationReady || vm.sending)
                    .onSubmit(sendText)

                if vm.sending, vm.activeLane != .cantrip {
                    Button { vm.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                } else if vm.sending {
                    ProgressView().controlSize(.small)
                } else if input.isEmpty {
                    Button {
                        if voice.isSpeaking { vm.interruptAndListen() } else { voice.toggleListening() }
                    } label: {
                        Image(systemName: voice.isListening ? "mic.fill" : "mic")
                            .font(.title2).foregroundStyle(voice.isListening ? Color.red : Color.accentColor)
                    }
                    .disabled(!voice.authorized || !destinationReady)
                } else {
                    Button(action: sendText) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(!destinationReady || remote.isMutating)
                }
            }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    /// Shown in place of the composer when paused — a clear "you're sending nothing"
    /// state with a one-tap resume.
    private var pausedBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent paused").font(.callout.weight(.semibold))
                Text("No requests will be sent.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Resume") { paused = false }.buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }

    /// "/" autocomplete — the command/skill menu, like Telegram/Discord.
    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { cmd in
                Button { input = cmd.command + " " } label: {
                    HStack(spacing: 8) {
                        Text(cmd.command).font(.callout.monospaced().weight(.semibold)).foregroundStyle(.tint)
                        Text(cmd.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 7).padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                if cmd.id != suggestions.last?.id { Divider() }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Animated waveform status — "talking back" while listening, replying, or speaking.
    @ViewBuilder private var voiceStatus: some View {
        if voice.isPreparingRecognition {
            HStack(spacing: 10) {
                ProgressView()
                Text(voice.recognitionStatusText ?? "Preparing speech recognition…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else if voice.isListening {
            HStack(spacing: 10) {
                WaveformView(active: true, color: .red)
                Text(voice.partial.isEmpty ? "Listening…" : voice.partial)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
        } else if let error = voice.recognitionError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if voice.isSpeaking {
            HStack(spacing: 10) {
                WaveformView(active: true, color: .accentColor)
                Text("Hermes is speaking").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { voice.stopSpeaking() } label: { Image(systemName: "stop.circle").font(.title3) }
            }
        } else if vm.isWorking {
            HStack(spacing: 10) {
                ThinkingView(size: 22, color: .accentColor)
                Text(
                    vm.runStatusText
                        ?? (vm.activeLane == .cantrip
                            ? "Cantrip is working…"
                            : "Hermes is thinking…")
                )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private func sendText() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        composerRevision = UUID()
        vm.send(text)
    }
}

struct ExecutionLaneBadge: View {
    let lane: ExecutionLane

    private var tint: Color {
        switch lane {
        case .copilot: .orange
        case .local: .green
        case .cantrip: .cyan
        }
    }

    var body: some View {
        Label(lane.badgeTitle, systemImage: lane.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                tint.opacity(0.12),
                in: Capsule()
            )
    }
}

private struct ExecutionLanePicker: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        Menu {
            ForEach(ExecutionLane.allCases) { lane in
                Button {
                    env.select(lane)
                } label: {
                    Label(
                        pickerTitle(lane),
                        systemImage: lane == env.executionLane
                            ? "checkmark.circle.fill"
                            : lane.systemImage
                    )
                }
                .disabled(!env.isAvailable(lane))
            }
        } label: {
            ExecutionLaneBadge(lane: env.executionLane)
        }
        .menuIndicator(.hidden)
    }

    private func pickerTitle(_ lane: ExecutionLane) -> String {
        switch lane {
        case .local where !env.isAvailable(.local):
            "\(lane.title) · Not configured"
        case .cantrip where remote.isConnected:
            "\(lane.title) · Connected"
        case .cantrip where !remote.isConfigured:
            "\(lane.title) · Set up"
        default:
            lane.title
        }
    }
}

/// A pulsing brain for the "thinking" state (the agent is working) — used instead
/// of the waveform, which is for listening/speaking (audio).
struct ThinkingView: View {
    var size: CGFloat = 28
    var color: Color = .accentColor

    var body: some View {
        Image(systemName: "brain")
            .font(.system(size: size))
            .foregroundStyle(color)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
            .symbolEffect(.pulse, options: .repeating)
    }
}

/// A row of bars that wave while `active` (voice "talking back"); flat otherwise.
/// Parameterized so it works both small (input bar) and large (voice mode).
struct WaveformView: View {
    var active: Bool
    var color: Color = .accentColor
    var barCount = 5
    var barWidth: CGFloat = 3.5
    var spacing: CGFloat = 3
    var minHeight: CGFloat = 6
    var maxHeight: CGFloat = 24

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let amp = active ? (sin(t * 7 + Double(i) * 0.9) * 0.5 + 0.5) : 0.18
                    Capsule().fill(color)
                        .frame(width: barWidth, height: minHeight + amp * (maxHeight - minHeight))
                }
            }
        }
    }
}

private struct TurnView: View {
    let turn: ChatTurn
    var onAction: (ChatAction) -> Void = { _ in }
    var onApproval: (String) -> Void = { _ in }

    /// Parse inline markdown (bold/italic/code/links) while preserving the
    /// newlines streamed from the agent; falls back to plain text on a partial
    /// (mid-stream) markdown token.
    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    /// Dimmer tint for the decline-ish choice.
    private func isCancel(_ command: String) -> Bool {
        ["/cancel", "/deny", "/no", "/nevermind"].contains(command.lowercased())
    }

    var body: some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(turn.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let lane = turn.executionLane {
                    ExecutionLaneBadge(lane: lane)
                }
                if let author = turn.author, !author.isEmpty {
                    Text(author)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let thinking = turn.thinking, !thinking.isEmpty {
                    DisclosureGroup("Reasoning") {
                        Text(thinking)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                    .font(.caption)
                }
                ForEach(turn.tools) { ToolRow(tool: $0) }
                if !turn.text.isEmpty {
                    Markdown(turn.text)            // full GFM: tables, lists, code blocks, headings
                        .textSelection(.enabled)
                }
                if !turn.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(turn.actions) { a in
                            Button { onAction(a) } label: { Text(a.label).font(.callout.weight(.medium)) }
                                .buttonStyle(.borderedProminent)
                                .tint(isCancel(a.command) ? Color.secondary : Color.accentColor)
                        }
                    }
                    .padding(.top, 4)
                }
                if let approval = turn.approval {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            approval.description ?? "This action needs approval.",
                            systemImage: "exclamationmark.shield"
                        )
                        .font(.caption)
                        if let command = approval.command, !command.isEmpty {
                            Text(command)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(6)
                        }
                        HStack(spacing: 8) {
                            ForEach(approval.choices, id: \.self) { choice in
                                Button(approvalTitle(choice)) {
                                    onApproval(choice)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(
                                    choice == "deny"
                                        ? Color.secondary
                                        : Color.accentColor
                                )
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        Color.orange.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                if turn.streaming && turn.text.isEmpty && turn.tools.isEmpty {
                    ThinkingView(size: 22, color: .gray)
                }
                if let err = turn.error {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func approvalTitle(_ choice: String) -> String {
        switch choice {
        case "once": "Allow Once"
        case "session": "Allow Session"
        case "always": "Always Allow"
        case "deny": "Deny"
        default: choice.capitalized
        }
    }
}

/// Collapsible tool/skill activity row — the "see Hermes working" surface.
private struct ToolRow: View {
    let tool: ToolActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: tool.done ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(tool.done ? .green : .secondary)
                        .symbolEffect(.pulse, isActive: !tool.done)
                    Text(tool.label).font(.caption.weight(.semibold).monospaced())
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                if !tool.arguments.isEmpty {
                    Text(tool.arguments).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                if let out = tool.output, !out.isEmpty {
                    Text(out).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(12)
                }
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
