import AppKit
import SwiftUI

/// The parts of Cantrip's ⌥Space panel that belong to the Mac you're at, while the panel is the
/// Home window's chat inside Cantrip.app (`CantripHomeWindowPlugin`'s panel): apps and files
/// matching what you type, and the text you had selected and the screenshots Cantrip took as the
/// panel opened. Cantrip.app answers the searches and supplies the context; a message to this Mac
/// carries the context as `macContext`, to another Mac the selection goes as text.
/// The Home window (and Gateway Mac) use `inactive`, which never shows anything.
@MainActor
final class MacPanelLauncher: ObservableObject {
    static let inactive = MacPanelLauncher()

    struct Suggestion: Identifiable, Equatable {
        enum Kind: String { case app, file }

        let id: String
        let kind: Kind
        let title: String
        var subtitle: String?
        /// "open" or "switch" for an app, shown on its Return key cap.
        var action: String?
        var icon: NSImage?
    }

    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var selection: CantripMacContext.Selection?
    @Published private(set) var screenshots: [CantripMacContext.Screenshot] = []
    /// The screenshots chip was removed: this opening's messages go without them.
    @Published private(set) var screenshotsRemoved = false
    /// Escape hid the suggestions for this text.
    @Published private(set) var dismissedQuery: String?
    /// Bumped each time the panel opens: the composer takes focus and searches its text again.
    @Published private(set) var opening = 0

    /// Cantrip.app's search (apps and files for the text), and what it opens.
    var onQuery: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    /// The text the suggestions are for; nil after the panel hid, so the same text searches again.
    private var lastQuery: String?

    var isActive: Bool { onQuery != nil }

    /// The top app match, which Return opens (⌘Return still asks).
    var appSuggestion: Suggestion? { suggestions.first { $0.kind == .app } }
    var fileSuggestions: [Suggestion] { suggestions.filter { $0.kind == .file } }

    /// Typing: an empty query clears the list.
    func query(_ text: String) {
        guard isActive, text != lastQuery else { return }
        lastQuery = text
        if dismissedQuery != text { dismissedQuery = nil }
        onQuery?(text)
    }

    func dismissSuggestions() {
        dismissedQuery = lastQuery
    }

    func beginOpening() {
        opening += 1
    }

    /// The panel hid: nothing stays listed for text typed before.
    func reset() {
        suggestions = []
        lastQuery = nil
        dismissedQuery = nil
    }

    func open(_ suggestion: Suggestion) {
        onOpen?(suggestion.id)
    }

    /// Whether the list shows for this text: Cantrip's answer is for it and Escape didn't hide it.
    func showsSuggestions(for text: String) -> Bool {
        isActive && !suggestions.isEmpty && text == lastQuery && dismissedQuery != text
    }

    func setSuggestions(_ list: [Suggestion]) {
        suggestions = list
    }

    /// A new opening of the panel: its selection (⌥⇧Space) and screenshots.
    func setContext(selection: CantripMacContext.Selection?, screenshots: [CantripMacContext.Screenshot],
                    newOpening: Bool) {
        if newOpening {
            screenshotsRemoved = false
            self.selection = selection
        } else if let selection {
            self.selection = selection
        }
        self.screenshots = screenshots
    }

    func removeSelection() { selection = nil }
    func removeScreenshots() { screenshotsRemoved = true }

    var attachedScreenshots: [CantripMacContext.Screenshot] { screenshotsRemoved ? [] : screenshots }

    /// The context for the message being sent: the selection goes once (`didSend`); the
    /// screenshots stay with every message of this opening, as the panel's did. Nil outside the panel.
    var pendingContext: CantripMacContext? {
        guard isActive else { return nil }
        return CantripMacContext(selection: selection, screenshots: attachedScreenshots)
    }

    /// A message took the selection that was pending when it was sent.
    func didSend(_ context: CantripMacContext?) {
        if let sent = context?.selection, sent == selection { selection = nil }
    }

    /// From Cantrip.app: `{selection: {text, appName}?, screenshots: [{path, index, isMain}]}`.
    static func context(from dictionary: [String: Any]) -> (CantripMacContext.Selection?, [CantripMacContext.Screenshot]) {
        var selection: CantripMacContext.Selection?
        if let raw = dictionary["selection"] as? [String: Any], let text = raw["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selection = .init(text: text, appName: (raw["appName"] as? String) ?? "the frontmost app")
        }
        let screenshots = ((dictionary["screenshots"] as? [[String: Any]]) ?? []).compactMap { item -> CantripMacContext.Screenshot? in
            guard let path = item["path"] as? String, let index = item["index"] as? Int else { return nil }
            return .init(path: path, index: index, isMain: (item["isMain"] as? Bool) ?? (index == 1))
        }
        return (selection, screenshots)
    }

