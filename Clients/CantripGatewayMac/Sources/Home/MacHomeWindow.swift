import AppKit
import SwiftUI

/// Cantrip Home for the Mac: the iOS Home lane (Chat, Tasks, Artifacts, Background) and every
/// project tab in a sidebar window. All state and networking come from the shared Hermes model
/// objects; an open tab uses the same `.cantrip` lane as a tab opened from iOS Home's drawer.
struct MacHomeWindow: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var navigation: MacHomeNavigation
    @ObservedObject var directLocal: DirectLocalChat
    @StateObject private var vm: ChatViewModel
    @StateObject private var usageModel = CopilotUsageModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hermes.paused") private var paused = false
    @State private var showingMaintenance = false
    @State private var confirmingDirectLocalClear = false

    init(env: HermesEnv, remote: CantripRemoteModel, voice: VoiceController, navigation: MacHomeNavigation,
         directLocal: DirectLocalChat) {
        // Home (with its tabs) is the Mac's only lane; HermesEnv always launches into it. Forcing
        // it here would undo an open tab, since SwiftUI re-runs this init whenever env changes.
        navigation.attach(env: env, remote: remote)
        self.env = env
        self.remote = remote
        self.voice = voice
        self.navigation = navigation
        self.directLocal = directLocal
        _vm = StateObject(wrappedValue: ChatViewModel(env: env, remote: remote, voice: voice))
    }

    var body: some View {
        NavigationSplitView {
            MacHomeSidebar(env: env, remote: remote, voice: voice, navigation: navigation) {
                navigation.sheet = .mascot
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } detail: {
            NavigationStack { detail }
                .id(navigation.showingDirectLocal ? "directLocal" : isTabOpen ? "tab" : navigation.section.rawValue)
        }
        .frame(minWidth: 760, minHeight: 540)
        .toolbar { toolbar }
        .focusedSceneValue(\.startFreshTabID, startFreshTabID)
        .sheet(isPresented: $navigation.showingBackground) {
            CantripHomeBackgroundView(
                remote: remote, openLog: nil, openSession: nil,
                openTab: { navigation.openTab($0) }
            )
            .macSheetFrame(width: 620, height: 640)
        }
        .sheet(item: $navigation.renamingTab) { session in
            CantripTabRenameSheet(model: remote, session: session)
                .macSheetFrame(width: 420, height: 220)
        }
        .sheet(item: $navigation.sheet, content: sheet)
        .sheet(isPresented: $navigation.showingDirectLocalSettings) {
            MacDirectLocalSettingsView(chat: directLocal) { navigation.showingDirectLocalSettings = false }
                .macSheetFrame(width: 640, height: 760)
        }
        .cantripSectionPrompt(model: remote)
        .sheet(item: $remote.modelSettingsSession) { session in
            CantripSessionSettingsView(model: remote, session: session, identity: remote.usageIdentity)
                .macSheetFrame()
        }
        .sheet(item: $remote.inputRequestsSession) { session in
            CantripInputRequestsView(model: remote, session: session)
                .macSheetFrame()
        }
        .sheet(isPresented: $remote.showingMacAccess) {
            NavigationStack { CantripMacAccessView(remote: remote) }
                .macSheetFrame(width: 760, height: 620)
        }
        .sheet(item: $navigation.pairing) { prompt in
            CantripPairingView(prompt: prompt, model: remote) { _ in navigation.pairing = nil }
                .macSheetFrame(width: 520, height: prompt.link == nil ? 260 : 600)
        }
        .confirmationDialog("Clear the local conversation?", isPresented: $confirmingDirectLocalClear) {
            Button("Clear Conversation", role: .destructive) { directLocal.clear() }
        } message: {
            Text("This deletes it from this Mac. It was never synced, so there is no other copy.")
        }
        .onOpenURL { url in
            if let pairing = CantripPairingLink.parse(url) { navigation.showPairing(pairing) }
        }
        .onChange(of: showingMaintenance) { _, showing in
            if showing {
                navigation.sheet = .maintenance
                showingMaintenance = false
            }
        }
        .onAppear {
            setActive(scenePhase)
            remote.setFrontmost(NSApplication.shared.isActive)
            #if DEBUG
            if !DirectLocalQA.isActive { voice.requestAuth() }
            #else
            voice.requestAuth()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in setActive(phase) }
        // Behind other apps Home still updates, every 15 s instead of every 1.5-5 s.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            remote.setFrontmost(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            remote.setFrontmost(false)
        }
        .onChange(of: env.executionLane) { _, lane in vm.switchLane(to: lane) }
        .onChange(of: vm.sending) { _, sending in
            // A tab or Home picked while a send (or image upload) was in flight opens after it.
            if !sending, env.executionLane != vm.activeLane { vm.switchLane(to: env.executionLane) }
        }
        .onChange(of: remote.transcriptRevision) { _, _ in vm.syncRemoteTranscript() }
        .onChange(of: remote.selectedSessionID) { _, _ in vm.syncRemoteTranscript() }
        .onChange(of: remote.selectedServerID) { _, _ in
            vm.leaveVoiceMode()
            vm.remoteDeliveryMode = .auto
            navigation.closeAll()
            navigation.showHome()
            Task {
                await remote.selectHome()
                vm.syncRemoteTranscript()
            }
        }
        .onChange(of: remote.notificationNavigationID) { _, _ in
            navigation.closeAll()
            vm.leaveVoiceMode()
            vm.syncRemoteTranscript()
            // A background run's request opens Home's Background list on that run.
            if remote.homeBackgroundFocus != nil {
                DispatchQueue.main.async { navigation.showingBackground = true }
            }
        }
        .onChange(of: remote.homeBackgroundFocus) { _, focus in
            if focus != nil { navigation.showingBackground = true }
        }
        .onChange(of: paused) { _, isPaused in
            guard isPaused else { return }
            remote.cancelVideoUpload()
            voice.stopListening(finalize: false)
            voice.stopSpeaking()
            if navigation.sheet == .voiceMode { navigation.sheet = nil }
        }
    }

    /// The lane the chat actually shows; a requested switch waits for an in-flight send.
    private var isTabOpen: Bool { vm.activeLane == .cantrip }

    /// The open tab, while the menu bar's Start Fresh can run on it.
    private var startFreshTabID: String? {
        guard isTabOpen, let session = remote.selectedSession, !remote.isMutating,
              CantripStartFresh.support(for: session) == true, !CantripStartFresh.isBusy(session)
        else { return nil }
        return session.id
    }

    @ViewBuilder private var detail: some View {
        if navigation.showingDirectLocal {
            MacDirectLocalView(chat: directLocal, remote: remote) {
                navigation.showingDirectLocalSettings = true
            }
        } else if isTabOpen {
            MacHomeChatView(remote: remote, vm: vm, voice: voice, navigation: navigation,
                            slashCommands: remote.slashCommands, isTab: true)
        } else {
            homeSection
        }
    }

    @ViewBuilder private var homeSection: some View {
        switch navigation.section {
        case .chat:
            MacHomeChatView(remote: remote, vm: vm, voice: voice, navigation: navigation,
                            slashCommands: remote.slashCommands)
        case .tasks:
            CantripHomeTasksView(
                remote: remote,
                openChat: { navigation.openChat(prefill: $0) },
                openRun: { navigation.openRun($0, remote: remote) }
            )
        case .artifacts:
            CantripHomeArtifactsView(remote: remote, openChat: { navigation.openChat(prefill: $0) })
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if navigation.showingDirectLocal {
            directLocalToolbar
        } else if isTabOpen {
            tabToolbar
        } else {
            homeToolbar
        }
    }

    /// Direct local mode: its settings and conversation; nothing here talks to the paired host.
    @ToolbarContentBuilder private var directLocalToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                navigation.showingDirectLocalSettings = true
            } label: {
                Label("Local Model Settings", systemImage: "slider.horizontal.3")
            }
            .help("Local model server, model, context and system prompt")
            Menu {
                Button("Clear Conversation…", systemImage: "trash", role: .destructive) {
                    confirmingDirectLocalClear = true
                }
                .disabled(directLocal.messages.isEmpty || directLocal.isReplying)
                Divider()
                Button("Back to Home", systemImage: "house") { navigation.showHome() }
                SettingsLink { Label("Settings…", systemImage: "gearshape") }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Local model actions")
            .accessibilityIdentifier("directLocal.menu")
        }
    }

    /// A project tab: Stop, delivery (Auto) and the tab's More menu.
    @ToolbarContentBuilder private var tabToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            CantripStopButton(
                session: remote.selectedSession,
                isConnected: remote.isConnected,
                isMutating: remote.isMutating,
                isStopping: remote.stoppingSessionID != nil
                    && remote.stoppingSessionID == remote.selectedSessionID,
                onStop: vm.stopRemote
            )
            .disabled(vm.sending)
            if remote.selectedSession != nil {
                CantripDeliveryPicker(deliveryMode: $vm.remoteDeliveryMode, compact: true)
                    .disabled(remote.isMutating || vm.sending)
                    .help("Delivery: how a message reaches a working tab")
            }
            tabMenu
        }
    }

    private var tabMenu: some View {
        Menu {
            if let session = remote.selectedSession, remote.sessions.contains(where: { $0.id == session.id }) {
                CantripTabActions(
                    model: remote, session: session,
                    onRename: { navigation.renamingTab = session },
                    onClose: { navigation.closeTab(session.id) }
                )
                Divider()
            }
            if remote.selectedSession?.canResume == true {
                Button("Resume", systemImage: "play") {
                    Task {
                        _ = await remote.resume()
                        vm.syncRemoteTranscript()
                    }
                }
                .disabled(remote.isMutating)
            }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await remote.refreshNow() } }
                .disabled(!remote.isConfigured || remote.isRefreshing)
            Button("Copilot Usage", systemImage: "gauge.with.dots.needle.33percent") {
                navigation.sheet = .usage
            }
            .disabled(!remote.isConfigured)
            Button(paused ? "Resume Agent" : "Pause Agent",
                   systemImage: paused ? "play.circle" : "pause.circle") { paused.toggle() }
            Button("Voice Mode", systemImage: "waveform") { navigation.sheet = .voiceMode }
                .disabled(paused || !remote.isConfigured || remote.selectedSessionID == nil)
            Divider()
            Button("Back to Home", systemImage: "house") { navigation.showHome() }
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
        } label: {
            Label("More", systemImage: paused ? "pause.circle" : "ellipsis.circle")
        }
        .help(paused ? "Tab actions — agent paused" : "Tab actions")
        .accessibilityIdentifier("tab.menu")
    }

    @ToolbarContentBuilder private var homeToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            MacHomeBackgroundButton(activeCount: backgroundCount, inputCount: backgroundInputCount) {
                navigation.showingBackground = true
            }
            if navigation.section == .chat, remote.selectedSession != nil {
                CantripDeliveryPicker(deliveryMode: $vm.remoteDeliveryMode, compact: true)
                    .disabled(remote.isMutating || vm.sending)
            }
            Button {
                Task { await remote.refreshNow() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh Cantrip Home (⌘R)")
            .disabled(!remote.isConfigured || remote.isRefreshing)
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            if let session = remote.selectedSession {
                Button("Model Settings…", systemImage: "slider.horizontal.3") {
                    remote.modelSettingsSession = remote.selectedSession
                }
                .disabled(remote.isMutating)
                CantripStartFreshMenuItem(
                    model: remote, sessionID: session.id, support: CantripStartFresh.support(for: session),
                    isDisabled: remote.isMutating || CantripStartFresh.isBusy(session)
                )
            }
            Button("Copilot Usage", systemImage: "gauge.with.dots.needle.33percent") {
                navigation.sheet = .usage
            }
            .disabled(!remote.isConfigured)
            Button(paused ? "Resume Agent" : "Pause Agent",
                   systemImage: paused ? "play.circle" : "pause.circle") { paused.toggle() }
            Button("Voice Mode", systemImage: "waveform") { navigation.sheet = .voiceMode }
                .disabled(paused || !remote.isConfigured || remote.selectedSessionID == nil)
            Divider()
            Button("GitHub Builds", systemImage: "hammer") { navigation.sheet = .builds }
            Button("Cantrip Memory", systemImage: "brain") { navigation.sheet = .memory }
            Button("Customize Mascot", systemImage: "tshirt") { navigation.sheet = .mascot }
            CantripMacMenuActions(remote: remote, showingMaintenance: $showingMaintenance) {
                vm.leaveVoiceMode()
            }
            Divider()
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
        } label: {
            Label("More", systemImage: paused ? "pause.circle" : "ellipsis.circle")
        }
        .help(paused ? "More — agent paused" : "More")
    }

    @ViewBuilder private func sheet(_ sheet: MacHomeSheet) -> some View {
        switch sheet {
        case .usage:
            CopilotUsageView(model: usageModel, remote: remote)
                .macSheetFrame()
                .task {
                    usageModel.useSource(remote.usageIdentity)
                    await usageModel.refresh { try await remote.copilotUsage() }
                }
        case .memory:
            CantripMemoryView(remote: remote).macSheetFrame(width: 720, height: 680)
        case .builds:
            GitHubBuildsView(remote: remote).macSheetFrame(width: 720, height: 680)
        case .mascot:
            CantripMascotCustomizationView().macSheetFrame(width: 560, height: 680)
        case .maintenance:
            CantripMaintenanceSheet(remote: remote).macSheetFrame()
        case .voiceMode:
            VoiceModeView(voice: voice, vm: vm, onClose: { navigation.sheet = nil })
                .macSheetFrame(width: 520, height: 620)
                .onDisappear { vm.leaveVoiceMode() }
        case .queue:
            if let sessionID = remote.selectedSessionID {
                CantripQueueView(remote: remote, sessionID: sessionID).macSheetFrame()
            }
        case .backgroundTasks:
            if let sessionID = remote.selectedSessionID {
                CantripBackgroundTasksView(remote: remote, sessionID: sessionID)
                    .macSheetFrame(width: 620, height: 560)
            }
        }
    }

    /// Background-run requests waiting on the user (same rule as iOS Home's header).
    private var backgroundInputCount: Int {
        guard remote.selectedSession?.isCantripHome == true else { return 0 }
        return remote.selectedSession?.backgroundInputCount
            ?? (remote.homeBackground?.runs.filter(\.needsInput).count ?? 0)
    }

    private var backgroundCount: Int {
        guard remote.selectedSession?.isCantripHome == true else { return 0 }
        return CantripHomeBackgroundCount.active(
            transcript: remote.selectedSession?.transcript ?? [], session: remote.selectedSession
        )
    }

    /// macOS keeps visible windows "active" even when another app is frontmost, so Home
    /// keeps updating on screen (slower; see setFrontmost); a hidden or minimized-only app
    /// stops polling.
    private func setActive(_ phase: ScenePhase) {
        let active = phase != .background
        remote.setAppActive(active)
        vm.setAppActive(active)
    }
}

