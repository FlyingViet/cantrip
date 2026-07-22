import AppKit
import SwiftUI

/// A tooltip the assistant places on screen: normalized coords (0–1,
/// origin top-left, relative to the screenshot it viewed) plus a label.
struct OverlayHint: Decodable {
    let x: Double
    let y: Double
    let label: String
    /// 1-based display number matching the captured screenshots (1 = main).
    let display: Int?
}

/// Full-screen, click-through window that renders the assistant's
/// tutorial callouts on top of whatever the user is doing.
final class OverlayController {
    static let shared = OverlayController()
    private var windows: [NSWindow] = []
    private init() {}

    /// Find the NSScreen for a capture's display number (main = 1).
    private func screen(forDisplayIndex index: Int) -> NSScreen? {
        let captures = ScreenCapture.shared.lastCaptures
        if let capture = captures.first(where: { $0.index == index }) {
            return NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID) == capture.displayID
            }
        }
        return index == 1 ? NSScreen.main : nil
    }

    func show(_ hints: [OverlayHint]) {
        DispatchQueue.main.async {
            self.clearNow()
            guard !hints.isEmpty else { return }
            // One overlay window per referenced display; numbering stays
            // global so the response text's ①②③ references hold.
            let numbered = hints.enumerated().map { (number: $0.offset + 1, hint: $0.element) }
            let grouped = Dictionary(grouping: numbered) { $0.hint.display ?? 1 }
            for (displayIndex, displayHints) in grouped {
                guard let screen = self.screen(forDisplayIndex: displayIndex)
                    ?? NSScreen.main else { continue }
                let w = NSWindow(contentRect: screen.frame,
                                 styleMask: .borderless,
                                 backing: .buffered,
                                 defer: false)
                w.isOpaque = false
                w.backgroundColor = .clear
                w.hasShadow = false
                w.level = .floating
                w.ignoresMouseEvents = true // clicks pass through
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                w.contentView = NSHostingView(
                    rootView: OverlayView(hints: displayHints,
                                          size: screen.frame.size))
                w.setFrame(screen.frame, display: true)
                w.orderFrontRegardless()
                self.windows.append(w)
            }
            Log.write("overlay: showing \(hints.count) hints on \(grouped.count) display(s)")
        }
    }

    func clear() {
        DispatchQueue.main.async { self.clearNow() }
    }

    private func clearNow() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private struct OverlayView: View {
    let hints: [(number: Int, hint: OverlayHint)]
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(hints, id: \.number) { entry in
                HintBubble(number: entry.number, label: entry.hint.label)
                    .position(x: min(max(entry.hint.x, 0), 1) * size.width,
                              y: min(max(entry.hint.y, 0), 1) * size.height)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct HintBubble: View {
    let number: Int
    let label: String
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.95),
                            in: RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4)
                .frame(maxWidth: 260)
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: 34, height: 34)
                    .scaleEffect(pulsing ? 1.25 : 0.9)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                               value: pulsing)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 22, height: 22)
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        // Anchor the marker dot at the target point; label floats above.
        .offset(y: -28)
        .onAppear { pulsing = true }
    }
}
