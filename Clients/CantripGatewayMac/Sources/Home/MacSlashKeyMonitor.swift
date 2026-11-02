import AppKit
import SwiftUI

/// Routes Up/Down, Tab, Return and Escape to the composer's "/" suggestions while they show. Only
/// unmodified keys in this window are taken, so Option-Return still adds a new line, Shift-Tab
/// still moves focus, and text being composed with an input method keeps its keys.
struct MacSlashKeyMonitor: NSViewRepresentable {
    var isActive: Bool
    /// Returns true when the list used the key; false lets the text field handle it as usual.
    var onKey: (BackendSlashKey) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onKey = onKey
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.setActive(false)
    }

    static func key(for event: NSEvent) -> BackendSlashKey? {
        guard event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else { return nil }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 48: return .tab
        case 36, 76: return .return
        case 53: return .escape
        default: return nil
        }
    }

    /// Puts the insertion point after text the list inserted, instead of selecting it all.
    static func moveInsertionPointToEnd() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    final class MonitorView: NSView {
        var onKey: ((BackendSlashKey) -> Bool)?
        private var monitor: Any?

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let window = self.window, event.window === window,
                          !((window.firstResponder as? NSTextView)?.hasMarkedText() ?? false),
                          let key = MacSlashKeyMonitor.key(for: event) else { return event }
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

/// Reports the composer's caret as a UTF-16 offset (-1 while a range is selected) from its text
/// view's selection changes, while the composer has focus. Read-only: it never moves the caret.
struct MacComposerCaretObserver: NSViewRepresentable {
    var isActive: Bool
    var onChange: (Int?) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.setActive(false)
    }

    /// Puts the insertion point at `offset` once the text the app just set has reached the field.
    static func moveInsertionPoint(to offset: Int) {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let length = (editor.string as NSString).length
            editor.setSelectedRange(NSRange(location: min(offset, length), length: 0))
        }
    }

    final class ObserverView: NSView {
        var onChange: ((Int?) -> Void)?
        private var observer: NSObjectProtocol?

        func setActive(_ active: Bool) {
            if active, observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main
                ) { [weak self] note in
                    guard let self, let editor = note.object as? NSTextView, let window = self.window,
                          editor.window === window, window.firstResponder === editor else { return }
                    let range = editor.selectedRange()
                    MainActor.assumeIsolated { self.onChange?(range.length == 0 ? range.location : -1) }
                }
            } else if !active, let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { setActive(false) }
        }
    }
}
