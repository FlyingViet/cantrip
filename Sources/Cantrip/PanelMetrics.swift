import AppKit
import SwiftUI

/// Screen-dependent panel dimensions, recomputed each time the panel is
/// summoned (it may land on a different display). Laptop screens keep the
/// classic 680pt Spotlight width; big externals get proportionally more.
final class PanelMetrics: ObservableObject {
    static let shared = PanelMetrics()
    @Published var contentWidth: CGFloat = 680
    @Published var transcriptMaxHeight: CGFloat = 340
    private init() {}

    func update(for screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return }
        let width = min(max(680, visible.width * 0.40), 1100)
        let height = min(max(340, visible.height * 0.38), 600)
        if abs(width - contentWidth) > 0.5 { contentWidth = width }
        if abs(height - transcriptMaxHeight) > 0.5 { transcriptMaxHeight = height }
    }
}
