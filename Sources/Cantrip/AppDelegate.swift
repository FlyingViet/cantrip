import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panel: LauncherPanel!
    /// Latest size the panel content asked for, applied once per run-loop turn.
    private var pendingPanelSize: CGSize?
    private var hotkey: HotkeyManager!
    private var selectionHotkey: HotkeyManager!
    private var pasteMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private let manager: SessionManager
    private let services: HostServices
    private let recoveryReport: CrashRecovery.Report?
    private var remoteControlMenuItem: NSMenuItem?
    private var panelInterfaceMenuItem: NSMenuItem?
    private var windowInterfaceMenuItem: NSMenuItem?
    private var openHomeWindowMenuItem: NSMenuItem?

    init(recoveryReport: CrashRecovery.Report?) {
        self.recoveryReport = recoveryReport
        manager = SessionManager()
        services = HostServices(manager: manager)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Antigravity's model list (Gemini, Claude Opus/Sonnet, …) comes from `agy models`.
        if AntigravityBackend.isInstalled(customPath: AppSettings.shared.agyPath) {
            AppSettings.shared.refreshAntigravityModelsIfNeeded()
        }
        // Main menu: invisible for accessory apps, but REQUIRED for standard
        // keyboard shortcuts (⌘C/⌘V/⌘X/⌘A/⌘Z) to route to the text field.
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "New Conversation", action: #selector(newConversation), keyEquivalent: "n")
        appMenu.addItem(withTitle: "New Session", action: #selector(newSessionAction), keyEquivalent: "t")
        appMenu.addItem(withTitle: "Reset Panel Size", action: #selector(resetPanelSize), keyEquivalent: "")
        appMenu.addItem(withTitle: "Close Tab", action: #selector(closeCurrentSession), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Previous Tab",
                        action: #selector(selectPreviousSession),
                        keyEquivalent: "\u{F702}")
        appMenu.addItem(withTitle: "Next Tab",
                        action: #selector(selectNextSession),
                        keyEquivalent: "\u{F703}")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Export Settings to ~/.cantriprc",
                        action: #selector(exportSettings), keyEquivalent: "")
        appMenu.addItem(withTitle: "Import Settings from ~/.cantriprc",
                        action: #selector(importSettings), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cantrip",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu

        // Menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkle.magnifyingglass",
                                   accessibilityDescription: "Cantrip")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle (⌥Space)", action: #selector(togglePanel), keyEquivalent: "")
        let openHomeWindowMenuItem = NSMenuItem(title: "Open Home Window", action: #selector(openHomeWindow),
                                                keyEquivalent: "")
        openHomeWindowMenuItem.target = self
        menu.addItem(openHomeWindowMenuItem)
        self.openHomeWindowMenuItem = openHomeWindowMenuItem
        menu.addItem(withTitle: "Stop Current Request", action: #selector(stopRequest), keyEquivalent: "")
        menu.addItem(withTitle: "End Remote View", action: #selector(endRemoteView), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Panel & Overlays", action: #selector(forceHide), keyEquivalent: "")
        menu.addItem(.separator())
        let remoteControlMenuItem = NSMenuItem(
            title: "Remote Control Daemon",
            action: #selector(toggleRemoteControlDaemon),
            keyEquivalent: ""
        )
        remoteControlMenuItem.target = self
        menu.addItem(remoteControlMenuItem)
        self.remoteControlMenuItem = remoteControlMenuItem
        menu.addItem(.separator())
        // Interface: the floating panel or Cantrip Gateway's Home window (macOS 26).
        for mode in InterfaceMode.allCases {
            let item = NSMenuItem(title: "Interface: \(mode.label)", action: #selector(chooseInterface(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            menu.addItem(item)
            if mode == .panel { panelInterfaceMenuItem = item } else { windowInterfaceMenuItem = item }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cantrip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        AppSettings.shared.$interfaceMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in self?.applyInterfaceMode(mode) }
            .store(in: &cancellables)

        // Floating panel
        panel = LauncherPanel()
        PanelVisibility.shared.track(panel)
        panel.install(LauncherView(
            manager: manager,
            onDismiss: { [weak self] in self?.hidePanel() },
            onSizeChange: { [weak self] size in
                // Defer: resizing the window inside SwiftUI's layout pass
                // causes layout recursion and a blank (invisible) panel.
                // Coalesce: a layout that settles over two passes (the
                // composer gains a line, then the transcript gives it back)
                // resizes once, instead of tripping the flip-flop damping.
                guard let self else { return }
                let scheduled = self.pendingPanelSize != nil
                self.pendingPanelSize = size
                guard !scheduled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, let size = self.pendingPanelSize else { return }
                    self.pendingPanelSize = nil
                    self.panel.resizeContent(to: size)
                }
            },
            onKeepVisibleChange: { [weak self] keep in self?.panel.keepVisibleWhileUnfocused = keep }
        ))

        // Global hotkey: Option + Space
        hotkey = HotkeyManager { [weak self] in
            self?.togglePanel()
        }

        // Selection hotkey: Option + Shift + Space — grab the selected text
        // from the frontmost app, then open the panel with it attached.
        selectionHotkey = HotkeyManager(keyCode: UInt32(kVK_Space),
                                        modifiers: UInt32(optionKey | shiftKey),
                                        id: 2) { [weak self] in
            guard let self else { return }
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the frontmost app"
            if let text = SelectionGrabber.grab(),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.manager.active.selectionContext = SelectionContext(text: text, appName: appName)
                Log.write("selection: grabbed \(text.count) chars from \(appName)")
            }
            if !self.panel.isVisible { self.togglePanel() }
        }

        // Panel opacity follows the settings slider, live.
        panel.alphaValue = AppSettings.shared.panelOpacity
        AppSettings.shared.$panelOpacity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] opacity in
                self?.panel.animator().alphaValue = opacity
            }
            .store(in: &cancellables)

        // Menu bar icon reflects streaming state.
        UNUserNotificationCenter.current().delegate = self
        manager.$anyStreaming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] streaming in
                self?.statusItem.button?.image = NSImage(
                    systemSymbolName: streaming ? "sparkles" : "sparkle.magnifyingglass",
                    accessibilityDescription: "Cantrip")
            }
            .store(in: &cancellables)

        // Sessions, the CLI socket, Remote and Cantrip Home; the panel and menus are added here.
        services.onRunFinished = { [weak self] finished in self?.notifyIfHidden(for: finished) }
        services.onRemoteControlEnabledChange = { [weak self] enabled in
            self?.remoteControlMenuItem?.state = enabled ? .on : .off
        }
        services.start(recoveryReport: recoveryReport)
        // The tab on screen in the panel counts as seen for the badge on paired iPhones.
        services.remoteControlServer?.isOnScreen = { [weak self] id in
            guard let self else { return false }
            return !self.usesHomeWindow && self.panel.isVisible && self.manager.active.id == id
        }
        manager.$activeIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.markActiveTabSeen() }
            .store(in: &cancellables)

        // Local key monitor: ⌘V image-paste, and ⌘←/⌘→ cursor jumps
        // (borderless panels don't always deliver ⌘-arrows to the editor).
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.panel.isKeyWindow,
                  event.modifierFlags.contains(.command) else { return event }

            // ⌘← / ⌘→: with text in the field → jump cursor to start/end
            // (⇧ extends selection); with an empty field → switch tabs.
            if event.keyCode == 123 || event.keyCode == 124 {
                let editor = self.panel.firstResponder as? NSTextView
                if let editor, !editor.string.isEmpty {
                    let shift = event.modifierFlags.contains(.shift)
                    switch (event.keyCode, shift) {
                    case (123, false): editor.moveToBeginningOfDocument(nil)
                    case (123, true): editor.moveToBeginningOfDocumentAndModifySelection(nil)
                    case (124, false): editor.moveToEndOfDocument(nil)
                    default: editor.moveToEndOfDocumentAndModifySelection(nil)
                    }
                } else {
                    event.keyCode == 123 ? self.manager.selectPrevious()
                                         : self.manager.selectNext()
                }
                return nil // consumed
            }

            // ⌘V with an image on the clipboard → attach it.
            if !self.manager.showingRemote,
               event.charactersIgnoringModifiers?.lowercased() == "v",
               let path = ImagePasteboard.capture() {
                self.manager.active.attachments.append(path)
                return nil // consumed
            }
            return event
        }

        AppSettings.shared.refreshLaunchAtLoginRegistrationIfNeeded()
        if recoveryReport != nil {
            DispatchQueue.main.async { [weak self] in self?.showPanel() }
        }
        services.continueRestoredWork()
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.stop()
    }

    @objc func stopRequest() {
        guard !manager.showingRemote else { return }
        manager.active.cancel()
    }

    @objc func toggleRemoteControlDaemon() {
        AppSettings.shared.remoteControlEnabled.toggle()
    }

    @objc func exportSettings() {
        AppSettings.shared.exportDotfile()
    }

    @objc func importSettings() {
        AppSettings.shared.importDotfile()
    }

    @objc func resetPanelSize() {
        PanelMetrics.shared.clearUserSize()
        LauncherPanel.clearUserPosition()
        for key in ["councilPaneUserWidth", "settingsPaneUserWidth",
                    "stepsPaneUserWidth", "pluginPaneUserWidth"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        panel.center(onActiveScreen: true)
    }

    @objc func newSessionAction() {
        manager.newSession()
        if !panel.isVisible { togglePanel() }
    }

    @objc func closeCurrentSession() {
        manager.closeSelectedTab()
    }

    @objc func selectPreviousSession() {
        manager.selectPrevious()
    }

    @objc func selectNextSession() {
        manager.selectNext()
    }

    private func notifyIfHidden(for finished: ChatSession) {
        // Notify if the panel is hidden OR the finished session isn't the
        // one on screen (background session completed).
        guard !panel.isVisible || finished.id != manager.active.id else { return }
        let preview = finished.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text
            ?? finished.messages.last(where: { $0.role == .error })?.text
            ?? "Response ready"
        let title = finished.notificationTitle
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Cantrip — \(title)"
            content.body = RemoteCompletion.summaryPreview(preview) ?? String(preview.prefix(160))
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let raw = response.notification.request.content.userInfo["sessionID"] as? String,
               let id = UUID(uuidString: raw), manager.sessions.contains(where: { $0.id == id }) {
                manager.select(id)
            }
            if !panel.isVisible { togglePanel() }
        }
        completionHandler()
    }

    @objc func endRemoteView() {
        RemoteDesktop.shared.stop()
    }

    @objc func newConversation() {
        guard !manager.showingRemote else { return }
        manager.active.newConversation()
    }

    @objc func forceHide() {
        if !manager.showingRemote {
            manager.active.cancel()
        }
        OverlayController.shared.clear()
        panel.keepVisibleWhileUnfocused = false
        panel.orderOut(nil)
    }

    @objc func togglePanel() {
        if usesHomeWindow {
            toggleHomeWindow()
            return
        }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        ScreenCapture.shared.captureNow()  // before the panel covers the screen
        LocationProvider.shared.refresh()  // no-op unless enabled in settings
        CalendarProvider.shared.refresh()  // cached 15 min; no-op if disabled
        UpdateChecker.shared.checkIfDue()
        NSApp.activate(ignoringOtherApps: true)
        panel.center(onActiveScreen: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        manager.active.focusRequested = true
        markActiveTabSeen()
        Log.write("showPanel: frame=\(panel.frame), visible=\(panel.isVisible), key=\(panel.isKeyWindow), screen=\(NSScreen.main?.visibleFrame ?? .zero)")
    }

    private func hidePanel() {
        panel.orderOut(nil)
    }

    /// The panel shows this tab: its alerts stop counting toward the app icon's badge.
    private func markActiveTabSeen() {
        guard !usesHomeWindow, panel.isVisible else { return }
        services.remoteControlServer?.markSeen(manager.active.id)
    }

    // MARK: - Home window (Window interface)

    private var usesHomeWindow: Bool {
        AppSettings.shared.interfaceMode == .window && HomeWindow.isAvailable
    }

    private func toggleHomeWindow() {
        if HomeWindow.isOpen, NSApp.isActive {
            HomeWindow.close()
        } else {
            openHomeWindow()
        }
    }

    /// Opens the Home window on this host's own server (loopback), hiding the panel.
    @objc func openHomeWindow() {
        guard HomeWindow.isAvailable else {
            presentHomeWindowUnavailable()
            return
        }
        guard let token = AppSettings.shared.ensureRemoteControlToken() else {
            Log.write("home-window: no server token")
            return
        }
        hidePanel()
        HomeWindow.open(port: AppSettings.shared.remoteControlPort, token: token) {}
    }

    @objc func chooseInterface(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = InterfaceMode(rawValue: raw) else { return }
        if mode == .window, !HomeWindow.isAvailable {
            presentHomeWindowUnavailable()
            return
        }
        AppSettings.shared.interfaceMode = mode
    }

    /// Switching interface opens the one picked and puts the other away.
    private func applyInterfaceMode(_ mode: InterfaceMode) {
        panelInterfaceMenuItem?.state = mode == .panel ? .on : .off
        windowInterfaceMenuItem?.state = mode == .window ? .on : .off
        openHomeWindowMenuItem?.isHidden = !HomeWindow.isAvailable
        guard didApplyInterface else {
            didApplyInterface = true
            return
        }
        if mode == .window, HomeWindow.isAvailable {
            // After the server has picked up the change (its settings are debounced).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.openHomeWindow() }
        } else {
            HomeWindow.close()
        }
    }
    private var didApplyInterface = false

    private func presentHomeWindowUnavailable() {
        let alert = NSAlert()
        alert.messageText = "The Home window isn't available"
        alert.informativeText = HomeWindow.unavailableReason ?? ""
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Opening Cantrip.app again (Finder, Spotlight, the Dock while the window is up) shows the
    /// interface: the Home window in the Window interface.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if usesHomeWindow { openHomeWindow() }
        return false
    }
}
