import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panel: LauncherPanel!
    private var hotkey: HotkeyManager!
    private var selectionHotkey: HotkeyManager!
    private var pasteMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private let manager = SessionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Main menu: invisible for accessory apps, but REQUIRED for standard
        // keyboard shortcuts (⌘C/⌘V/⌘X/⌘A/⌘Z) to route to the text field.
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "New Conversation", action: #selector(newConversation), keyEquivalent: "n")
        appMenu.addItem(withTitle: "New Session", action: #selector(newSessionAction), keyEquivalent: "t")
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
        menu.addItem(withTitle: "Stop Current Request", action: #selector(stopRequest), keyEquivalent: "")
        menu.addItem(withTitle: "Hide Panel & Overlays", action: #selector(forceHide), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cantrip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // Floating panel
        panel = LauncherPanel()
        panel.install(LauncherView(
            manager: manager,
            onDismiss: { [weak self] in self?.hidePanel() },
            onSizeChange: { [weak self] size in
                // Defer: resizing the window inside SwiftUI's layout pass
                // causes layout recursion and a blank (invisible) panel.
                DispatchQueue.main.async { self?.panel.resizeContent(to: size) }
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

        // Notify when any session's run finishes while the panel is hidden.
        manager.onAnyRunFinished = { [weak self] finished in
            self?.notifyIfHidden(for: finished)
        }

        // Unix-socket server for the `cantrip` CLI.
        CLIServer.shared.start()

        // Daily memory consolidation, off the launch path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            Consolidator.runIfDue()
        }

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
            if event.charactersIgnoringModifiers?.lowercased() == "v",
               let path = ImagePasteboard.capture() {
                self.manager.active.attachments.append(path)
                return nil // consumed
            }
            return event
        }
    }

    @objc func stopRequest() {
        manager.active.cancel()
    }

    @objc func exportSettings() {
        AppSettings.shared.exportDotfile()
    }

    @objc func importSettings() {
        AppSettings.shared.importDotfile()
    }

    @objc func newSessionAction() {
        manager.newSession()
        if !panel.isVisible { togglePanel() }
    }

    @objc func closeCurrentSession() {
        manager.close(manager.activeIndex)
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
        let title = finished.title
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Cantrip — \(title)"
            content.body = String(preview.prefix(160))
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
            if !panel.isVisible { togglePanel() }
        }
        completionHandler()
    }

    @objc func newConversation() {
        manager.active.newConversation()
    }

    @objc func forceHide() {
        manager.active.cancel()
        OverlayController.shared.clear()
        panel.keepVisibleWhileUnfocused = false
        panel.orderOut(nil)
    }

    @objc func togglePanel() {
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
        Log.write("showPanel: frame=\(panel.frame), visible=\(panel.isVisible), key=\(panel.isKeyWindow), screen=\(NSScreen.main?.visibleFrame ?? .zero)")
    }

    private func hidePanel() {
        panel.orderOut(nil)
    }
}
