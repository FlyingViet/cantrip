import SwiftUI

/// Cold-launch splash: Pip in the Dino Hoodie picks up from the static launch screen at the
/// same frame, size and position, hops hello, then fades into the app. The app loads underneath
/// the whole time; the splash only covers it and never gates startup, reconnection or Home.
enum CantripLaunchSplash {
    /// Info.plist `UILaunchScreen` assets; the splash draws on the same color.
    static let backgroundColorName = "LaunchBackground"
    static let imageName = "LaunchPip"
    /// Point size of the `LaunchPip` image, centered on screen by the system launch screen.
    static let badgeSize: CGFloat = 132
    static let outfit: CantripMascotOutfit = .dinoHoodie
    /// Renderer clock for the launch image: neutral pose, eyes open, no tilt or breath.
    static let handoffTime: TimeInterval = 0
    static let wordmark = "Cantrip"
    static let wordmarkGap: CGFloat = 26
    static let glowColor = Color(red: 0.22, green: 0.55, blue: 0.27)
    static let glowPeakOpacity = 0.32

    /// The visible chat has settled (loaded or failed), or there is nothing remote to wait for.
    @MainActor
    static func isReady(lane: ExecutionLane, remote: CantripRemoteModel) -> Bool {
        guard lane.usesCantripRemote, remote.isConfigured else { return true }
        if remote.detailError != nil || remote.errorMessage != nil { return true }
        if lane == .home { return remote.selectedSession?.isCantripHome == true }
        return remote.selectedSession != nil
            || (remote.connectionState == .connected && remote.sessions.isEmpty)
    }
}

struct CantripLaunchSplashTiming: Equatable {
    let reducedMotion: Bool

    /// Rest on the exact launch frame while the system finishes its launch-screen crossfade.
    var hold: TimeInterval { reducedMotion ? 0 : 0.25 }
    /// Pip's hello hop (the mascot's celebration, compressed).
    var hop: TimeInterval { 0.7 }
    /// Earliest dismissal, so the greeting reads even when the app is ready instantly.
    var minimum: TimeInterval { reducedMotion ? 0.55 : 1.0 }
    /// Latest dismissal; a slow reconnect keeps loading in the app, not behind the splash.
    var maximum: TimeInterval { reducedMotion ? 0.9 : 1.2 }
    var exit: TimeInterval { reducedMotion ? 0.25 : 0.3 }
    var skipExit: TimeInterval { 0.18 }

    func dismissal(readyAt: TimeInterval?) -> TimeInterval {
        min(maximum, max(minimum, readyAt ?? maximum))
    }

    /// Celebration clock for the renderer, or nil when Pip should rest.
    func celebration(at elapsed: TimeInterval) -> TimeInterval? {
        guard !reducedMotion else { return nil }
        let progress = (elapsed - hold) / hop
        guard progress > 0, progress < 1 else { return nil }
        return progress * CantripMascotView.celebrationDuration
    }

    /// Wordmark and glow fade in after the handoff; opacity only, so Reduce Motion keeps it.
    func greeting(at elapsed: TimeInterval) -> Double {
        Self.ease((elapsed - hold - 0.05) / 0.35)
    }

    static func ease(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }
}

/// Process-wide: created once with the app, so resuming from the background never replays it.
@MainActor
final class CantripLaunchSplashController: ObservableObject {
    @Published private(set) var isPresented: Bool
    @Published private(set) var skipRequested = false

    init(isPresented: Bool = true) {
        self.isPresented = isPresented
    }

    /// Notification and link launches go straight to their target.
    func skip() {
        guard isPresented else { return }
        skipRequested = true
    }

    func finish() {
        isPresented = false
    }
}

extension View {
    func cantripLaunchSplash(
        _ controller: CantripLaunchSplashController,
        isReady: @escaping @MainActor () -> Bool
    ) -> some View {
        overlay { CantripLaunchSplashOverlay(controller: controller, isReady: isReady) }
    }
}

private struct CantripLaunchSplashOverlay: View {
    @ObservedObject var controller: CantripLaunchSplashController
    let isReady: @MainActor () -> Bool

    var body: some View {
        if controller.isPresented {
            CantripLaunchSplashView(controller: controller, isReady: isReady)
                .transition(.identity)
        }
    }
}

