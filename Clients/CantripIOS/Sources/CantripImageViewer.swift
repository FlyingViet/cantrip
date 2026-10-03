import SwiftUI
import UIKit

/// Photos-style swipe-to-dismiss rules, kept separate so they can be tested directly.
enum CantripImageDismissal {
    /// A release past this fraction of the screen height dismisses.
    static let distanceFraction: CGFloat = 0.12
    /// A flick faster than this (points per second) in the drag direction dismisses.
    static let velocityThreshold: CGFloat = 900
    /// The image shrinks to this scale as the drag reaches full progress.
    static let minimumScale: CGFloat = 0.7

    /// Only a mostly vertical drag at minimum zoom starts a dismissal, so pinching and
    /// panning a zoomed image keep working.
    static func canBegin(zoomScale: CGFloat, minimumZoomScale: CGFloat, velocity: CGPoint) -> Bool {
        zoomScale <= minimumZoomScale * 1.01 && abs(velocity.y) > abs(velocity.x)
    }

    /// 0 while the image is centered, 1 once it has been dragged 40% of the height either way.
    static func progress(translationY: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return min(1, abs(translationY) / (height * 0.4))
    }

    static func scale(progress: CGFloat) -> CGFloat {
        1 - (1 - minimumScale) * min(1, max(0, progress))
    }

    static func shouldDismiss(translationY: CGFloat, velocityY: CGFloat, height: CGFloat) -> Bool {
        if abs(velocityY) > velocityThreshold {
            // Flicking back toward the center cancels, even after a long drag.
            return translationY == 0 || (velocityY > 0) == (translationY > 0)
        }
        return abs(translationY) > height * distanceFraction
    }

    /// Maps the fitted image rect onto `source` (scaled to fit inside it, centered on it). View
    /// transforms apply about the center of `bounds`.
    static func transform(from fitted: CGRect, to source: CGRect, in bounds: CGRect) -> CGAffineTransform {
        guard fitted.width > 0, fitted.height > 0, source.width > 0, source.height > 0 else { return .identity }
        let scale = min(source.width / fitted.width, source.height / fitted.height)
        let dx = source.midX - bounds.midX - scale * (fitted.midX - bounds.midX)
        let dy = source.midY - bounds.midY - scale * (fitted.midY - bounds.midY)
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }
}

/// Hosts the zoomable image over a black backdrop and owns the dismissal gesture and the
/// open/close animations to and from the thumbnail.
final class CantripImageStageView: UIView, UIGestureRecognizerDelegate {
    let scrollView = ChatImageScrollView()
    let backdrop = UIView()
    private(set) var dismissPan: UIPanGestureRecognizer!
    /// The thumbnail's frame in window coordinates, if the viewer opened from one.
    var sourceFrame: CGRect?
    var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    var onProgress: ((CGFloat) -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var progress: CGFloat = 0
    private(set) var isDismissing = false
    private var hasAnimatedIn = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        backdrop.backgroundColor = .black
        addSubview(backdrop)
        addSubview(scrollView)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        scrollView.addGestureRecognizer(pan)
        // At minimum zoom a vertical drag dismisses; otherwise the scroll view pans as usual.
        scrollView.panGestureRecognizer.require(toFail: pan)
        dismissPan = pan
        scrollView.accessibilityIdentifier = "imageViewer.image"
        scrollView.onEscape = { [weak self] in self?.dismiss() ?? false }
        scrollView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Close image") { [weak self] _ in self?.dismiss() ?? false }
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        scrollView.setImage(image)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        // Bounds/center, not frame, so the dismissal transform never fights layout.
        scrollView.bounds = CGRect(origin: scrollView.bounds.origin, size: bounds.size)
        scrollView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        scrollView.layoutIfNeeded()
        if !hasAnimatedIn, bounds.width > 0, scrollView.image != nil, window != nil { animateIn() }
    }

    override func accessibilityPerformEscape() -> Bool { dismiss() }

    // MARK: Geometry

