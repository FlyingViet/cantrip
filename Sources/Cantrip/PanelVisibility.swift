import AppKit
import SwiftUI

/// Whether the launcher panel can be seen. A repeating symbol effect keeps SwiftUI
/// re-rendering the whole panel every frame even after it is ordered out, so pulses
/// only run while it is on screen and not covered.
final class PanelVisibility: ObservableObject {
    static let shared = PanelVisibility()
    @Published private(set) var isVisible = false
    private var observer: NSObjectProtocol?

    func track(_ window: NSWindow) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        update(window)
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.update(window)
        }
    }

    private func update(_ window: NSWindow) {
        let visible = window.occlusionState.contains(.visible)
        if visible != isVisible { isVisible = visible }
    }
}

extension View {
    /// `.symbolEffect(.pulse)` that pauses while the panel can't be seen.
    func visiblePulse(isActive: Bool) -> some View {
        modifier(VisiblePulse(isActive: isActive))
    }
}

private struct VisiblePulse: ViewModifier {
    @ObservedObject private var visibility = PanelVisibility.shared
    let isActive: Bool

    func body(content: Content) -> some View {
        content.symbolEffect(.pulse, isActive: isActive && visibility.isVisible)
    }
}