    /// From Cantrip.app: `[{id, kind: app|file, title, subtitle?, action?, icon?: NSImage}]`.
    static func suggestions(from list: [[String: Any]]) -> [Suggestion] {
        list.compactMap { item in
            guard let id = item["id"] as? String, let title = item["title"] as? String,
                  let kind = (item["kind"] as? String).flatMap(Suggestion.Kind.init(rawValue:)) else { return nil }
            return Suggestion(id: id, kind: kind, title: title, subtitle: item["subtitle"] as? String,
                              action: item["action"] as? String, icon: item["icon"] as? NSImage)
        }
    }
}

/// The selected text and screenshots going with the next message, each removable.
struct MacPanelContextChips: View {
    @ObservedObject var launcher: MacPanelLauncher

    var body: some View {
        let shots = launcher.attachedScreenshots
        if launcher.selection != nil || !shots.isEmpty {
            HStack(spacing: 8) {
                if let selection = launcher.selection {
                    chip(icon: "text.quote",
                         text: "Selected text from \(selection.appName)",
                         help: String(selection.text.prefix(600)),
                         remove: launcher.removeSelection)
                        .accessibilityIdentifier("panel.context.selection")
                }
                if !shots.isEmpty {
                    chip(icon: "macwindow",
                         text: shots.count == 1 ? "Screen" : "\(shots.count) screens",
                         help: "Screenshots taken as the panel opened go with your messages (Settings › Attach screen).",
                         remove: launcher.removeScreenshots)
                        .accessibilityIdentifier("panel.context.screen")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(icon: String, text: String, help: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption).accessibilityHidden(true)
            Text(text).font(.caption).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .help(help)
    }
}

/// Apps and files matching the text: Return opens the app, ⌘Return asks Cantrip instead; a file
/// opens when clicked.
struct MacPanelSuggestionList: View {
    @ObservedObject var launcher: MacPanelLauncher
    var maxHeight: CGFloat
    var onOpen: (MacPanelLauncher.Suggestion) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let app = launcher.appSuggestion {
                    Button { onOpen(app) } label: {
                        HStack(spacing: 10) {
                            icon(app, size: 24)
                            Text(app.title).font(.body)
                            Spacer(minLength: 8)
                            keycap("↩", app.action ?? "open")
                            keycap("⌘↩", "ask instead")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("panel.suggestion.app")
                }
                ForEach(launcher.fileSuggestions) { file in
                    Button { onOpen(file) } label: {
                        HStack(spacing: 8) {
                            icon(file, size: 18)
                            Text(file.title).font(.callout).lineLimit(1)
                            if let subtitle = file.subtitle {
                                Text(subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(file.subtitle.map { "Open \($0)/\(file.title)" } ?? "Open \(file.title)")
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("panel.suggestions")
    }

    @ViewBuilder private func icon(_ suggestion: MacPanelLauncher.Suggestion, size: CGFloat) -> some View {
        if let image = suggestion.icon {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: suggestion.kind == .app ? "app" : "doc").frame(width: size, height: size)
        }
    }

    private func keycap(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.caption.monospaced())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Return, ⌘Return and Escape in the panel's composer while an app suggestion shows.
struct MacPanelKeyMonitor: NSViewRepresentable {
    enum Key { case open, ask, dismiss }

    var isActive: Bool
    var onKey: (Key) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onKey = onKey
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.setActive(false)
    }

    static func key(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Key? {
        let flags = modifiers.intersection([.shift, .control, .option, .command])
        switch keyCode {
        case 36, 76: return flags.isEmpty ? .open : flags == .command ? .ask : nil
        case 53: return flags.isEmpty ? .dismiss : nil
        default: return nil
        }
    }

    final class MonitorView: NSView {
        var onKey: ((Key) -> Bool)?
        private var monitor: Any?

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let window = self.window, event.window === window,
                          !((window.firstResponder as? NSTextView)?.hasMarkedText() ?? false),
                          let key = MacPanelKeyMonitor.key(keyCode: event.keyCode, modifiers: event.modifierFlags)
                    else { return event }
                    return self.onKey?(key) == true ? nil : event
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { setActive(false) }
        }
    }
}