    /// Where the image sits at minimum zoom with no transform.
    var fittedImageRect: CGRect {
        guard let image = scrollView.image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private var sourceRect: CGRect? {
        guard let sourceFrame, window != nil, sourceFrame.width > 1, sourceFrame.height > 1 else { return nil }
        let rect = convert(sourceFrame, from: nil)
        // A thumbnail scrolled off screen has nothing to fly back to.
        return rect.intersects(bounds) ? rect : nil
    }

    private var thumbnailTransform: CGAffineTransform? {
        sourceRect.map { CantripImageDismissal.transform(from: fittedImageRect, to: $0, in: bounds) }
    }

    // MARK: Open

    func animateIn() {
        hasAnimatedIn = true
        if !reduceMotion(), let start = thumbnailTransform {
            scrollView.transform = start
            backdrop.alpha = 0
            UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0,
                           options: [.allowUserInteraction]) {
                self.scrollView.transform = .identity
                self.backdrop.alpha = 1
            }
        } else {
            alpha = 0
            UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        }
    }

    // MARK: Dismissal

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        // The movement so far shows the direction more reliably than the first velocity sample.
        let translation = dismissPan.translation(in: self)
        return canBeginDismissal(movement: translation == .zero ? dismissPan.velocity(in: self) : translation)
    }

    func canBeginDismissal(movement: CGPoint) -> Bool {
        !isDismissing && CantripImageDismissal.canBegin(
            zoomScale: scrollView.zoomScale, minimumZoomScale: scrollView.minimumZoomScale, velocity: movement
        )
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began, .changed:
            updateDismissal(translation: translation)
        case .ended:
            finishDismissal(translation: translation, velocity: gesture.velocity(in: self))
        case .cancelled, .failed:
            finishDismissal(translation: translation, velocity: .zero, cancelled: true)
        default:
            break
        }
    }

    /// Follows the finger, shrinking the image and fading the backdrop.
    func updateDismissal(translation: CGPoint) {
        guard !isDismissing else { return }
        let progress = CantripImageDismissal.progress(translationY: translation.y, height: bounds.height)
        let scale = reduceMotion() ? 1 : CantripImageDismissal.scale(progress: progress)
        scrollView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
            .scaledBy(x: scale, y: scale)
        setProgress(progress)
    }

    func finishDismissal(translation: CGPoint, velocity: CGPoint, cancelled: Bool = false) {
        guard !isDismissing else { return }
        if !cancelled, CantripImageDismissal.shouldDismiss(
            translationY: translation.y, velocityY: velocity.y, height: bounds.height
        ) {
            dismiss(direction: translation.y < 0 ? -1 : 1)
        } else {
            let reset = {
                self.scrollView.transform = .identity
                self.setProgress(0)
            }
            if reduceMotion() {
                UIView.animate(withDuration: 0.15, animations: reset)
            } else {
                UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8,
                               initialSpringVelocity: 0, options: [.allowUserInteraction], animations: reset)
            }
        }
    }

    /// Closes with the same animation as a completed drag: back into the thumbnail when it is
    /// on screen, otherwise off the screen in the drag direction, or a fade with Reduce Motion.
    @discardableResult
    func dismiss(direction: CGFloat = 1) -> Bool {
        guard !isDismissing else { return false }
        isDismissing = true
        dismissPan.isEnabled = false
        let finish: (Bool) -> Void = { [weak self] _ in self?.onDismiss?() }
        if reduceMotion() {
            UIView.animate(withDuration: 0.2, animations: {
                self.alpha = 0
                self.setProgress(1)
            }, completion: finish)
            return true
        }
        let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale * 1.01
        let target: CGAffineTransform
        let current = scrollView.transform
        if let thumbnail = thumbnailTransform {
            target = thumbnail
        } else {
            target = current.translatedBy(x: 0, y: direction * bounds.height / max(0.1, current.a))
        }
        UIView.animate(withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState]) {
            if zoomed { self.scrollView.setZoomScale(self.scrollView.minimumZoomScale, animated: false) }
            self.scrollView.transform = target
            self.setProgress(1)
        }
        UIView.animate(withDuration: 0.14, delay: 0.2, options: [.beginFromCurrentState],
                       animations: { self.scrollView.alpha = 0 }, completion: finish)
        return true
    }

    private func setProgress(_ value: CGFloat) {
        progress = value
        backdrop.alpha = 1 - value
        onProgress?(value)
    }
}

/// Lets SwiftUI chrome (Done, VoiceOver escape) run the stage's dismissal animation.
@MainActor
final class CantripImageViewerControl {
    weak var stage: CantripImageStageView?

    @discardableResult
    func dismiss() -> Bool { stage?.dismiss() ?? false }
}

struct ZoomableChatImage: UIViewRepresentable {
    let image: UIImage
    var label: String = "Image"
    var sourceFrame: CGRect?
    var control: CantripImageViewerControl?
    var onProgress: ((CGFloat) -> Void)?
    var onDismiss: (() -> Void)?