/// The toolbar's Background button: same counts and badges as iOS Home's header button.
struct MacHomeBackgroundButton: View {
    let activeCount: Int
    var inputCount = 0
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "gearshape.2")
                    .symbolEffect(.pulse, isActive: activeCount > 0 && !reduceMotion)
                    .foregroundStyle(activeCount > 0 ? CantripHomeBackgroundStyle.activeTint : Color.primary)
                if inputCount > 0 {
                    badge(Image(systemName: "questionmark"))
                } else if activeCount > 0 {
                    badge(Text(activeCount > 9 ? "9+" : "\(activeCount)").monospacedDigit())
                }
            }
        }
        .help("Background tasks and scheduled runs (⌘B)")
        .accessibilityLabel("Background")
        .accessibilityValue(inputCount > 0
            ? "\(inputCount) \(inputCount == 1 ? "needs" : "need") your input"
                + (activeCount > 0 ? ", \(activeCount) running" : "")
            : activeCount == 0 ? "Nothing running" : "\(activeCount) running")
        .accessibilityIdentifier("home.background")
    }

    private func badge(_ content: some View) -> some View {
        content
            .font(.caption2.weight(.bold))
            .foregroundStyle(CantripHomeBackgroundStyle.badgeText)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(CantripHomeBackgroundStyle.activeTint, in: Capsule())
            .accessibilityHidden(true)
    }
}

extension View {
    /// iOS sheets size to the screen; macOS sheets size to their content, so give the
    /// shared sheets a comfortable window-sized frame.
    func macSheetFrame(width: CGFloat = 600, height: CGFloat = 600) -> some View {
        frame(minWidth: min(width, 480), idealWidth: width, minHeight: min(height, 420), idealHeight: height)
    }
}
