import AppKit
import ApplicationServices
import Carbon.HIToolbox

struct SelectionContext: Equatable {
    let text: String
    let appName: String
}

/// Grabs the selected text from the frontmost app. Tries the Accessibility
/// API first (no clipboard involvement); falls back to simulating ⌘C and
/// restoring the clipboard afterwards. Requires the Accessibility grant
/// (prompted on first use).
enum SelectionGrabber {
    static func grab() -> String? {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            Log.write("selection: Accessibility not granted — prompted")
            return nil
        }
        if let text = axSelectedText(), !text.isEmpty { return text }
        return copySimulatedSelection()
    }

    private static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedObj: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focusedObj) == .success,
              let focused = focusedObj else { return nil }
        var selObj: AnyObject?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement,
                                            kAXSelectedTextAttribute as CFString,
                                            &selObj) == .success else { return nil }
        return selObj as? String
    }

    private static func copySimulatedSelection() -> String? {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        let previousChange = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Wait briefly for the copy to land.
        for _ in 0..<20 {
            usleep(20_000)
            if pb.changeCount != previousChange { break }
        }
        guard pb.changeCount != previousChange else { return nil }
        let text = pb.string(forType: .string)

        // Put the user's clipboard back.
        if let previous {
            pb.clearContents()
            pb.setString(previous, forType: .string)
        }
        return text
    }
}
