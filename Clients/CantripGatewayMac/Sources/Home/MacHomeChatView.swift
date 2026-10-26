import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Home's conversation. Mirrors the Home lane of the iOS `ChatView`: the same
/// `ChatViewModel`, transcript rows (`TurnView`), history paging, input requests,
/// attachments and send path, laid out for a Mac window.
struct MacHomeChatView: View {
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject var vm: ChatViewModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var navigation: MacHomeNavigation
    /// The backend "/" commands of Home and every tab (`remote.slashCommands`).
    @ObservedObject var slashCommands: BackendSlashCommandStore
    /// A project tab opened from the sidebar instead of Home's own chat.
    var isTab = false
    @AppStorage("hermes.paused") private var paused = false
    @AppStorage(CantripMascotName.storageKey) private var mascotName = ""
    @State private var input = ""
    @State private var textDrafts: [String: String] = [:]
    @State private var imageDrafts: [String: [ChatImageAttachment]] = [:]
    @State private var videoDrafts: [String: ChatVideoAttachment] = [:]
    @State private var fileDrafts: [String: [ChatFileAttachment]] = [:]
    /// Tabs picked from the "@" suggestions, per draft (`remoteDraftKey`).
    @State private var mentionDrafts: [String: [CantripTabMention]] = [:]
    /// The composer's caret (UTF-16 offset; -1 while a range is selected), read from its text
    /// view for "@" suggestions. Nil: the end of the text. Only read, never pushed back: a
    /// `TextField(selection:)` binding on the Mac lags while typing and restores a stale caret.
    @State private var composerCaret: Int?
    /// The text as the field last reported it (typed), to tell the app's own edits apart.
    @State private var fieldText = ""
    /// Escape hid the "@" suggestions for the "@" at this UTF-16 offset.
    @State private var mentionDismissedAt: Int?
    @State private var mentionHighlight: CantripMentionHighlight?
    @State private var imageImportID: UUID?
    @State private var composerPaste: ComposerPasteRequest?
    @State private var submittingRemote = false
    @State private var imageSendError: String?
    @State private var attachmentError: String?
    @State private var composerRevision = UUID()
    @State private var size = CGSize(width: 900, height: 700)
    @State private var isDropTargeted = false
    /// Escape hides the "/" suggestions until the text changes.
    @State private var slashDismissedText: String?
    /// The row picked with the arrow keys, for the text it was picked on.
    @State private var slashHighlight: SlashHighlight?
    @FocusState private var composerFocused: Bool

    private struct SlashHighlight: Equatable {
        let text: String
        let index: Int
    }

    /// Messages and the composer stay in a readable column on wide windows.
    static let readableWidth: CGFloat = 860

