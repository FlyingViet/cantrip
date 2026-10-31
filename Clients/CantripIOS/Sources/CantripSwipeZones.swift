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

    /// At the root: keeps `CantripSwipeZones` current with every exempt view on screen.
    func collectsCantripSwipeExemptions() -> some View {
        onPreferenceChange(CantripSwipeExemptKey.self) { frames in
            MainActor.assumeIsolated { CantripSwipeZones.exemptFrames = frames }
        }
    }
}
