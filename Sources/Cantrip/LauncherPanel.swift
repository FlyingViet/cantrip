import AppKit
import SwiftUI

/// Borderless floating panel that behaves like Spotlight:
/// centered, floats above everything, dismisses on Esc / losing focus.
/// The window is resized explicitly (keeping its top edge fixed) as the
/// SwiftUI content grows/shrinks — see `resizeContent(to:)`.
final class LauncherPanel: NSPanel {
    static let panelWidth: CGFloat = 680
    static let maxPanelHeight: CGFloat = 760

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 90),
                   styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        // NOTE: not using hidesOnDeactivate — it races with app activation
        // when showing from a global hotkey (panel gets hidden instantly on
        // first press). Instead, dismiss when the panel loses key status.
        hidesOnDeactivate = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.keepVisibleWhileUnfocused else { return }
            self.orderOut(nil)
        }
    }

    /// While true (pinned, or a response is streaming), losing focus
    /// does NOT dismiss the panel — it persists as an overlay.
    var keepVisibleWhileUnfocused = false

    /// Install the SwiftUI root view. sizingOptions is emptied so the hosting
    /// view never fights our manual window sizing.
    func install<Content: View>(_ rootView: Content) {
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = contentLayoutRect
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        OverlayController.shared.clear()
        orderOut(nil) // Esc closes
    }

    /// The screen the panel should live on: the one it's already on, else
    /// the one containing the mouse. Never NSScreen.main, which follows
    /// keyboard focus and made the panel wander between displays.
    private var targetScreen: NSScreen? {
        if let current = screen { return current }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.screens.first
    }

    /// Resize to fit content, keeping the top edge and horizontal center
    /// fixed and never extending past the edges of the screen.
    func resizeContent(to size: CGSize) {
        let screenFrame = targetScreen?.visibleFrame
        let maxHeight = min(Self.maxPanelHeight,
                            (screenFrame?.height ?? Self.maxPanelHeight) * 0.9)
        let newHeight = max(60, min(size.height, maxHeight))
        let newWidth = max(Self.panelWidth,
                           min(size.width, (screenFrame?.width ?? size.width) * 0.95))
        Log.write("resizeContent: requested=\(size), clamped=(\(newWidth), \(newHeight)), current=\(frame)")
        guard abs(newHeight - frame.height) > 0.5 || abs(newWidth - frame.width) > 0.5 else { return }
        var f = frame
        let top = f.maxY
        let midX = f.midX
        f.size = NSSize(width: newWidth, height: newHeight)
        f.origin.x = midX - newWidth / 2
        f.origin.y = top - newHeight
        if let screenFrame {
            f.origin.y = max(f.origin.y, screenFrame.minY)
            f.origin.x = min(max(f.origin.x, screenFrame.minX),
                             screenFrame.maxX - newWidth)
        }
        setFrame(f, display: true)
    }

    /// Position like Spotlight: horizontally centered, top edge in the
    /// upper third of the screen the mouse is on.
    func center(onActiveScreen: Bool) {
        // Deliberately mouse-based (not the panel's last screen): summoning
        // should appear where you're working right now.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let sf = screen.visibleFrame
        let x = sf.midX - frame.width / 2
        let top = sf.minY + sf.height * 0.72
        setFrameOrigin(NSPoint(x: x, y: top - frame.height))
    }
}
