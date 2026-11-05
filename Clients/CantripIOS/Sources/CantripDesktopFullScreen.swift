import SwiftUI

/// Zoom and touch math for the full-screen Mac.
enum CantripDesktopFit {
    /// Pinching zooms up to this many times the fitted size.
    static let maxZoom: CGFloat = 4

    /// The zoom that shows the whole screen inside `container`.
    static func fitScale(image: CGSize, in container: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return 1 }
        return min(container.width / image.width, container.height / image.height)
    }

    /// The touch as a fraction of the screen's width and height; nil outside it.
    static func point(_ location: CGPoint, in size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0,
              (0...size.width).contains(location.x), (0...size.height).contains(location.y) else { return nil }
        return CGPoint(x: min(location.x / size.width, 0.999999), y: min(location.y / size.height, 0.999999))
    }

    /// Where a drag lets go: past the screen's edge, at the edge.
    static func clampedPoint(_ location: CGPoint, in size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        return CGPoint(x: min(max(location.x / size.width, 0), 0.999999),
                       y: min(max(location.y / size.height, 0), 0.999999))
    }

    /// "4:05": what's left of the five-minute session.
    static func remaining(until expiresAt: Double, now: Date) -> String {
        let seconds = max(0, Int((expiresAt - now.timeIntervalSince1970).rounded(.up)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

#if os(iOS)
import UIKit

/// View Mac, full screen: opens from the header, asks Face ID and shows the Mac edge to edge with a
/// toolbar that drops down from the top. Touch works as on the Mac's own trackpad would: tap to
/// click, drag to drag, pinch to zoom. Closing it ends the session.
struct CantripViewMacScreen: View {
    @ObservedObject var remote: CantripRemoteModel
    @StateObject private var desktop: CantripDesktopModel
    @AppStorage("cantrip.desktop.control") private var control = false
    @State private var clickKind = "click"
    @State private var toolbarShown = true
    @State private var keyboardShown = false
    @State private var fitRequest = 0
    @State private var started = false
    let onClose: () -> Void
    let onOpenPermissions: () -> Void

    init(remote: CantripRemoteModel, onClose: @escaping () -> Void, onOpenPermissions: @escaping () -> Void) {
        self.remote = remote
        self.onClose = onClose
        self.onOpenPermissions = onOpenPermissions
        _desktop = StateObject(wrappedValue: CantripDesktopModel(remote: remote))
    }

    private var controls: Bool { desktop.lease?.control == true }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let lease = desktop.lease {
                CantripDesktopScreen(
                    image: desktop.image,
                    controls: lease.control,
                    dragsOnMac: lease.supportsDrag == true,
                    tapKind: clickKind,
                    fitRequest: fitRequest,
                    onTap: { kind, point in click(kind, at: point) },
                    onDrag: { from, to in drag(from: from, to: to) }
                )
                // Edge to edge, but above the keyboard so what's typed stays in view.
                .ignoresSafeArea(.container)
                if desktop.image == nil {
                    ProgressView("Waiting for a screen frame…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(spacing: 8) {
                    if toolbarShown {
                        toolbar(lease).transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        handle.transition(.opacity)
                    }
                    if let error = desktop.error { errorBanner(error) }
                }
                .padding(.top, 4)
                .padding(.horizontal, 8)
            } else {
                CantripDesktopStartCard(
                    macName: remote.macName,
                    busy: desktop.busy,
                    error: desktop.error,
                    onStart: start,
                    onOpenPermissions: onOpenPermissions,
                    onClose: onClose
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            if controls {
                CantripDesktopKeyboard(isShown: $keyboardShown, desktop: desktop)
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .animation(.snappy(duration: 0.25), value: toolbarShown)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .modifier(CantripDesktopHidesVerticalBar())
        .task {
            guard !started else { return }
            started = true
            await desktop.start(control: control)
        }
        .onDisappear {
            keyboardShown = false
            Task { await desktop.stop() }
        }
        // Leaving the app (or Control Center over it) ends viewing, as it always has.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            guard desktop.lease != nil else { return }
            keyboardShown = false
            Task { await desktop.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            keyboardShown = false
            Task { await desktop.stop() }
        }
        .onChange(of: desktop.lease == nil) { _, ended in
            if ended { keyboardShown = false }
        }
        .onChange(of: remote.usageIdentity) { _, _ in onClose() }
        .onChange(of: remote.notificationNavigationID) { _, _ in onClose() }
        .accessibilityAction(.escape) { onClose() }
    }

    private func start() {
        Task { await desktop.start(control: control) }
    }

    private func click(_ kind: String, at point: CGPoint) {
        guard let frame = desktop.frame else { return }
        Task { await desktop.send(.init(frameID: frame.id, kind: kind, x: Double(point.x), y: Double(point.y))) }
    }

    private func drag(from: CGPoint, to: CGPoint) {
        guard let frame = desktop.frame else { return }
        Task {
            await desktop.send(.init(frameID: frame.id, kind: "drag", x: Double(from.x), y: Double(from.y),
                                     toX: Double(to.x), toY: Double(to.y)))
        }
    }

    private func errorBanner(_ error: String) -> some View {
        Button { desktop.error = nil } label: {
            Text(error)
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 520, alignment: .leading)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Dismisses the message")
        .accessibilityIdentifier("desktop.fullScreen.error")
    }

    // MARK: - Drop-down toolbar

    private func toolbar(_ lease: CantripDesktopLease) -> some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(lease, wide: true)
            toolbarRow(lease, wide: false)
        }
        .padding(4)
        .glassEffect(.regular, in: Capsule())
        .environment(\.colorScheme, .dark)
        // Swipe it back up to get it out of the way.
        .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { value in
            if value.translation.height < -24 { toolbarShown = false }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View Mac toolbar")
        .accessibilityIdentifier("desktop.fullScreen.toolbar")
    }

    private func toolbarRow(_ lease: CantripDesktopLease, wide: Bool) -> some View {
        HStack(spacing: 0) {
            tool("Close View Mac", "xmark", id: "desktop.fullScreen.close") { onClose() }
            if lease.control {
                tool(keyboardShown ? "Hide Keyboard" : "Show Keyboard",
                     keyboardShown ? "keyboard.chevron.compact.down" : "keyboard",
                     id: "desktop.fullScreen.keyboard") { keyboardShown.toggle() }
                tapActionMenu
                if wide {
                    ForEach(Self.keys, id: \.key) { key in
                        tool(key.title, key.symbol, id: "desktop.fullScreen.key.\(key.key)") { desktop.press(key.key) }
                    }
                    tool("Scroll Up", "arrow.up.to.line", id: "desktop.fullScreen.scrollUp") { scroll(3) }
                    tool("Scroll Down", "arrow.down.to.line", id: "desktop.fullScreen.scrollDown") { scroll(-3) }
                } else {
                    keysMenu
                }
            }
            viewMenu(lease)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(CantripDesktopFit.remaining(until: lease.expiresAt, now: context.date))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .accessibilityLabel("Time left")
            }
            tool("Hide Toolbar", "chevron.compact.up", id: "desktop.fullScreen.collapse") { toolbarShown = false }
        }
        .fixedSize()
    }

    private func tool(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolIcon(symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
    }

    private func toolIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private static let tapActions: [(kind: String, title: String, symbol: String)] = [
        ("click", "Click", "cursorarrow.click"),
        ("doubleClick", "Double Click", "cursorarrow.click.2"),
        ("rightClick", "Right Click", "contextualmenu.and.cursorarrow"),
    ]

    /// What a one-finger tap does (a double tap always double-clicks, a two-finger tap right-clicks).
    private var tapActionMenu: some View {
        let current = Self.tapActions.first { $0.kind == clickKind } ?? Self.tapActions[0]
        return Menu {
            Picker("Tap Action", selection: $clickKind) {
                ForEach(Self.tapActions, id: \.kind) { Label($0.title, systemImage: $0.symbol).tag($0.kind) }
            }
        } label: { toolIcon(current.symbol) }
        .accessibilityLabel("Tap Action")
        .accessibilityValue(current.title)
        .accessibilityIdentifier("desktop.fullScreen.tapAction")
    }

    private static let keys: [(key: String, title: String, symbol: String)] = [
        ("escape", "Escape", "escape"),
        ("tab", "Tab", "arrow.right.to.line"),
        ("return", "Return", "return"),
        ("delete", "Delete", "delete.left"),
        ("left", "Left Arrow", "arrow.left"),
        ("up", "Up Arrow", "arrow.up"),
        ("down", "Down Arrow", "arrow.down"),
        ("right", "Right Arrow", "arrow.right"),
    ]

    private var keysMenu: some View {
        Menu {
            Section("Keys") {
                ForEach(Self.keys, id: \.key) { key in
                    Button { desktop.press(key.key) } label: { Label(key.title, systemImage: key.symbol) }
                }
            }
            Section("Scroll") {
                Button { scroll(3) } label: { Label("Scroll Up", systemImage: "arrow.up.to.line") }
                Button { scroll(-3) } label: { Label("Scroll Down", systemImage: "arrow.down.to.line") }
            }
        } label: { toolIcon("command") }
        .accessibilityLabel("Keys and Scrolling")
        .accessibilityIdentifier("desktop.fullScreen.keys")
    }

    /// Fit, which display, and whether this session can control the Mac.
    private func viewMenu(_ lease: CantripDesktopLease) -> some View {
        Menu {
            Button { fitRequest += 1 } label: {
                Label("Fit to Screen", systemImage: "arrow.down.right.and.arrow.up.left.rectangle")
            }
            if lease.displays.count > 1 {
                Picker("Display", selection: $desktop.displayID) {
                    ForEach(lease.displays) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            Button {
                // A session is view-only or in control from the start: switching starts a new one.
                control = !lease.control
                Task {
                    await desktop.stop()
                    await desktop.start(control: control)
                }
            } label: {
                Label(lease.control ? "Switch to View Only" : "Switch to Keyboard & Pointer Control",
                      systemImage: lease.control ? "eye" : "cursorarrow.rays")
            }
        } label: { toolIcon("display") }
        .accessibilityLabel("Screen")
        .accessibilityIdentifier("desktop.fullScreen.view")
    }

    /// The toolbar folded away: a small tab to pull it back down.
    private var handle: some View {
        Button { toolbarShown = true } label: {
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 26)
                .background(.black.opacity(0.55), in: Capsule())
                .frame(minWidth: 88, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 8).onEnded { value in
            if value.translation.height > 16 { toolbarShown = true }
        })
        .accessibilityLabel("Show Toolbar")
        .accessibilityIdentifier("desktop.fullScreen.expand")
    }

    private func scroll(_ delta: Int) {
        guard let frame = desktop.frame else { return }
        Task { await desktop.send(.init(frameID: frame.id, kind: "scroll", delta: delta)) }
    }
}

/// Before the Mac shows (and after a session ends): keyboard and pointer control, Face ID to start.
struct CantripDesktopStartCard: View {
    let macName: String
    let busy: Bool
    let error: String?
    let onStart: () -> Void
    let onOpenPermissions: () -> Void
    let onClose: () -> Void
    @AppStorage("cantrip.desktop.control") private var control = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("View \(macName)", systemImage: "display")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if busy {
                ProgressView("Connecting…")
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("desktop.start.error")
                }
                Toggle("Keyboard and pointer control", isOn: $control)
                    .accessibilityIdentifier("cantrip.desktop.control")
                Button(action: onStart) {
                    Label(control ? "Authenticate & Control Mac" : "Authenticate & View Mac", systemImage: "faceid")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("desktop.start")
            }
            Text("Face ID confirms each session, which lasts up to five minutes. Screen frames and typed input aren't saved or sent to the model.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button("Mac Permissions", action: onOpenPermissions)
                    .accessibilityIdentifier("desktop.start.permissions")
                Spacer()
                Button("Close", action: onClose)
                    .accessibilityIdentifier("desktop.start.close")
            }
            .frame(minHeight: 44)
        }
        .padding(20)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
        .padding(20)
    }
}

/// On the iPhone Duo, keeps the system's vertical bar from holding a column beside the Mac's screen.
private struct CantripDesktopHidesVerticalBar: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if AGENTGATEWAY_DUO_SDK
        if #available(iOS 27.1, *) {
            content.toolbarVerticalBehavior(.disabled)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Screen

/// The Mac's screen. One finger taps (click, or the chosen tap action), double-taps (double click)
/// and drags on the Mac; two fingers tap to right-click, pinch to zoom and move the zoomed screen.
/// Macs without drag support leave one-finger drags to moving the zoomed screen.
final class CantripDesktopScreenView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    var onTap: (String, CGPoint) -> Void = { _, _ in }
    var onDrag: (CGPoint, CGPoint) -> Void = { _, _ in }
    var tapKind = "click"
    var controls = false { didSet { updateGestures() } }
    var dragsOnMac = false { didSet { updateGestures() } }

    private let tap = UITapGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let drag = UIPanGestureRecognizer()
    private let dragPath = CAShapeLayer()
    private let touchDown = TouchDownRecorder()
    private var dragStart: (normalized: CGPoint, local: CGPoint)?
    private var fitted = true
    private var laidOutSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Live Mac screen"
        imageView.accessibilityIdentifier = "desktop.fullScreen.screen"
        addSubview(imageView)
        dragPath.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        dragPath.fillColor = UIColor.systemBlue.withAlphaComponent(0.85).cgColor
        dragPath.lineWidth = 3
        dragPath.lineCap = .round
        dragPath.lineDashPattern = [6, 5]
        layer.addSublayer(dragPath)

        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(doubleTapped(_:)))
        tap.require(toFail: doubleTap)
        tap.addTarget(self, action: #selector(tapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.addTarget(self, action: #selector(twoFingerTapped(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = touchDown
        drag.addTarget(self, action: #selector(dragged(_:)))
        [tap, doubleTap, twoFingerTap, drag].forEach(addGestureRecognizer)
        updateGestures()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateGestures() {
        tap.isEnabled = controls
        doubleTap.isEnabled = controls
        twoFingerTap.isEnabled = controls
        drag.isEnabled = controls && dragsOnMac
        // One finger drags on the Mac; then the zoomed screen moves with two.
        panGestureRecognizer.minimumNumberOfTouches = drag.isEnabled ? 2 : 1
        imageView.accessibilityHint = controls
            ? "Tap to click, double-tap to double-click, tap with two fingers to right-click\(dragsOnMac ? ", drag to drag on the Mac" : ""). Pinch to zoom."
            : "View only. Pinch to zoom."
        imageView.accessibilityTraits = controls ? .allowsDirectInteraction : .image
    }

    func show(_ image: UIImage?) {
        guard let image else { imageView.image = nil; return }
        if imageView.bounds.size != image.size {
            // A new display or a first frame: start fitted.
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
            fitted = true
            laidOutSize = .zero
            setNeedsLayout()
        }
        imageView.image = image
    }

    func fit() {
        fitted = true
        setZoomScale(minimumZoomScale, animated: true)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard imageView.bounds.width > 0, bounds.width > 0 else { return }
        if bounds.size != laidOutSize {
            // Rotating, unfolding or the keyboard changes the room; a fitted screen stays fitted.
            laidOutSize = bounds.size
            let fit = CantripDesktopFit.fitScale(image: imageView.bounds.size, in: bounds.size)
            minimumZoomScale = fit
            maximumZoomScale = fit * CantripDesktopFit.maxZoom
            if fitted || zoomScale < fit { zoomScale = fit }
            describeZoom()
        }
        center()
    }

    /// Keeps a screen smaller than the view in its middle.
    private func center() {
        let size = imageView.frame.size
        let x = max(0, (bounds.width - size.width) / 2), y = max(0, (bounds.height - size.height) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
        if fitted, !isZooming, !isTracking, !isDecelerating {
            contentOffset = CGPoint(x: -inset.left, y: -inset.top)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        fitted = zoomScale <= minimumZoomScale * 1.01
        center()
        describeZoom()
    }

    /// VoiceOver reads the zoom, e.g. "Zoom 250%"; 100% shows the whole screen.
    private func describeZoom() {
        let percent = minimumZoomScale > 0 ? Int((zoomScale / minimumZoomScale * 100).rounded()) : 100
        imageView.accessibilityValue = "Zoom \(percent)%"
    }

    // MARK: Touch

    @objc private func tapped(_ gesture: UITapGestureRecognizer) { send(tapKind, gesture) }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) { send("doubleClick", gesture) }
    @objc private func twoFingerTapped(_ gesture: UITapGestureRecognizer) { send("rightClick", gesture) }

    private func send(_ kind: String, _ gesture: UIGestureRecognizer) {
        guard let point = CantripDesktopFit.point(gesture.location(in: imageView), in: imageView.bounds.size) else { return }
        onTap(kind, point)
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let size = imageView.bounds.size
        switch gesture.state {
        case .began:
            // The press is where the finger first touched, before it moved far enough to count.
            let origin = touchDown.location.map { convert($0, to: imageView) } ?? gesture.location(in: imageView)
            guard let start = CantripDesktopFit.point(origin, in: size) else { dragStart = nil; return }
            dragStart = (start, imageView.convert(origin, to: self))
            drawDrag(to: gesture.location(in: self))
        case .changed:
            drawDrag(to: gesture.location(in: self))
        case .ended:
            if let start = dragStart?.normalized,
               let end = CantripDesktopFit.clampedPoint(gesture.location(in: imageView), in: size) {
                onDrag(start, end)
            }
            dragStart = nil
            fadeDrag()
        default:
            dragStart = nil
            dragPath.path = nil
        }
    }

    /// A dashed line from the press to the finger, so the drag shows before the next frame does.
    private func drawDrag(to point: CGPoint) {
        guard let start = dragStart?.local else { return }
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: point)
        path.append(UIBezierPath(ovalIn: CGRect(x: start.x - 6, y: start.y - 6, width: 12, height: 12)))
        path.append(UIBezierPath(ovalIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dragPath.opacity = 1
        dragPath.path = path.cgPath
        CATransaction.commit()
    }

    private func fadeDrag() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.8)
        dragPath.opacity = 0
        CATransaction.commit()
    }
}

/// Remembers where a drag's finger came down (the drag only starts once it has moved).
private final class TouchDownRecorder: NSObject, UIGestureRecognizerDelegate {
    var location: CGPoint?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let view = gestureRecognizer.view { location = touch.location(in: view) }
        return true
    }
}

struct CantripDesktopScreen: UIViewRepresentable {
    let image: UIImage?
    let controls: Bool
    let dragsOnMac: Bool
    let tapKind: String
    let fitRequest: Int
    let onTap: (String, CGPoint) -> Void
    let onDrag: (CGPoint, CGPoint) -> Void

    final class Coordinator { var fitRequest = 0 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CantripDesktopScreenView {
        context.coordinator.fitRequest = fitRequest
        return CantripDesktopScreenView()
    }

    func updateUIView(_ view: CantripDesktopScreenView, context: Context) {
        view.onTap = onTap
        view.onDrag = onDrag
        view.tapKind = tapKind
        if view.controls != controls { view.controls = controls }
        if view.dragsOnMac != dragsOnMac { view.dragsOnMac = dragsOnMac }
        view.show(image)
        if context.coordinator.fitRequest != fitRequest {
            context.coordinator.fitRequest = fitRequest
            view.fit()
        }
    }
}

// MARK: - Keyboard

/// Takes the keyboard's input for the Mac. Nothing typed is shown, suggested, corrected or learned
/// on this device.
final class CantripDesktopKeyInputView: UIView, UIKeyInput {
    var onText: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onKey: (String) -> Void = { _ in }
    var onResign: () -> Void = {}

    var hasText: Bool { true }
    func insertText(_ text: String) { onText(text) }
    func deleteBackward() { onDelete() }

    override var canBecomeFirstResponder: Bool { true }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign() }
        return resigned
    }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var isSecureTextEntry: Bool = true

    /// A hardware keyboard's arrows and Escape.
    override var keyCommands: [UIKeyCommand]? {
        Self.hardwareKeys.keys.sorted().map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(pressHardwareKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    private static let hardwareKeys: [String: String] = [
        UIKeyCommand.inputUpArrow: "up", UIKeyCommand.inputDownArrow: "down",
        UIKeyCommand.inputLeftArrow: "left", UIKeyCommand.inputRightArrow: "right",
        UIKeyCommand.inputEscape: "escape",
    ]

    @objc private func pressHardwareKey(_ command: UIKeyCommand) {
        if let input = command.input, let key = Self.hardwareKeys[input] { onKey(key) }
    }
}

struct CantripDesktopKeyboard: UIViewRepresentable {
    @Binding var isShown: Bool
    let desktop: CantripDesktopModel

    func makeUIView(context: Context) -> CantripDesktopKeyInputView {
        let view = CantripDesktopKeyInputView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: CantripDesktopKeyInputView, context: Context) {
        view.onText = { [desktop] in desktop.type($0) }
        view.onDelete = { [desktop] in desktop.deleteBackward() }
        view.onKey = { [desktop] in desktop.press($0) }
        // The keyboard's own dismiss key (iPad) hides it too.
        let shown = $isShown
        view.onResign = { if shown.wrappedValue { shown.wrappedValue = false } }
        if isShown, !view.isFirstResponder {
            DispatchQueue.main.async { if view.window != nil { view.becomeFirstResponder() } }
        } else if !isShown, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ view: CantripDesktopKeyInputView, coordinator: ()) {
        view.onResign = {}
        view.resignFirstResponder()
    }
}

// MARK: - Presentation

/// Hides the status bar (and the iPhone Duo's vertical bar) and the home indicator over the Mac.
final class CantripDesktopFullScreenController: UIHostingController<CantripViewMacScreen> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
}

@MainActor
enum CantripViewMacPresenter {
    /// Covers the whole screen; closing it ends the session.
    static func present(remote: CantripRemoteModel) {
        guard let presenter = CantripImageViewerPresenter.topViewController(),
              !(presenter is CantripDesktopFullScreenController) else { return }
        final class Holder { weak var controller: UIViewController? }
        let holder = Holder()
        let host = CantripDesktopFullScreenController(rootView: CantripViewMacScreen(
            remote: remote,
            onClose: { holder.controller?.dismiss(animated: true) },
            onOpenPermissions: {
                holder.controller?.dismiss(animated: true) { remote.showingMacAccess = true }
            }
        ))
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        host.modalPresentationCapturesStatusBarAppearance = true
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .black
        host.view.accessibilityViewIsModal = true
        holder.controller = host
        presenter.present(host, animated: true) {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }
}
#endif
