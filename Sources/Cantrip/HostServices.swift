import Combine
import Foundation
import UserNotifications

/// Everything Cantrip runs for its sessions and remote clients, with no window, menu or hotkey:
/// session recovery, the `cantrip` CLI socket, the Remote server and Cantrip Home. The app adds
/// its panel and menus on top; `--headless` runs this alone.
@MainActor
final class HostServices {
    let manager: SessionManager
    private(set) var remoteControlServer: RemoteControlServer?
    private var cancellables: Set<AnyCancellable> = []
    /// A run finished (the app also posts a Mac notification while its panel is hidden).
    var onRunFinished: ((ChatSession) -> Void)?
    /// The Remote control setting changed (the app mirrors it in its menu).
    var onRemoteControlEnabledChange: ((Bool) -> Void)?

    /// The background engine's notifications go to Cantrip.app, which posts them (`MacNotices`).
    private var postsMacNotifications: Bool { !HostMode.isHeadless || HostMode.isEngine }

    /// The host running in this process.
    private(set) static weak var running: HostServices?

    init(manager: SessionManager) {
        self.manager = manager
    }

    /// Work a restart would interrupt: tabs streaming, queued or running a shell command, and
    /// Cantrip Home's background jobs.
    var busyWork: Int {
        manager.sessions.filter { $0.isStreaming || !$0.queued.isEmpty || $0.shell.isRunning }.count
            + CantripHomeStore.shared.runner.jobs.count
    }

    /// A finished run's notification (shown when it isn't on screen).
    static func runFinishedNotice(_ finished: ChatSession) -> MacNotice {
        let preview = finished.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text
            ?? finished.messages.last(where: { $0.role == .error })?.text
            ?? "Response ready"
        return MacNotice(id: UUID().uuidString, title: "Cantrip — \(finished.notificationTitle)",
                         body: RemoteCompletion.summaryPreview(preview) ?? String(preview.prefix(160)),
                         sessionID: finished.id.uuidString, runFinished: true)
    }

    func start(recoveryReport: CrashRecovery.Report?) {
        Self.running = self
        UsageTracker.shared.startAutoRefresh()
        BackendStatusMonitor.shared.start(postsMacNotifications: postsMacNotifications)
        GitHubAuthMonitor.shared.start()
        // Each CLI's own rules join the agent policy once; its deny rules go back into each CLI.
        DispatchQueue.global(qos: .utility).async { AgentPolicySetup.run() }
        SecretsHub.shared.start()
        // Older replies point at agent files folders recorded before Cantrip tracked them.
        let transcripts = SessionManager.chatsDir
        DispatchQueue.global(qos: .utility).async {
            SessionOutputFolders.shared.backfillIfNeeded(transcripts: transcripts)
        }

        manager.onAnyRunFinished = { [weak self] finished in
            self?.onRunFinished?(finished)
            self?.remoteControlServer?.notifyCompletion(for: finished)
        }
        manager.onAnyInputNeeded = { [weak self] session, request in
            guard let self else { return }
            remoteControlServer?.notifyInput(for: session, request: request)
            guard postsMacNotifications, !session.isPrivate else { return }
            Task { @MainActor in
                // The engine's app asks for permission itself.
                if !HostMode.isEngine {
                    guard (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) == true
                    else { return }
                }
                guard session.pendingInputs.contains(where: { $0.id == request.id }), !session.isPrivate else { return }
                MacNotices.post(MacNotice(id: request.id.uuidString, title: "Cantrip needs your input",
                                          body: "Open Cantrip to review a pending request.",
                                          sessionID: session.id.uuidString, sound: true))
            }
        }
        manager.onAnyInputResolved = { [weak self] id in
            guard let self else { return }
            remoteControlServer?.resolveInputNotification(id)
            guard postsMacNotifications else { return }
            MacNotices.remove([id.uuidString])
        }
        CantripHomeStore.shared.attach(manager: manager)
        AppSettings.shared.$cantripHomeEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in CantripHomeStore.shared.homeAvailabilityChanged() }
            .store(in: &cancellables)
        MacAttention.shared.onAttention = { [weak self] issue in
            guard let self, !manager.active.isPrivate, !manager.active.isLocalPrivate else { return }
            remoteControlServer?.notifyMacAttention(sessionID: manager.active.id, issueID: issue.id)
        }
        MacAttention.shared.onResolved = { [weak self] id in
            self?.remoteControlServer?.resolveInputNotification(id)
        }

        // Unix-socket server for the `cantrip` CLI, including `cantrip status|pair|config`.
        let control = HostControl(manager: manager)
        CLIServer.shared.controlHandler = { control.handle($0) }
        CLIServer.shared.start()

