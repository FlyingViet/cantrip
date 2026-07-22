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
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool
    var onDismiss: () -> Void
    var onSizeChange: (CGSize) -> Void = { _ in }
    var onKeepVisibleChange: (Bool) -> Void = { _ in }
    @State private var pinned = false
    @State private var showSteps = false
    @StateObject private var fileSearch = FileSearch.shared
    @ObservedObject private var usage = UsageTracker.shared
    @ObservedObject private var updater = UpdateChecker.shared
    @ObservedObject private var metrics = PanelMetrics.shared
    @State private var showUsage = false
    @State private var showHistory = false
    @State private var historySearch = ""
    @State private var historyEntries: [HistoryEntry] = []
    @State private var archivedSessions: [SessionManager.ArchivedSession] = []
    /// Instant caption for whichever toolbar icon is hovered.
    @State private var toolbarHint: String?
    @State private var showTerminal = false
    @State private var terminalCommand = ""
    @State private var terminalHistoryIndex: Int?
    @State private var terminalHistoryDraft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            mainColumn
                .frame(width: metrics.contentWidth)
            if showSettings {
                Divider().opacity(0.3)
                settingsSidebar
            }
            if showSteps {
                Divider().opacity(0.3)
                stepsSidebar
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
        .onPreferenceChange(ContentSizeKey.self) { size in
            onSizeChange(size)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: pinned) {
            onKeepVisibleChange(pinned || session.isStreaming)
        }
        .onChange(of: session.isStreaming) {
            onKeepVisibleChange(pinned || session.isStreaming)
        }
        .onChange(of: manager.activeIndex) {
            terminalCommand = ""
            resetTerminalHistoryNavigation()
        }
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
        .onChange(of: query) { _, newValue in
            fileSearch.search(newValue)
            FileRAG.shared.prepare(for: newValue)
        }
        // Any file dropped on the panel becomes an attachment.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
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
        // Voice mode loop: reply spoken → resume listening → dictation
        // ends → auto-submit.
        .onReceive(NotificationCenter.default.publisher(for: SpeechSynth.didFinish)) { _ in
            if settings.voiceMode, !session.isStreaming { speech.start() }
        }
        .onChange(of: speech.isRecording) { _, recording in
            if !recording, settings.voiceMode,
               !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                submit()
            }
        }
    }

    /// Private mode wears purple so there's never doubt which mode
    /// you're typing in.
    private var privateTintOverlay: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.purple.opacity(session.isPrivate ? 0.08 : 0))
            .allowsHitTesting(false)
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(session.isPrivate ? Color.purple.opacity(0.55)
                                            : Color.white.opacity(0.15))
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            if manager.sessions.count > 1 {
                sessionTabs
                Divider().opacity(0.3)
            }
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
                .background(sessionShortcuts)
            if let suggestion = appSuggestion {
                appSuggestionRow(suggestion)
            }
            if query.hasPrefix("/") {
                commandSuggestionRows
            }
            if !fileSearch.results.isEmpty && !showHistory {
                fileResultsRows
            }
            if !session.attachments.isEmpty {
                attachmentChips
            }
            if let selection = session.selectionContext {
                selectionChip(selection)
            }
            if !session.queued.isEmpty || session.isStreaming {
                queueView
            }
            if showTerminal {
                Divider().opacity(0.3)
                terminalView
            } else if showUsage {
                Divider().opacity(0.3)
                usageView
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
            // Row 1: the essentials — clean, Spotlight-like.
            HStack(spacing: 10) {
                Button(action: { withAnimation(.easeOut(duration: 0.15)) { showSettings.toggle() } }) {
                    Image(systemName: backendIcon)
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("\(backendBadge) — click for backend & settings")

                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .light))
                    .focused($inputFocused)
                    .onSubmit { submit() }

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
                        .symbolEffect(.pulse, isActive: speech.isRecording)
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

            if updater.commitsBehind > 0 {
                Button(action: {
                    // Stream the update through the transcript like a
                    // ! command, so pull/build progress is visible.
                    session.submit("!" + UpdateChecker.shared.updateCommand)
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                        Text("New update")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("\(updater.commitsBehind) new commit\(updater.commitsBehind == 1 ? "" : "s") on GitHub — click to pull, rebuild, and relaunch (app restarts)")
            }

            Spacer()

            Button(action: { session.isPrivate.toggle() }) {
                Image(systemName: session.isPrivate ? "eye.slash.fill" : "eye.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(session.isPrivate ? Color.purple : Color.secondary)
            }
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
                        .symbolEffect(.pulse, isActive: terminalBusy && !showTerminal)
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

            Button(action: { withAnimation(.easeOut(duration: 0.15)) { showSteps.toggle() } }) {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 15))
                    .foregroundStyle(showSteps ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(showSteps ? "Hide progress sidebar" : "Show progress sidebar (tool steps)")
            .hoverHint("Progress — live tool steps & diffs", $toolbarHint)

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
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button(action: { session.newConversation() }) {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("New conversation (this session)")

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
        switch settings.backend {
        case .claudeCode: return "terminal"
        case .copilot: return "airplane"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .localModel: return "cpu"
        }
    }

    /// ⌘1–9 select session; ⌘⇧[ / ⌘⇧] cycle.
    private var sessionShortcuts: some View {
        Group {
            ForEach(1..<10, id: \.self) { n in
                Button(action: { manager.select(n - 1) }) { EmptyView() }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button(action: { manager.selectPrevious() }) { EmptyView() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button(action: { manager.selectNext() }) { EmptyView() }
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
                ForEach(Array(manager.sessions.enumerated()), id: \.element.id) { index, chat in
                    HStack(spacing: 5) {
                        if chat.isStreaming {
                            ProgressView().controlSize(.mini)
                        }
                        if index < 9 {
                            Text("⌘\(index + 1)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(.quaternary.opacity(0.6),
                                            in: RoundedRectangle(cornerRadius: 3))
                        }
                        Text(chat.title)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 140)
                        Button(action: { manager.close(index) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(index == manager.activeIndex
                                ? AnyShapeStyle(.quaternary)
                                : AnyShapeStyle(.clear),
                                in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { manager.select(index) }
                }
                Button(action: { manager.newSession() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New session (⌘T)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
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
            SettingsView()
            Spacer(minLength: 0)
        }
        .frame(width: 330, alignment: .topLeading)
    }

    // MARK: - Progress sidebar

    private var allActivities: [ToolActivity] {
        session.messages.flatMap(\.activities)
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
            if allActivities.isEmpty {
                Text("No steps yet — tool activity will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        ToolProgressView(activities: allActivities)
                            .id("steps-end")
                    }
                    .frame(maxHeight: 560)
                    .onChange(of: allActivities.count) {
                        proxy.scrollTo("steps-end", anchor: .bottom)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 280, alignment: .topLeading)
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
                    keycap("↩", "queue")
                    if settings.backend == .claudeCode {
                        keycap("⌥↩", "add context")
                    }
                    keycap("⌘↩", "interrupt")
                }
            }
            ForEach(Array(session.queued.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(.quaternary))
                    Text(item)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(action: { session.queued.remove(at: index) }) {
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
        session.isPrivate ? "Private — nothing is saved" : "How can I help you?"
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
        case .codex:
            let model = settings.codexModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Codex" : "Codex · \(model)"
        case .localModel:
            return "Local · \(settings.localModel)"
        }
    }

    /// Backend + model, shown subtly since the placeholder no longer does.
    private var backendBadge: String {
        switch settings.backend {
        case .claudeCode:
            let model = settings.claudeModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Claude Code" : "Claude Code · \(model)"
        case .copilot:
            if let model = settings.effectiveCopilotModel {
                return "Copilot · \(model)"
            }
            return "Copilot"
        case .codex:
            let model = settings.codexModel.trimmingCharacters(in: .whitespaces)
            return model.isEmpty ? "Codex" : "Codex · \(model)"
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

    private var commandSuggestionRows: some View {
        let matches = CommandRegistry.shared.matches(for: query)
        return VStack(alignment: .leading, spacing: 0) {
            if matches.isEmpty {
                Text("No matching skills — add executables to ~/.config/cantrip/commands")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            ForEach(matches.prefix(6)) { command in
                Button(action: { query = "/\(command.name) " }) {
                    HStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor)
                        Text("/\(command.name)")
                            .font(.system(size: 13, design: .monospaced))
                        if !command.description.isEmpty {
                            Text(command.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        keycap("↩", "run")
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

    // MARK: - App typeahead

    /// Top app hit for the current query (Spotlight-style).
    private var appSuggestion: AppMatch? {
        guard !showHistory, !session.isStreaming else { return nil }
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
            if !speech.isRecording { speech.start() }
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

    /// A command (yours or the agent's) is running in the shell.
    private var terminalBusy: Bool {
        session.shell.isRunning || session.shell.hasAgentCommandRunning
    }

    private func toggleTerminal() {
        withAnimation(.easeOut(duration: 0.15)) {
            showTerminal.toggle()
            if showTerminal { showHistory = false; showUsage = false }
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
                .frame(maxHeight: metrics.transcriptMaxHeight)
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
            if let limit = usage.rateLimit {
                HStack(spacing: 6) {
                    Image(systemName: limit.status == "allowed"
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(limit.status == "allowed" ? .green : .orange)
                    if let percent = limit.percentUsed {
                        Text("Claude: \(Int(percent))% of \(limit.type.replacingOccurrences(of: "_", with: " ")) limit used · resets \(limit.resetsAt.formatted(date: .omitted, time: .shortened))")
                            .font(.callout)
                    } else {
                        Text("Claude \(limit.type.replacingOccurrences(of: "_", with: " ")) window: \(limit.status) · resets \(limit.resetsAt.formatted(date: .omitted, time: .shortened))")
                            .font(.callout)
                    }
                }
                if limit.percentUsed == nil {
                    Text("(exact % isn't exposed by the claude CLI in headless mode yet — shown when available)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Claude: no window data yet — send a Claude query first")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "airplane")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let quota = usage.copilotQuota {
                    Text("Copilot: \(quota)").font(.callout)
                } else {
                    Text("Copilot: quota unavailable — needs an authenticated `gh` CLI")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                Button(action: { usage.refreshQuotas(force: true) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Refresh plan quotas")
            }
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
            Text("Claude figures come from the CLI itself; Copilot from GitHub's billing API. Neither exposes plan allotments per-user yet, so percentages appear when the platforms provide them.")
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
                .frame(maxHeight: metrics.transcriptMaxHeight)
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

    private func submit(interrupt: Bool = false, inject: Bool = false) {
        // Enter with an app suggestion showing launches the app;
        // ⌘↩ bypasses the suggestion and asks the AI.
        if !interrupt, !inject, let suggestion = appSuggestion {
            launchApp(suggestion)
            return
        }
        if speech.isRecording { speech.stop() }
        let text = query
        query = ""
        session.submit(text, interrupt: interrupt, inject: inject)
    }

    // MARK: - Conversation

    private var conversationView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // VStack, not LazyVStack: lazy layout sometimes renders
                // nothing after a tab switch until scrolled. The transcript
                // is capped at ~30 messages, so laziness buys nothing.
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if let status = session.statusText {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(status).font(.callout).foregroundStyle(.secondary)
                        }
                        .id("status")
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("conversation-bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: metrics.transcriptMaxHeight)
            // Fresh scroll-view identity per session: prevents stale layout
            // state from the previous tab leaving a blank transcript.
            .id(session.id)
            .onAppear {
                scrollConversationToBottom(proxy)
            }
            .onChange(of: session.messages) {
                scrollConversationToBottom(proxy)
            }
            .onChange(of: session.statusText) {
                scrollConversationToBottom(proxy)
            }
        }
    }

    private func scrollConversationToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
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

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .assistant:
            // Tool steps render in the progress sidebar, not inline.
            if message.text.isEmpty {
                EmptyView()
            } else {
                MarkdownContent(text: message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
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

private struct ToolActivityRow: View {
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir, "checkout", "--", path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            state = p.terminationStatus == 0 ? .done : .failed
            Log.write("revert \(path): exit \(p.terminationStatus)")
        } catch {
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

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        ScrollView(.vertical) {
            settingsContent
        }
        .frame(maxHeight: 500)
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                        ForEach(AppSettings.copilotEffortLevels, id: \.value) { level in
                            Text(level.label).tag(level.value)
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Context window").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $settings.copilotContextTier) {
                        Text("Default (\(settings.copilotFileContextTier ?? "standard"))").tag("")
                        Text("Standard").tag("default")
                        Text("Long · up to 1M").tag("long_context")
                    }
                    .labelsHidden()
                }
                labeledField("Working directory", text: $settings.claudeWorkdir, prompt: NSHomeDirectory())
                Toggle("Allow all tools (--allow-all-tools) — lets Copilot run commands unprompted", isOn: $settings.copilotAllowTools)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                Toggle("Discourage subagents (they're slow server-side) — work inline instead", isOn: $settings.copilotDiscourageSubagents)
                    .font(.caption)
                    .toggleStyle(.checkbox)
            case .codex:
                labeledField("codex path (blank = auto)", text: $settings.codexPath, prompt: "/opt/homebrew/bin/codex")
                labeledField("Model (blank = default, e.g. gpt-5-codex)", text: $settings.codexModel, prompt: "")
                Text("Requires the OpenAI Codex CLI: npm install -g @openai/codex, then run `codex` once to sign in. \"Act on my behalf\" maps to --dangerously-bypass-approvals-and-sandbox.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .localModel:
                labeledField("Base URL", text: $settings.localBaseURL, prompt: "http://hermes.local:8000/v1")
                labeledField("Model", text: $settings.localModel, prompt: "hermes")
                labeledField("API key (optional)", text: $settings.localAPIKey, prompt: "")
                labeledField("System prompt", text: $settings.localSystemPrompt, prompt: "")
            }
            Divider().opacity(0.3)
            Toggle("Act on my behalf — all backends (run commands, edit files, send messages without asking)", isOn: $settings.allowActions)
                .font(.caption)
                .toggleStyle(.checkbox)
            Toggle("Memory vault — remember procedures that worked (markdown notes, Obsidian-compatible)", isOn: $settings.memoryEnabled)
                .font(.caption)
                .toggleStyle(.checkbox)
            if settings.memoryEnabled {
                labeledField("Memory vault folder", text: $settings.memoryPath, prompt: "\(NSHomeDirectory())/Cantrip Memory")
            }
            Toggle("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0 }))
                .font(.caption)
                .toggleStyle(.checkbox)
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

    /// Approximate native context window per model family — Copilot may
    /// cap lower; shown as guidance, not a promise.
    private func contextHint(for model: String) -> String? {
        let m = model.lowercased()
        if m == "auto" { return nil }
        if m == "gpt-5.6-sol",
           settings.effectiveCopilotContextTier == "long_context" { return "~1M" }
        if m.contains("haiku") { return "~200k" }
        if m.contains("claude") || m.contains("gemini") { return "~1M" }
        if m.contains("gpt") { return "~400k" }
        return nil
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
                .help("Re-discover available models from `copilot help`")
            }
        }
        .onAppear {
            if settings.copilotAvailableModels.isEmpty {
                settings.refreshCopilotModels()
            }
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