    var body: some View {
        VStack(spacing: 0) {
            notices
            transcript
                .id(transcriptIdentity)
            CantripPinnedSubagents(
                remote: remote,
                sessionID: remote.selectedSessionID,
                subagents: CantripPinnedSubagents.liveForeground(in: remote.selectedSession?.transcript ?? []),
                maxHeight: max(120, size.height * 0.35)
            )
            .frame(maxWidth: Self.readableWidth)
            inputBar
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .navigationTitle(isTab ? remote.selectedSession?.title ?? "Tab" : "Chat")
        .navigationSubtitle(subtitle)
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted, perform: dropImages)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .alert("Message not confirmed", isPresented: Binding(
            get: { imageSendError != nil }, set: { if !$0 { imageSendError = nil } }
        )) {
            Button("OK") { imageSendError = nil }
        } message: {
            Text(imageSendError ?? "")
        }
        .alert("Attachment", isPresented: Binding(
            get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } }
        )) {
            Button("OK") { attachmentError = nil }
        } message: {
            Text(attachmentError ?? "")
        }
        .onChange(of: transcriptIdentity) { previous, current in
            // A draft never follows a server switch into another Mac's Home.
            textDrafts[previous] = input
            input = textDrafts[current] ?? ""
            composerRevision = UUID()
            voice.stopListening(finalize: false)
            voice.stopSpeaking()
        }
        .onChange(of: navigation.composerFocusRequest) { _, _ in applyPrefillAndFocus() }
        .onChange(of: submittingRemote) { _, submitting in
            if !submitting { composerFocused = true }
        }
        .onAppear(perform: applyPrefillAndFocus)
        .modifier(CantripThreadPresenter(remote: remote))
    }

    // MARK: Transcript

    private var transcript: some View {
        ChatTranscriptScrollView(
            scrollRequest: vm.scrollToLatestRequest,
            prependRevision: vm.historyPrependRevision,
            prependAnchor: vm.historyPrependAnchor,
            loadOlder: { remote.requestOlderMessages() }
        ) {
            CantripHistoryControls(model: remote)
            if isTab, let session = remote.selectedSession, session.id == remote.selectedSessionID,
               let child = session.child, let parentID = session.parentID {
                CantripChildTabBanner(child: child, onOpenParent: { navigation.openTab(parentID) })
            }
            if vm.turns.isEmpty { emptyState }
            let threadLines = CantripThreadLine.lines(in: remote.selectedSession?.transcript ?? [])
            ForEach(vm.turns) { turn in
                let message = vm.remoteMessage(for: turn.id)
                TurnView(
                    turn: turn,
                    remote: remote,
                    cantripSessionID: remote.selectedSessionID,
                    remoteMessage: message,
                    onAction: { vm.send($0.command) },
                    onApproval: { vm.approveRun($0, for: turn.id) },
                    // Handoff cards open the tab right here, in the sidebar's Tabs section.
                    onOpenTab: { navigation.openTab($0) },
                    threadLine: message.flatMap { threadLines[$0.id] }
                )
                .id(turn.id)
                if let message, message.isPreview == true {
                    CantripMessageDetailsButton(
                        model: remote, message: message, sessionID: remote.selectedSessionID ?? ""
                    )
                }
            }
            CantripInputTranscript(model: remote)
        }
        // Mentions of open tabs open them in the sidebar's Tabs section.
        .cantripMentionLinks(remote: remote, onOpenTab: { navigation.openTab($0) })
        .contentMargins(.horizontal, sideMargin, for: .scrollContent)
        .textSelection(.enabled)
    }

    private var sideMargin: CGFloat { max(0, (size.width - Self.readableWidth) / 2) }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            if isTab, remote.isConfigured {
                Text(remote.selectedSession?.title ?? "No tab open").font(.title3.weight(.semibold))
                Text(remote.selectedSession == nil
                     ? "Choose a tab in the sidebar, or press ⌘T for a new one."
                     : "Type or use voice to start this tab. Cantrip runs it on your Mac.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if !remote.isConfigured {
                Text("Connect to Cantrip").font(.title3.weight(.semibold))
                Text("Open Settings and enter the pairing token from Cantrip on your Mac. A Tailscale URL is optional.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                SettingsLink { Text("Open Settings…") }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            } else {
                switch availability {
                case .ready:
                    Text("Hi, I'm \(CantripMascotName.display(mascotName))").font(.title3.weight(.semibold))
                    Text("Ask anything, create a task, or make an artifact.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                case .opening:
                    Text("Opening Cantrip Home…").font(.title3.weight(.semibold))
                    ProgressView().controlSize(.small)
                case .unavailable(let message):
                    Text("Cantrip Home unavailable").font(.title3.weight(.semibold))
                    Text(message)
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    SettingsLink { Text("Open Settings…") }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 30)
    }

    private var emptyStateIcon: String {
        guard remote.isConfigured else { return "antenna.radiowaves.left.and.right.slash" }
        if isTab { return "rectangle.stack" }
        switch availability {
        case .ready: return "house.fill"
        case .opening: return "house"
        case .unavailable: return "house.slash"
        }
    }

    private var availability: CantripHomeChatAvailability {
        .resolve(
            isConfigured: remote.isConfigured,
            isHomeSelected: remote.isHomeSelected,
            isHomeSession: remote.selectedSession?.isCantripHome == true,
            error: remote.detailError
        )
    }

    // MARK: Notices

    /// While a run streams, its status already shows above the composer.
    private var idleStatus: String? {
        guard let session = remote.selectedSession, !session.isStreaming,
              let status = session.status, !status.isEmpty else { return nil }
        return status
    }

    private var hasNotices: Bool {
        // Unpaired, the empty state already explains what to do.
        guard remote.isConfigured else { return false }
        return idleStatus != nil || remote.selectedSession?.deliveryStatus != nil
            || remote.errorMessage != nil || remote.detailError != nil
    }

    @ViewBuilder private var notices: some View {
        if hasNotices {
            VStack(spacing: 6) {
                if let status = idleStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let status = remote.selectedSession?.deliveryStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = remote.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                CantripDetailNotice(model: remote)
            }
            .frame(maxWidth: Self.readableWidth)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
            Divider()
        }
    }

    private var subtitle: String {
        if paused { return "Agent paused" }
        if isTab {
            // "Working · ~/Coding/Plexa", like the tab rows' state.
            let state = CantripTabRowText.state(for: remote.selectedSession, connection: remote.connectionState).text
            guard let folder = remote.selectedSession?.workdir, !folder.isEmpty else { return state }
            return "\(state) · \((folder as NSString).abbreviatingWithTildeInPath)"
        }
        if vm.isWorking { return vm.runStatusText ?? "Working…" }
        return remote.isConnected ? remote.endpointHost : remote.connectionLabel
    }

    // MARK: Input

    /// A tab's live background subagents (build/upload/download watchers), as iOS lists them
    /// above a tab's composer. Home counts its own on the toolbar's Background button instead.
    static func liveBackgroundTasks(in session: CantripRemoteSession?, selectedID: String?,
                                    isTab: Bool) -> [CantripRemoteSubagent] {
        guard isTab, let session, session.id == selectedID, session.isCantripHome != true else { return [] }
        return CantripPinnedSubagents.liveBackground(in: session.transcript)
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            // Like iOS: a tab shows its running watchers here; Home keeps them behind Background.
            let backgroundTasks = Self.liveBackgroundTasks(
                in: remote.selectedSession, selectedID: remote.selectedSessionID, isTab: isTab
            )
            if !backgroundTasks.isEmpty {
                CantripBackgroundTaskButton(subagents: backgroundTasks) { navigation.sheet = .backgroundTasks }
                    .help("Show this tab's background tasks")
            }
            if let session = remote.selectedSession, session.id == remote.selectedSessionID,
               session.queuedCount > 0 {
                CantripQueueButton(session: session) { navigation.sheet = .queue }
            }
            if paused {
                pausedBar
            } else {
                voiceStatus
                if let sessionID = remote.selectedSessionID {
                    ImageAttachmentPreviews(
                        attachments: imageDraft(for: sessionID), remote: remote,
                        disabled: imagePickerDisabled, isImporting: importingImages
                    )
                    if let video = videoDraft(for: sessionID).wrappedValue {
                        VideoAttachmentPreview(video: video, disabled: imagePickerDisabled || importingImages) {
                            videoDraft(for: sessionID).wrappedValue = nil
                        }
                    }
                    FileAttachmentPreviews(files: fileDraft(for: sessionID),
                                           disabled: imagePickerDisabled || importingImages)
                    CantripMentionChips(mentions: mentionDrafts[remoteDraftKey(sessionID)] ?? [],
                                        disabled: vm.sending || submittingRemote, onRemove: removeMention)
                    if importingImages {
                        Button("Cancel attachment preparation") { imageImportID = nil }
                    }
                    if let progress = remote.videoUploadProgress {
                        VStack(alignment: .leading) {
                            ProgressView(value: progress.fraction)
                            Text(progress.label).font(.caption).foregroundStyle(.secondary)
                            Button("Cancel upload") { remote.cancelVideoUpload() }
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                if let presentation = slashPresentation {
                    BackendSlashSuggestionList(
                        presentation: presentation,
                        highlighted: slashHighlightIndex,
                        maxHeight: min(320, max(120, size.height * 0.4)),
                        canOpenModelSettings: canOpenModelSettingsFromSlash,
                        style: .compact,
                        onChoose: { chooseSlashCommand($0, via: .activate) }
                    )
                }
                if let popup = mentionPopup {
                    CantripMentionSuggestionList(
                        popup: popup,
                        sessions: Dictionary(remote.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                        highlighted: CantripMentionHighlight.index(mentionHighlight, popup: popup),
                        maxHeight: min(360, max(120, size.height * 0.4)),
                        onPick: pickMention
                    )
                }
                composer
            }
        }
        .frame(maxWidth: Self.readableWidth)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .background {
            MacSlashKeyMonitor(isActive: slashPresentation != nil, onKey: handleSlashKey)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .background {
            // Return picks the highlighted tab instead of sending while "@" suggestions show.
            MacSlashKeyMonitor(isActive: mentionPopup != nil, onKey: handleMentionKey)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: input) { _, text in
            // Text the app put in (a draft, dictation, a command) puts the caret at its end, as
            // without a selection binding; typing keeps the field's own caret.
            if text != fieldText {
                fieldText = text
                composerCaret = nil
            }
            refreshMentions()
        }
        .onChange(of: composerCaret) { _, _ in refreshMentions() }
        .background {
            MacComposerCaretObserver(isActive: composerFocused) { composerCaret = $0 }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onChange(of: BackendSlashCommands.slashToken(input) != nil) { _, entered in
            if entered { remote.refreshSlashCommandsIfNeeded() }
        }
        .onChange(of: input) { _, text in
            // Escape hid the list for that text only.
            if text != slashDismissedText { slashDismissedText = nil }
        }
        .onChange(of: composerFocused) { _, focused in
            // A tab focuses its composer as it opens: prefetch so "/" usually shows a cached list.
            if focused { remote.refreshSlashCommandsIfNeeded() }
        }
        .onChange(of: remote.slashCommandContext) { _, _ in
            if slashToken != nil { remote.refreshSlashCommandsIfNeeded() }
        }
        #if DEBUG
        .task {
            if let text = await CantripUITestFixtures.composerTextWhenReady({ destinationReady && composerAcceptsText }) {
                input = text
                composerFocused = true
                MacSlashKeyMonitor.moveInsertionPointToEnd()
            }
        }
        #endif
    }

    // MARK: Slash commands

    /// The typed "/" token while the backend's suggestions can show.
    private var slashToken: String? {
        guard !paused, composerFocused, composerAcceptsText, slashDismissedText != input,
              // A reply to the agent's question is never a command.
              !(vm.remoteDeliveryMode == .auto && remote.chatInputRequest != nil),
              remote.slashCommandContext != nil else { return nil }
        return BackendSlashCommands.slashToken(input)
    }

    private var slashPresentation: BackendSlashPresentation? {
        guard let context = remote.slashCommandContext else { return nil }
        return BackendSlashCommands.presentation(
            token: slashToken,
            response: slashCommands.response(for: context.key),
            isLoading: slashCommands.isLoading(context.key)
        )
    }

    /// The arrow-key row for this text, else the default: a strong, runnable first match.
    private var slashHighlightIndex: Int? {
        guard let token = slashToken, let presentation = slashPresentation else { return nil }
        if let slashHighlight, slashHighlight.text == input { return slashHighlight.index }
        return BackendSlashCommands.defaultHighlight(token: token, matches: presentation.matches)
    }

    private var canOpenModelSettingsFromSlash: Bool {
        remote.selectedSession?.supportsModelSettings == true
    }

    private func handleSlashKey(_ key: BackendSlashKey) -> Bool {
        guard let presentation = slashPresentation else { return false }
        switch BackendSlashCommands.handle(key, matches: presentation.matches, highlighted: slashHighlightIndex) {
        case .ignore:
            return false
        case .highlight(let index):
            slashHighlight = SlashHighlight(text: input, index: index)
        case .choose(let match, let trigger):
            chooseSlashCommand(match, via: trigger)
        case .dismiss:
            slashDismissedText = input
        }
        return true
    }

    /// Model settings open; Return or a click sends a command without arguments; anything else
    /// (and Tab) is inserted with the cursor after it, ready for the argument.
    private func chooseSlashCommand(_ match: BackendCommandMatch, via trigger: BackendCommandTrigger) {
        guard let choice = BackendSlashCommands.choose(
            match.command, via: trigger, canOpenModelSettings: canOpenModelSettingsFromSlash
        ) else { return }
        input = choice.text
        slashHighlight = nil
        if choice.opensModelSettings {
            remote.modelSettingsSession = remote.selectedSession
        } else if choice.sendsImmediately {
            sendText()
        } else {
            composerFocused = true
            MacSlashKeyMonitor.moveInsertionPointToEnd()
        }
    }

    // MARK: Tab mentions

    /// "@" suggestions for the composer's caret, while this tab (or Home) takes mentions.
    private var mentionPopup: CantripTabMentions.Popup? {
        guard !paused, composerFocused, composerAcceptsText, slashToken == nil,
              // A reply to the agent's question goes to the question, not to the model.
              !(vm.remoteDeliveryMode == .auto && remote.chatInputRequest != nil),
              let session = remote.selectedSession, session.id == remote.selectedSessionID,
              CantripTabMentions.supportsMentions(session),
              let caret = CantripMentionCaret.position(in: input, utf16Offset: composerCaret) else { return nil }
        let candidates = CantripTabMentions.candidates(
            sessions: remote.sessions, sections: remote.tabSections, composingID: session.id
        )
        return CantripTabMentions.popup(text: input, caret: caret, candidates: candidates,
                                        dismissedAt: mentionDismissedAt,
                                        picks: mentionDrafts[remoteDraftKey(session.id)] ?? [])
    }

    private func handleMentionKey(_ key: BackendSlashKey) -> Bool {
        guard let popup = mentionPopup else { return false }
        switch CantripTabMentions.handle(key, popup: popup,
                                         highlighted: CantripMentionHighlight.index(mentionHighlight, popup: popup)) {
        case .ignore:
            return false
        case .highlight(let index):
            mentionHighlight = CantripMentionHighlight(at: popup.at, query: popup.query, index: index)
        case .pick(let candidate):
            pickMention(candidate)
        case .dismiss:
            mentionDismissedAt = popup.at
        }
        return true
    }

    /// "@Label " replaces the typed "@query"; the tab is kept with the draft until it's sent.
    private func pickMention(_ candidate: CantripTabMentions.Candidate) {
        guard let popup = mentionPopup, let sessionID = remote.selectedSessionID else { return }
        let caret = CantripMentionCaret.position(in: input, utf16Offset: composerCaret) ?? input.endIndex
        let key = remoteDraftKey(sessionID)
        let picks = mentionDrafts[key] ?? []
        // A label stands for one tab: a second tab with the same title gets its own label.
        let picked = CantripTabMentions.insert(candidate, at: String.Index(utf16Offset: popup.at, in: input),
                                               caret: caret, in: input,
                                               label: CantripTabMentions.uniqueLabel(for: candidate, among: picks))
        mentionDrafts[key] = CantripTabMentions.adding(CantripTabMention(id: candidate.id, label: picked.label),
                                                       to: picks)
        input = picked.text
        fieldText = picked.text
        let caretOffset = picked.text.utf16.distance(from: picked.text.startIndex, to: picked.caret)
        composerCaret = caretOffset
        MacComposerCaretObserver.moveInsertionPoint(to: caretOffset)
        mentionHighlight = nil
        composerFocused = true
    }

    /// A chip's remove button: the mention and its "@Label" text go.
    private func removeMention(_ mention: CantripTabMention) {
        guard let sessionID = remote.selectedSessionID else { return }
        let key = remoteDraftKey(sessionID)
        let picks = mentionDrafts[key] ?? []
        mentionDrafts[key] = picks.filter { $0 != mention }
        input = CantripTabMentions.removing(mention, from: input, among: picks)
        composerFocused = true
        MacSlashKeyMonitor.moveInsertionPointToEnd()
    }

    /// Deleting a mention's "@Label" text drops its chip; Escape's dismissal lasts while its "@" does.
    private func refreshMentions() {
        mentionDismissedAt = CantripTabMentions.keepsDismissal(
            mentionDismissedAt, text: input, caret: CantripMentionCaret.position(in: input, utf16Offset: composerCaret)
        )
        guard let sessionID = remote.selectedSessionID else { return }
        let key = remoteDraftKey(sessionID)
        guard let mentions = mentionDrafts[key], !mentions.isEmpty else { return }
        let kept = CantripTabMentions.remaining(mentions, in: input)
        if kept != mentions { mentionDrafts[key] = kept.isEmpty ? nil : kept }
    }

    private var composer: some View {
        ChatComposer {
            if let sessionID = remote.selectedSessionID {
                ImageAttachmentPicker(
                    attachments: imageDraft(for: sessionID),
                    importID: $imageImportID,
                    imageSupport: remote.selectedSession?.id == sessionID
                        ? remote.selectedSession?.supportsImageAttachments : nil,
                    disabled: imagePickerDisabled,
                    video: videoDraft(for: sessionID),
                    videoSupport: remote.selectedSession?.id == sessionID
                        ? remote.selectedSession?.supportsVideoAttachments : nil,
                    files: fileDraft(for: sessionID),
                    fileSupport: remote.selectedSession?.id == sessionID
                        ? remote.selectedSession?.supportsFileAttachments : nil,
                    mixedSupport: remote.selectedSession?.id == sessionID
                        ? remote.selectedSession?.supportsMixedAttachments : nil,
                    paste: $composerPaste
                )
                .id(sessionID)
            }
        } message: {
            TextField(
                CantripInputComposer.placeholder(
                    for: remote.chatInputRequest, mode: vm.remoteDeliveryMode,
                    recipient: isTab ? remote.selectedSession?.title ?? "Cantrip"
                        : CantripMascotName.display(mascotName)
                ),
                text: Binding(get: { input }, set: { input = $0; fieldText = $0 }),
                axis: .vertical
            )
            .id(composerRevision)
            .focused($composerFocused)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(!destinationReady || !composerAcceptsText || vm.sending || submittingRemote)
            .onSubmit(sendText)
            .help("Return sends. Option-Return adds a new line. Type / for this tab's commands and skills, @ to mention another tab. Paste attaches copied photos, videos and files.")
            .composerPaste(isEnabled: !imagePickerDisabled && !importingImages) {
                composerPaste = ComposerPasteRequest(providers: $0)
            }
            .accessibilityIdentifier("chat.message")
        } trailing: {
            CantripStopButton(
                session: remote.selectedSession,
                isConnected: remote.isConnected,
                isMutating: remote.isMutating,
                isStopping: remote.stoppingSessionID != nil
                    && remote.stoppingSessionID == remote.selectedSessionID,
                iconOnly: true,
                onStop: vm.stopRemote
            )
            .disabled(vm.sending || importingImages || submittingRemote)
            composerAction
        } accessory: {
            CantripInputComposer(
                model: remote, deliveryMode: vm.remoteDeliveryMode,
                maxHeight: min(360, max(72, size.height * 0.45)),
                busy: vm.sending || submittingRemote || importingImages
            )
        }
    }

    private var composerAction: some View {
        Group {
            if vm.sending || submittingRemote || importingImages {
                ProgressView().controlSize(.small)
            } else if input.isEmpty && !hasImageDraft {
                ChatMicrophoneButton(
                    isListening: voice.isListening,
                    isEnabled: voice.authorized && destinationReady && composerAcceptsText && !voice.isFinishing,
                    onStart: {
                        if voice.isSpeaking { vm.interruptAndListen() } else { voice.startListening() }
                    },
                    onFinish: { voice.stopListening(finalize: true) },
                    onContinuousVoice: {
                        voice.stopListening(finalize: false)
                        navigation.sheet = .voiceMode
                    }
                )
                .help("Talk to Cantrip: hold and release, or click to start and click again to send. Double-click for voice mode.")
            } else {
                Button(action: sendText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!destinationReady || !composerAcceptsText || remote.isMutating)
                .help("Send (Return)")
                .accessibilityLabel(vm.remoteDeliveryMode == .auto && remote.chatInputRequest != nil
                    ? "Send reply" : "Send prompt")
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }

    private var pausedBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "pause.circle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent paused").font(.callout.weight(.semibold))
                Text("No requests will be sent.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            CantripStopButton(
                session: remote.selectedSession, isConnected: remote.isConnected,
                isMutating: remote.isMutating,
                isStopping: remote.stoppingSessionID != nil
                    && remote.stoppingSessionID == remote.selectedSessionID,
                iconOnly: true, onStop: vm.stopRemote
            )
            Button("Resume") { paused = false }.buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var voiceStatus: some View {
        if voice.isPreparingRecognition {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(voice.recognitionStatusText ?? "Preparing speech recognition…")
                    .font(.callout).foregroundStyle(.secondary)
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
                .font(.caption).foregroundStyle(.red)
        } else if voice.isSpeaking {
            HStack(spacing: 10) {
                WaveformView(active: true, color: .accentColor)
                Text("\(CantripMascotName.display(mascotName)) is speaking")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { voice.stopSpeaking() } label: { Image(systemName: "stop.circle").font(.title3) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop speaking")
            }
        } else if vm.isWorking && remote.chatInputRequest == nil {
            HStack(spacing: 10) {
                ThinkingView(size: 22, color: .accentColor)
                Text(vm.runStatusText ?? "Cantrip is working…")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Sending

    private func sendText() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paused, !importingImages, !submittingRemote, !vm.sending,
              destinationReady, composerAcceptsText, !remote.isMutating,
              !text.isEmpty || hasImageDraft,
              let sessionID = remote.selectedSessionID else { return }
        let draftKey = remoteDraftKey(sessionID)
        let images = imageDrafts[draftKey] ?? []
        let video = videoDrafts[draftKey]
        let files = fileDrafts[draftKey] ?? []
        let originalInput = input
        // Picked tabs go out as tokens with their IDs; the draft keeps the plain text.
        let mentions = CantripTabMentions.remaining(mentionDrafts[draftKey] ?? [], in: text)
        let wireText = CantripTabMentions.supportsMentions(remote.selectedSession) && !mentions.isEmpty
            ? CantripTabMentions.encode(text, mentions: mentions) : text
        submittingRemote = true
        Task { @MainActor in
            defer { submittingRemote = false }
            let sent = await vm.sendRemote(wireText, images: images, video: video, files: files, sessionID: sessionID)
            if sent {
                let sentIDs = Set(images.map(\.id))
                imageDrafts[draftKey]?.removeAll { sentIDs.contains($0.id) }
                if videoDrafts[draftKey]?.id == video?.id { videoDrafts.removeValue(forKey: draftKey) }
                let sentFiles = Set(files.map(\.id))
                fileDrafts[draftKey]?.removeAll { sentFiles.contains($0.id) }
                if remoteDraftKey(remote.selectedSessionID ?? "") == draftKey, input == originalInput {
                    input = ""
                    mentionDrafts.removeValue(forKey: draftKey)
                    composerCaret = nil
                    composerRevision = UUID()
                }
            } else {
                imageSendError = (remote.errorMessage ?? "Cantrip did not confirm the message.")
                    + "\n\nYour draft has been kept. If the connection was lost, check the conversation before sending again to avoid a duplicate."
            }
        }
    }

    private func applyPrefillAndFocus() {
        if let prefill = navigation.composerPrefill {
            input = prefill
            composerRevision = UUID()
            navigation.composerPrefill = nil
        }
        DispatchQueue.main.async { composerFocused = true }
    }

    // MARK: Drafts

    private func remoteDraftKey(_ sessionID: String) -> String {
        "\(remote.selectedServerID?.uuidString ?? remote.usageIdentity.uuidString)/\(sessionID)"
    }

    private var transcriptIdentity: String {
        "\(ExecutionLane.home.rawValue):\(remoteDraftKey(remote.selectedSessionID ?? ""))"
    }

    private func imageDraft(for sessionID: String) -> Binding<[ChatImageAttachment]> {
        let key = remoteDraftKey(sessionID)
        return Binding(get: { imageDrafts[key] ?? [] }, set: { imageDrafts[key] = $0 })
    }

    private func fileDraft(for sessionID: String) -> Binding<[ChatFileAttachment]> {
        let key = remoteDraftKey(sessionID)
        return Binding(get: { fileDrafts[key] ?? [] }, set: { fileDrafts[key] = $0 })
    }

    private func videoDraft(for sessionID: String) -> Binding<ChatVideoAttachment?> {
        let key = remoteDraftKey(sessionID)
        return Binding(get: { videoDrafts[key] }, set: { videoDrafts[key] = $0 })
    }

    private var destinationReady: Bool { remote.isConfigured && remote.selectedSessionID != nil }

    private var composerAcceptsText: Bool {
        CantripInputComposer.acceptsText(for: remote.chatInputRequest, mode: vm.remoteDeliveryMode)
    }

    private var imagePickerDisabled: Bool {
        !destinationReady || !composerAcceptsText || vm.sending || submittingRemote
            || remote.isMutating || voice.isListening
    }

    private var hasImageDraft: Bool {
        guard let sessionID = remote.selectedSessionID else { return false }
        return !(imageDrafts[remoteDraftKey(sessionID)] ?? []).isEmpty
            || videoDrafts[remoteDraftKey(sessionID)] != nil
            || !(fileDrafts[remoteDraftKey(sessionID)] ?? []).isEmpty
    }

    private var importingImages: Bool { imageImportID != nil }

    // MARK: Drag and drop

    /// Dropped image files and images become attachments, through the same processor and
    /// limits as the attachment menu.
    private func dropImages(_ providers: [NSItemProvider]) -> Bool {
        guard let sessionID = remote.selectedSessionID, !imagePickerDisabled, !importingImages else {
            return false
        }
        guard remote.selectedSession?.supportsImageAttachments == true else {
            attachmentError = "Update Cantrip and choose a backend that accepts images to attach them."
            return false
        }
        let key = remoteDraftKey(sessionID)
        guard videoDrafts[key] == nil || remote.selectedSession?.supportsMixedAttachments == true else {
            attachmentError = VideoAttachmentError.mixedAttachments.localizedDescription
            return false
        }
        let existing = imageDrafts[key]?.count ?? 0
        guard existing + providers.count <= ImageAttachmentProcessor.maximumCount else {
            attachmentError = ImageAttachmentError.tooMany.localizedDescription
            return false
        }
        let importID = UUID()
        imageImportID = importID
        Task { @MainActor in
            defer { if imageImportID == importID { imageImportID = nil } }
            do {
                var imported: [ChatImageAttachment] = []
                for provider in providers {
                    let data = try await Self.imageData(from: provider)
                    try Task.checkCancellation()
                    imported.append(try await Task.detached(priority: .userInitiated) {
                        try ImageAttachmentProcessor.prepare(data)
                    }.value)
                }
                guard imageImportID == importID else { return }
                guard (imageDrafts[key]?.count ?? 0) + imported.count <= ImageAttachmentProcessor.maximumCount else {
                    throw ImageAttachmentError.tooMany
                }
                imageDrafts[key, default: []].append(contentsOf: imported)
            } catch is CancellationError {
                return
            } catch {
                attachmentError = error.localizedDescription
            }
        }
        return true
    }

    private static func imageData(from provider: NSItemProvider) async throws -> Data {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: error ?? ImageAttachmentError.invalidImage) }
                }
            }
            return try await Task.detached(priority: .userInitiated) {
                try ImageAttachmentProcessor.readFile(url)
            }.value
        }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? ImageAttachmentError.invalidImage) }
            }
        }
    }
}
