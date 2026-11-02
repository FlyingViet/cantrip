import AppKit
import SwiftUI

// macOS versions of the image viewer pieces that are UIKit-backed on iOS. The shared
// `CantripImageViewer` view (title, Done, loading, retry) is used unchanged.

/// macOS has no swipe-to-dismiss stage; `CantripImageViewer` falls back to its `onDismiss`.
@MainActor
final class CantripImageViewerControl {
    @discardableResult
    func dismiss() -> Bool { false }
}

struct ZoomableChatImage: NSViewRepresentable {
    let image: NSImage
    var label: String = "Image"
    var sourceFrame: CGRect?
    var control: CantripImageViewerControl?
    var onProgress: ((CGFloat) -> Void)?
    var onDismiss: (() -> Void)?

    func makeNSView(context: Context) -> CantripImageStage { CantripImageStage() }

    func updateNSView(_ stage: CantripImageStage, context: Context) {
        stage.setAccessibilityLabel(label)
        stage.setImage(image)
    }
}

/// A magnifiable image: pinch or double-click to zoom, drag or scroll to pan.
final class CantripImageStage: NSScrollView {
    let imageView = NSImageView()
    private var fittedSize: CGSize = .zero

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = true
        backgroundColor = .black
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        documentView = imageView
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityHelp("Pinch or double-click to zoom. Scroll to pan.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: NSImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        fittedSize = .zero
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0, fittedSize != bounds.size else { return }
        fittedSize = bounds.size
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        minMagnification = min(fit, 1)
        maxMagnification = max(1, fit * 6)
        magnification = min(fit, 1)
    }

    var fittedMagnification: CGFloat { minMagnification }

    @objc private func toggleZoom(_ gesture: NSClickGestureRecognizer) {
        if magnification > minMagnification * 1.01 {
            animator().magnification = minMagnification
        } else {
            let point = gesture.location(in: imageView)
            setMagnification(min(maxMagnification, minMagnification * 3), centeredAt: point)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        magnification = min(maxMagnification, magnification * 2)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        magnification = max(minMagnification, magnification / 2)
        return true
    }
}

/// Keeps a smaller-than-window image centered instead of pinned to the bottom-left.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// Esc closes the viewer even when no control inside it has keyboard focus.
private final class CantripImageViewerWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// Opens the shared viewer in its own window, sized to the image and closed by Done or Esc.
@MainActor
enum CantripImageViewerPresenter {
    private static var open: [ObjectIdentifier: NSWindow] = [:]

    @discardableResult
    static func present(
        title: String, imageLabel: String, placeholder: NSImage?, sourceFrame: CGRect?,
        loadID: String, load: @escaping @MainActor () async throws -> NSImage
    ) -> NSWindow? {
        let window = CantripImageViewerWindow(
            contentRect: initialFrame(for: placeholder),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        let close: () -> Void = { [weak window] in window?.performClose(nil) }
        let viewer = CantripImageViewer(
            title: title, imageLabel: imageLabel, placeholder: placeholder, sourceFrame: sourceFrame,
            loadID: loadID, load: load, onDismiss: close
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: viewer)
        window.setFrame(initialFrame(for: placeholder), display: false)
        window.center()
        let id = ObjectIdentifier(window)
        open[id] = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = open.removeValue(forKey: id) }
        }
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// The placeholder is only a thumbnail, so size by its aspect ratio within a comfortable
    /// box on the current screen rather than by its pixels.
    static func initialFrame(for image: NSImage?, screen: CGSize? = NSScreen.main?.visibleFrame.size) -> CGRect {
        let visible = screen ?? CGSize(width: 1440, height: 900)
        let box = CGSize(width: min(1100, visible.width * 0.8), height: min(820, visible.height * 0.8))
        guard let size = image?.size, size.width > 0, size.height > 0 else {
            return CGRect(x: 0, y: 0, width: min(960, box.width), height: min(720, box.height))
        }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGRect(x: 0, y: 0, width: max(480, (size.width * scale).rounded()),
                      height: max(360, (size.height * scale).rounded()))
    }
}
