import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

/// Cantrip.app as the background engine's client ("Keep agents running when Cantrip quits"): the
/// menu bar item, ⌥Space and the Home and Settings windows, on the engine's loopback server. The
/// engine (`BackgroundEngine`, `HeadlessHost`) owns tabs, Cantrip Home and paired devices, so
/// quitting or updating the app leaves them running. ⌥Space opens the panel: the Home window's
/// chat in a floating panel (the plug-in's), with this Mac's apps and files (`PanelSearch`), the
/// selected text (⌥⇧Space) and screenshots. With Interface set to Window it opens the Home window.
@MainActor
final class ClientAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var loginItemsMenuItem: NSMenuItem!
    private var panelMenuItem: NSMenuItem!
    private var homeMenuItem: NSMenuItem!
    private var hotkey: HotkeyManager?
    private var selectionHotkey: HotkeyManager?
    /// What goes with the panel's messages from this opening: the selection and screenshots.
    private var panelContext: [String: Any] = [:]
    /// Bumped per opening, so late screenshots never land in a later one.
    private var panelOpening = 0
    /// The panel has this opening's context (later changes go to it as updates).
    private var panelContextDelivered = false
    private var timer: Timer?
    private var connection: BackgroundEngine.Connection?
    private var outbox: String?
    private var cursor: Int?
    private var syncing = false
    private var switching = false
    private var lastStart: Date?
    private var loggedWaiting = false
    private var settingsOpen = false
    /// A window asked for before the engine answered, and when.
    private var pendingOpen: (window: Window, at: Date)?

    private enum Window { case home, settings, panel }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        hotkey = HotkeyManager { [weak self] in self?.toggleMainSurface() }
        // ⌥⇧Space: the panel with the frontmost app's selected text attached.
        selectionHotkey = HotkeyManager(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey),
                                        id: 2) { [weak self] in self?.openPanelWithSelection() }
        UNUserNotificationCenter.current().delegate = self
        AppSettings.shared.refreshLaunchAtLoginRegistrationIfNeeded()
        Log.write("client: Cantrip.app is the background agents' window, pid \(getpid()), build \(CrashRecovery.buildIdentity)")
        let arguments = CommandLine.arguments
        if arguments.contains(BackgroundEngine.openSettingsArgument) {
            openSettingsWindow()
        } else if arguments.contains(BackgroundEngine.openHomeArgument) {
            openHomeWindow()
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.write(switching ? "client: quit to reopen" : "client: quit; the background agents keep running")
    }

    /// Opening Cantrip again (Finder, Spotlight) shows the Home window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHomeWindow()
        return false
    }

    // MARK: - Menus

    private func buildMenus() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("Open Home Window", #selector(openHomeWindow), key: "0"))
        appMenu.addItem(item("Settings…", #selector(openSettingsWindow), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cantrip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Required for ⌘C/⌘V/⌘X/⌘A/⌘Z in the windows' text fields (accessory apps show no menu bar).
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

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.mainMenu = mainMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Cantrip")
        let menu = NSMenu()
        menu.delegate = self
        panelMenuItem = item("Open Panel (⌥Space)", #selector(openPanelFromMenu))
        menu.addItem(panelMenuItem)
        homeMenuItem = item("Open Home Window", #selector(openHomeWindow))
        menu.addItem(homeMenuItem)
        menu.addItem(item("Settings…", #selector(openSettingsWindow)))
        menu.addItem(.separator())
        statusLine = NSMenuItem(title: "Starting the background agents…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        loginItemsMenuItem = item("Open Login Items Settings…", #selector(openLoginItemsSettings))
        loginItemsMenuItem.isHidden = true
        menu.addItem(loginItemsMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cantrip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let panel = usesPanel
        panelMenuItem.isHidden = !panel
        homeMenuItem.title = panel ? "Open Home Window" : "Open Home Window (⌥Space)"
    }

    private func setStatus(_ text: String, needsApproval: Bool = false) {
        statusLine.title = text
        loginItemsMenuItem.isHidden = !needsApproval
    }

    // MARK: - Windows

    /// ⌥Space: the panel, unless Interface is Window (read fresh: the engine saves Settings).
    private var usesPanel: Bool {
        let mode = InterfaceMode(rawValue: UserDefaults.standard.string(forKey: "interfaceMode") ?? "") ?? .panel
        return mode == .panel && HomeWindow.supportsPanel
    }

    private func toggleMainSurface() {
        if usesPanel { togglePanel() } else { toggleHomeWindow() }
    }

    private func toggleHomeWindow() {
        if HomeWindow.isOpen, NSApp.isActive {
            HomeWindow.close()
        } else {
            openHomeWindow()
        }
    }

    /// Like Cantrip's own panel: ⌥Space puts a visible panel away (it floats above every app, and
    /// takes the keyboard without making Cantrip the active app).
    private func togglePanel() {
        if HomeWindow.isPanelOpen {
            HomeWindow.closePanel()
        } else {
            openPanel(selection: nil)
        }
    }

    @objc func openPanelFromMenu() {
        openPanel(selection: nil)
    }

    private func openPanelWithSelection() {
        guard usesPanel else {
            openHomeWindow()
            return
        }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the frontmost app"
        var selection: [String: String]?
        if let text = SelectionGrabber.grab(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selection = ["text": text, "appName": appName]
            Log.write("selection: grabbed \(text.count) chars from \(appName)")
        }
        if HomeWindow.isPanelOpen, let selection {
            // Already up: the selection joins this opening.
            panelContext["selection"] = selection
            deliverPanelContext()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openPanel(selection: selection)
    }

    /// A new opening: screenshots first (before the panel covers the screen), then the panel.
    private func openPanel(selection: [String: String]?) {
        guard !HomeWindow.isPanelOpen else {
            open(.panel)
            return
        }
        panelOpening += 1
        let opening = panelOpening
        panelContextDelivered = false
        panelContext = ["screenshots": [[String: Any]]()]
        if let selection { panelContext["selection"] = selection }
        ScreenCapture.shared.captureNow(attachScreen: UserDefaults.standard.bool(forKey: "attachScreen")) { [weak self] captures in
            guard let self, opening == self.panelOpening else { return }
            self.panelContext["screenshots"] = captures.map { ["path": $0.path, "index": $0.index, "isMain": $0.isMain] }
            if self.panelContextDelivered { self.deliverPanelContext() }
        }
        open(.panel)
    }

    /// The opening's context, or an update to it once the panel has it.
    private func deliverPanelContext() {
        var context = panelContext
        context["newOpening"] = !panelContextDelivered
        if HomeWindow.isPanelOpen || !panelContextDelivered { HomeWindow.setPanelContext(context) }
    }

    @objc func openHomeWindow() {
        open(.home)
    }

    @objc func openSettingsWindow() {
        open(.settings)
    }

    private func open(_ window: Window) {
        guard let connection else {
            // Opens once the engine answers (`tick`).
            pendingOpen = (window, pendingOpen?.at ?? Date())
            tick()
            return
        }
        pendingOpen = nil
        NSApp.activate(ignoringOtherApps: true)
        switch window {
        case .panel:
            var context = panelContext
            context["newOpening"] = !panelContextDelivered
            HomeWindow.openPanel(port: connection.port, token: connection.token, context: context) {}
            panelContextDelivered = true
        case .home: HomeWindow.open(port: connection.port, token: connection.token) {}
        case .settings:
            settingsOpen = true
            HomeWindow.openSettings(port: connection.port, token: connection.token) { [weak self] in self?.settingsOpen = false }
        }
    }

    @objc func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - The engine

    /// Every 2 seconds: start the engine if it isn't running, follow its connection, post its
    /// notifications, and switch back to running agents in the app once the setting is off.
    private func tick() {
        guard !switching, !syncing else { return }
        guard BackgroundEngine.runningPID != nil else {
            connection = nil
            if !BackgroundEngine.isEnabled {
                switchToHost(openHome: HomeWindow.isOpen, openSettings: settingsOpen)
                return
            }
            startEngineIfDue()
            failPendingOpenIfStale()
            return
        }
        syncing = true
        let after = cursor, outbox = outbox
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try BackgroundEngine.sync(after: after, outbox: outbox) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.syncing = false
                    self.apply(result)
                }
            }
        }
    }

    private func apply(_ result: Result<BackgroundEngine.Sync, Error>) {
        let sync: BackgroundEngine.Sync
        switch result {
        case .failure(let error):
            // Starting up (it takes the host lock before its socket listens), or restarting.
            if connection != nil || !loggedWaiting {
                Log.write("client: the background agents didn't answer: \(error.localizedDescription)")
            }
            loggedWaiting = true
            connection = nil
            setStatus("Waiting for the background agents…")
            failPendingOpenIfStale()
            return
        case .success(let value):
            sync = value
        }
        if sync.connection != connection {
            let reconnect = connection != nil
            connection = sync.connection
            HomeWindow.localKey = sync.connection.localKey
            if reconnect || HomeWindow.isOpen { HomeWindow.refresh(port: sync.connection.port, token: sync.connection.token) }
            Log.write("client: connected to the background agents, pid \(sync.connection.pid), build \(sync.connection.build)")
        }
        BackgroundEngine.lastError = nil
        post(sync.notices)
        outbox = sync.outbox
        cursor = sync.seq
        if let pending = pendingOpen { open(pending.window) }

        if !sync.enabled {
            // Turned off in Settings: hand the tabs back to the app once nothing is working.
            setStatus(sync.busy > 0 ? "Turning off once nothing is working (\(sync.busy) working)…" : "Turning off…")
            if sync.busy == 0 { switchToHost(openHome: HomeWindow.isOpen, openSettings: settingsOpen) }
            return
        }
        setStatus(sync.busy > 0 ? "Agents run in the background · \(sync.busy) working" : "Agents run in the background")

        // The engine installed an update over this app's bundle: reopen into it while nobody is
        // using the windows.
        if PendingUpdate.launchedExecutableReplaced(), !NSApp.isActive {
            switching = true
            Log.write("client: Cantrip.app was updated; reopening it")
            BackgroundEngine.relaunchApp(opening: HomeWindow.isOpen ? BackgroundEngine.openHomeArgument : nil)
        }
    }

    private func startEngineIfDue() {
        if let lastStart, Date().timeIntervalSince(lastStart) < 10 { return }
        lastStart = Date()
        if let holder = HostLock.holder() {
            // `cantrip daemon run`, or Cantrip from another copy of the app.
            setStatus("Cantrip is already running (pid \(holder.pid)); quit it to use the background agents")
            return
        }
        do {
            try BackgroundEngine.start()
            BackgroundEngine.lastError = nil
            setStatus("Starting the background agents…")
        } catch {
            let message = error.localizedDescription
            BackgroundEngine.lastError = message
            setStatus(message, needsApproval: message.contains(BackgroundEngine.approvalMessage))
            Log.write("client: \(message)")
        }
    }

    private func failPendingOpenIfStale() {
        guard let pending = pendingOpen, Date().timeIntervalSince(pending.at) > 20 else { return }
        pendingOpen = nil
        let alert = NSAlert()
        alert.messageText = "Cantrip's background agents aren't answering"
        alert.informativeText = BackgroundEngine.lastError ?? statusLine.title
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Stops the engine and reopens Cantrip, which then runs the agents itself.
    private func switchToHost(openHome: Bool, openSettings: Bool) {
        switching = true
        Log.write("client: background agents are off; stopping the engine and reopening Cantrip to run them")
        setStatus("Turning off the background agents…")
        BackgroundEngine.stop()
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<40 where BackgroundEngine.runningPID != nil { usleep(250_000) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    BackgroundEngine.relaunchApp(opening: openSettings ? BackgroundEngine.openSettingsArgument
                                                 : openHome ? BackgroundEngine.openHomeArgument : nil)
                }
            }
        }
    }

    // MARK: - Notifications

    private func post(_ notices: [(seq: Int, entry: MacNoticeOutbox.Entry)]) {
        if !notices.isEmpty { Log.write("client: \(notices.count) notification update(s) from the background agents") }
        for (_, entry) in notices {
            switch entry {
            case .post(let notice):
                // A finished run in the window in front of you needs no banner.
                if notice.runFinished, NSApp.isActive, HomeWindow.isOpen { continue }
                MacNotices.show(notice)
            case .remove(let ids):
                MacNotices.withdraw(ids)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in self?.openHomeWindow() }
        completionHandler()
    }
}
