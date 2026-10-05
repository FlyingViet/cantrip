import SwiftUI

/// Cantrip Home for the Mac: the iOS Home lane (Chat, Tasks, Artifacts, Background) in a
/// sidebar window. All state and networking come from the shared Hermes model objects.
struct MacHomeWindow: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var navigation: MacHomeNavigation
    @StateObject private var vm: ChatViewModel
    @StateObject private var usageModel = CopilotUsageModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hermes.paused") private var paused = false
    @State private var showingMaintenance = false

    init(env: HermesEnv, remote: CantripRemoteModel, voice: VoiceController, navigation: MacHomeNavigation) {
        // Home is the only lane on the Mac.
        if env.executionLane != .home {
            env.setLaneVisible(.home, isVisible: true)
            env.select(.home)
        }
        self.env = env
        self.remote = remote
        self.voice = voice
        self.navigation = navigation
        _vm = StateObject(wrappedValue: ChatViewModel(env: env, remote: remote, voice: voice))
    }

    var body: some View {
        NavigationSplitView {
            MacHomeSidebar(remote: remote, voice: voice, navigation: navigation) {
                navigation.sheet = .mascot
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } detail: {
            NavigationStack { detail }
                .id(navigation.section)
        }
        .frame(minWidth: 760, minHeight: 540)
        .toolbar { toolbar }
        .sheet(isPresented: $navigation.showingBackground) {
            CantripHomeBackgroundView(remote: remote, openLog: nil, openSession: nil, openTab: nil)
                .macSheetFrame(width: 620, height: 640)
        }
        .sheet(item: $navigation.sheet, content: sheet)
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
        .onChange(of: showingMaintenance) { _, showing in
            if showing {
                navigation.sheet = .maintenance
                showingMaintenance = false
            }
        }
        .onAppear {
            setActive(scenePhase)
            voice.requestAuth()
        }
        .onChange(of: scenePhase) { _, phase in setActive(phase) }
        .onChange(of: remote.transcriptRevision) { _, _ in vm.syncRemoteTranscript() }
        .onChange(of: remote.selectedSessionID) { _, _ in vm.syncRemoteTranscript() }
        .onChange(of: remote.selectedServerID) { _, _ in
            vm.leaveVoiceMode()
            vm.remoteDeliveryMode = .auto
            navigation.closeAll()
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

    @ViewBuilder private var detail: some View {
        switch navigation.section {
        case .chat:
            MacHomeChatView(remote: remote, vm: vm, voice: voice, navigation: navigation)
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
            if remote.selectedSession != nil {
                Button("Model Settings…", systemImage: "slider.horizontal.3") {
                    remote.modelSettingsSession = remote.selectedSession
                }
                .disabled(remote.isMutating)
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
    /// keeps updating on screen; a hidden or minimized-only app stops polling.
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
