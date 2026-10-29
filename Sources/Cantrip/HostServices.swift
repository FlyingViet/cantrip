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

    private var postsMacNotifications: Bool { !HostMode.isHeadless }

    init(manager: SessionManager) {
        self.manager = manager
    }

    func start(recoveryReport: CrashRecovery.Report?) {
        UsageTracker.shared.startAutoRefresh()
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
                do {
                    let center = UNUserNotificationCenter.current()
                    guard try await center.requestAuthorization(options: [.alert, .sound]),
                          session.pendingInputs.contains(where: { $0.id == request.id }), !session.isPrivate else { return }
                    let content = UNMutableNotificationContent()
                    content.title = "Cantrip needs your input"
                    content.body = "Open Cantrip to review a pending request."
                    content.sound = .default
                    content.userInfo = ["sessionID": session.id.uuidString]
                    try await center.add(UNNotificationRequest(identifier: request.id.uuidString, content: content, trigger: nil))
                } catch { Log.write("input: Mac attention notification could not be delivered") }
            }
        }
        manager.onAnyInputResolved = { [weak self] id in
            guard let self else { return }
            remoteControlServer?.resolveInputNotification(id)
            guard postsMacNotifications else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
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
            let content = UNMutableNotificationContent()
            content.title = "Cantrip — \(title)"
            content.body = summary
            content.userInfo = ["sessionID": handoff.tabID.uuidString]
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: handoff.id.uuidString, content: content, trigger: nil
            ))
        }
        // A headless host exists to serve remote clients, so its server runs whatever the app's
        // Remote control toggle says (and that setting isn't changed).
        let headless = HostMode.isHeadless
        AppSettings.shared.$remoteControlEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.onRemoteControlEnabledChange?(enabled)
                if !enabled, !headless {
                    self?.remoteControlServer?.stop()
                    AppSettings.shared.reportRemoteControlError(nil)
                }
            }
            .store(in: &cancellables)
        Publishers.CombineLatest4(
            AppSettings.shared.$remoteControlEnabled,
            AppSettings.shared.$remoteControlPort,
            AppSettings.shared.$remoteLANPort,
            AppSettings.shared.$remoteControlCredentialRevision
        )
        .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
        .sink { enabled, port, lanPort, _ in
            guard enabled || headless else { return }
            guard let token = AppSettings.shared.ensureRemoteControlToken() else {
                remoteControlServer.stop()
                return
            }
            remoteControlServer.start(port: port, token: token, lanPort: lanPort == 0 ? nil : lanPort)
        }
        .store(in: &cancellables)

        // Daily memory consolidation, off the launch path; failed runs retry with backoff.
        Consolidator.start()
        // Daily cleanup of agent session folders and worktrees nothing uses anymore.
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
        for error in RunJournal.drainForTermination() {
            Log.write("run-journal: exit flush failed code=\((error as NSError).code)")
        }
        CrashRecovery.markCleanExit()
    }
}
