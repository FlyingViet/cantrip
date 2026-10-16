import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Geometry of the interactive back swipe from a project tab to Cantrip Home.
enum CantripBackSwipe {
    static let edgeWidth: CGFloat = 24
    static let parallaxFraction: CGFloat = 0.3
    static let buttonDuration: TimeInterval = 0.32

    /// A drag that starts at the leading edge and moves mostly sideways becomes a back swipe.
    static func begins(start: CGPoint, translation: CGSize) -> Bool {
        (0...edgeWidth).contains(start.x)
            && translation.width > 0
            && translation.width > abs(translation.height) * 1.5
    }

    /// Released past about a third of the width, or flicked hard enough to carry past halfway.
    static func completes(offset: CGFloat, predictedOffset: CGFloat, width: CGFloat) -> Bool {
        guard width > 0 else { return false }
        return offset >= width * 0.35 || (offset >= edgeWidth && predictedOffset >= width * 0.5)
    }

    static func progress(offset: CGFloat, width: CGFloat) -> CGFloat {
        width > 0 ? min(max(offset / width, 0), 1) : 0
    }

    /// Home starts shifted left under the tab and catches up as the tab moves away.
    static func underlayOffset(progress: CGFloat, width: CGFloat) -> CGFloat {
        -width * parallaxFraction * (1 - progress)
    }

    /// Time to carry the tab the rest of the way: shorter for a short remainder or a fast flick.
    static func finishDuration(offset: CGFloat, width: CGFloat, velocity: CGFloat) -> TimeInterval {
        let remaining = max(width - offset, 0)
        guard width > 0, remaining > 0 else { return 0 }
        let byDistance = buttonDuration * Double(remaining / width)
        let byVelocity = velocity > 0 ? Double(remaining / velocity) : .infinity
        return min(max(min(byDistance, byVelocity), 0.12), buttonDuration)
    }
}

/// What Cantrip Home looked like on screen, shown under a tab while it is swiped away and over the
/// live Home until its conversation has reloaded. Only kept while it matches Home's content.
struct CantripScreenSnapshot {
    let signature: String
    let windowSize: CGSize
    let colorScheme: ColorScheme
    #if os(iOS)
    let view: UIView
    #endif

    /// Still lines up with the screen: same window size (no rotation) and appearance.
    @MainActor
    func fits(colorScheme: ColorScheme) -> Bool {
        colorScheme == self.colorScheme && Self.keyWindowSize() == windowSize
    }

    @MainActor
    static func keyWindowSize() -> CGSize? {
        #if os(iOS)
        keyWindow()?.bounds.size
        #else
        nil
        #endif
    }

    #if os(iOS)
    @MainActor
    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            // Inactive too: going to the background is the last chance to picture Home.
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
    #endif

    /// The key window's current frame. Nil when a sheet covers it or there is no window.
    @MainActor
    static func capture(signature: String, colorScheme: ColorScheme) -> CantripScreenSnapshot? {
        #if os(iOS)
        guard let window = keyWindow(), window.bounds.width > 0,
              window.rootViewController?.presentedViewController == nil,
              let view = window.snapshotView(afterScreenUpdates: false) else { return nil }
        return CantripScreenSnapshot(signature: signature, windowSize: window.bounds.size,
                                     colorScheme: colorScheme, view: view)
        #else
        return nil
        #endif
    }
}

