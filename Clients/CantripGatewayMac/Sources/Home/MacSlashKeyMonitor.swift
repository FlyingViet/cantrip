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
