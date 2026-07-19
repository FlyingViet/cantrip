import AppKit
import SwiftUI

/// A tooltip the assistant places on screen: normalized coords (0–1,
/// origin top-left, relative to the screenshot it viewed) plus a label.
struct OverlayHint: Decodable {
    let x: Double
    let y: Double
    let label: String
}

/// Full-screen, click-through window that renders the assistant's
/// tutorial callouts on top of whatever the user is doing.
final class OverlayController {
    static let shared = OverlayController()
    private var window: NSWindow?
    private init() {}

    func show(_ hints: [OverlayHint]) {
        DispatchQueue.main.async {
            self.clearNow()
            guard !hints.isEmpty, let screen = NSScreen.main else { return }
            let w = NSWindow(contentRect: screen.frame,
                             styleMask: .borderless,
                             backing: .buffered,
                             defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .floating
            w.ignoresMouseEvents = true // clicks pass through to the real UI
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(
                rootView: OverlayView(hints: hints, size: screen.frame.size))
            w.orderFrontRegardless()
            self.window = w
            Log.write("overlay: showing \(hints.count) hints")
        }
    }

    func clear() {
        DispatchQueue.main.async { self.clearNow() }
    }

    private func clearNow() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct OverlayView: View {
    let hints: [OverlayHint]
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(hints.enumerated()), id: \.offset) { index, hint in
                HintBubble(number: index + 1, label: hint.label)
                    .position(x: min(max(hint.x, 0), 1) * size.width,
                              y: min(max(hint.y, 0), 1) * size.height)
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
