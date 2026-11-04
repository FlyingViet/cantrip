import SwiftUI

/// The anywhere-swipes (right to open the tab drawer or go back to Home, left to put the drawer
/// away) start wherever a mostly sideways drag starts, except over content whose own sideways drag
/// matters: a map, a sideways scroller, the Mac's screen. Those mark themselves with
/// `cantripSwipeExempt()`; the root view collects their frames with `collectsCantripSwipeExemptions()`.
@MainActor
enum CantripSwipeZones {
    static var exemptFrames: [CGRect] = []

    /// Whether a drag starting here (global coordinates) belongs to the content under it.
    static func isExempt(_ point: CGPoint) -> Bool {
        exemptFrames.contains { $0.contains(point) }
    }

    /// Mostly sideways: at least twice as far across as up or down.
    nonisolated static func isSideways(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * 2
    }
}

/// Tells a swipe from a tap. A touch that moves more than `slop`, more across than up or down, is a
/// swipe (it opens the tab drawer, goes back to Home, scrolls something sideways), so the link,
/// card or button it started on doesn't act when it lifts, nor on a lift that lands just after.
@MainActor
enum CantripSwipeTaps {
    nonisolated static let slop: CGFloat = 10
    /// The lift can reach the content under the finger just after the swipe reports its end.
    static let settle: TimeInterval = 0.35
    private static var swiping = false
    private static var quietUntil = Date.distantPast

    nonisolated static func isSwipe(_ translation: CGSize) -> Bool {
        abs(translation.width) >= slop && abs(translation.width) >= abs(translation.height)
    }

    static func moved(_ translation: CGSize) {
        if isSwipe(translation) { swiping = true }
    }

    static func ended(at now: Date = Date()) {
        guard swiping else { return }
        swiping = false
        quietUntil = now.addingTimeInterval(settle)
    }

    static func allowsTap(at now: Date = Date()) -> Bool {
        !swiping && now >= quietUntil
    }

    /// `action`, skipped when a swipe's lift calls it.
    static func tap<Value>(_ action: @escaping (Value) -> Void) -> (Value) -> Void {
        { value in if allowsTap() { action(value) } }
    }
}

private struct CantripSwipesCancelTaps: ViewModifier {
    @Environment(\.openURL) private var openURL
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        content
            // Links and every card's link open through here.
            .environment(\.openURL, OpenURLAction { url in
                guard CantripSwipeTaps.allowsTap() else { return .discarded }
                openURL(url)
                return .handled
            })
            .simultaneousGesture(
                DragGesture(minimumDistance: CantripSwipeTaps.slop, coordinateSpace: .global)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { CantripSwipeTaps.moved($0.translation) }
                    .onEnded { _ in CantripSwipeTaps.ended() }
            )
            // A drag the system takes over never reports its end.
            .onChange(of: isDragging) { _, dragging in
                if !dragging { CantripSwipeTaps.ended() }
            }
    }
}

private struct CantripSwipeExemptKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value.append(contentsOf: nextValue()) }
}

extension View {
    /// Sideways drags that start here stay with this view (maps, sideways scrollers).
    func cantripSwipeExempt() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: CantripSwipeExemptKey.self, value: [geometry.frame(in: .global)])
            }
        }
    }

    /// At the root, beside the swipes: a link or card a swipe starts on doesn't open when it lifts.
    /// Taps that open something without a URL check `CantripSwipeTaps.allowsTap()` themselves.
    func cantripSwipesCancelTaps() -> some View {
        modifier(CantripSwipesCancelTaps())
    }

    /// At the root: keeps `CantripSwipeZones` current with every exempt view on screen.
    func collectsCantripSwipeExemptions() -> some View {
        onPreferenceChange(CantripSwipeExemptKey.self) { frames in
            MainActor.assumeIsolated { CantripSwipeZones.exemptFrames = frames }
        }
    }
}
