import AppKit
import SwiftUI

/// Borderless floating panel that behaves like Spotlight:
/// centered, floats above everything, dismisses on Esc / losing focus.
/// The window is resized explicitly (keeping its top edge fixed) as the
/// SwiftUI content grows/shrinks — see `resizeContent(to:)`.
final class LauncherPanel: NSPanel {
    static let panelWidth: CGFloat = 680
    static let userResizedNotification = Notification.Name("CantripPanelUserResized")
    static let userResizingNotification = Notification.Name("CantripPanelUserResizing")
    static let maxPanelHeight: CGFloat = 880

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 90),
                   styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel,
                               .resizable],
                   backing: .buffered,
                   defer: false)
        minSize = NSSize(width: 600, height: 120)

        // Stream drag-resize ticks so the layout follows the mouse live…
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.inLiveResize else { return }
            NotificationCenter.default.post(name: Self.userResizingNotification,
                                            object: nil,
                                            userInfo: ["size": self.frame.size])
        }
        // …and persist when the drag ends.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.userResizedNotification,
                                            object: nil,
                                            userInfo: ["size": self.frame.size])
        }

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
            guard let self,
                  !self.keepVisibleWhileUnfocused,
                  self.attachedModalPresentationCount == 0 else { return }
            self.orderOut(nil)
        }
        installMoveObserver()

        // Keep PanelMetrics' idea of the screen current: dragging the
        // panel to another display (or a resolution change) must refresh
        // availableTotalWidth, or the sidebar-squeeze math works against
        // the old screen and the UI can clip until the next summon.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            guard let self, let screen = self.screen else { return }
            PanelMetrics.shared.update(for: screen)
        }
    }

    /// While true (pinned, or a response is streaming), losing focus
    /// does NOT dismiss the panel — it persists as an overlay.
    var keepVisibleWhileUnfocused = false
    private var attachedModalPresentationCount = 0

    func beginAttachedModalPresentation() {
        attachedModalPresentationCount += 1
    }

    func endAttachedModalPresentation() {
        attachedModalPresentationCount = max(0, attachedModalPresentationCount - 1)
    }

    // Remember where the user drags the panel: the top edge persists as
    // a fraction of the screen's visible height (maps across displays);
    // X always re-centers on summon.
    private static let topFractionKey = "panelUserTopFraction"
    /// Suppresses the didMove observer during our own positioning.
    private var isProgrammaticMove = false

    static func clearUserPosition() {
        UserDefaults.standard.removeObject(forKey: topFractionKey)
    }

    private func installMoveObserver() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isProgrammaticMove, !self.inLiveResize,
                  self.isVisible,
                  let sf = self.screen?.visibleFrame, sf.height > 0 else { return }
            let fraction = (self.frame.maxY - sf.minY) / sf.height
            UserDefaults.standard.set(min(max(fraction, 0.2), 0.98),
                                      forKey: Self.topFractionKey)
        }
    }

    // Oscillation damping: long content near a wrap boundary can make the
    // reported content height alternate between two values on every layout
    // pass (height → rewrap → height → …). Unchecked, that resizes the
    // window hundreds of times per second and pegs the main thread until
    // the app beachballs. Detect the A→B→A pattern and hold the taller
    // height briefly to break the cycle.
    private var recentHeights: [(height: CGFloat, at: Date)] = []
    /// The two heights the layout is flapping between while a hold is
    /// active (matched exactly, so any oscillation amplitude is covered).
    private var oscillationLow: CGFloat = 0
    private var oscillationHigh: CGFloat = 0
    private var oscillationHoldUntil = Date.distantPast

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
        // Never fight the user's drag mid-resize.
        guard !inLiveResize else { return }
        let screenFrame = targetScreen?.visibleFrame
        let maxHeight = min(Self.maxPanelHeight,
                            (screenFrame?.height ?? Self.maxPanelHeight) * 0.9)
        var newHeight = max(60, min(size.height, maxHeight))
        let newWidth = max(Self.panelWidth,
                           min(size.width, (screenFrame?.width ?? size.width) * 0.95))

        let now = Date()
        recentHeights.removeAll { now.timeIntervalSince($0.at) > 1.0 }
        if now < oscillationHoldUntil {
            if abs(newHeight - oscillationLow) < 0.5
                || abs(newHeight - oscillationHigh) < 0.5 {
                // Riding out the flip-flop. Never drop a width change,
                // though — apply it at the held height.
                guard abs(newWidth - frame.width) > 0.5 else { return }
                newHeight = oscillationHigh
            } else {
                oscillationHoldUntil = .distantPast // genuinely new size
            }
        }
        if now >= oscillationHoldUntil,
           let last = recentHeights.last,
           recentHeights.count >= 2,
           abs(last.height - newHeight) > 0.5,
           abs(recentHeights[recentHeights.count - 2].height - newHeight) < 0.5,
           now.timeIntervalSince(last.at) < 0.5 {
            // A→B→A within half a second: layout feedback loop.
            oscillationLow = min(newHeight, last.height)
            oscillationHigh = max(newHeight, last.height)
            oscillationHoldUntil = now + 1.0
            newHeight = oscillationHigh
            Log.write("resizeContent: oscillation damped — holding height \(newHeight) for 1s")
        }
        recentHeights.append((newHeight, now))
        if recentHeights.count > 6 { recentHeights.removeFirst() }

        guard abs(newHeight - frame.height) > 0.5 || abs(newWidth - frame.width) > 0.5 else { return }
        Log.write("resizeContent: requested=\(size), clamped=(\(newWidth), \(newHeight)), current=\(frame)")
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
        isProgrammaticMove = true
        setFrame(f, display: true)
        isProgrammaticMove = false
    }

    /// Position like Spotlight: horizontally centered; the top edge uses
    /// the user's remembered drag height (fraction of screen height),
    /// defaulting to the upper third of the screen the mouse is on.
    func center(onActiveScreen: Bool) {
        // Deliberately mouse-based (not the panel's last screen): summoning
        // should appear where you're working right now.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        PanelMetrics.shared.update(for: screen)
        let sf = screen.visibleFrame
        let stored = UserDefaults.standard.double(forKey: Self.topFractionKey)
        let topFraction = stored > 0 ? stored : 0.72
        let x = sf.midX - frame.width / 2
        let top = sf.minY + sf.height * topFraction
        let y = max(top - frame.height, sf.minY) // never below the screen
        isProgrammaticMove = true
        setFrameOrigin(NSPoint(x: x, y: y))
        isProgrammaticMove = false
    }
}
