import SwiftUI
import AppKit
import Combine

struct LauncherView: View {
    @ObservedObject var manager: SessionManager
    /// Active session — manager forwards child objectWillChange, so
    /// observing the manager is sufficient for re-rendering.
    private var session: ChatSession { manager.active }
    private var shell: PersistentShell { session.shell }
    @ObservedObject var settings = AppSettings.shared
    @StateObject private var speech = SpeechRecognizer()
    @State private var query = ""
    @State private var tabDrafts: [UUID: String] = [:]
    @State private var suppressVoiceSubmission = false
    @State private var deliveryMode: MessageDeliveryMode = .auto
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool
    var onDismiss: () -> Void
    var onSizeChange: (CGSize) -> Void = { _ in }
    var onKeepVisibleChange: (Bool) -> Void = { _ in }
    @State private var pinned = false
    @State private var showSteps = false
    @State private var progressPaneSection = ProgressPaneSection.steps
    @StateObject private var fileSearch = FileSearch.shared
    @ObservedObject private var usage = UsageTracker.shared
    @ObservedObject private var updater = UpdateChecker.shared
    @ObservedObject private var metrics = PanelMetrics.shared
    @State private var showUsage = false
    @State private var showHistory = false
    @State private var historySearch = ""
    @State private var historyEntries: [HistoryEntry] = []
    @State private var archivedSessions: [SessionManager.ArchivedSession] = []
    @State private var renamingSession: ChatSession?
    @State private var modelSettingsSession: ChatSession?
    @State private var showingInputRequests = false
    @State private var tabName = ""
    /// The tab "Move to Section > New Section..." files under the section being named.
    @State private var sectioningSession: ChatSession?
    @State private var sectionName = ""
    @State private var editingSections = false
    @State private var creatingSection = false
    @State private var renamingSection: TabSection?
    @State private var deletingSection: TabSection?
    @ObservedObject private var childTabStore = ChildTabStore.shared
    /// A child tab whose Discard is waiting for confirmation.
    @State private var discardingChild: ChildTab?
    /// A child tab whose Run in This Tab Instead is waiting for confirmation.
    @State private var requeueingChild: ChildTab?
    @State private var childTabError: String?
    /// Why Continue on a failed message couldn't start (offline, busy).
    @State private var continueError: String?
    /// The section header a dragged tab or section is over.
    @State private var sectionDropTarget: String?
    @ObservedObject private var sectionCollapse = TabSectionCollapse.shared
    /// Instant caption for whichever toolbar icon is hovered.
    @State private var toolbarHint: String?
    /// Council seat column visibility (collapsible to a slim strip).
    @State private var showCouncilPanes = true
    // Inner-pane widths, user-draggable via PaneDivider (persisted).
    @AppStorage("councilPaneUserWidth") private var councilPaneUserWidth = 300.0
    @AppStorage("settingsPaneUserWidth") private var settingsPaneUserWidth = 330.0
    @AppStorage("stepsPaneUserWidth") private var stepsPaneUserWidth = 280.0
    // Plugins ("Extensions"): popover, approve-on-install flow, and the
    // dashboard pane a panel-plugin renders into.
    @ObservedObject private var pluginManager = PluginManager.shared
    @State private var showExtensions = false
    @State private var pendingApproval: Plugin?
    @State private var pluginReloadToken = 0
    @AppStorage("activePluginPanel") private var activePluginPanelID = ""
    @AppStorage("pluginPaneUserWidth") private var pluginPaneUserWidth = 320.0
    // Window sizing inputs: the laid-out content, plus how far the
    // floating suggestions dropdown reaches (it's overlay-only, so the
    // window must be told to make room downward when it's taller than
    // what's beneath it).
    @State private var measuredContentSize = CGSize.zero
    /// The composer's frame in the panel's coordinate space — the
    /// dropdown pins its top edge to this frame's bottom.
    @State private var inputBarFrame = CGRect.zero
    /// Natural (unscrolled) height of the suggestion rows, so the
    /// dropdown can size to its content below the scroll cap.
    @State private var suggestionListHeight: CGFloat = 0
    /// The tab backend's commands, skills and Cantrip scripts for "/" suggestions.
    @State private var commandList: BackendCommandList?
    @State private var commandListSession: UUID?
    @State private var commandsLoading = false
    /// Keyboard-highlighted suggestion row (index into `commandMatches`).
    @State private var commandHighlight: Int?
    /// Escape hides the suggestions for exactly this text.
    @State private var dismissedSlashText: String?
    /// Tabs picked from the "@" list, per tab; sent as mention tokens (TabMentions).
    @State private var tabMentions: [UUID: [TabMentions.Pick]] = [:]
    /// Keyboard-highlighted row of the "@" list (index into `mentionMatches`).
    @State private var mentionHighlight: Int?
    /// Escape hides the "@" list for the "@" at this place ("<tab ID> <offset>").
    @State private var dismissedMention: String?
    /// The text field's current and smallest (one-line) heights; the
    /// difference is what extra lines added.
    @State private var composerHeight: CGFloat = 0
    @State private var composerOneLineHeight = CGFloat.infinity
    @State private var showTerminal = false
    @State private var terminalCommand = ""
    @State private var terminalHistoryIndex: Int?
    @State private var terminalHistoryDraft = ""
    @StateObject private var remoteConnection = RemoteConnection()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            mainColumn
                // Council seat panes get their own width on top of the
                // configured width, so the main transcript isn't squeezed
                // (kept in lockstep with sidebarExtra — see its comment).
                .frame(width: effectiveContentWidth + councilPaneWidth)
            if !manager.showingRemote, showSettings {
                PaneDivider(width: paneBinding($settingsPaneUserWidth, range: 280...560),
                            range: 280...560)
                settingsSidebar
            }
            if !manager.showingRemote, showSteps {
                PaneDivider(width: paneBinding($stepsPaneUserWidth, range: 220...480),
                            range: 220...480)
                stepsSidebar
            }
            if !manager.showingRemote, let plugin = activePluginPanel {
                PaneDivider(width: paneBinding($pluginPaneUserWidth, range: 240...640),
                            range: 240...640)
                pluginSidebar(plugin)
            }
        }
        .padding(.bottom, 6)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(privateTintOverlay)
        .overlay(panelBorder)
        .background(GeometryReader { geo in
            Color.clear
                .preference(key: ContentSizeKey.self, value: geo.size)
        })
        .coordinateSpace(name: "panel")
        .sheet(isPresented: Binding(
            get: { modelSettingsSession != nil },
            set: { if !$0 { modelSettingsSession = nil } }
        )) {
            if let chat = modelSettingsSession {
                if chat.isLocalPrivate { PrivateLocalSettingsView(session: chat) }
                else { SessionModelSettingsView(session: chat) }
            }
        }
        .sheet(isPresented: $editingSections) {
            TabSectionsEditor(manager: manager)
        }
        .sheet(isPresented: $showingInputRequests) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Secure Input").font(.headline)
                ScrollView { RemoteInputView(session: session, secureOnly: true) }
                Button("Done") { showingInputRequests = false }
            }.padding(20).frame(width: 600, height: 480)
        }
        .alert("Rename Tab", isPresented: Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        ), presenting: renamingSession) { chat in
            TextField("Tab name", text: $tabName)
            Button("Cancel", role: .cancel) { renamingSession = nil }
            Button("Save") {
                do { try chat.updateTab(name: tabName) }
                catch { manager.tabActionError = error.localizedDescription }
                renamingSession = nil
            }
        } message: { _ in
            Text("Up to 80 characters. Leave blank to use the automatic name.")
        }
        .alert("New Section", isPresented: Binding(
            get: { sectioningSession != nil },
            set: { if !$0 { sectioningSession = nil } }
        ), presenting: sectioningSession) { chat in
            TextField("Section name", text: $sectionName)
            Button("Cancel", role: .cancel) { sectioningSession = nil }
            Button("Create") {
                do {
                    let section = try manager.createSection(named: sectionName)
                    try manager.setSection(section.id, for: chat.id)
                } catch { manager.tabActionError = error.localizedDescription }
                sectioningSession = nil
            }
        } message: { chat in
            Text("\(chat.title) moves into it. Sections group tabs in Cantrip Agent, Gateway and the browser.")
        }
        .alert("New Section", isPresented: $creatingSection) {
            TextField("Section name", text: $sectionName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                do { try manager.createSection(named: sectionName) }
                catch { manager.tabActionError = error.localizedDescription }
            }
        } message: {
            Text("An empty section. Drop tabs on its header or use a tab's Move to Section. It shows on every device.")
        }
        .alert("Rename Section", isPresented: Binding(
            get: { renamingSection != nil },
            set: { if !$0 { renamingSection = nil } }
        ), presenting: renamingSection) { section in
            TextField("Section name", text: $sectionName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                do { try manager.renameSection(section.id, to: sectionName) }
                catch { manager.tabActionError = error.localizedDescription }
            }
        } message: { _ in
            Text("Up to \(TabSectionStore.maximumNameLength) characters.")
        }
        .alert(deletingSection.map { "Delete \u{201C}\($0.name)\u{201D}?" } ?? "Delete Section?", isPresented: Binding(
            get: { deletingSection != nil },
            set: { if !$0 { deletingSection = nil } }
        ), presenting: deletingSection) { section in
            Button("Delete Section", role: .destructive) { deleteSection(section) }
            Button("Cancel", role: .cancel) {}
        } message: { section in
            let count = tabCount(section)
            Text("Its \(count == 1 ? "tab moves" : "\(count) tabs move") back to Tabs. No tabs are closed.")
        }
        .modifier(ChildTabAlerts(discarding: $discardingChild, requeueing: $requeueingChild,
                                 error: $childTabError, perform: performChildAction))
        .keepingLauncherPanelOpen(while: presentingPanelModal)
        .alert("Tab Protected", isPresented: Binding(
            get: { manager.tabActionError != nil || session.tabActionError != nil },
            set: { if !$0 { manager.tabActionError = nil; session.tabActionError = nil } }
        )) {
            Button("OK") { manager.tabActionError = nil; session.tabActionError = nil }
        } message: {
            Text(manager.tabActionError ?? session.tabActionError ?? "")
        }
        // The floating dropdown lives at PANEL level, explicitly placed:
        // top edge at the composer's measured bottom, expanding downward
        // over whatever is beneath (Spotlight-style). Overlays draw above
        // the whole base composite, so no zIndex juggling is needed.
        .overlay(alignment: .topLeading) {
            if !manager.showingRemote,
               lowerSectionVisible, hasSuggestions, inputBarFrame != .zero {
                suggestionsOverlay
                    .frame(width: inputBarFrame.width)
                    .offset(x: inputBarFrame.minX, y: inputBarFrame.maxY)
            }
        }
        .onPreferenceChange(ContentSizeKey.self) { size in
            measuredContentSize = size
            reportSize()
        }
        .onPreferenceChange(InputBarFrameKey.self) { frame in
            inputBarFrame = frame
            reportSize()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: pinned) {
            onKeepVisibleChange(pinned || session.isStreaming)
        }
        .onChange(of: session.isStreaming) {
            onKeepVisibleChange(pinned || session.isStreaming)
        }
        .onChange(of: session.id) { previous, current in
            tabDrafts[previous] = query
            query = tabDrafts[current] ?? ""
            terminalCommand = ""
            resetTerminalHistoryNavigation()
            showTerminal = false
            if speech.isRecording { suppressVoiceSubmission = true }
            speech.stop()
            commandList = nil
            commandListSession = nil
            commandHighlight = nil
            mentionHighlight = nil
            dismissedMention = nil
            BackendCommandCatalog.shared.prefetch(session)
            if slashToken != nil { loadCommands() }
        }
        .onChange(of: session.workdir) {
            commandList = nil
            commandListSession = nil
            commandHighlight = nil
            if slashToken != nil { loadCommands() }
        }
        .onAppear { BackendCommandCatalog.shared.prefetch(session) }
        // Agent commands mirror into the terminal silently (background);
        // the toolbar icon signals activity — open it when you want to look.
        .onChange(of: session.focusRequested) { _, requested in
            if requested {
                inputFocused = true
                session.focusRequested = false
            }
        }
        .onChange(of: speech.transcript) { _, text in
            if speech.isRecording { query = text }
        }
        .onChange(of: query) { oldValue, newValue in
            if !session.isLocalPrivate {
                // An "@tab" being typed isn't a file search.
                fileSearch.search(newValue.contains(where: \.isNewline) || TabMentions.query(in: newValue) != nil ? "" : newValue)
                FileRAG.shared.prepare(for: newValue)
            }
            commandQueryChanged(from: oldValue, to: newValue)
            mentionQueryChanged(from: oldValue, to: newValue)
        }
        // Any file dropped on the panel becomes an attachment.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !manager.showingRemote, !session.isLocalPrivate else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async {
                        session.attachments.append(url.path)
                    }
                }
            }
            return true
        }
        // Live drag: layout follows the mouse.
        .onReceive(NotificationCenter.default.publisher(
            for: LauncherPanel.userResizingNotification)) { note in
            guard let size = note.userInfo?["size"] as? CGSize else { return }
            metrics.setLiveSize(totalWidth: size.width,
                                totalHeight: size.height,
                                sidebarExtra: sidebarExtra)
        }
        // Drag ended: adopt and remember the size.
        .onReceive(NotificationCenter.default.publisher(
            for: LauncherPanel.userResizedNotification)) { note in
            guard let size = note.userInfo?["size"] as? CGSize else { return }
            metrics.setUserSize(totalWidth: size.width,
                                totalHeight: size.height,
                                sidebarExtra: sidebarExtra)
        }
        // Voice mode loop: reply spoken → resume listening → dictation
        // ends → auto-submit.
        .onReceive(NotificationCenter.default.publisher(for: SpeechSynth.didFinish)) { _ in
            if settings.voiceMode, !session.isStreaming, !session.isLocalPrivate { speech.start() }
        }
        .onChange(of: speech.isRecording) { _, recording in
            if !recording, suppressVoiceSubmission {
                suppressVoiceSubmission = false
                return
            }
            if !recording, settings.voiceMode, !session.isLocalPrivate,
               !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                submit()
            }
        }
    }

    /// Private mode wears purple so there's never doubt which mode
    /// you're typing in.
    private var privateTintOverlay: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.purple.opacity(!manager.showingRemote && session.isPrivate ? 0.08 : 0))
            .allowsHitTesting(false)
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(!manager.showingRemote && session.isPrivate
                          ? Color.purple.opacity(0.55)
                          : Color.white.opacity(0.15))
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            sessionTabs
            Divider().opacity(0.3)
            if manager.showingRemote {
                RemoteConnectionView(connection: remoteConnection)
            } else {
                localSessionContent
            }
        }
        .background(sessionShortcuts)
    }

    private var localSessionContent: some View {
        VStack(spacing: 0) {
            inputBar
                .background(
                    // ⌘↩ never reaches TextField.onSubmit (the modifier
                    // suppresses it), so register it as a real shortcut.
                    Group {
                        Button(action: { submit(interrupt: true) }) { EmptyView() }
                            .keyboardShortcut(.return, modifiers: .command)
                        Button(action: { submit(inject: true) }) { EmptyView() }
                            .keyboardShortcut(.return, modifiers: .option)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                )
                // Report where the composer ends so the suggestions
                // dropdown can pin its top edge exactly there (see the
                // panel-level overlay in body) — Spotlight-style, always
                // fully below the typing area, never covering it.
                .background(GeometryReader { geo in
                    Color.clear.preference(
                        key: InputBarFrameKey.self,
                        value: geo.frame(in: .named("panel")))
                })
            if !lowerSectionVisible, hasSuggestions {
                suggestionList
            }
            if !session.attachments.isEmpty {
                attachmentChips
            }
            if !currentMentions.isEmpty {
                mentionChips
            }
            if let selection = session.selectionContext {
                selectionChip(selection)
            }
            if !session.queued.isEmpty || session.isStreaming || session.deliveryStatus != nil {
                queueView
            }
            if showTerminal {
                Divider().opacity(0.3)
                terminalView
            } else if showUsage {
                Divider().opacity(0.3)
                ScrollView { usageView }
                    .frame(maxHeight: lowerSectionMaxHeight)
            } else if showHistory {
                Divider().opacity(0.3)
                historyView
            } else if !session.messages.isEmpty || session.statusText != nil {
                Divider().opacity(0.3)
                conversationView
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 4) {
            MacDesktopStatusView()
            // Row 1: the essentials — clean, Spotlight-like.
            HStack(spacing: 10) {
                Button(action: {
                    if session.isLocalPrivate { modelSettingsSession = session }
                    else { withAnimation(.easeOut(duration: 0.15)) { showSettings.toggle() } }
                }) {
                    Image(systemName: backendIcon)
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("\(backendBadge) — click for backend & settings")

                TextField(placeholder, text: $query, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .light))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onKeyPress(keys: [.return, Self.keypadEnter], phases: [.down, .repeat],
                                action: handleModifiedReturn)
                    .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: [.down, .repeat],
                                action: handleCommandKey)
                    .accessibilityHint(showsMentionSuggestions && !mentionMatches.isEmpty
                        ? "\(mentionMatches.count) tab suggestions. Up and Down arrows choose, Return or Tab mentions the tab, Escape hides them."
                        : slashToken != nil && !commandMatches.isEmpty
                        ? "\(commandMatches.count) command suggestions. Up and Down arrows choose, Tab inserts, Return runs, Escape hides them."
                        : "")
                    .onSubmit { submit() }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ComposerHeightKey.self, value: geo.size.height)
                    })
                    .onPreferenceChange(ComposerHeightKey.self) { height in
                        guard height > 1 else { return }
                        composerHeight = height
                        composerOneLineHeight = min(composerOneLineHeight, height)
                    }

                if session.isStreaming {
                    Button(action: session.cancel) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }

                Button(action: toggleVoiceMode) {
                    Image(systemName: settings.voiceMode ? "mic.fill" : "mic")
                        .font(.system(size: 16))
                        .foregroundStyle(speech.isRecording
                                         ? Color.red
                                         : settings.voiceMode ? Color.accentColor : Color.secondary)
                        .visiblePulse(isActive: speech.isRecording)
                }
                .buttonStyle(.plain)
                .help(settings.voiceMode
                      ? "Stop voice conversation"
                      : "Start voice conversation — listens, sends, and speaks replies")
            }

            // Row 2: tools & toggles.
            toolbarRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var toolbarRow: some View {
        HStack(spacing: 12) {
            Button(action: pickWorkdir) {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    if (session.workdir as NSString).standardizingPath != NSHomeDirectory() {
                        Text((session.workdir as NSString).lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 90)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Session working directory: \(session.workdir) — click to change")
            .hoverHint("Working directory — where commands & agents run", $toolbarHint)

            if isGitRepo {
                gitMenu
                    .hoverHint("Git quick actions for this repo", $toolbarHint)
            }

            if let hint = toolbarHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            if updater.updateAvailable {
                Button(action: {
                    // Stream the update through the transcript like a
                    // ! command, so pull/build progress is visible.
                    session.submit("!" + UpdateChecker.shared.updateCommand)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                        Text(updater.commitsBehind > 0 ? "New update" : "Rebuild needed")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(updater.commitsBehind > 0
                    ? "\(updater.commitsBehind) new commit\(updater.commitsBehind == 1 ? "" : "s") on GitHub — click to pull, rebuild, and relaunch (app restarts)"
                    : "The running app was built from older source than this checkout — click to rebuild and relaunch (app restarts)")
            }

            Spacer()

            councilMenu
                .disabled(session.isLocalPrivate)
                .hoverHint("Council mode — several models answer in parallel, then the chair delivers a joint verdict", $toolbarHint)

            Button(action: {
                pluginManager.reload()
                pendingApproval = nil
                showExtensions.toggle()
            }) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 13))
                    .foregroundStyle(showExtensions || activePluginPanel != nil
                                     ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Extensions — your plugins (dashboards & MCP tools)")
            .hoverHint("Extensions — toggle plugins, open their dashboards", $toolbarHint)
            .popover(isPresented: $showExtensions, arrowEdge: .bottom) {
                extensionsPopover
            }

            Button(action: { session.isPrivate.toggle() }) {
                Image(systemName: session.isPrivate ? "eye.slash.fill" : "eye.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(session.isPrivate ? Color.purple : Color.secondary)
            }
            .disabled(session.isLocalPrivate)
            .buttonStyle(.plain)
            .help(session.isPrivate
                  ? "Private mode ON — this session isn't saved to transcripts, history, or memory"
                  : "Private mode — don't save this session anywhere")
            .hoverHint("Private mode — session saved nowhere", $toolbarHint)

            Button(action: toggleTerminal) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "greaterthan.square")
                        .font(.system(size: 15))
                        .foregroundStyle(showTerminal ? Color.accentColor
                            : terminalBusy ? Color.orange : Color.secondary)
                        .visiblePulse(isActive: terminalBusy && !showTerminal)
                    if terminalBusy && !showTerminal {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -3)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(terminalBusy
                  ? "Terminal — a command is running in the background; click to watch"
                  : "Terminal — persistent shell inside the panel")
            .hoverHint(terminalBusy ? "Terminal — command running in background"
                                    : "Terminal — shell with persistent state (cd, env)",
                       $toolbarHint)

            Button(action: toggleHistory) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15))
                    .foregroundStyle(showHistory ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Browse past conversations")
            .hoverHint("History — past sessions & conversations", $toolbarHint)

            Button(action: toggleUsage) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 14))
                    .foregroundStyle(showUsage ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Usage & spending")
            .hoverHint("Usage — quotas & spending per backend", $toolbarHint)

            Button(action: { toggleProgressPane(.steps) }) {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 15))
                    .foregroundStyle(showSteps && progressPaneSection == .steps
                                     ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(showSteps && progressPaneSection == .steps
                  ? "Hide progress sidebar" : "Show tool steps")
            .hoverHint("Progress — live tool steps & diffs", $toolbarHint)

            Button(action: { toggleProgressPane(.background) }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 15))
                        .foregroundStyle(showSteps && progressPaneSection == .background
                                         ? Color.accentColor
                                         : activeBackgroundTasks > 0 ? Color.orange : Color.secondary)
                        .visiblePulse(isActive: activeBackgroundTasks > 0
                                      && (!showSteps || progressPaneSection != .background))
                    if activeBackgroundTasks > 0 {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -3)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(showSteps && progressPaneSection == .background
                  ? "Hide background tasks" : "Show background tasks")
            .hoverHint(activeBackgroundTasks == 1
                       ? "Background — 1 task running"
                       : activeBackgroundTasks > 1
                           ? "Background — \(activeBackgroundTasks) tasks running"
                           : "Background — watchers and other background tasks",
                       $toolbarHint)

            Button(action: { pinned.toggle() }) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 14))
                    .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(pinned ? "Unpin — panel hides when you click away"
                         : "Pin — panel stays visible while you work in other apps")
            .hoverHint("Pin — keep panel visible over other apps", $toolbarHint)

            Button(action: toggleScreenSharing) {
                Image(systemName: settings.attachScreen ? "macwindow.badge.plus" : "macwindow")
                    .font(.system(size: 15))
                    .foregroundStyle(settings.attachScreen ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(settings.attachScreen
                  ? "Screen context on — queries include a screenshot taken when the panel opened"
                  : "Attach a screenshot of your screen to queries")
            .hoverHint("Screen context — let queries see your displays", $toolbarHint)

            Button(action: { withAnimation(.easeOut(duration: 0.15)) { showSettings.toggle() } }) {
                Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(showSettings ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            // ("New conversation" button removed — ⌘N still works, and new
            // tabs (⌘T) are the natural fresh-start.)

            Menu {
                let archived = manager.archivedSessions()
                if archived.isEmpty {
                    Text("No archived sessions")
                } else {
                    Text("Reopen session")
                    ForEach(archived.prefix(8)) { entry in
                        Button("\(entry.title) — \(entry.date.formatted(date: .abbreviated, time: .shortened))") {
                            manager.restore(entry.id)
                        }
                    }
                }
                Divider()
                Button("Browse all in History…") { toggleHistory() }
            } label: {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } primaryAction: {
                manager.newSession()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Click: new session (⌘T) · menu: reopen a past session")
            .hoverHint("Sessions — click for new, open menu to restore", $toolbarHint)
        }
    }

    private var backendIcon: String {
        if session.isLocalPrivate { return "lock.shield.fill" }
        switch settings.backend {
        case .claudeCode: return "terminal"
        case .copilot: return "airplane"
        case .copilotRemote: return "antenna.radiowaves.left.and.right"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "sparkles"
        case .localModel: return "cpu"
        }
    }

    /// ⌘1–9 select tabs; ⌘⇧[ / ⌘⇧] cycle.
    private var sessionShortcuts: some View {
        Group {
            Button(action: selectRemote) { EmptyView() }
                .keyboardShortcut("1", modifiers: .command)
            ForEach(2..<10, id: \.self) { n in
                Button(action: {
                    let tabs = panelTabs
                    if tabs.indices.contains(n - 2) { manager.select(tabs[n - 2].id) }
                }) { EmptyView() }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button(action: {
                manager.selectPrevious()
            }) { EmptyView() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button(action: {
                manager.selectNext()
            }) { EmptyView() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    // MARK: - Session tabs

    private var sessionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button(action: selectRemote) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(remoteConnection.isConnected
                                  ? Color.green
                                  : Color.secondary.opacity(0.45))
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(remoteConnection.isConnected
                                                ? "Connected"
                                                : "Disconnected")
                        shortcutBadge(1)
                        Text("Remote")
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(manager.showingRemote
                                ? AnyShapeStyle(.quaternary)
                                : AnyShapeStyle(.clear),
                                in: Capsule())
                }
                .buttonStyle(.plain)
                .help(remoteConnection.isConnected
                      ? "Connected to remote Cantrip"
                      : "Connect to sessions on another Cantrip")

                let order = panelTabs
                if let groups = manager.tabSectionGroups() {
                    ForEach(groups) { group in
                        sectionPill(group)
                        ForEach(TabSectionCollapse.visible(group, collapsed: sectionCollapse.collapsed.contains(group.id),
                                                           activeID: activeTabID), id: \.id) { chat in
                            tabPill(chat, position: order.firstIndex { $0.id == chat.id } ?? 0, order: order)
                        }
                    }
                } else {
                    ForEach(Array(manager.sessions.enumerated()), id: \.element.id) { index, chat in
                        tabPill(chat, position: index, order: order)
                    }
                }

                Button(action: {
                    manager.newSession()
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New session (⌘T)")

                Button(action: promptNewSection) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New Section: group tabs on every device")
                .accessibilityLabel("New Section")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    /// A tab's pill; `position` is its place in `order`, the strip's display order.
    private func tabPill(_ chat: ChatSession, position: Int, order: [ChatSession]) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                if chat.isStreaming {
                    ProgressView().controlSize(.mini)
                }
                if position < 8 {
                    shortcutBadge(position + 2)
                }
                if manager.parentID(ofChild: chat.id) != nil {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ChildTabColors.lane)
                        .accessibilityHidden(true)
                }
                Text(chat.title)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 140)
                if chat.isLocked {
                    Image(systemName: chat.isLocalPrivate ? "lock.shield.fill" : "lock.fill")
                        .font(.system(size: 10))
                        .help(chat.isLocalPrivate ? "Permanent self-hosted-model tab. History is saved and available remotely." : "Locked tab - unlock from the tab menu to close")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, chat.isLocked ? 10 : 0)
            .padding(.vertical, 4)
            .overlay {
                SessionTabDragHandle(id: chat.id, title: chat.title,
                                     canDrag: manager.parentID(ofChild: chat.id) == nil) {
                    manager.select(chat.id)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(childParentTitle(chat).map { "Child tab of \($0)" } ?? "")
            .accessibilityAction { manager.select(chat.id) }
            if !chat.isLocked {
                Button(action: { manager.close(chat.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(chat.title)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(isActiveTab(chat)
                    ? AnyShapeStyle(.quaternary)
                    : AnyShapeStyle(.clear),
                    in: Capsule())
        .contentShape(Capsule())
        .dropDestination(for: String.self) { items, _ in
            guard items.count == 1, let value = items.first,
                  value.hasPrefix("cantrip-tab:"),
                  let id = UUID(uuidString: String(value.dropFirst("cantrip-tab:".count))),
                  let source = order.firstIndex(where: { $0.id == id }),
                  let target = order.firstIndex(where: { $0.id == chat.id }),
                  id != chat.id else { return false }
            return moveTab(id, relativeTo: chat.id, after: source < target)
        }
        .help("Drag to reorder. Right-click for tab actions.")
        .contextMenu {
            Button(chat.isLocalPrivate ? "Private Local Settings..." : "Model Settings...") { modelSettingsSession = chat }
            Button("Start Fresh") { startFresh(chat) }
                .disabled(chat.startFreshUnavailableReason != nil)
            if !chat.isLocalPrivate {
                Button("Sign in to GitHub on Mac...") { chat.submitRemote("/login github", mode: .queue) }
                    .disabled(chat.isStreaming || !chat.queued.isEmpty)
            }
            Button("Rename Tab...") {
                tabName = chat.tabMetadata.customTitle ?? chat.title
                renamingSession = chat
            }
            Button(chat.isLocked ? "Unlock Tab" : "Lock Tab") {
                do { try chat.updateTab(isLocked: !chat.isLocked) }
                catch { manager.tabActionError = error.localizedDescription }
            }
            .disabled(chat.isLocalPrivate)
            if let parentID = manager.parentID(ofChild: chat.id) {
                Button("Open Parent Tab") { manager.select(parentID) }
            }
            if !chat.isPrivate, manager.parentID(ofChild: chat.id) == nil {
                Menu("Move to Section") {
                    let current = manager.sectionID(of: chat)
                    Toggle("Tabs", isOn: Binding(get: { current == nil }, set: { _ in fileTab(chat, in: nil) }))
                    ForEach(manager.tabSections) { section in
                        Toggle(section.name, isOn: Binding(get: { current == section.id },
                                                           set: { _ in fileTab(chat, in: section.id) }))
                    }
                    Divider()
                    Button("New Section...") {
                        sectionName = ""
                        sectioningSession = chat
                    }
                    Button("Edit Sections...") { editingSections = true }
                }
            }
            Divider()
            Button("Move Tab Left") {
                moveTab(chat.id, offset: -1)
            }
            .disabled(position == 0 || manager.parentID(ofChild: chat.id) != nil)
            Button("Move Tab Right") {
                moveTab(chat.id, offset: 1)
            }
            .disabled(position == order.count - 1 || manager.parentID(ofChild: chat.id) != nil)
            Divider()
            Button("Close Tab", role: .destructive) { manager.close(chat.id) }
                .disabled(chat.isLocked)
        }
    }

    /// An alert, sheet or dialog is up on the panel (it takes key focus; the panel must stay).
    private var presentingPanelModal: Bool {
        modelSettingsSession != nil || editingSections || showingInputRequests || renamingSession != nil
            || sectioningSession != nil || creatingSection || renamingSection != nil || deletingSection != nil
            || manager.tabActionError != nil || session.tabActionError != nil
            || discardingChild != nil || requeueingChild != nil || childTabError != nil
    }

    // MARK: Tab sections in the strip

    private static let sectionDragPrefix = "cantrip-section:"

    /// The strip's tabs in display order (grouped by section; collapsed sections keep only busy tabs).
    private var panelTabs: [ChatSession] { manager.panelTabs(collapsed: sectionCollapse.collapsed) }

    private var activeTabID: UUID? {
        manager.showingRemote || !manager.sessions.indices.contains(manager.activeIndex)
            ? nil : manager.sessions[manager.activeIndex].id
    }

    private func isActiveTab(_ chat: ChatSession) -> Bool { activeTabID == chat.id }

    private func tabCount(_ section: TabSection) -> Int {
        manager.sessions.filter { manager.sectionID(of: $0) == section.id }.count
    }

    /// A section's header pill, like the browser strip: click to collapse, drag onto another
    /// header to reorder, drop a tab on it to file the tab, right-click for its actions.
    private func sectionPill(_ group: TabSectionGroup) -> some View {
        let collapsed = sectionCollapse.collapsed.contains(group.id)
        let targeted = sectionDropTarget == group.id
        let count = group.sessions.count
        return HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
            Text(group.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: 120)
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.clear), in: Capsule())
        .overlay { Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5).opacity(targeted ? 1 : 0) }
        .overlay {
            if let section = group.section {
                SessionTabDragHandle(id: section.id, title: section.name,
                                     payloadPrefix: Self.sectionDragPrefix) { toggleSection(group) }
            } else {
                Color.clear.contentShape(Capsule()).onTapGesture { toggleSection(group) }
            }
        }
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.name) section, \(count == 1 ? "1 tab" : "\(count) tabs")")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits([.isButton, .isHeader])
        .accessibilityAction { toggleSection(group) }
        .accessibilityAction(named: "New Section") { promptNewSection() }
        .accessibilityActions {
            if let section = group.section {
                Button("Rename Section") { promptRename(section) }
                Button("Delete Section") { requestDelete(section) }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, on: group)
        } isTargeted: { isTargeted in
            if isTargeted { sectionDropTarget = group.id } else if sectionDropTarget == group.id { sectionDropTarget = nil }
        }
        .help(group.section == nil
              ? "Click to collapse. Right-click for New Section."
              : "Click to collapse. Drag onto another section to reorder. Drop a tab here to file it. Right-click for section actions.")
        .contextMenu { sectionMenu(group) }
    }

    @ViewBuilder private func sectionMenu(_ group: TabSectionGroup) -> some View {
        if let section = group.section {
            let index = manager.tabSections.firstIndex { $0.id == section.id } ?? 0
            Button("Rename Section...") { promptRename(section) }
            Button("New Tab Here") { newTab(in: section) }
            Divider()
            Button("Move Section Left") { moveSection(section.id, to: index - 1) }
                .disabled(index == 0)
            Button("Move Section Right") { moveSection(section.id, to: index + 1) }
                .disabled(index == manager.tabSections.count - 1)
            Divider()
            Button(tabCount(section) == 0 ? "Delete Section" : "Delete Section...", role: .destructive) {
                requestDelete(section)
            }
            Divider()
        }
        Button("New Section...") { promptNewSection() }
        Button("Edit Sections...") { editingSections = true }
    }

    private func toggleSection(_ group: TabSectionGroup) {
        withAnimation(.snappy(duration: 0.2)) { sectionCollapse.toggle(group.id) }
    }

    private func promptNewSection() {
        sectionName = ""
        creatingSection = true
    }

    private func promptRename(_ section: TabSection) {
        sectionName = section.name
        renamingSection = section
    }

    /// Empty sections go at once; a section with tabs asks first (its tabs move back to Tabs).
    private func requestDelete(_ section: TabSection) {
        if tabCount(section) == 0 { deleteSection(section) } else { deletingSection = section }
    }

    private func deleteSection(_ section: TabSection) {
        do { try manager.deleteSection(section.id) }
        catch { manager.tabActionError = error.localizedDescription }
    }

    private func moveSection(_ id: UUID, to position: Int) {
        guard manager.tabSections.indices.contains(position) else { return }
        do { try manager.moveSection(id, to: position) }
        catch { manager.tabActionError = error.localizedDescription }
    }

    private func newTab(in section: TabSection) {
        do { manager.select(try manager.newSession(inSection: section.id).id) }
        catch { manager.tabActionError = error.localizedDescription }
    }

    /// A tab dropped on a header is filed there; a section's header takes the target's place
    /// (on Tabs: first).
    private func drop(_ items: [String], on group: TabSectionGroup) -> Bool {
        guard items.count == 1, let value = items.first else { return false }
        if value.hasPrefix("cantrip-tab:"),
           let id = UUID(uuidString: String(value.dropFirst("cantrip-tab:".count))),
           let chat = manager.sessions.first(where: { $0.id == id }) {
            guard manager.sectionID(of: chat) != group.section?.id else { return false }
            fileTab(chat, in: group.section?.id)
            return true
        }
        if value.hasPrefix(Self.sectionDragPrefix),
           let id = UUID(uuidString: String(value.dropFirst(Self.sectionDragPrefix.count))),
           id != group.section?.id {
            // Onto Tabs (always last): the last section.
            moveSection(id, to: group.section.flatMap { target in manager.tabSections.firstIndex { $0.id == target.id } }
                        ?? manager.tabSections.count - 1)
            return true
        }
        return false
    }

    private func fileTab(_ chat: ChatSession, in sectionID: UUID?) {
        do { try manager.setSection(sectionID, for: chat.id) }
        catch { manager.tabActionError = error.localizedDescription }
    }

    /// Moves a tab past its neighbor in the strip's display order (into that tab's section).
    private func moveTab(_ id: UUID, offset: Int) {
        let order = panelTabs
        guard let index = order.firstIndex(where: { $0.id == id }),
              order.indices.contains(index + offset) else {
            manager.tabActionError = SessionTabError.unavailable.localizedDescription
            return
        }
        moveTab(id, relativeTo: order[index + offset].id, after: offset > 0)
    }

    @discardableResult
    private func moveTab(_ id: UUID, relativeTo targetID: UUID, after: Bool) -> Bool {
        do {
            try manager.moveSession(id, relativeTo: targetID, after: after)
            return true
        } catch {
            manager.tabActionError = error.localizedDescription
            return false
        }
    }

    private func shortcutBadge(_ number: Int) -> some View {
        Text("⌘\(number)")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 3))
    }

    private func selectRemote() {
        manager.selectRemote()
        showSettings = false
        showSteps = false
        showTerminal = false
        showUsage = false
        showHistory = false
        activePluginPanelID = ""
    }

    // MARK: - Settings sidebar

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Settings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { withAnimation(.easeOut(duration: 0.15)) { showSettings = false } }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            SettingsView(
                busySessions: manager.sessions.filter {
                    $0.isStreaming || !$0.queued.isEmpty || $0.shell.isRunning
                }.count,
                onUpdate: { session.submit("!" + UpdateChecker.shared.updateCommand) })
            Spacer(minLength: 0)
        }
        .frame(width: CGFloat(settingsPaneUserWidth), alignment: .topLeading)
    }

    // MARK: - Progress sidebar

    private var allActivities: [ToolActivity] {
        session.messages.flatMap(\.activities)
    }

    private var sessionSubagents: [ToolActivity] {
        allActivities.flatMap(\.subagentActivities)
    }

    private var backgroundTasks: [ToolActivity] {
        sessionSubagents.filter { $0.subagent?.background == true }
    }

    private var foregroundSubagents: [ToolActivity] {
        sessionSubagents.filter { $0.subagent?.background != true }
    }

    private var activeBackgroundTasks: Int {
        backgroundTasks.filter { $0.subagent?.isActive == true }.count
    }

    /// Running subagents, pinned below the transcript until each one finishes.
    private var pinnedSubagents: [ToolActivity] {
        sessionSubagents.filter { $0.subagent?.isActive == true }
    }

    private var stopSubagent: (SubagentInfo, @escaping (String?) -> Void) -> Void {
        let session = session
        return { info, done in
            session.cancelSubagent(agentID: info.agentID) { result in
                switch result {
                case .success(true): done(nil)
                case .success(false): done("It had already finished.")
                case .failure(let error): done(error.localizedDescription)
                }
            }
        }
    }

    private func progressSectionTitle(_ title: String, detail: String? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title)
            if let detail { Text("· \(detail)").foregroundStyle(.tertiary) }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
    }

    private var stepsSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Progress")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if session.isStreaming {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button(action: { withAnimation(.easeOut(duration: 0.15)) { showSteps = false } }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            let steps = allActivities.filter { $0.subagent == nil }
            ProgressPaneTabs(
                selection: $progressPaneSection,
                steps: steps.count + foregroundSubagents.count,
                backgroundTasks: backgroundTasks.count
            )
            if progressPaneSection == .background {
                if backgroundTasks.isEmpty {
                    Text("No background tasks yet. Watchers for builds, uploads, and downloads appear here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        SubagentMonitorView(activities: backgroundTasks, stop: stopSubagent)
                    }
                    .frame(maxHeight: 620)
                }
            } else {
                if steps.isEmpty && foregroundSubagents.isEmpty {
                    Text("No steps yet — tool activity will appear here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if !foregroundSubagents.isEmpty {
                    let running = foregroundSubagents.filter { $0.subagent?.isActive == true }.count
                    progressSectionTitle("Subagents", detail: running > 0 ? "\(running) running" : nil)
                    ScrollView {
                        SubagentMonitorView(activities: foregroundSubagents, stop: stopSubagent)
                    }
                    .frame(maxHeight: 320)
                }
                if !steps.isEmpty {
                    if !foregroundSubagents.isEmpty { progressSectionTitle("Steps").padding(.top, 4) }
                    ScrollViewReader { proxy in
                        ScrollView {
                            ToolProgressView(activities: steps)
                                .id("steps-end")
                        }
                        .frame(maxHeight: foregroundSubagents.isEmpty ? 560 : 300)
                        .onChange(of: steps.count) {
                            proxy.scrollTo("steps-end", anchor: .bottom)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: CGFloat(stepsPaneUserWidth), alignment: .topLeading)
    }

    // MARK: - Extensions (plugins)

    /// A plugin's dashboard, as a right-side pane. Definite height (the
    /// transcript's max) because a WKWebView has no intrinsic size and the
    /// panel lays out with fixedSize(vertical: true).
    private func pluginSidebar(_ plugin: Plugin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(plugin.panelTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { pluginReloadToken += 1 }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Reload the plugin page")
                Button(action: { activePluginPanelID = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close this dashboard")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            PluginPanelView(plugin: plugin, reloadToken: pluginReloadToken) { prompt in
                session.submit(prompt)
            }
            .id(plugin.id)
            .frame(height: metrics.transcriptMaxHeight)
        }
        .frame(width: CGFloat(pluginPaneUserWidth), alignment: .topLeading)
    }

    private var extensionsPopover: some View {
        Group {
            if let plugin = pendingApproval {
                approvalCard(plugin)
            } else {
                pluginList
            }
        }
        .frame(width: 340)
    }

    private var pluginList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Extensions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if pluginManager.plugins.isEmpty {
                Text("No plugins installed. Drop a folder containing a manifest.json into the plugins directory — PLUGINS.md in the repo has the format and a starter example.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(pluginManager.plugins) { plugin in
                pluginRow(plugin)
            }
            Divider()
            HStack {
                Button("Open Plugins Folder") {
                    NSWorkspace.shared.open(PluginManager.pluginsDirectory)
                }
                Spacer()
                Button("Rescan") { pluginManager.reload() }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func pluginRow(_ plugin: Plugin) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.manifest.name)
                        .font(.callout)
                    if let version = plugin.manifest.version {
                        Text("v\(version)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if pluginManager.isEnabled(plugin), !pluginManager.isApproved(plugin) {
                        // Manifest changed since approval (or never approved):
                        // stays inert until the user re-reviews it.
                        Text("needs approval")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let description = plugin.manifest.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if pluginManager.isActive(plugin), plugin.panelURL != nil {
                Button(action: {
                    activePluginPanelID =
                        activePluginPanelID == plugin.id ? "" : plugin.id
                }) {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 12))
                        .foregroundStyle(activePluginPanelID == plugin.id
                                         ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(activePluginPanelID == plugin.id
                      ? "Hide this plugin's dashboard"
                      : "Show this plugin's dashboard")
            }
            // The toggle reflects ACTIVE (enabled + approved): a plugin
            // whose manifest changed since approval reads as OFF, and
            // switching it on re-opens the approval card.
            Toggle("", isOn: Binding(
                get: { pluginManager.isActive(plugin) },
                set: { on in
                    if on, !pluginManager.isApproved(plugin) {
                        pendingApproval = plugin // approve-on-install gate
                    } else {
                        pluginManager.setEnabled(plugin, on)
                        if !on, activePluginPanelID == plugin.id {
                            activePluginPanelID = ""
                        }
                    }
                }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private func approvalCard(_ plugin: Plugin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approve “\(plugin.manifest.name)”?")
                .font(.callout.weight(.semibold))
            if let description = plugin.manifest.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("This plugin provides:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if plugin.capabilitySummary.isEmpty {
                Text("• Nothing — the manifest declares no panel or MCP servers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(plugin.capabilitySummary, id: \.self) { line in
                Text("• \(line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Dashboard pages run with full network access; MCP server commands run as your user. Approval is tied to this exact manifest — any edit asks again.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { pendingApproval = nil }
                Button("Approve & Enable") {
                    pluginManager.approve(plugin)
                    pluginManager.setEnabled(plugin, true)
                    pendingApproval = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func keycap(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Progress + pending queue: what's running now and what runs next.
    private var queueView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.pendingInputs.contains(where: { $0.kind == .secret }) {
                Button("Enter password securely") {
                    showingInputRequests = true
                }
                .buttonStyle(.bordered)
            }
            if let request = session.chatInputRequest {
                Text("Question waiting: \(request.title). Use Auto to reply.").font(.caption).foregroundStyle(.secondary)
            }
            if session.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(session.currentActivity.map { "Now: \($0.title)" }
                         ?? session.statusText.map { "Now: \($0)" }
                         ?? "Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Picker("Delivery", selection: $deliveryMode) {
                        ForEach(MessageDeliveryMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Auto interprets your message; choose a mode to override it.")
                    if settings.backend == .claudeCode {
                        keycap("⌥↩", "add context")
                    }
                    keycap("⌘↩", "interrupt")
                }
            }
            if let status = session.deliveryStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(session.queued.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(.quaternary))
                    PromptTextView(text: item.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let plan = session.queuePlans[item.id] {
                        Text(plan.reason)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(plan.kind == .fork ? AnyShapeStyle(ChildTabColors.lane) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(plan.kind == .fork ? AnyShapeStyle(ChildTabColors.lane.opacity(0.13)) : AnyShapeStyle(.quaternary),
                                        in: Capsule())
                            .layoutPriority(-1)
                            .help(plan.reason)
                    }
                    if session.supportsChildTabs {
                        let unavailable = manager.childTabs.forkUnavailableReason(session)
                        Button(action: { forkQueued(item.id) }) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(unavailable == nil ? AnyShapeStyle(ChildTabColors.lane) : AnyShapeStyle(.tertiary))
                        }
                        .buttonStyle(.plain)
                        .disabled(unavailable != nil)
                        .help(unavailable ?? "Run in a child tab: its own tab and branch, merged back when it's done.")
                        .accessibilityLabel("Run in Child Tab")
                        .accessibilityHint(unavailable ?? "")
                    }
                    Button(action: { session.sendQueuedNow(id: item.id) }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Send now, without waiting. Anything already running keeps going in the background.")
                    .accessibilityLabel("Send now")
                    Button(action: { session.removeQueued(at: index) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from queue")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var attachmentChips: some View {
        HStack(spacing: 8) {
            ForEach(Array(session.attachments.enumerated()), id: \.offset) { index, path in
                ZStack(alignment: .topTrailing) {
                    if let image = NSImage(contentsOfFile: path),
                       ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg"]
                           .contains((path as NSString).pathExtension.lowercased()) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.white.opacity(0.2)))
                            .help(path)
                    } else {
                        VStack(spacing: 2) {
                            Image(nsImage: AppCatalog.shared.icon(
                                for: URL(fileURLWithPath: path)))
                                .resizable()
                                .frame(width: 28, height: 28)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 8))
                                .lineLimit(1)
                                .frame(width: 48)
                        }
                        .frame(width: 52, height: 44)
                        .help(path)
                    }
                    Button(action: { session.attachments.remove(at: index) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                }
            }
            Text("attached — will be analyzed with your next question")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var placeholder: String {
        session.isLocalPrivate ? "Private Local - saved, self-hosted models"
            : session.isPrivate ? "Private — nothing is saved" : "How can I help you?"
    }

    /// Dropdown row labels: backend + its currently selected model.
    private func pickerLabel(for kind: BackendKind) -> String {
        switch kind {
        case .claudeCode:
            let model = settings.claudeModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Claude Code" : "Claude Code · \(model)"
        case .copilot:
            if let model = settings.effectiveCopilotModel {
                return "Copilot · \(model)"
            }
            return "Copilot"
        case .copilotRemote:
            return "Copilot Remote · \(settings.acpAddress)"
        case .codex:
            let model = settings.codexModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Codex" : "Codex · \(model)"
        case .antigravity:
            let model = settings.agyModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Antigravity" : "Antigravity · \(model)"
        case .localModel:
            return "Local · \(settings.localModel)"
        }
    }

    /// Backend + model, shown subtly since the placeholder no longer does.
    private var backendBadge: String {
        if session.isLocalPrivate { return "Private Local - Ollama" }
        switch settings.backend {
        case .claudeCode:
            let model = settings.claudeModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Claude Code" : "Claude Code · \(model)"
        case .copilot:
            if let model = settings.effectiveCopilotModel {
                return "Copilot · \(model)"
            }
            return "Copilot"
        case .copilotRemote:
            return "Copilot Remote · \(settings.acpAddress)"
        case .codex:
            let model = settings.codexModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Codex" : "Codex · \(model)"
        case .antigravity:
            let model = settings.agyModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Antigravity" : "Antigravity · \(model)"
        case .localModel: return settings.localModel
        }
    }

    // MARK: - Workdir & git

    private var isGitRepo: Bool {
        FileManager.default.fileExists(atPath: session.workdir + "/.git")
    }

    private func pickWorkdir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: session.workdir)
        panel.prompt = "Use as Working Directory"
        if panel.runModal() == .OK, let url = panel.url {
            session.workdir = url.path
        }
    }

    // ── Council mode: pick model seats; same backend may hold several ──

    private var councilMenu: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { session.councilMode },
                set: { session.councilMode = $0 })) {
                Text("Council mode")
            }
            .disabled(settings.councilMembers.count < 2)

            Picker("Convene for", selection: Binding(
                get: { settings.councilScope },
                set: { settings.councilScope = $0 })) {
                Text("Planning & review only").tag("planReview")
                Text("Every message").tag("always")
            }

            if !settings.councilMembers.isEmpty {
                Section("Seats (click to remove)") {
                    ForEach(settings.councilMembers) { member in
                        Button {
                            settings.councilMembers.removeAll { $0.id == member.id }
                            if settings.councilMembers.count < 2 { session.councilMode = false }
                        } label: {
                            Label(member.label, systemImage: "minus.circle")
                        }
                    }
                }
            }

            Section("Add a seat") {
                Menu("Claude Code") {
                    councilModelButtons(backend: .claudeCode,
                                        models: AppSettings.claudeModelAliases)
                }
                Menu("Copilot") {
                    councilModelButtons(backend: .copilot,
                                        models: settings.copilotAvailableModels)
                }
                Menu("Codex") {
                    councilModelButtons(backend: .codex,
                                        models: [settings.codexModel].filter { !$0.isEmpty })
                }
                Menu("Antigravity") {
                    councilModelButtons(backend: .antigravity,
                                        models: settings.agyAvailableModels)
                }
                Menu("Local Model") {
                    councilModelButtons(backend: .localModel,
                                        models: [settings.localModel].filter { !$0.isEmpty })
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: session.councilMode ? "person.3.fill" : "person.3")
                    .font(.system(size: 13))
                if session.councilMode {
                    Text("\(settings.councilMembers.count)")
                        .font(.caption)
                }
            }
            .foregroundStyle(session.councilMode ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(session.councilMode
              ? "Council mode ON: \(settings.councilMembers.map(\.label).joined(separator: " + ")) answer in parallel; \(settings.backendLabel(settings.backend)) chairs the verdict"
              : "Council mode — pick 2+ model seats, then every prompt gets parallel answers and a joint verdict")
    }

    @ViewBuilder
    private func councilModelButtons(backend: BackendKind, models: [String]) -> some View {
        Button("Configured default") { addCouncilSeat(backend: backend, model: "") }
        ForEach(models, id: \.self) { model in
            Button(backend == .antigravity ? settings.agyModelLabel(model) : model) {
                addCouncilSeat(backend: backend, model: model)
            }
        }
    }

    private func addCouncilSeat(backend: BackendKind, model: String) {
        let member = CouncilMember(backend: backend.rawValue, model: model)
        guard !settings.councilMembers.contains(member),
              settings.councilMembers.count < 8 else { return }
        settings.councilMembers.append(member)
        if settings.councilMembers.count >= 2 { session.councilMode = true }
    }

    private var gitMenu: some View {
        Menu {
            Button("Summarize repo status") {
                session.submit("Run `git status` and `git log --oneline -10` here and summarize what's going on in this repo, briefly.")
            }
            Button("Commit message from staged diff") {
                session.submit("Run `git diff --staged`. If nothing is staged, say so. Otherwise write one concise conventional commit message for it — output only the message in a code block.")
            }
            Button("Review uncommitted changes") {
                session.submit("Run `git diff` and `git diff --staged` and review the changes: bugs, risks, missed edge cases. Be specific and brief.")
            }
            Button("Review branch vs default") {
                session.submit("Determine this repo's default branch, then review `git diff <default>...HEAD`: summarize the changeset and flag any issues.")
            }
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Git quick actions (\((session.workdir as NSString).lastPathComponent))")
    }

    // MARK: - Command (skill) typeahead

    /// The window height request: normally the measured content, but when
    /// the floating dropdown reaches past the content's bottom the window
    /// extends downward to contain it (top edge is fixed, so existing UI
    /// never moves — the panel just gains room underneath). The dropdown
    /// bottom is arithmetic — composer bottom + capped list height — so
    /// no geometry needs measuring through the offset.
    private func reportSize() {
        var size = measuredContentSize
        if lowerSectionVisible, hasSuggestions, inputBarFrame != .zero {
            let dropdownBottom = inputBarFrame.maxY
                + min(max(suggestionListHeight, 1), 320)
            size.height = max(size.height, dropdownBottom + 16)
        }
        onSizeChange(size)
    }

    /// Below the composer, sections give up whatever height extra
    /// composer lines take, so the panel keeps its size instead of
    /// pushing the tabs out of the height-capped window.
    private var lowerSectionMaxHeight: CGFloat {
        let growth = composerOneLineHeight.isFinite ? max(0, composerHeight - composerOneLineHeight) : 0
        return max(160, metrics.transcriptMaxHeight - growth)
    }

    /// The section below the input bar exists (transcript, terminal,
    /// history, or usage) — i.e. there is content for suggestions to
    /// float over.
    private var lowerSectionVisible: Bool {
        showTerminal || showUsage || showHistory
            || !session.messages.isEmpty || session.statusText != nil
    }

    private var hasSuggestions: Bool {
        !session.isLocalPrivate && (appSuggestion != nil
            || slashToken != nil
            || showsMentionSuggestions
            || (!fileSearch.results.isEmpty && !showHistory))
    }

    /// The suggestion rows themselves, shared between the inline layout
    /// (empty panel) and the floating overlay.
    @ViewBuilder private var suggestionRows: some View {
        if showsMentionSuggestions {
            mentionSuggestionRows
        } else {
            if let suggestion = appSuggestion {
                appSuggestionRow(suggestion)
            }
            if slashToken != nil {
                commandSuggestionRows
            }
            if !fileSearch.results.isEmpty && !showHistory {
                fileResultsRows
            }
        }
    }

    /// The rows in a scroll container capped at 320pt. A ScrollView is
    /// greedy (it takes whatever height it's offered), so the rows'
    /// natural height is measured and the frame pinned to
    /// min(content, cap): short lists hug their content, long lists
    /// scroll instead of growing the dropdown or the panel.
    private var suggestionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    suggestionRows
                }
                .background(GeometryReader { geo in
                    Color.clear.preference(key: SuggestionListHeightKey.self,
                                           value: geo.size.height)
                })
            }
            // Keyboard selection keeps the highlighted command or tab in view.
            .onChange(of: commandHighlight) { _, index in
                if let index { proxy.scrollTo("command-\(index)") }
            }
            .onChange(of: mentionHighlight) { _, index in
                if let index { proxy.scrollTo("mention-\(index)") }
            }
        }
        .frame(height: min(max(suggestionListHeight, 1), 320))
        .onPreferenceChange(SuggestionListHeightKey.self) {
            suggestionListHeight = $0
            reportSize() // dropdown height feeds the window's extent
        }
        // Preferences don't fire on removal, so reset — otherwise the
        // next appearance flashes one frame at the previous height, and
        // the window would keep the dropdown's extra room. Guarded: when
        // the list is merely MOVING between the inline site and the
        // floating overlay (hasSuggestions still true), the other
        // instance may already have re-reported the same height — its
        // preference won't fire again for an unchanged value, so zeroing
        // here after it appeared would stick the dropdown at 1pt.
        .onDisappear {
            if !hasSuggestions { suggestionListHeight = 0 }
            reportSize()
        }
    }

    /// Floating dropdown: opaque enough to read over the transcript,
    /// shadowed so it reads as a layer, and never part of the layout —
    /// showing or dismissing it cannot move or resize anything.
    private var suggestionsOverlay: some View {
        suggestionList
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .padding(.horizontal, 8)
    }

    private var commandSuggestionRows: some View {
        let matches = commandMatches
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.command.name) { index, match in
                commandRow(match.command, highlighted: index == commandHighlight)
                    .id("command-\(index)")
            }
            if matches.isEmpty, commandsLoading {
                commandInfoRow("Loading commands…")
            } else if matches.isEmpty, slashToken?.isEmpty == false {
                commandInfoRow("No matching commands. Return sends your text as typed.")
            }
            if let status = currentCommandList?.status {
                commandInfoRow(status)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command suggestions")
    }

    private func commandInfoRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }

    private func commandRow(_ command: BackendCommand, highlighted: Bool) -> some View {
        let unavailable = command.availability == .unavailable
        let choice = BackendCommandFilter.choose(command, canOpenModelSettings: canOpenModelSettingsFromCommand)
        let detail = unavailable || command.availability == .cantrip ? (command.note ?? command.description) : command.description
        return Button(action: { chooseCommand(command, viaTab: false) }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.commandIcon(command.kind))
                    .font(.system(size: 12))
                    .foregroundStyle(unavailable ? Color.secondary : Color.accentColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(command.title)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .layoutPriority(2)
                if let hint = command.inputHint {
                    Text(hint)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .layoutPriority(0)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                Text(command.source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                if highlighted, !unavailable {
                    keycap("↩", { if case .insert(_, true) = choice { return "run" }; return "insert" }())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
            .opacity(unavailable ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(unavailable)
        .help(unavailable ? (command.note ?? "Not available in Cantrip") : command.description)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.commandAccessibilityLabel(command))
        .accessibilityHint(unavailable ? "" : {
            switch choice {
            case .insert(_, true): return "Runs the command"
            case .openModelSettings: return "Opens this tab's model settings"
            default: return "Inserts the command"
            }
        }())
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    static func commandIcon(_ kind: BackendCommand.Kind) -> String {
        switch kind {
        case .builtin: return "command"
        case .custom: return "text.badge.star"
        case .skill: return "wand.and.stars"
        case .cantrip: return "puzzlepiece.extension"
        }
    }

    static func commandAccessibilityLabel(_ command: BackendCommand) -> String {
        var parts = [command.title]
        if !command.description.isEmpty { parts.append(command.description) }
        parts.append(command.source)
        if let note = command.note { parts.append(note) }
        if command.availability == .unavailable { parts.append("unavailable") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Command suggestions

    /// The command name being typed, unless the suggestions were dismissed for this text.
    private var slashToken: String? {
        guard !session.isLocalPrivate, !showHistory, dismissedSlashText != query else { return nil }
        return BackendCommandFilter.slashToken(query)
    }

    /// This tab's list, or Cantrip's own scripts until the backend's list arrives.
    private var currentCommandList: BackendCommandList? {
        if commandListSession == session.id, let commandList { return commandList }
        return nil
    }

    private var commandMatches: [BackendCommandFilter.Match] {
        guard let token = slashToken else { return [] }
        let commands = currentCommandList?.commands
            ?? BackendCommandParsers.cantripScripts(CommandRegistry.shared.commands.map { ($0.name, $0.description) })
        return BackendCommandFilter.matches(token: token, in: commands)
    }

    private var canOpenModelSettingsFromCommand: Bool {
        !session.isLocalPrivate && session.modelSettingsUnavailableReason == nil
    }

    private func loadCommands() {
        let chat = session
        CommandRegistry.shared.reload()
        commandsLoading = true
        Task { @MainActor in
            let list = await BackendCommandCatalog.shared.list(for: chat)
            guard chat.id == session.id else { return }
            commandList = list
            commandListSession = chat.id
            commandsLoading = false
            resetCommandHighlight()
        }
    }

    private func commandQueryChanged(from oldValue: String, to newValue: String) {
        if dismissedSlashText != nil, dismissedSlashText != newValue { dismissedSlashText = nil }
        let wasOpen = BackendCommandFilter.slashToken(oldValue) != nil
        guard slashToken != nil else { commandHighlight = nil; return }
        if !wasOpen {
            loadCommands()
            let count = commandMatches.count
            if count > 0 {
                AccessibilityNotification.Announcement(count == 1 ? "1 command" : "\(count) commands").post()
            }
        }
        resetCommandHighlight()
    }

    private func resetCommandHighlight() {
        guard let token = slashToken else { commandHighlight = nil; return }
        commandHighlight = BackendCommandFilter.defaultHighlight(token: token, matches: commandMatches)
    }

    /// Up/Down move through the suggestions, Tab inserts, Escape hides them for this text.
    private func handleCommandKey(_ press: KeyPress) -> KeyPress.Result {
        if showsMentionSuggestions, press.modifiers.intersection([.command, .option, .control]).isEmpty {
            return handleMentionKey(press)
        }
        guard slashToken != nil, press.modifiers.intersection([.command, .option, .control]).isEmpty else {
            return .ignored
        }
        let matches = commandMatches
        let choosable = matches.indices.filter { matches[$0].command.availability != .unavailable }
        switch press.key {
        case .escape:
            dismissedSlashText = query
            commandHighlight = nil
            return .handled
        case .tab:
            guard !press.modifiers.contains(.shift) else { return .ignored }
            guard let index = commandHighlight.flatMap({ matches.indices.contains($0) ? $0 : nil }) ?? choosable.first
            else { return .handled }
            chooseCommand(matches[index].command, viaTab: true)
            return .handled
        case .downArrow, .upArrow:
            guard !choosable.isEmpty else { return .handled }
            let down = press.key == .downArrow
            if let current = commandHighlight, let position = choosable.firstIndex(of: current) {
                let next = (position + (down ? 1 : choosable.count - 1)) % choosable.count
                commandHighlight = choosable[next]
            } else {
                commandHighlight = down ? choosable.first : choosable.last
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func chooseCommand(_ command: BackendCommand, viaTab: Bool) {
        switch BackendCommandFilter.choose(command, viaTab: viaTab, canOpenModelSettings: canOpenModelSettingsFromCommand) {
        case .none:
            return
        case .openModelSettings:
            query = ""
            modelSettingsSession = session
        case .insert(let text, let send):
            commandHighlight = nil
            if send {
                query = text.trimmingCharacters(in: .whitespaces)
                submit()
            } else {
                query = text
                inputFocused = true
            }
        }
    }

    // MARK: - Tab mentions

    private var currentMentions: [TabMentions.Pick] { tabMentions[session.id] ?? [] }

    /// The caret in the composer, when its field editor shows this text (end of text otherwise).
    private var composerCaret: String.Index? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == query else { return nil }
        let range = editor.selectedRange()
        guard range.length == 0 else { return nil }
        return Range(NSRange(location: range.location, length: 0), in: query)?.lowerBound
    }

    /// The "@query" being typed, unless its list was dismissed.
    private var mentionToken: (at: String.Index, query: String)? {
        guard !manager.showingRemote, !showHistory, TabMentions.supportsMentions(session),
              let found = TabMentions.query(in: query, caret: composerCaret),
              dismissedMention != mentionPlace(found.at, in: query),
              !TabMentions.isPicked(at: found.at, in: query, picks: currentMentions) else { return nil }
        return found
    }

    private func mentionPlace(_ at: String.Index, in text: String) -> String {
        "\(session.id) \(text.distance(from: text.startIndex, to: at))"
    }

    private var mentionCandidates: [TabMentions.Candidate] {
        TabMentions.candidates(for: session, in: manager)
    }

    private var mentionMatches: [TabMentions.Candidate] {
        guard let token = mentionToken else { return [] }
        return TabMentions.matches(token.query, in: mentionCandidates)
    }

    /// Shown while an "@query" is typed and there are tabs to mention. A space with no match
    /// means the "@" was ordinary text.
    private var showsMentionSuggestions: Bool {
        guard let token = mentionToken else { return false }
        let candidates = mentionCandidates
        guard !candidates.isEmpty else { return false }
        return !TabMentions.matches(token.query, in: candidates).isEmpty || !token.query.contains(where: \.isWhitespace)
    }

    private var mentionSuggestionRows: some View {
        let matches = mentionMatches
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, candidate in
                mentionRow(candidate, highlighted: index == mentionHighlight)
                    .id("mention-\(index)")
            }
            if matches.isEmpty, let token = mentionToken {
                commandInfoRow("No open tab matches “\(token.query)”. Return sends your text as typed.")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab suggestions")
    }

    private func mentionRow(_ candidate: TabMentions.Candidate, highlighted: Bool) -> some View {
        let isChild = candidate.parentTitle != nil
        return Button(action: { chooseMention(candidate) }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isChild ? "arrow.triangle.branch" : "macwindow")
                    .font(.system(size: 12))
                    .foregroundStyle(isChild ? AnyShapeStyle(ChildTabColors.lane) : AnyShapeStyle(Color.accentColor))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(candidate.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(2)
                if !candidate.detail.isEmpty {
                    Text(candidate.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                }
                Spacer(minLength: 6)
                if highlighted {
                    keycap("↩", "mention")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
        .help(candidate.detail.isEmpty ? "Mention “\(candidate.title)”" : "Mention “\(candidate.title)” · \(candidate.detail)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(candidate.accessibilityLabel)
        .accessibilityHint("Mentions this tab, so the model looks into exactly this tab")
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    /// Picked tabs, each sent with its ID; removing one removes its "@Label" from the text.
    private var mentionChips: some View {
        HStack(spacing: 6) {
            ForEach(currentMentions, id: \.self) { mention in
                HStack(spacing: 3) {
                    Text("@" + mention.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(action: { removeMention(mention) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove mention")
                    .accessibilityLabel("Remove mention \(mention.label)")
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.13), in: Capsule())
                .help("Sent with this tab's ID: the model looks into exactly “\(mention.label)”.")
            }
            Text("mentioned — the model looks into exactly these tabs")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mentioned tabs")
    }

    private func mentionQueryChanged(from oldValue: String, to newValue: String) {
        let kept = TabMentions.remaining(currentMentions, in: newValue)
        if kept != currentMentions { tabMentions[session.id] = kept.isEmpty ? nil : kept }
        let found = TabMentions.query(in: newValue, caret: composerCaret)
        if let dismissed = dismissedMention, found.map({ mentionPlace($0.at, in: newValue) }) != dismissed {
            dismissedMention = nil
        }
        guard showsMentionSuggestions else { mentionHighlight = nil; return }
        let matches = mentionMatches
        let wasOpen = TabMentions.query(in: oldValue) != nil && mentionHighlight != nil
        mentionHighlight = matches.isEmpty ? nil : 0
        if !wasOpen {
            AccessibilityNotification.Announcement(matches.count == 1 ? "1 tab" : "\(matches.count) tabs").post()
        }
    }

    /// Up/Down move through the tabs, Tab mentions one, Escape hides the list for this "@".
    private func handleMentionKey(_ press: KeyPress) -> KeyPress.Result {
        let matches = mentionMatches
        switch press.key {
        case .escape:
            if let token = mentionToken { dismissedMention = mentionPlace(token.at, in: query) }
            mentionHighlight = nil
            return .handled
        case .tab:
            guard !press.modifiers.contains(.shift) else { return .ignored }
            guard let index = mentionHighlight.flatMap({ matches.indices.contains($0) ? $0 : nil }) ?? matches.indices.first
            else { return .handled }
            chooseMention(matches[index])
            return .handled
        case .downArrow, .upArrow:
            guard !matches.isEmpty else { return .handled }
            let down = press.key == .downArrow
            if let current = mentionHighlight, matches.indices.contains(current) {
                mentionHighlight = (current + (down ? 1 : matches.count - 1)) % matches.count
            } else {
                mentionHighlight = down ? 0 : matches.count - 1
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func chooseMention(_ candidate: TabMentions.Candidate) {
        guard let token = mentionToken else { return }
        let result = TabMentions.insert(candidate, at: token.at, caret: composerCaret, in: query,
                                        label: TabMentions.uniqueLabel(for: candidate, among: currentMentions))
        let caret = NSRange(result.caret..<result.caret, in: result.text).location
        query = result.text
        tabMentions[session.id] = currentMentions.filter { !($0.id == candidate.id && $0.label == result.label) }
            + [TabMentions.Pick(label: result.label, id: candidate.id)]
        mentionHighlight = nil
        inputFocused = true
        placeComposerCaret(at: caret, in: result.text)
        AccessibilityNotification.Announcement("Mentioned \(candidate.title)").post()
    }

    /// Puts the caret after a picked mention. Return ends the field's editing and refocusing
    /// selects all of its text, so this waits for the field editor to show `text`.
    private func placeComposerCaret(at location: Int, in text: String, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) {
            guard query == text else { return }
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.string == text {
                editor.setSelectedRange(NSRange(location: location, length: 0))
            } else if attempt < 6 {
                placeComposerCaret(at: location, in: text, attempt: attempt + 1)
            }
        }
    }

    private func removeMention(_ mention: TabMentions.Pick) {
        query = TabMentions.removing(mention, from: query, among: currentMentions)
        let kept = currentMentions.filter { $0 != mention }
        tabMentions[session.id] = kept.isEmpty ? nil : kept
        inputFocused = true
    }

    // MARK: - App typeahead

    /// Top app hit for the current query (Spotlight-style).
    private var appSuggestion: AppMatch? {
        guard !session.isLocalPrivate, !showHistory, !session.isStreaming,
              !query.contains(where: \.isNewline), mentionToken == nil else { return nil }
        return AppCatalog.shared.match(query: query)
    }

    private func appSuggestionRow(_ suggestion: AppMatch) -> some View {
        Button(action: { launchApp(suggestion) }) {
            HStack(spacing: 10) {
                Image(nsImage: AppCatalog.shared.icon(for: suggestion.url))
                    .resizable()
                    .frame(width: 24, height: 24)
                Text("\(suggestion.isRunning ? "Switch to" : "Open") \(suggestion.name)")
                    .font(.system(size: 14))
                Spacer()
                keycap("↩", suggestion.isRunning ? "switch" : "open")
                keycap("⌘↩", "ask AI instead")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.4))
        }
        .buttonStyle(.plain)
    }

    private func launchApp(_ suggestion: AppMatch) {
        AppCatalog.shared.launch(suggestion)
        query = ""
        fileSearch.clear()
        onDismiss()
    }

    private var fileResultsRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(fileSearch.results, id: \.self) { url in
                Button(action: {
                    NSWorkspace.shared.open(url)
                    query = ""
                    fileSearch.clear()
                    onDismiss()
                }) {
                    HStack(spacing: 10) {
                        Image(nsImage: AppCatalog.shared.icon(for: url))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(url.lastPathComponent)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Text(url.deletingLastPathComponent().path
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                            onDismiss()
                        }) {
                            Image(systemName: "magnifyingglass.circle")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
    }

    private func toggleVoiceMode() {
        settings.voiceMode.toggle()
        if settings.voiceMode {
            if !speech.isRecording { speech.start(requireOnDevice: session.isLocalPrivate) }
        } else {
            SpeechSynth.shared.stop()
            if speech.isRecording { speech.stop() }
        }
    }

    private func toggleHistory() {
        withAnimation(.easeOut(duration: 0.15)) {
            showHistory.toggle()
            if showHistory { showUsage = false; showTerminal = false }
        }
        if showHistory {
            historyEntries = HistoryStore.load()
            archivedSessions = manager.archivedSessions()
        }
    }

    private func toggleUsage() {
        withAnimation(.easeOut(duration: 0.15)) {
            showUsage.toggle()
            if showUsage { showHistory = false; showTerminal = false }
        }
        if showUsage { usage.refreshQuotas() }
    }

    /// The transcript's width after yielding to open sidebars. The window
    /// itself is clamped to 95% of the screen (LauncherPanel.resizeContent),
    /// so when the stored contentWidth plus the panes can't fit — panel
    /// already at max width, then settings opens — something must give.
    /// It's the transcript, down to its 560pt floor, and only while the
    /// panes are open: this is computed, never persisted, so closing the
    /// pane restores the full width. Without this the content laid out
    /// wider than the window could grow and the UI clipped.
    private var effectiveContentWidth: CGFloat {
        let available = metrics.availableTotalWidth
        guard available > 0 else { return metrics.contentWidth }
        return min(metrics.contentWidth, max(560, available - sidebarExtra))
    }

    /// Width consumed by open sidebars (for resize math).
    private var sidebarExtra: CGFloat {
        guard !manager.showingRemote else { return 0 }
        return (showSettings ? CGFloat(settingsPaneUserWidth) + 7 : 0)
            + (showSteps ? CGFloat(stepsPaneUserWidth) + 7 : 0)
            + (activePluginPanel != nil ? CGFloat(pluginPaneUserWidth) + 7 : 0)
            + councilPaneWidth
    }

    /// The plugin whose dashboard pane is showing: it must still be
    /// enabled, approved, and have a valid panel entry file — disabling
    /// or editing the plugin closes the pane automatically.
    private var activePluginPanel: Plugin? {
        guard !activePluginPanelID.isEmpty else { return nil }
        return pluginManager.activePlugins.first {
            $0.id == activePluginPanelID && $0.panelURL != nil
        }
    }

    /// The council seat column's contribution to the panel width. MUST be
    /// counted here AND in mainColumn's frame with the same value — drag
    /// resizing subtracts sidebarExtra before persisting contentWidth, so
    /// an unaccounted column makes every drag re-add its width (the
    /// resize feedback glitch).
    private var councilActive: Bool {
        !manager.showingRemote && session.councilMode && settings.councilMembers.count >= 2
            && !showUsage && !showHistory
            && (!session.messages.isEmpty || session.statusText != nil)
    }

    private var councilPaneWidth: CGFloat {
        guard councilActive else { return 0 }
        return showCouncilPanes ? CGFloat(councilPaneUserWidth) + 7 : 27
    }

    /// Inner-pane resize: redistribute width between the transcript and
    /// the dragged pane so the OUTER window never changes size. The setter
    /// asks the transcript to give up (or take back) width first, then
    /// applies to the pane only what the transcript actually yielded —
    /// so when either side hits its clamp, both simply stop moving and
    /// the window total stays exact.
    private func paneBinding(_ storage: Binding<Double>,
                             range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { storage.wrappedValue },
            set: { proposed in
                let clamped = min(max(proposed, range.lowerBound), range.upperBound)
                let requested = clamped - storage.wrappedValue
                guard abs(requested) > 0.01 else { return }
                // Stored width above what's visible (panel squeezed onto a
                // smaller screen) is phantom slack: with it in place, a
                // shrink-the-pane drag would eat the slack invisibly and
                // the divider would feel dead. Snap it away so the trade
                // operates on the width the user actually sees.
                if metrics.contentWidth > effectiveContentWidth {
                    PanelMetrics.shared.adjustContentWidth(
                        by: effectiveContentWidth - metrics.contentWidth)
                }
                let given = PanelMetrics.shared.adjustContentWidth(by: -CGFloat(requested))
                guard given != 0 else { return } // transcript pinned at its clamp
                storage.wrappedValue -= Double(given)
            }
        )
    }

    /// A command (yours or the agent's) is running in the shell.
    private var terminalBusy: Bool {
        session.shell.isRunning || session.shell.hasAgentCommandRunning
    }

    private func toggleTerminal() {
        guard !session.isLocalPrivate else {
            session.tabActionError = "Shell commands and tools are disabled in Private Local."
            return
        }
        withAnimation(.easeOut(duration: 0.15)) {
            showTerminal.toggle()
            if showTerminal { showHistory = false; showUsage = false }
        }
    }

    private func toggleProgressPane(_ section: ProgressPaneSection) {
        withAnimation(.easeOut(duration: 0.15)) {
            if showSteps, progressPaneSection == section {
                showSteps = false
            } else {
                progressPaneSection = section
                showSteps = true
            }
        }
    }

    private func openProgressPane(_ section: ProgressPaneSection) {
        withAnimation(.easeOut(duration: 0.15)) {
            progressPaneSection = section
            showSteps = true
        }
    }

    // MARK: - Terminal mode

    private var terminalView: some View {
        VStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(shell.output.isEmpty
                         ? "Session terminal — agent commands and output appear here automatically.\nRun your own commands below; cd, exports, and variables persist."
                         : shell.output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(shell.output.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("term-end")
                }
                .frame(maxHeight: lowerSectionMaxHeight)
                .onChange(of: shell.output) {
                    proxy.scrollTo("term-end", anchor: .bottom)
                }
            }
            HStack(spacing: 6) {
                Text("$")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                TextField("command", text: $terminalCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        if press.key == .upArrow {
                            navigateTerminalHistory(backward: true)
                            return .handled
                        }
                        if press.key == .downArrow {
                            navigateTerminalHistory(backward: false)
                            return .handled
                        }
                        if press.key == KeyEquivalent("c"),
                           press.modifiers.contains(.control) {
                            if shell.isRunning {
                                shell.interrupt()
                            } else if shell.hasAgentCommandRunning {
                                session.cancel()
                            } else {
                                terminalCommand = ""
                                resetTerminalHistoryNavigation()
                            }
                            return .handled
                        }
                        return .ignored
                    }
                    .onSubmit(submitTerminalCommand)
                if shell.isRunning || shell.hasAgentCommandRunning {
                    ProgressView().controlSize(.mini)
                }
                Button("Clear") { shell.clear() }
                    .font(.caption)
                Button(action: { shell.restart() }) {
                    Image(systemName: "arrow.counterclockwise.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Restart the manual shell (kills its running command)")
            }
        }
        .padding(12)
    }

    private func submitTerminalCommand() {
        guard !session.isLocalPrivate else {
            session.tabActionError = "Shell commands and tools are disabled in Private Local."
            return
        }
        let command = terminalCommand.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        shell.run(command, workdir: session.workdir)
        terminalCommand = ""
        resetTerminalHistoryNavigation()
    }

    private func navigateTerminalHistory(backward: Bool) {
        let history = shell.commandHistory
        guard !history.isEmpty else { return }

        if backward {
            if let index = terminalHistoryIndex {
                terminalHistoryIndex = max(0, index - 1)
            } else {
                terminalHistoryDraft = terminalCommand
                terminalHistoryIndex = history.count - 1
            }
        } else if let index = terminalHistoryIndex {
            if index < history.count - 1 {
                terminalHistoryIndex = index + 1
            } else {
                terminalHistoryIndex = nil
                terminalCommand = terminalHistoryDraft
                return
            }
        } else {
            return
        }

        if let index = terminalHistoryIndex {
            terminalCommand = history[index]
        }
    }

    private func resetTerminalHistoryNavigation() {
        terminalHistoryIndex = nil
        terminalHistoryDraft = ""
    }

    // MARK: - Usage dashboard

    private func money(_ value: Double) -> String {
        value < 0.1 ? String(format: "$%.3f", value) : String(format: "$%.2f", value)
    }

    private var claudeMonthSpend: Double {
        usage.summary(days: 30)[BackendKind.claudeCode.rawValue]?.costUSD ?? 0
    }

    private var usageView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ClaudeUsageView(usage: usage)
            if usage.copilotUsage.antigravity != nil { AntigravityUsageView(usage: usage) }
            CopilotUsageView(usage: usage)
            if claudeMonthSpend > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "dollarsign.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Claude spend: \(money(claudeMonthSpend)) in the last 30 days")
                        .font(.callout)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Codex: plan-based (ChatGPT subscription) — limits not exposed by the CLI")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Local (\(settings.localModel)): free — runs on your hardware")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Claude figures come from its CLI. Copilot allowance comes from the Mac's signed-in Copilot account, not billing reports.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectionChip(_ selection: SelectionContext) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.quote")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("\(selection.text.count) chars from \(selection.appName):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(selection.text.prefix(70).replacingOccurrences(of: "\n", with: " "))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Button(action: { session.selectionContext = nil }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - History

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !archivedSessions.isEmpty {
                Text("Past sessions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(archivedSessions.prefix(8)) { archived in
                        HStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(archived.title)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text("\(archived.date.formatted(date: .abbreviated, time: .shortened)) · \(archived.messageCount) messages")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("Open") {
                                manager.restore(archived.id)
                                withAnimation { showHistory = false }
                            }
                            .font(.caption)
                            Button(action: {
                                manager.deleteArchived(archived.id)
                                archivedSessions = manager.archivedSessions()
                            }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Delete this session permanently")
                        }
                    }
                }
                Divider().opacity(0.3)
            }
            TextField("Search past conversations…", text: $historySearch)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            let filtered = historyEntries.filter {
                historySearch.isEmpty ||
                $0.user.localizedCaseInsensitiveContains(historySearch) ||
                $0.assistant.localizedCaseInsensitiveContains(historySearch)
            }
            if filtered.isEmpty {
                Text(historyEntries.isEmpty ? "No history yet." : "No matches.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filtered.prefix(100)) { entry in
                            HistoryRow(entry: entry) { question in
                                query = question
                                withAnimation { showHistory = false }
                                inputFocused = true
                            }
                        }
                    }
                }
                .frame(maxHeight: lowerSectionMaxHeight)
            }
        }
        .padding(12)
    }

    private func toggleScreenSharing() {
        settings.attachScreen.toggle()
        if settings.attachScreen {
            ScreenCapture.shared.requestAccess()
            ScreenCapture.shared.captureNow()
        }
    }

    private static let keypadEnter = KeyEquivalent("\u{3}")

    /// The field editor treats ⇧↩ as plain Return and swallows ⌥↩ as a
    /// newline before the hidden ⌥↩ shortcut can fire, so both are
    /// handled here. ⌘↩ still reaches its keyboard shortcut first.
    private func handleModifiedReturn(_ press: KeyPress) -> KeyPress.Result {
        switch press.modifiers.intersection([.shift, .option, .control, .command]) {
        case .shift:
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
                editor.insertNewlineIgnoringFieldEditor(nil)
            } else {
                query += "\n"
            }
            return .handled
        case .option:
            if press.phase == .down { submit(inject: true) }
            return .handled
        default:
            return .ignored
        }
    }

    private func submit(interrupt: Bool = false, inject: Bool = false) {
        // Return with a tab highlighted in the "@" list mentions it.
        if !interrupt, !inject, showsMentionSuggestions, let index = mentionHighlight, mentionMatches.indices.contains(index) {
            chooseMention(mentionMatches[index])
            return
        }
        // Return with a command suggestion highlighted chooses it (runs it, or inserts it when it
        // needs input); with nothing highlighted the text is sent as typed.
        if !interrupt, !inject, slashToken != nil, let index = commandHighlight, commandMatches.indices.contains(index) {
            chooseCommand(commandMatches[index].command, viaTab: false)
            return
        }
        // Enter with an app suggestion showing launches the app;
        // ⌘↩ bypasses the suggestion and asks the AI.
        if !session.isLocalPrivate, session.chatInputRequest == nil, !interrupt, !inject, let suggestion = appSuggestion {
            launchApp(suggestion)
            return
        }
        if speech.isRecording { speech.stop() }
        // Picked tabs travel as mention tokens carrying their IDs.
        let text = TabMentions.encode(query, mentions: currentMentions)
        if !interrupt, !inject, deliveryMode == .auto, let request = session.chatInputRequest {
            do { try session.submitInputReply(text, id: request.id) }
            catch { session.deliveryStatusForInput(error.localizedDescription); return }
            query = ""
            tabMentions[session.id] = nil
            return
        }
        query = ""
        tabMentions[session.id] = nil
        session.submit(text, mode: interrupt ? .interrupt : inject ? .inject : deliveryMode)
        deliveryMode = .auto
    }

    // MARK: - Conversation

    private var conversationView: some View {
        HStack(alignment: .top, spacing: 0) {
            mainTranscript
            if councilActive {
                if showCouncilPanes {
                    PaneDivider(width: paneBinding($councilPaneUserWidth, range: 220...560),
                                range: 220...560)
                    councilSeatColumn
                        .frame(width: CGFloat(councilPaneUserWidth))
                        .frame(maxHeight: lowerSectionMaxHeight)
                } else {
                    Divider().opacity(0.3)
                    councilReopenStrip
                        .frame(width: 26)
                        .frame(maxHeight: lowerSectionMaxHeight)
                }
            }
        }
    }

    /// The orchestrator view: user turns, worker replies, and council
    /// verdicts. Individual seat answers live in the side panes while
    /// council mode is on.
    private var transcriptMessages: [ChatMessage] {
        guard session.councilMode else { return session.messages }
        return session.messages.filter {
            $0.author == nil || $0.author?.hasPrefix("Verdict") == true
        }
    }

    private var errorRecovery: MessageRow.ErrorRecovery {
        let chat = session
        return MessageRow.ErrorRecovery(
            changeModelTitle: chat.isLocalPrivate ? "Private Local Settings" : "Change Model",
            isDisabled: chat.startFreshUnavailableReason != nil,
            startFresh: { startFresh(chat) },
            changeModel: { modelSettingsSession = chat }
        )
    }

    private func startFresh(_ chat: ChatSession) {
        do { try chat.startFresh() }
        catch { manager.tabActionError = error.localizedDescription }
    }

    // MARK: Child tabs

    private func childParentTitle(_ chat: ChatSession) -> String? {
        guard manager.parentID(ofChild: chat.id) != nil else { return nil }
        return childTabStore.record(chat.id)?.parentTitle
    }

    /// Moves a queued message into a child tab; this tab stays selected.
    private func forkQueued(_ itemID: UUID) {
        let parentID = session.id
        Task {
            do { try await manager.childTabs.fork(parentID: parentID, itemID: itemID) }
            catch { childTabError = error.localizedDescription }
        }
    }

    /// A child card's button. Open selects an open child or reopens it from history.
    private func runChildAction(_ action: String, _ child: ChildTab) {
        if action == "open", manager.sessions.contains(where: { $0.id == child.id }) {
            manager.select(child.id)
            return
        }
        if action == "discard" {
            discardingChild = child
            return
        }
        if action == "requeue" {
            requeueingChild = child
            return
        }
        performChildAction(action, child)
    }

    private func performChildAction(_ action: String, _ child: ChildTab) {
        do { try manager.childTabs.perform(action, childID: child.id) }
        catch { childTabError = error.localizedDescription }
    }

    private var mainTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // VStack, not LazyVStack: lazy layout sometimes renders
                // nothing after a tab switch until scrolled. The transcript
                // is capped at ~30 messages, so laziness buys nothing.
                VStack(alignment: .leading, spacing: 12) {
                    let repeatedErrorID = session.repeatedErrorMessageID
                    let continuableIDs = session.continuableMessageIDs
                    if let parentID = manager.parentID(ofChild: session.id), let record = childTabStore.record(session.id) {
                        ChildTabBanner(record: record) { manager.select(parentID) }
                    }
                    ForEach(transcriptMessages) { message in
                        MessageRow(message: message, localOnly: session.isLocalPrivate,
                                   appActions: settings.copilotMCPApps ? mcpAppActions : nil,
                                   openSubagents: { background in
                                       openProgressPane(background ? .background : .steps)
                                   },
                                   errorRecovery: message.id == repeatedErrorID ? errorRecovery : nil,
                                   continueFailed: continuableIDs.contains(message.id) ? {
                                       continueError = session.continueFailedRun(
                                           from: message.id, includesAmbientContext: true)
                                   } : nil,
                                   childAction: { action, child in runChildAction(action, child) },
                                   childTabOpen: message.childResult.map { child in
                                       manager.sessions.contains { $0.id == child.id }
                                   } ?? false)
                            .id(message.id)
                    }
                    RemoteInputView(session: session, openSecureInput: { showingInputRequests = true })
                    if let status = session.statusText {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(status).font(.callout).foregroundStyle(.secondary)
                        }
                        .id("status")
                    }
                    if let continueError {
                        Text(continueError).font(.caption).foregroundStyle(.secondary)
                    }
                    // The failed message offers Continue itself; this covers a run whose message is gone.
                    if session.canResume, !session.isStreaming, continuableIDs.isEmpty {
                        Button {
                            session.resumeInterrupted()
                        } label: {
                            Label("Resume from where it left off",
                                  systemImage: "arrow.uturn.forward")
                                .font(.callout)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .id("resume-button")
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("conversation-bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                let pinned = pinnedSubagents
                if !pinned.isEmpty {
                    SubagentStrip(activities: pinned, open: {
                        openProgressPane(pinned.contains { $0.subagent?.background == true }
                                         ? .background : .steps)
                    })
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider().opacity(0.5) }
                }
            }
            .frame(maxHeight: lowerSectionMaxHeight)
            // Fresh scroll-view identity per session: prevents stale layout
            // state from the previous tab leaving a blank transcript.
            .id(session.id)
            .onAppear {
                scrollConversationToBottom(proxy)
            }
            .onChange(of: session.messages) {
                continueError = nil
                scrollConversationToBottom(proxy)
            }
            .onChange(of: session.statusText) {
                scrollConversationToBottom(proxy)
            }
            .onChange(of: session.canResume) {
                scrollConversationToBottom(proxy)
            }
            // Extra composer lines shrink the transcript from the top; keep
            // the end of the latest reply in view.
            .onChange(of: lowerSectionMaxHeight) {
                scrollConversationToBottom(proxy)
            }
        }
    }

    private var mcpAppActions: MCPAppActions {
        let session = session
        return MCPAppActions(
            serverRequest: { app, method, params, completion in
                session.mcpAppRequest(app, method: method, params: params, completion: completion)
            },
            sendMessage: { app, text in session.submitMCPAppMessage(text, from: app) },
            updateContext: { app, text in session.setMCPAppContext(app, text: text) }
        )
    }

    private func scrollConversationToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    // ── Council seat panes: fixed column, max 2 visible, switchable ──

    private var councilSeatLabels: [String] {
        settings.councilMembers.map(\.label)
    }

    private var councilSeatColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "person.3")
                    .font(.caption2)
                Text("Council")
                    .font(.caption2).bold()
                Spacer()
                Button(action: { withAnimation(.easeOut(duration: 0.15)) { showCouncilPanes = false } }) {
                    Image(systemName: "chevron.right.2")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Hide the council seats")
            }
            .foregroundStyle(.secondary)
            ScrollView { // every seat, scrollable
                VStack(spacing: 6) {
                    ForEach(councilSeatLabels, id: \.self) { label in
                        let message = latestSeatMessage(label)
                        SeatPane(label: label,
                                 message: message,
                                 streaming: session.isStreaming
                                     && message.map { !session.councilFinished.contains($0.id) } ?? false)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }

    /// Slim strip shown while the seat column is hidden — click to reopen.
    private var councilReopenStrip: some View {
        Button(action: { withAnimation(.easeOut(duration: 0.15)) { showCouncilPanes = true } }) {
            VStack(spacing: 6) {
                Image(systemName: "chevron.left.2")
                    .font(.caption2)
                Image(systemName: "person.3")
                    .font(.caption2)
                if session.isStreaming {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Show the council seats")
    }

    private func latestSeatMessage(_ label: String) -> ChatMessage? {
        session.messages.last(where: { $0.author == label })
    }
}

/// A draggable divider between the main column and a side pane. The pane
/// sits to the RIGHT, so dragging left grows it. The binding it writes is
/// wrapped by paneBinding, which trades the width against the transcript
/// (metrics.contentWidth) — the outer window size never changes; the
/// divider only redistributes space between the two inner columns.
///
/// AppKit-backed on purpose: the panel is movable-by-window-background,
/// and on a borderless NSPanel that window drag wins over a SwiftUI
/// DragGesture — grabbing the divider moved the whole window instead of
/// resizing the split. A real NSView that returns false from
/// mouseDownCanMoveWindow keeps the mouse events for itself.
private struct PaneDivider: NSViewRepresentable {
    @Binding var width: Double
    let range: ClosedRange<Double>

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        configure(view)
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        configure(view)
    }

    private func configure(_ view: HandleView) {
        view.currentWidth = { width }
        view.onDrag = { delta, startWidth in
            // Pane sits to the RIGHT: dragging left (negative delta) grows it.
            let proposed = startWidth - delta
            width = min(max(proposed, range.lowerBound), range.upperBound)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: HandleView, context: Context) -> CGSize? {
        // 7pt grab zone (1pt line + 3pt each side) — MUST stay 7 to match
        // the +7 accounting in sidebarExtra/councilPaneWidth.
        CGSize(width: 7, height: min(proposal.height ?? 10, 10_000))
    }

    final class HandleView: NSView {
        var currentWidth: () -> Double = { 0 }
        var onDrag: (Double, Double) -> Void = { _, _ in }
        private var dragStartWidth = 0.0
        private var dragStartX: CGFloat = 0

        /// The whole point: keep AppKit from treating a divider drag as
        /// "move the window by its background".
        override var mouseDownCanMoveWindow: Bool { false }

        /// Start the drag on the first click even if the panel wasn't key.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            dragStartWidth = currentWidth()
            // Screen coordinates: stable even as the layout shifts the
            // divider mid-drag (view-local coords would feed back).
            dragStartX = NSEvent.mouseLocation.x
        }

        override func mouseDragged(with event: NSEvent) {
            NSCursor.resizeLeftRight.set() // hold the cursor through the drag
            onDrag(Double(NSEvent.mouseLocation.x - dragStartX), dragStartWidth)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.withAlphaComponent(0.5).setFill()
            NSRect(x: bounds.midX - 0.5, y: 0,
                   width: 1, height: bounds.height).fill()
        }
    }
}

/// One advisor's live answer: fixed-size pane, bottom-pinned scroll so
/// streaming output follows like a terminal.
private struct SeatPane: View {
    let label: String
    let message: ChatMessage?
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle")
                    .font(.caption2)
                Text(label)
                    .font(.caption2).bold()
                    .lineLimit(1)
                Spacer()
                if streaming { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(.secondary)
            Divider().opacity(0.3)
            if let message, !message.text.isEmpty || !message.thinking.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if !message.thinking.isEmpty {
                            Text(message.thinking)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(message.text.isEmpty ? nil : 3)
                        }
                        if !message.text.isEmpty {
                            MarkdownContent(text: message.text)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
            } else {
                Text(streaming ? "Deliberating…" : "No answer yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    var onAskAgain: (String) -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                MarkdownContent(text: entry.assistant)
                    .textSelection(.enabled)
                Button("Ask again") { onAskAgain(entry.user) }
                    .font(.caption)
            }
            .padding(.top, 4)
            .padding(.leading, 14)
        } label: {
            HStack(spacing: 6) {
                Text("\(entry.day) \(entry.time)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Text(entry.user)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text(entry.backend)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Instant hover caption: shows `text` in the toolbar's hint slot while
/// the mouse is over the view (complements the delayed .help tooltips).
private extension View {
    func hoverHint(_ text: String, _ hint: Binding<String?>) -> some View {
        onHover { hovering in
            if hovering {
                hint.wrappedValue = text
            } else if hint.wrappedValue == text {
                hint.wrappedValue = nil
            }
        }
    }
}

private struct ContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The composer's frame in the panel's coordinate space — the floating
/// suggestions dropdown pins its top edge to this frame's bottom, so it
/// can only ever appear BELOW the typing area, expanding downward.
private struct InputBarFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct ComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Natural height of the suggestion rows inside their ScrollView, so the
/// dropdown sizes to content below the scroll cap (see suggestionList).
private struct SuggestionListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MessageRow: View {
    struct ErrorRecovery {
        let changeModelTitle: String
        let isDisabled: Bool
        let startFresh: () -> Void
        let changeModel: () -> Void
    }

    let message: ChatMessage
    var localOnly = false
    /// Nil while MCP App views are turned off: saved views stay hidden and inert.
    var appActions: MCPAppActions?
    /// Shows the Progress pane's subagent monitor.
    var openSubagents: ((Bool) -> Void)?
    /// Offered on an error that repeated: the tab is likely stuck on its earlier context.
    var errorRecovery: ErrorRecovery?
    /// A failed run's last message: picks the task up from where it stopped.
    var continueFailed: (() -> Void)?
    /// A child tab card's buttons (`ChildTab.actions`).
    var childAction: ((String, ChildTab) -> Void)?
    var childTabOpen = false

    private var visibleApps: [MCPAppPayload] { appActions == nil ? [] : message.apps }
    /// Finished subagents grouped by the reply block they follow; running ones are pinned below the transcript.
    private var placedSubagents: [(block: Int, agents: [ToolActivity])] {
        guard openSubagents != nil else { return [] }
        let finished = message.activities.flatMap(\.subagentActivities).filter { $0.subagent?.isActive == false }
        return Dictionary(grouping: finished) { message.subagentTextBlock($0.id) }
            .sorted { $0.key < $1.key }
            .map { (block: $0.key, agents: $0.value) }
    }

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .leading, spacing: 3) {
                PromptTextView(text: message.text)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let usage = message.promptUsage, !usage.isEmpty {
                    PromptUsageLine(usage: usage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .assistant:
            // Tool steps render in the progress sidebar, not inline; MCP App
            // views (e.g. galleries) are part of the reply.
            let placed = placedSubagents
            if message.text.isEmpty && message.thinking.isEmpty && message.author == nil
                && visibleApps.isEmpty && placed.isEmpty {
                EmptyView()
            } else {
                let parts = ReplyBlocks.split(message.text, before: placed.map(\.block))
                VStack(alignment: .leading, spacing: 6) {
                    if let author = message.author {
                        Label(author, systemImage: author.hasPrefix("Verdict")
                              ? "checkmark.seal" : "person.crop.circle")
                            .font(.caption2)
                            .foregroundStyle(author.hasPrefix("Verdict")
                                             ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(.tertiary))
                    }
                    if !message.thinking.isEmpty {
                        ThinkingDisclosure(text: message.thinking)
                    }
                    ForEach(visibleApps) { app in
                        MCPAppInlineView(app: app, actions: appActions)
                    }
                    // Each finished subagent's strip sits where the reply had got to when it ended.
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        if index > 0, let openSubagents {
                            let agents = placed[index - 1].agents
                            SubagentStrip(activities: agents, open: {
                                openSubagents(agents.contains { $0.subagent?.background == true })
                            })
                        }
                        if !part.isEmpty {
                            if localOnly {
                                Text(verbatim: part).textSelection(.enabled)
                            } else {
                                MarkdownContent(text: part)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .error:
            VStack(alignment: .leading, spacing: 6) {
                Label(message.text, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                if let continueFailed {
                    Button("Continue", systemImage: "arrow.uturn.forward", action: continueFailed)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Pick this task up from where it stopped")
                }
                if let errorRecovery {
                    Text("This error happened twice in a row. Start fresh to drop the earlier context, or try another model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Start Fresh", systemImage: "arrow.counterclockwise", action: errorRecovery.startFresh)
                        Button(errorRecovery.changeModelTitle, systemImage: "slider.horizontal.3",
                               action: errorRecovery.changeModel)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(errorRecovery.isDisabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .freshStart:
            HStack(spacing: 8) {
                VStack { Divider() }
                Label(message.text, systemImage: "arrow.counterclockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .layoutPriority(1)
                VStack { Divider() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        case .handoff where message.childResult != nil && childAction != nil:
            if let child = message.childResult, let childAction {
                ChildTabCard(record: child, isOpen: childTabOpen, action: childAction)
            }
        case .handoff:
            VStack(alignment: .leading, spacing: 3) {
                Label(message.handoffResult?.headline ?? "Handoff",
                      systemImage: message.handoffResult?.isAsk == true ? "questionmark.bubble" : "rectangle.stack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let ask = message.handoffResult, ask.isAsk, !ask.summary.isEmpty {
                    Text(verbatim: "“\(ask.summary)”").font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let detail = message.handoffResult?.detail, !detail.isEmpty {
                    Text(verbatim: detail).font(.callout).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

/// Streamed extended-thinking text, collapsed by default so long silent
/// stretches are legible without crowding the answer.
private struct ThinkingDisclosure: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.leading, 14)
        } label: {
            Label("Reasoning", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ToolProgressView: View {
    let activities: [ToolActivity]

    private struct ActivityGroup: Identifiable {
        let id: String
        let toolName: String
        var items: [ToolActivity]

        var state: ToolActivityState {
            if items.contains(where: { $0.state == .running }) { return .running }
            if items.contains(where: { $0.state == .failed }) { return .failed }
            if items.contains(where: { $0.state == .cancelled }) { return .cancelled }
            return .succeeded
        }
    }

    /// Consecutive activities of the same tool collapse into one group.
    private var groups: [ActivityGroup] {
        var result: [ActivityGroup] = []
        for activity in activities {
            if var last = result.last, last.toolName == activity.toolName {
                last.items.append(activity)
                result[result.count - 1] = last
            } else {
                result.append(ActivityGroup(id: activity.id,
                                            toolName: activity.toolName,
                                            items: [activity]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(groups) { group in
                if group.items.count == 1 {
                    ToolActivityRow(activity: group.items[0])
                } else {
                    ToolActivityGroupRow(label: friendlyToolLabel(group.toolName),
                                         state: group.state,
                                         items: group.items)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Human-readable umbrella name for a tool's activity group.
func friendlyToolLabel(_ name: String) -> String {
    switch name.lowercased() {
    case "web_fetch", "webfetch", "fetch": return "Fetching from web"
    case "web_search", "websearch": return "Searching the web"
    case "bash", "shell": return "Running commands"
    case "read", "view": return "Reading files"
    case "edit", "write", "str_replace", "notebookedit": return "Editing files"
    case "grep", "glob": return "Searching files"
    case "task": return "Running subtasks"
    default:
        return name.isEmpty ? "Working"
            : name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct ToolActivityGroupRow: View {
    let label: String
    let state: ToolActivityState
    let items: [ToolActivity]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items) { activity in
                    ToolActivityRow(activity: activity)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 20)
        } label: {
            HStack(spacing: 7) {
                groupStatusIcon
                    .frame(width: 14, height: 14)
                Text("\(label) · \(items.count) steps")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var groupStatusIcon: some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

struct ToolActivityRow: View {
    let activity: ToolActivity
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ToolActivityDetails(activity: activity)
                .padding(.top, 6)
                .padding(.leading, 20)
        } label: {
            HStack(spacing: 7) {
                statusIcon
                    .frame(width: 14, height: 14)
                Text(activity.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(activity.toolName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .disclosureGroupStyle(.automatic)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch activity.state {
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ToolActivityDetails: View {
    let activity: ToolActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !activity.children.isEmpty {
                Text("Subagent · \(activity.children.count) steps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(activity.children) { child in
                        ToolActivityRow(activity: child)
                    }
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor.opacity(0.3))
                        .frame(width: 2)
                }
            }
            if !activity.fileChanges.isEmpty {
                Text(activity.fileChanges.count == 1 ? "File edited" : "Files edited")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(activity.fileChanges) { change in
                    FileChangeRow(change: change)
                }
            }
            if let input = activity.input {
                detailSection("Input", text: input)
            }
            if let output = activity.output {
                detailSection("Output", text: output)
            }
            if activity.fileChanges.isEmpty,
               activity.input == nil,
               activity.output == nil {
                Text("No additional details were reported.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
            .padding(7)
            .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct FileChangeRow: View {
    let change: ToolFileChange
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            DiffView(diff: change.diff)
                .padding(.top, 5)
        } label: {
            HStack(spacing: 6) {
                Label(change.path, systemImage: "doc.text")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                RevertButton(path: change.path)
            }
                .help(change.path)
        }
    }
}

/// Discard uncommitted changes to one file via git (repo resolved from
/// the file's own path, so no session context needed).
private struct RevertButton: View {
    let path: String
    @State private var state: RevertState = .idle
    private enum RevertState { case idle, confirming, done, failed }

    var body: some View {
        switch state {
        case .idle:
            Button(action: { state = .confirming }) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Revert this file (git checkout — discards these changes)")
        case .confirming:
            Button("Revert?") { revert() }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .help("Reverted")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .help("Revert failed — not a git file, or already committed")
        }
    }

    private func revert() {
        let dir = (path as NSString).deletingLastPathComponent
        if let result = try? ProcessRunner.run("/usr/bin/git", ["-C", dir, "checkout", "--", path]) {
            state = result.status == 0 ? .done : .failed
            Log.write("revert \(path): exit \(result.status)")
        } else {
            state = .failed
        }
    }
}

private struct DiffView: View {
    let diff: String

    var body: some View {
        let lines = diff.components(separatedBy: "\n")
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(200).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(foreground(for: line))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(for: line))
                }
                if lines.count > 200 {
                    Text("… \(lines.count - 200) more lines")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(5)
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxHeight: 180)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }

    private func foreground(for line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red }
        return .secondary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") {
            return .green.opacity(0.08)
        }
        if line.hasPrefix("-"), !line.hasPrefix("---") {
            return .red.opacity(0.08)
        }
        return .clear
    }
}

/// The pinned encrypted-LAN port. Commits on Return or focus loss, not per keystroke, because
/// each change restarts the listener and drops connected clients.
private struct RemoteLANPortField: View {
    @ObservedObject var settings: AppSettings
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Auto", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            // Follow changes made elsewhere (e.g. Import Settings) unless the user is typing.
            .onChange(of: settings.remoteLANPort) { _, port in
                if !focused { text = Self.display(port) }
            }
            .onAppear { text = Self.display(settings.remoteLANPort) }
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard text != Self.display(settings.remoteLANPort) else { return }
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            settings.remoteLANPort = 0
        } else if let port = Int(value), (1...65535).contains(port), port != settings.remoteControlPort {
            settings.remoteLANPort = port
        }
        text = Self.display(settings.remoteLANPort)
    }

    private static func display(_ port: Int) -> String { port == 0 ? "" : String(port) }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    var busySessions = 0
    var onUpdate: (() -> Void)?

    /// Panel (this window) or Cantrip Gateway's Home window, both on this Mac's sessions.
    private var interfacePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Interface").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $settings.interfaceMode) {
                Text("Panel (⌥Space)").tag(InterfaceMode.panel)
                Text("Home window, like Cantrip Gateway").tag(InterfaceMode.window)
                    .disabled(!HomeWindow.isAvailable)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(HomeWindow.unavailableReason
                 ?? "The Home window has a sidebar of tabs, Home, tasks, artifacts and a terminal. ⌥Space and the menu bar icon open whichever you pick; the other stays available from the menu.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            settingsContent
        }
        .frame(maxHeight: 500)
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            interfacePicker
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Backend").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $settings.backend) {
                    ForEach(BackendKind.allCases) { kind in
                        Text(settings.backendLabel(kind)).tag(kind)
                    }
                }
                .labelsHidden()
            }
            Divider().opacity(0.3)
            switch settings.backend {
            case .claudeCode:
                labeledField("claude path (blank = auto)", text: $settings.claudePath, prompt: "/usr/local/bin/claude")
                claudeModelPicker
                VStack(alignment: .leading, spacing: 2) {
                    Text("Effort").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $settings.claudeEffort) {
                        ForEach(AppSettings.claudeEffortLevels, id: \.value) { level in
                            Text(level.label).tag(level.value)
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permissions").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $settings.claudePermissionMode) {
                        ForEach(AppSettings.claudePermissionModes, id: \.value) { mode in
                            Text(mode.label).tag(mode.value)
                        }
                    }
                    .labelsHidden()
                }
                labeledField("Working directory", text: $settings.claudeWorkdir, prompt: NSHomeDirectory())
            case .copilot:
                labeledField("copilot path (blank = auto)", text: $settings.copilotPath, prompt: "/opt/homebrew/bin/copilot")
                copilotModelPicker
                VStack(alignment: .leading, spacing: 2) {
                    Text("Effort").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $settings.copilotEffort) {
                        ForEach(copilotEffortOptions, id: \.value) { level in
                            Text(level.label).tag(level.value)
                                .disabled(!level.value.isEmpty && selectedCopilotModelInfo?.reasoningEfforts?.contains(level.value) == false)
                        }
                    }
                    .labelsHidden()
                    if !settings.copilotEffort.isEmpty,
                       selectedCopilotModelInfo?.reasoningEfforts?.contains(settings.copilotEffort) == false {
                        Text("The saved effort is not supported by this model. Choose Default or a supported level.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Context window").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $settings.copilotContextTier) {
                        Text("Default (\(settings.copilotFileContextTier ?? "standard"))").tag("")
                        ForEach(copilotContextTierOptions, id: \.self) { tier in
                            Text(contextTierLabel(tier)).tag(tier)
                                .disabled(selectedCopilotModelInfo?.contextTiers?.contains(tier) == false)
                        }
                    }
                    .labelsHidden()
                    if let tier = settings.effectiveCopilotContextTier,
                       selectedCopilotModelInfo?.contextTiers?.contains(tier) == false {
                        Text("The saved context tier is not supported by this model. Choose Standard.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                labeledField("Working directory", text: $settings.claudeWorkdir, prompt: NSHomeDirectory())
                Toggle("Allow all tools (--allow-all-tools) — lets Copilot run commands unprompted", isOn: $settings.copilotAllowTools)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                Toggle("Allow subagents for broad searches, noisy builds/tests and parallel work — off removes them", isOn: $settings.copilotAllowSubagents)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                Toggle("Show interactive MCP App views (e.g. Mobbin galleries) inline in chat", isOn: $settings.copilotMCPApps)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free an idle tab's memory after").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $settings.copilotIdleReleaseMinutes) {
                        ForEach(AppSettings.copilotIdleReleaseChoices, id: \.minutes) { choice in
                            Text(choice.label).tag(choice.minutes)
                        }
                    }
                    .labelsHidden()
                    Text("Each tab's Copilot runtime holds 0.5–3 GB. A freed tab picks up its conversation on your next message, about 3 seconds slower. Tabs with running commands or background agents are kept.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            case .copilotRemote:
                labeledField("ACP server (host:port)", text: $settings.acpAddress, prompt: "127.0.0.1:3000")
                labeledField("Working directory", text: $settings.claudeWorkdir, prompt: NSHomeDirectory())
                Text("Connects to a Copilot CLI running as an ACP server: `copilot --acp --port 3000`. It binds loopback only, so reach a remote machine through a tunnel — `ssh -N -L 3000:127.0.0.1:3000 yourbox` — then point this at 127.0.0.1:3000. Model & tools are whatever the server was started with; \"Act on my behalf\" approves its tool requests, otherwise they're declined.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .codex:
                labeledField("codex path (blank = auto)", text: $settings.codexPath, prompt: "/opt/homebrew/bin/codex")
                labeledField("Model (blank = default, e.g. gpt-5-codex)", text: $settings.codexModel, prompt: "")
                Text("Requires the OpenAI Codex CLI: npm install -g @openai/codex, then run `codex` once to sign in. \"Act on my behalf\" maps to --dangerously-bypass-approvals-and-sandbox.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .antigravity:
                labeledField("agy path (blank = auto)", text: $settings.agyPath, prompt: "~/.local/bin/agy")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Picker("", selection: $settings.agyModel) {
                            Text("Default (Auto: Argon / Gemini 3.8 Flash)").tag("")
                            ForEach(settings.agyModelOptions, id: \.self) { model in
                                Text(settings.agyModelLabel(model)).tag(model)
                            }
                        }
                        .labelsHidden()
                        Button(action: { settings.refreshAntigravityModels() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(settings.agyRefreshInFlight)
                        .accessibilityLabel("Refresh Antigravity models")
                        .help("Refresh the model list from `agy models` (Gemini, Claude Opus/Sonnet and more). No chat or model request is made.")
                    }
                    if settings.agyRefreshInFlight {
                        Text("Refreshing Antigravity models…").font(.caption).foregroundStyle(.secondary)
                    } else if let error = settings.agyModelRefreshError {
                        Text("\(error) Previously cached models are unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let date = settings.agyCatalogUpdatedAt {
                        Text("Models refreshed \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onAppear { settings.refreshAntigravityModelsIfNeeded() }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Effort").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $settings.agyEffort) {
                        Text("Default").tag("")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permissions").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $settings.agyPermissionMode) {
                        Text("Ask before edits and commands").tag("default")
                        Text("Sandbox (--sandbox)").tag("sandbox")
                        Text("Allow everything (--dangerously-skip-permissions)").tag("bypassPermissions")
                    }
                    .labelsHidden()
                }
                labeledField("Working directory", text: $settings.claudeWorkdir, prompt: NSHomeDirectory())
                Text("Requires the Google Antigravity CLI (`agy`). \"Act on my behalf\" maps to --dangerously-skip-permissions. Otherwise Cantrip checks each tool call through a hook it adds to ~/.gemini/config/hooks.json, which does nothing for agy runs Cantrip didn't start.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .localModel:
                labeledField("Base URL", text: $settings.localBaseURL, prompt: "http://hermes.local:8000/v1")
                labeledField("Model", text: $settings.localModel, prompt: "hermes")
                labeledField("API key (optional)", text: $settings.localAPIKey, prompt: "")
                labeledField("System prompt", text: $settings.localSystemPrompt, prompt: "")
            }
            Divider().opacity(0.3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage limit fallback").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $settings.limitFallbackBackend) {
                    Text("Off — stop and show the error").tag("")
                    ForEach(BackendKind.allCases) { kind in
                        Text(settings.backendLabel(kind)).tag(kind.rawValue)
                    }
                }
                .labelsHidden()
                Text(settings.limitFallbackBackend == settings.backend.rawValue
                     ? "Choose a backend other than the one above; a backend can't fall back on itself."
                     : "When a backend says its plan's usage limit is reached, Cantrip continues the task on this backend and sends new messages from every tab there until the limit resets (an hour when the backend doesn't say). Council seats and Private Local tabs don't switch.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.3)
            Toggle("Act on my behalf — all backends (run commands, edit files, send messages without asking)", isOn: $settings.allowActions)
                .font(.caption)
                .toggleStyle(.checkbox)
            Text("Cantrip Home and its scheduled tasks follow this (and Claude's Permissions) on Copilot and Claude Code. Cantrip's blocked commands are always refused.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Start independent queued messages in child tabs automatically (Auto delivery only)", isOn: $settings.childTabsAutoFork)
                .font(.caption)
                .toggleStyle(.checkbox)
            Text("Each runs in its own tab and git branch and merges back when done. Its card's Run in This Tab Instead puts it back in the queue.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Memory vault — remember procedures that worked (markdown notes, Obsidian-compatible)", isOn: $settings.memoryEnabled)
                .font(.caption)
                .toggleStyle(.checkbox)
            if settings.memoryEnabled {
                labeledField("Memory vault folder", text: $settings.memoryPath, prompt: "\(NSHomeDirectory())/Cantrip Memory")
            }
            if AntigravityBackend.isInstalled(customPath: settings.agyPath) {
                // Opt-ins: both send content to Google through Antigravity; off by default.
                Toggle("Use Antigravity's Gemini Flash for routing, queue plans and Done-when checks in every tab (sends those messages to Google)",
                       isOn: $settings.agyAuxiliaryRouting)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                if settings.memoryEnabled {
                    Toggle("Consolidate memory with Antigravity's Gemini Flash (sends your memory notes to Google)",
                           isOn: $settings.agyMemoryConsolidation)
                        .font(.caption)
                        .toggleStyle(.checkbox)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Panel opacity — \(Int(settings.panelOpacity * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $settings.panelOpacity, in: 0.5...1.0, step: 0.05)
            }
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0 }))
                .font(.caption)
                .toggleStyle(.checkbox)
            if let error = settings.launchAtLoginError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Divider().opacity(0.3)
            Toggle("Remote control daemon", isOn: $settings.remoteControlEnabled)
                .font(.caption)
                .toggleStyle(.checkbox)
            if settings.remoteControlEnabled {
                Toggle("Cantrip Home — hidden always-on assistant for Chat, Tasks, and Artifacts",
                       isOn: $settings.cantripHomeEnabled)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                if settings.cantripHomeEnabled {
                    Text("Cantrip must remain running. Scheduled Home tasks use this Mac's selected backend and the Home session's model settings.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Stepper(value: $settings.cantripHomeParallelRuns,
                            in: 1...CantripHomeBackgroundRunner.maximumParallelLimit) {
                        Text("Background jobs at once: \(settings.cantripHomeParallelRuns)")
                            .font(.caption)
                    }
                    .help("Each scheduled task or incident runs in its own hidden session. Lower this if the Mac is short on memory.")
                    .onChange(of: settings.cantripHomeParallelRuns) { _, _ in
                        CantripHomeStore.shared.checkNow()
                    }
                }
                MacAccessView()
                HStack(spacing: 8) {
                    Text("Port")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("8765", text: Binding(
                        get: { String(settings.remoteControlPort) },
                        set: {
                            if let port = Int($0), (1...65535).contains(port) {
                                settings.remoteControlPort = port
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    Button("Copy pairing token") {
                        if let token = settings.ensureRemoteControlToken() {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                        }
                    }
                    .font(.caption)
                    Button("Regenerate") {
                        settings.regenerateRemoteControlToken()
                    }
                    .font(.caption)
                }
                Text("Tailscale Serve can proxy 127.0.0.1:\(settings.remoteControlPort). Cantrip Agent also discovers an end-to-end encrypted connection automatically on the same local network. Regenerating the token disconnects paired clients.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    Text("Direct port")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RemoteLANPortField(settings: settings)
                    .help("Fixed port for the encrypted local-network connection (for example 8766), so Cantrip Agent can save this Mac's direct address. Leave empty for an automatic port.")
                }
                Text(RemoteLANStatusText.describe(settings.remoteLANStatus, pinnedPort: settings.remoteLANPort,
                                                  addresses: RemoteLANAddresses.ipv4()))
                    .font(.caption2)
                    .foregroundStyle(settings.remoteLANStatus?.fellBack == true ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
            }
            if let error = settings.remoteControlError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            Toggle("Search my documents' contents as context (Spotlight index)", isOn: $settings.fileRAGEnabled)
                .font(.caption)
                .toggleStyle(.checkbox)
            Toggle("Share my calendar as context (next 48h, via Calendar.app)", isOn: $settings.shareCalendar)
                .font(.caption)
                .toggleStyle(.checkbox)
                .onChange(of: settings.shareCalendar) { _, enabled in
                    if enabled { CalendarProvider.shared.refresh() }
                }
            HStack(spacing: 6) {
                Toggle("Share my location as context (enables \"what's the weather\"-style queries)", isOn: $settings.shareLocation)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .onChange(of: settings.shareLocation) { _, enabled in
                        if enabled { LocationProvider.shared.refresh() }
                    }
                if settings.shareLocation, let loc = LocationProvider.shared.contextLine {
                    Text("· \(loc)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Divider().opacity(0.3)
            StorageUpkeepView()
            Divider().opacity(0.3)
            CantripVersionView(busySessions: busySessions, onUpdate: onUpdate)
        }
        .padding(16)
    }

    private var claudeModelPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Model").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $settings.claudeModel) {
                Text("Default (account setting)").tag("")
                ForEach(claudeModelOptions, id: \.self) { model in
                    Text(model == "sonnet[1m]" ? "sonnet[1m] · 1M context" : model)
                        .tag(model)
                }
            }
            .labelsHidden()
        }
    }

    private var claudeModelOptions: [String] {
        var options = AppSettings.claudeModelAliases
        let current = settings.claudeModel.trimmingCharacters(in: .whitespaces)
        if !current.isEmpty && !options.contains(current) { options.append(current) }
        return options
    }

    private var selectedCopilotModelInfo: CopilotModelInfo? {
        settings.effectiveCopilotModel.flatMap { settings.copilotModelInfo($0) }
    }

    private func contextHint(for model: String) -> String? {
        settings.copilotModelInfo(model)?.contextLabel.map { "\($0) max" }
    }

    private var copilotEffortOptions: [(value: String, label: String)] {
        let supported = selectedCopilotModelInfo?.reasoningEfforts
        let values = CopilotModelInfo.choices(
            supported: supported, fallback: settings.copilotEffortChoices, selected: settings.copilotEffort)
        let defaultLabel = supported == [] ? "Default (effort not supported)" : "Default"
        return [("", defaultLabel)] + values.map { value in
            (value,
             (AppSettings.copilotEffortLevels.first { $0.value == value }?.label ?? value.capitalized)
                + (supported?.contains(value) == false ? " (not supported)" : ""))
        }
    }

    private var copilotContextTierOptions: [String] {
        CopilotModelInfo.choices(
            supported: selectedCopilotModelInfo?.contextTiers,
            fallback: settings.copilotContextTierChoices, selected: settings.copilotContextTier)
    }

    private func contextTierLabel(_ tier: String) -> String {
        let name: String
        switch tier {
        case "default": name = "Standard"
        case "long_context": name = "Long"
        default: name = tier.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if selectedCopilotModelInfo?.contextTiers?.contains(tier) == false {
            return "\(name) (not supported)"
        }
        guard let tokens = selectedCopilotModelInfo?.promptTokens(for: tier) else { return name }
        return "\(name) · \(CopilotModelInfo.tokenLabel(tokens)) input"
    }

    private func copilotModelLabel(_ model: String) -> String {
        if let hint = contextHint(for: model) { return "\(model) · \(hint)" }
        return model
    }

    private var copilotModelOptions: [String] {
        var options = settings.copilotAvailableModels
        if !options.contains("auto") { options.insert("auto", at: 0) }
        let current = settings.copilotModel.trimmingCharacters(in: .whitespaces)
        if !current.isEmpty && !options.contains(current) { options.append(current) }
        return options
    }

    private var copilotModelPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Model").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Picker("", selection: $settings.copilotModel) {
                    Text("Default (\(settings.copilotFileDefaultModel ?? "auto"))").tag("")
                    ForEach(copilotModelOptions, id: \.self) { model in
                        Text(copilotModelLabel(model)).tag(model)
                    }
                }
                .labelsHidden()
                Button(action: { settings.refreshCopilotModels() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(settings.copilotRefreshInFlight)
                .accessibilityLabel("Refresh Copilot models")
                .help("Refresh models, supported efforts, and context limits from the signed-in Copilot CLI. No chat or model request is made.")
            }
            if settings.copilotRefreshInFlight {
                Text("Refreshing Copilot models…").font(.caption).foregroundStyle(.secondary)
            } else if let error = settings.copilotModelRefreshError {
                Text("\(error) Previously cached models are unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let date = settings.copilotCatalogUpdatedAt {
                Text("Catalog refreshed \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            settings.refreshCopilotModelsIfNeeded()
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}

/// The panel's child-tab alerts: confirm Discard and Run in This Tab Instead, and show errors.
private struct ChildTabAlerts: ViewModifier {
    @Binding var discarding: ChildTab?
    @Binding var requeueing: ChildTab?
    @Binding var error: String?
    let perform: (String, ChildTab) -> Void

    func body(content: Content) -> some View {
        content
            .alert(discarding.map { "Discard \u{201C}\($0.title)\u{201D}?" } ?? "Discard Child Tab?", isPresented: Binding(
                get: { discarding != nil },
                set: { if !$0 { discarding = nil } }
            ), presenting: discarding) { child in
                Button("Discard", role: .destructive) { perform("discard", child) }
                Button("Cancel", role: .cancel) {}
            } message: { child in
                Text(child.branch.map { "Its work on \($0) is deleted. The conversation stays in history." }
                     ?? "The conversation stays in history.")
            }
            .alert(requeueing.map { "Run \u{201C}\($0.title)\u{201D} in This Tab Instead?" } ?? "Run in This Tab Instead?", isPresented: Binding(
                get: { requeueing != nil },
                set: { if !$0 { requeueing = nil } }
            ), presenting: requeueing) { child in
                Button("Run Here Instead") { perform("requeue", child) }
                Button("Cancel", role: .cancel) {}
            } message: { child in
                Text("The child tab stops\(child.branch.map { " and its work on \($0) is deleted" } ?? ""). The request goes back to the front of this tab's queue.")
            }
            .alert("Child Tab", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }
}
