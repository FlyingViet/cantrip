import AppKit
import SwiftUI

/// Screen-dependent panel dimensions, recomputed each time the panel is
/// summoned (it may land on a different display). Laptop screens keep the
/// classic 680pt Spotlight width; big externals get proportionally more.
final class PanelMetrics: ObservableObject {
    static let shared = PanelMetrics()
    @Published var contentWidth: CGFloat = 680
    @Published var transcriptMaxHeight: CGFloat = 340

    private let d = UserDefaults.standard
    private init() {}

    /// User-dragged size overrides (persisted); 0 = none.
    private var userWidth: CGFloat {
        get { d.double(forKey: "panelUserWidth") }
        set { d.set(newValue, forKey: "panelUserWidth") }
    }
    private var userHeight: CGFloat {
        get { d.double(forKey: "panelUserHeight") }
        set { d.set(newValue, forKey: "panelUserHeight") }
    }

    func update(for screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return }
        let width = userWidth > 0
            ? min(max(560, userWidth), visible.width * 0.95)
            : min(max(680, visible.width * 0.40), 1100)
        let height = userHeight > 0
            ? min(max(220, userHeight), visible.height * 0.85)
            : min(max(340, visible.height * 0.38), 600)
        if abs(width - contentWidth) > 0.5 { contentWidth = width }
        if abs(height - transcriptMaxHeight) > 0.5 { transcriptMaxHeight = height }
    }

    /// Live drag tick: track the mouse, don't persist yet.
    func setLiveSize(totalWidth: CGFloat, totalHeight: CGFloat, sidebarExtra: CGFloat) {
        apply(totalWidth: totalWidth, totalHeight: totalHeight,
              sidebarExtra: sidebarExtra)
    }

    /// Drag ended: adopt and remember.
    func setUserSize(totalWidth: CGFloat, totalHeight: CGFloat, sidebarExtra: CGFloat) {
        apply(totalWidth: totalWidth, totalHeight: totalHeight,
              sidebarExtra: sidebarExtra)
        userWidth = contentWidth
        userHeight = transcriptMaxHeight
        Log.write("panel: user size saved \(Int(contentWidth))×\(Int(transcriptMaxHeight))")
    }

    private func apply(totalWidth: CGFloat, totalHeight: CGFloat, sidebarExtra: CGFloat) {
        let width = min(max(560, totalWidth - sidebarExtra), 1400)
        let height = min(max(220, totalHeight - 170), 900)
        if abs(width - contentWidth) > 0.5 { contentWidth = width }
        if abs(height - transcriptMaxHeight) > 0.5 { transcriptMaxHeight = height }
    }

    func clearUserSize() {
        userWidth = 0
        userHeight = 0
        update(for: NSScreen.main)
    }
}