struct CantripLaunchSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var controller: CantripLaunchSplashController
    let isReady: @MainActor () -> Bool
    /// Renders one deterministic frame for tests: (elapsed, exit start).
    var frame: (elapsed: TimeInterval, leavingAt: TimeInterval?)? = nil
    var reducedMotionOverride: Bool? = nil

    @State private var start: Date?
    @State private var leavingAt: TimeInterval?
    @State private var exitDuration: TimeInterval = 0.3

    private var timing: CantripLaunchSplashTiming {
        CantripLaunchSplashTiming(
            reducedMotion: reducedMotionOverride ?? (reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled)
        )
    }

    var body: some View {
        TimelineView(.animation(paused: frame != nil || start == nil)) { context in
            let elapsed = frame?.elapsed ?? start.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
            content(elapsed: elapsed, leavingAt: frame?.leavingAt ?? leavingAt)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: skip)
        .allowsHitTesting(!voiceOver)
        .accessibilityHidden(true)
        .onAppear(perform: startIfActive)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                controller.finish()
            } else {
                startIfActive()
            }
        }
        .onChange(of: controller.skipRequested) { _, requested in
            if requested { skip() }
        }
        .task(id: start) { await dismissWhenReady() }
        .task {
            // A scene held inactive (system alert, unfocused window) must not keep the splash up.
            try? await Task.sleep(for: .seconds(1))
            guard frame == nil, start == nil, scenePhase != .background else { return }
            start = Date()
        }
    }

    private func content(elapsed: TimeInterval, leavingAt: TimeInterval?) -> some View {
        let timing = self.timing
        let greeting = timing.greeting(at: elapsed)
        let exit = leavingAt.map { CantripLaunchSplashTiming.ease((elapsed - $0) / exitDuration) } ?? 0
        return ZStack {
            Color(CantripLaunchSplash.backgroundColorName)
            Circle()
                .fill(RadialGradient(
                    colors: [CantripLaunchSplash.glowColor, CantripLaunchSplash.glowColor.opacity(0)],
                    center: .center, startRadius: 0, endRadius: CantripLaunchSplash.badgeSize
                ))
                .frame(width: CantripLaunchSplash.badgeSize * 2, height: CantripLaunchSplash.badgeSize * 2)
                .opacity(CantripLaunchSplash.glowPeakOpacity * greeting)
            CantripLaunchPipBadge(
                time: CantripLaunchSplash.handoffTime + (timing.reducedMotion ? 0 : elapsed),
                celebration: timing.celebration(at: elapsed)
            )
            .overlay(alignment: .top) {
                Text(CantripLaunchSplash.wordmark)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .fixedSize()
                    .offset(y: CantripLaunchSplash.badgeSize + CantripLaunchSplash.wordmarkGap
                        + (timing.reducedMotion ? 0 : 10 * (1 - greeting)))
                    .opacity(greeting)
            }
            .scaleEffect(timing.reducedMotion ? 1 : 1 + 0.08 * exit)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(1 - exit)
    }

    /// Starts once the scene is active, which is after iOS has begun crossfading from the launch
    /// screen; starting at the first render would let Pip hop while the launch image is still visible.
    private func startIfActive() {
        guard frame == nil, start == nil, scenePhase == .active else { return }
        start = Date()
    }

    private func dismissWhenReady() async {
        guard let start else { return }
        var readyAt: TimeInterval?
        while !Task.isCancelled, leavingAt == nil {
            let elapsed = Date().timeIntervalSince(start)
            if readyAt == nil, isReady() { readyAt = elapsed }
            if elapsed >= timing.dismissal(readyAt: readyAt) { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard !Task.isCancelled else { return }
        await leave(exit: timing.exit)
    }

    private func skip() {
        guard frame == nil else { return }
        guard start != nil else {
            controller.finish()
            return
        }
        Task { await leave(exit: timing.skipExit) }
    }

    private func leave(exit: TimeInterval) async {
        guard let start, leavingAt == nil else { return }
        exitDuration = exit
        leavingAt = Date().timeIntervalSince(start)
        try? await Task.sleep(for: .seconds(exit))
        controller.finish()
    }
}

/// Pip exactly as the launch image draws it; the asset is rendered from this view.
struct CantripLaunchPipBadge: View {
    var time: TimeInterval = CantripLaunchSplash.handoffTime
    var celebration: TimeInterval? = nil

    var body: some View {
        Canvas { context, size in
            CantripMascotRenderer(
                mood: .idle, outfit: CantripLaunchSplash.outfit, time: time,
                celebration: celebration, motion: true, dark: true
            )
            .draw(in: &context, size: size)
        }
        .frame(width: CantripLaunchSplash.badgeSize, height: CantripLaunchSplash.badgeSize)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1) }
    }
}