    func makeUIView(context: Context) -> CantripImageStageView {
        let stage = CantripImageStageView()
        stage.sourceFrame = sourceFrame
        return stage
    }

    func updateUIView(_ stage: CantripImageStageView, context: Context) {
        stage.onProgress = onProgress
        stage.onDismiss = onDismiss
        stage.scrollView.accessibilityLabel = label
        control?.stage = stage
        stage.setImage(image)
    }
}

/// Full-screen zoomable viewer shared by chat images and Home artifacts. At minimum zoom,
/// drag up or down to dismiss, as in Photos.
struct CantripImageViewer: View {
    let title: String
    let imageLabel: String
    var placeholder: UIImage?
    var sourceFrame: CGRect?
    /// Changes when a different image should load.
    let loadID: String
    let load: @MainActor () async throws -> UIImage
    let onDismiss: () -> Void

    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var retry = 0
    @State private var chromeOpacity: Double = 1
    @State private var control = CantripImageViewerControl()

    var body: some View {
        ZStack {
            if let shown = image ?? placeholder {
                ZoomableChatImage(
                    image: shown, label: imageLabel, sourceFrame: sourceFrame, control: control,
                    onProgress: { chromeOpacity = Double(max(0, 1 - $0 * 3)) },
                    onDismiss: onDismiss
                )
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                if let errorMessage {
                    VStack(spacing: 16) {
                        Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                        Text(errorMessage).font(.callout).multilineTextAlignment(.center)
                        Button("Retry") { retry += 1 }.buttonStyle(.bordered)
                    }
                    .foregroundStyle(.white)
                    .padding()
                } else {
                    ProgressView("Loading image...").tint(.white).foregroundStyle(.white)
                }
            }
        }
        .overlay(alignment: .top) { chrome.opacity(chromeOpacity) }
        .overlay(alignment: .bottom) {
            if placeholder != nil, image == nil {
                status.opacity(chromeOpacity)
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityAction(.escape) { close() }
        .task(id: "\(loadID)/\(retry)") {
            errorMessage = nil
            do {
                image = try await load()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var chrome: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 72)
                .accessibilityAddTraits(.isHeader)
                .allowsHitTesting(false)
            HStack {
                Spacer()
                Button("Done") { close() }
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Closes the image")
                    .accessibilityIdentifier("imageViewer.done")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false))
    }

    @ViewBuilder private var status: some View {
        Group {
            if let errorMessage {
                Button {
                    retry += 1
                } label: {
                    Label("Showing a smaller copy. Tap to retry. \(errorMessage)",
                          systemImage: "exclamationmark.triangle")
                }
            } else {
                Label("Loading full image", systemImage: "arrow.down.circle")
            }
        }
        .font(.footnote)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(.bottom, 24)
    }

    private func close() {
        if !control.dismiss() { onDismiss() }
    }
}

/// Records a thumbnail's window frame without re-rendering on every scroll.
@MainActor
final class CantripViewerSource {
    var frame: CGRect?
}

extension View {
    func cantripViewerSource(_ source: CantripViewerSource) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { source.frame = $0 }
    }
}

/// Presents the viewer over the current screen without the system slide-up, so the stage's
/// own zoom and fade transitions show what is underneath.
@MainActor
enum CantripImageViewerPresenter {
    @discardableResult
    static func present(
        title: String, imageLabel: String, placeholder: UIImage?, sourceFrame: CGRect?,
        loadID: String, load: @escaping @MainActor () async throws -> UIImage
    ) -> UIViewController? {
        guard let presenter = topViewController() else { return nil }
        final class Holder { weak var controller: UIViewController? }
        let holder = Holder()
        let viewer = CantripImageViewer(
            title: title, imageLabel: imageLabel, placeholder: placeholder, sourceFrame: sourceFrame,
            loadID: loadID, load: load,
            onDismiss: { holder.controller?.dismiss(animated: false) }
        )
        let host = UIHostingController(rootView: viewer)
        host.modalPresentationStyle = .overFullScreen
        host.modalPresentationCapturesStatusBarAppearance = true
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        holder.controller = host
        presenter.present(host, animated: false) {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
        return host
    }

    static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        var top = (windows.first(where: \.isKeyWindow) ?? windows.first(where: { !$0.isHidden }))?
            .rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