/// Drives the back swipe: the tab follows the finger over Home, then either finishes the pop or
/// springs back. Scheduling is injectable so tests can step through it without a display.
@MainActor
final class CantripTabBackTransition: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// The finger is moving the tab.
        case tracking
        /// A cancelled swipe is springing back.
        case settling
        /// The tab is sliding off; the lane switches when it is gone.
        case finishing
        /// Home is showing; its snapshot stays on top until the live conversation reloads.
        case covering
        /// No snapshot: the live Home fades in.
        case entering
    }

    static let coverTimeout: TimeInterval = 1.5
    static let revealDuration: TimeInterval = 0.2

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var offset: CGFloat = 0
    @Published private(set) var contentOpacity: Double = 1
    @Published private(set) var coverOpacity: Double = 1
    @Published private(set) var homeSnapshot: CantripScreenSnapshot?
    var width: CGFloat = 0
    var snapshotFits: @MainActor (CantripScreenSnapshot, ColorScheme) -> Bool = { $0.fits(colorScheme: $1) }
    var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }
    /// Invalidates scheduled steps whenever the transition is restarted or abandoned.
    private var generation = 0

    var acceptsGesture: Bool { phase == .idle || phase == .tracking }
    var showsUnderlay: Bool { phase == .tracking || phase == .settling || phase == .finishing }
    var isBusy: Bool { phase != .idle }
    /// The tab is still on screen moving; the pop itself has not switched lanes yet.
    var isSliding: Bool { phase == .tracking || phase == .settling || phase == .finishing }

    // MARK: Home snapshot

    func keepHomeSnapshot(_ snapshot: CantripScreenSnapshot?) {
        guard phase == .idle, let snapshot else { return }
        homeSnapshot = snapshot
    }

    /// Leaving Home: keep the snapshot only if Home still shows what it captured.
    func leavingHome(signature: String?) {
        guard phase == .idle else { return }
        if homeSnapshot?.signature != signature { homeSnapshot = nil }
    }

    func discardHomeSnapshot() {
        guard phase == .idle else { return }
        homeSnapshot = nil
    }

    // MARK: Gesture

    func track(_ translation: CGFloat) {
        guard acceptsGesture else { return }
        if phase == .idle { generation += 1 }
        phase = .tracking
        offset = max(0, translation)
    }

    func release(predictedOffset: CGFloat, velocity: CGFloat, colorScheme: ColorScheme,
                 pop: @escaping () -> Void) {
        guard phase == .tracking else { return }
        if CantripBackSwipe.completes(offset: offset, predictedOffset: predictedOffset, width: width) {
            finish(duration: CantripBackSwipe.finishDuration(offset: offset, width: width, velocity: velocity),
                   colorScheme: colorScheme, pop: pop)
        } else {
            cancelTracking()
        }
    }

    /// The finger lifted short of the threshold, or the gesture was interrupted.
    func cancelTracking() {
        guard phase == .tracking else { return }
        generation += 1
        let current = generation
        phase = .settling
        withAnimation(.spring(duration: 0.3, bounce: 0)) { offset = 0 }
        schedule(0.3) { [weak self] in
            guard let self, self.generation == current else { return }
            self.phase = .idle
        }
    }

    /// The ‹ Home button: the same pop without a finger.
    func popFromButton(colorScheme: ColorScheme, reduceMotion: Bool, pop: @escaping () -> Void) {
        guard phase == .idle else { return }
        generation += 1
        if reduceMotion {
            phase = .finishing
            didLeaveTab(colorScheme: colorScheme, reduceMotion: true, pop: pop)
        } else {
            finish(duration: CantripBackSwipe.buttonDuration, curve: .easeInOut(duration: CantripBackSwipe.buttonDuration),
                   colorScheme: colorScheme, pop: pop)
        }
    }

    // MARK: Completion

    private func finish(duration: TimeInterval, curve: Animation? = nil,
                        colorScheme: ColorScheme, pop: @escaping () -> Void) {
        generation += 1
        let current = generation
        if let snapshot = homeSnapshot, !snapshotFits(snapshot, colorScheme) { homeSnapshot = nil }
        phase = .finishing
        // Past the edge, so nothing drawn into a landscape safe area stays visible.
        withAnimation(curve ?? .easeOut(duration: duration)) { offset = width + 40 }
        schedule(duration) { [weak self] in
            guard let self, self.generation == current else { return }
            self.didLeaveTab(colorScheme: colorScheme, reduceMotion: false, pop: pop)
        }
    }

    private func didLeaveTab(colorScheme: ColorScheme, reduceMotion: Bool, pop: () -> Void) {
        if let snapshot = homeSnapshot, !snapshotFits(snapshot, colorScheme) { homeSnapshot = nil }
        let current = generation
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) {
            pop()
            offset = 0
            if homeSnapshot != nil {
                phase = .covering
                coverOpacity = 1
            } else {
                phase = .entering
                contentOpacity = reduceMotion ? 1 : 0
            }
        }
        if phase == .covering {
            schedule(Self.coverTimeout) { [weak self] in
                guard let self, self.generation == current else { return }
                self.reveal()
            }
        } else {
            withAnimation(.easeOut(duration: Self.revealDuration)) { contentOpacity = 1 }
            schedule(Self.revealDuration) { [weak self] in
                guard let self, self.generation == current else { return }
                self.phase = .idle
            }
        }
    }

    /// Home's conversation reloaded under the snapshot; let it show once it has drawn.
    func homeBecameReady() {
        guard phase == .covering else { return }
        let current = generation
        schedule(0.12) { [weak self] in
            guard let self, self.generation == current else { return }
            self.reveal()
        }
    }

    private func reveal() {
        guard phase == .covering else { return }
        generation += 1
        let current = generation
        withAnimation(.easeOut(duration: Self.revealDuration)) { coverOpacity = 0 }
        schedule(Self.revealDuration) { [weak self] in
            guard let self, self.generation == current else { return }
            self.reset()
        }
    }

    /// Abandons any transition, e.g. when something else opens a tab mid-swipe.
    func reset() {
        generation += 1
        var instant = Transaction(animation: nil)
        instant.disablesAnimations = true
        withTransaction(instant) {
            if phase == .covering || phase == .entering { homeSnapshot = nil }
            phase = .idle
            offset = 0
            contentOpacity = 1
            coverOpacity = 1
        }
    }
}