        // Authenticated loopback HTTP for Tailscale plus encrypted Bonjour LAN access.
        let remoteControlServer = RemoteControlServer(manager: manager)
        remoteControlServer.onError = { message in
            DispatchQueue.main.async {
                AppSettings.shared.reportRemoteControlError(message)
            }
        }
        remoteControlServer.onLANStatus = { status in
            DispatchQueue.main.async {
                AppSettings.shared.reportRemoteLANStatus(status)
            }
        }
        self.remoteControlServer = remoteControlServer
        MCPHost.shared.start(remote: remoteControlServer, postsMacNotifications: postsMacNotifications)
        BackendStatusMonitor.shared.remote = remoteControlServer
        StorageUpkeepStatus.shared.remote = remoteControlServer
        WatchInternetRoute.shared.start(server: remoteControlServer)
        CantripHomeStore.shared.onHandoff = { [weak self] run, handoff in
            guard let self else { return }
            let title = "Handed to \(handoff.tabTitle)"
            let state = handoff.status == .running ? "Running now" : "Waiting in the tab's queue"
            let summary = "\(run.label) · \(state)"
            // Tapping opens the tab that took the work.
            remoteControlServer.notify(RemoteCompletion(
                id: handoff.id, sessionID: handoff.tabID, title: title,
                summary: RemoteCompletion.preview(summary), completedAt: Date()
            ))
            guard postsMacNotifications else { return }
            MacNotices.post(MacNotice(id: handoff.id.uuidString, title: "Cantrip — \(title)", body: summary,
                                      sessionID: handoff.tabID.uuidString))
        }
        // A headless host exists to serve remote clients, so its server runs whatever the app's
        // Remote control toggle says (and that setting isn't changed). The background engine is
        // Cantrip.app's own host: it follows the toggle, and always serves the app on loopback.
        let headless = HostMode.isHeadless && !HostMode.isEngine
        let engine = HostMode.isEngine
        // The Home window (Window interface) and Cantrip's Settings window are clients of this
        // server on loopback, so it also runs for them, without the LAN listener, while Remote
        // control is off.
        let servesHomeWindow = {
            engine || (!headless && HomeWindow.isAvailable
                && (AppSettings.shared.interfaceMode == .window || AppSettings.shared.localSettingsWindowOpen))
        }
        AppSettings.shared.$remoteControlEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.onRemoteControlEnabledChange?(enabled)
                if !enabled, !headless, !servesHomeWindow() {
                    self?.remoteControlServer?.stop()
                    AppSettings.shared.reportRemoteControlError(nil)
                }
            }
            .store(in: &cancellables)
        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                AppSettings.shared.$remoteControlEnabled,
                AppSettings.shared.$remoteControlPort,
                AppSettings.shared.$remoteLANPort,
                AppSettings.shared.$remoteControlCredentialRevision
            ),
            Publishers.CombineLatest(AppSettings.shared.$interfaceMode, AppSettings.shared.$localSettingsWindowOpen)
        )
        .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
        .sink { values, _ in
            let (enabled, port, lanPort, _) = values
            let remote = enabled || headless
            guard remote || servesHomeWindow() else {
                remoteControlServer.stop()
                return
            }
            guard let token = AppSettings.shared.ensureRemoteControlToken() else {
                remoteControlServer.stop()
                return
            }
            remoteControlServer.start(port: port, token: token, lanPort: lanPort == 0 ? nil : lanPort,
                                      servesLAN: remote)
        }
        .store(in: &cancellables)

        // Cantrip's OpenAI-compatible API on loopback, off until turned on (`OpenAIEndpoint`).
        let endpoint = OpenAIEndpoint.shared
        endpoint.onStatus = { port, error in AppSettings.shared.reportOpenAIEndpoint(listening: port, error: error) }
        Publishers.CombineLatest3(
            AppSettings.shared.$openAIEndpointEnabled,
            AppSettings.shared.$openAIEndpointPort,
            AppSettings.shared.$openAIEndpointKeyRevision
        )
        .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
        .sink { enabled, port, _ in
            if enabled {
                endpoint.start(port: port, key: AppSettings.shared.openAIEndpointKey)
            } else {
                endpoint.stop()
            }
        }
        .store(in: &cancellables)

        // The optional memory search index: built in the background while on, deleted when off.
        Publishers.CombineLatest3(
            AppSettings.shared.$memoryEnabled, AppSettings.shared.$memorySearchIndex, AppSettings.shared.$memoryPath
        )
        .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
        .sink { enabled, indexed, path in
            if enabled && indexed { MemoryStore.prepareSearchIndex(path: path) } else { MemoryStore.removeSearchIndex() }
        }
        .store(in: &cancellables)

        // Library skills linked for every backend on their own, while that's on.
        let skillsAutoLink = SkillsAutoLink()
        AppSettings.shared.$skillsAutoLink
            .removeDuplicates()
            .sink { on in
                guard on else { skillsAutoLink.stop(); return }
                skillsAutoLink.start { result in
                    switch result {
                    case .success(let report):
                        guard !report.lines.isEmpty else { return }
                        Log.write("skills: linked on their own: \(report.lines.joined(separator: "; "))")
                        Task { @MainActor in SkillsHub.shared.refresh() }
                    case .failure(let error):
                        Log.write("skills: automatic link failed: \(error.localizedDescription)")
                    }
                }
            }
            .store(in: &cancellables)

        // Daily memory consolidation, off the launch path; failed runs retry with backoff.
        Consolidator.start()
        // Daily cleanup of agent session folders and worktrees nothing uses anymore.
        StorageUpkeepStatus.shared.postsMacNotifications = postsMacNotifications
        StorageUpkeepStatus.shared.start()

        if let recoveryReport {
            manager.active.messages.append(ChatMessage(
                role: .error,
                text: CrashRecovery.message(for: recoveryReport)
            ))
            Log.write("recovery: surfaced crash \(recoveryReport.id.uuidString)")
        }
    }

    /// Resumes runs a crash or relaunch interrupted. Call last, once the host is fully set up.
    func continueRestoredWork() {
        _ = NetworkMonitor.shared
        manager.continueRestoredWork()
    }

    func stop() {
        remoteControlServer?.stop()
        OpenAIEndpoint.shared.stop()
        for error in RunJournal.drainForTermination() {
            Log.write("run-journal: exit flush failed code=\((error as NSError).code)")
        }
        CrashRecovery.markCleanExit()
    }
}