extension View {
    /// Inside a project tab, a swipe from the leading edge drags the tab away to reveal Home.
    func cantripTabBackSwipe(
        _ transition: CantripTabBackTransition,
        isEnabled: Bool,
        isHomeReady: Bool,
        pop: @escaping () -> Void
    ) -> some View {
        modifier(CantripTabBackSwipe(
            transition: transition, isEnabled: isEnabled, isHomeReady: isHomeReady, pop: pop
        ))
    }
}

private struct CantripTabBackSwipe: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var transition: CantripTabBackTransition
    let isEnabled: Bool
    let isHomeReady: Bool
    let pop: () -> Void
    @GestureState private var isDragging = false
    @State private var rejected = false

    func body(content: Content) -> some View {
        let progress = CantripBackSwipe.progress(offset: transition.offset, width: transition.width)
        ZStack(alignment: .topLeading) {
            if transition.showsUnderlay || transition.phase == .covering {
                underlay(progress: progress)
                    .zIndex(transition.phase == .covering ? 2 : 0)
            }
            content
                .background {
                    if transition.isBusy { Self.screenBackground.ignoresSafeArea() }
                }
                .offset(x: transition.offset)
                .opacity(transition.contentOpacity)
                .allowsHitTesting(transition.acceptsGesture)
                .zIndex(1)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { transition.width = $0 }
        .simultaneousGesture(drag, isEnabled: isEnabled && transition.acceptsGesture)
        .onChange(of: isDragging) { _, dragging in
            guard !dragging else { return }
            rejected = false
            // An interrupted drag never reports its end; settle once the normal end has had its turn.
            DispatchQueue.main.async { transition.cancelTracking() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { transition.cancelTracking() }
        }
        .onChange(of: isHomeReady) { _, ready in
            if ready { transition.homeBecameReady() }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                guard !rejected else { return }
                if transition.phase == .idle,
                   !CantripBackSwipe.begins(start: value.startLocation, translation: value.translation) {
                    rejected = true
                    return
                }
                transition.track(value.translation.width)
            }
            .onEnded { value in
                rejected = false
                transition.release(
                    predictedOffset: value.predictedEndTranslation.width,
                    velocity: value.velocity.width,
                    colorScheme: colorScheme,
                    pop: pop
                )
            }
    }

    @ViewBuilder
    private func underlay(progress: CGFloat) -> some View {
        let covering = transition.phase == .covering
        ZStack(alignment: .topLeading) {
            if let snapshot = transition.homeSnapshot {
                CantripSnapshotView(snapshot: snapshot)
                    .offset(x: covering || reduceMotion
                            ? 0 : CantripBackSwipe.underlayOffset(progress: progress, width: transition.width))
                    .opacity(covering ? transition.coverOpacity : 1)
            } else if !covering {
                Self.underlayBackground
            }
            if !covering {
                Color.black.opacity(0.25 * (1 - progress))
                // The tab's leading edge casts a soft shadow onto Home.
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 16)
                    .frame(maxHeight: .infinity)
                    .offset(x: transition.offset - 16)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private static var screenBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private static var underlayBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}

private struct CantripSnapshotView: View {
    let snapshot: CantripScreenSnapshot

    var body: some View {
        #if os(iOS)
        SnapshotHost(view: snapshot.view)
        #else
        Color.clear
        #endif
    }
}

#if os(iOS)
private struct SnapshotHost: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> Container { Container(snapshot: view) }
    func updateUIView(_ uiView: Container, context: Context) { uiView.show(view) }

    final class Container: UIView {
        private var snapshot: UIView

        init(snapshot: UIView) {
            self.snapshot = snapshot
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            clipsToBounds = true
            addSubview(snapshot)
        }

        required init?(coder: NSCoder) { nil }

        func show(_ view: UIView) {
            guard view !== snapshot || view.superview !== self else { return }
            snapshot = view
            addSubview(view)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The snapshot is the whole window, drawn at its original size from the top-left.
            snapshot.frame = CGRect(origin: .zero, size: snapshot.bounds.size)
        }
    }
}
#endif
