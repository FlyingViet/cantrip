import SwiftUI

struct ChatTranscriptScrollView<Content: View>: View {
    var scrollRequest = 0
    var prependRevision = 0
    var prependAnchor: UUID?
    var dismissKeyboard: () -> Void = {}
    var loadOlder: () -> Void = {}
    @ViewBuilder var content: () -> Content

    @State private var followsBottom = true
    @State private var userIsScrolling = false
    @State private var scrollPhase = ScrollPhase.idle
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var prependAnchorState = HistoryPrependAnchor()
    @State private var follow = TranscriptFollowTracker()

    var body: some View {
        ScrollView {
            // Lazy height estimates drift with long Markdown replies and replaced
            // optimistic messages. Measure the transcript before anchoring its end.
            VStack(alignment: .leading, spacing: 14, content: content)
                .scrollTargetLayout()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(followsBottom ? .bottom : .top, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollDismissesKeyboard(.interactively)
        .onUpwardHistoryScroll(prependRevision: prependRevision, perform: loadOlder)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY < 72
        } action: { _, isNearBottom in
            if userIsScrolling {
                followsBottom = isNearBottom
            }
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
            let endedUserScroll = newPhase == .idle
                && (oldPhase == .tracking
                    || oldPhase == .interacting
                    || oldPhase == .decelerating)
            userIsScrolling = newPhase == .tracking
                || newPhase == .interacting
                || newPhase == .decelerating
            scrollPhase = newPhase
            if newPhase == .idle, prependAnchor != nil,
               let target = prependAnchorState.target(previous: HistoryScrollGeometry(context.geometry, prependRevision: prependRevision),
                                                      current: HistoryScrollGeometry(context.geometry, prependRevision: prependRevision),
                                                      userIsScrolling: false) {
                position.scrollTo(y: target)
            }
            if endedUserScroll {
                followsBottom = context.geometry.contentSize.height
                    - context.geometry.visibleRect.maxY < 72
            }
        }
        .onChange(of: scrollRequest) { _, _ in
            scrollToLatest()
        }
        #if os(iOS)
        // The bottom anchor leaves a transcript at its top when it starts shorter than the
        // viewport and then grows past it (a tab opening on iPhone Duo's short, wide window
        // before its full transcript arrives), so move a reader who follows it to the end.
        .onScrollGeometryChange(for: TranscriptFollowSample.self) { TranscriptFollowSample($0) } action: { _, current in
            guard current.isAwayFromBottom, canFollow else { return }
            followToLatest()
        }
        // A tab's first transcript can finish laying out while the tab slides in, without any
        // geometry callback, so settle on the end a few times as it opens (unless the reader or
        // the history anchor has moved it).
        .task {
            for delay in [350, 900, 2000] {
                guard (try? await Task.sleep(for: .milliseconds(delay))) != nil else { return }
                if canFollow, position.edge == .bottom { position.scrollTo(edge: .bottom) }
            }
        }
        #endif
        .onScrollGeometryChange(for: CGFloat.self) { TranscriptFollowSample($0).distanceFromBottom } action: { _, distance in
            follow.distanceFromBottom = distance
        }
        .onScrollGeometryChange(for: HistoryScrollGeometry.self) { geometry in
            HistoryScrollGeometry(geometry, prependRevision: prependRevision)
        } action: { previous, current in
            guard prependAnchor != nil,
                  let target = prependAnchorState.target(previous: previous, current: current,
                                                         userIsScrolling: scrollPhase.isFingerDriven,
                                                         momentum: scrollPhase.isMomentum) else { return }
            followsBottom = false
            position.scrollTo(y: target)
        }
        #if os(macOS)
        // macOS holds the bottom anchor neither while content grows (images loading, streaming
        // replies) nor when the transcript itself gets shorter (a question card, pinned subagents
        // or queued messages opening below it), so stay on the latest message whenever the reader
        // was already there. A scroll issued mid-layout can land short, so it's re-applied.
        .onScrollGeometryChange(for: HistoryScrollSample.self) { HistoryScrollSample($0) } action: { previous, current in
            guard HistoryScrollSample.keepsLatestVisible(previous: previous, current: current),
                  prependAnchor == nil, !scrollPhase.isFingerDriven else { return }
            followToLatest()
        }
        #endif
        .overlay(alignment: .bottomTrailing) {
            if !followsBottom {
                Button(action: scrollToLatest) {
                    Label("Latest", systemImage: "arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .accessibilityLabel("Scroll to latest message")
            }
        }
    }

    private func scrollToLatest() {
        followsBottom = true
        position.scrollTo(edge: .bottom)
    }

    private var canFollow: Bool { followsBottom && !userIsScrolling && prependAnchor == nil }

    /// A `scrollTo` issued mid-transition (a tab sliding in) can be dropped, so check again shortly
    /// after and re-apply until the end is actually showing.
    private func followToLatest() {
        position.scrollTo(edge: .bottom)
        follow.generation += 1
        let generation = follow.generation
        Task { @MainActor in
            for delay in [120, 250, 500] {
                guard (try? await Task.sleep(for: .milliseconds(delay))) != nil,
                      generation == follow.generation, follow.distanceFromBottom > 1, canFollow else { return }
                position.scrollTo(edge: .bottom)
            }
        }
    }
}

/// Follow bookkeeping read outside `body`, so per-frame scroll updates don't re-render the transcript.
@MainActor
private final class TranscriptFollowTracker {
    var distanceFromBottom: CGFloat = 0
    var generation = 0
}

/// Content and viewport sizes, compared alone so scrolling never triggers a follow; carries how far
/// the visible area is from the end when they change.
struct TranscriptFollowSample: Equatable {
    var contentHeight: CGFloat
    var containerHeight: CGFloat
    var distanceFromBottom: CGFloat

    init(contentHeight: CGFloat, containerHeight: CGFloat, distanceFromBottom: CGFloat) {
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.distanceFromBottom = distanceFromBottom
    }

    init(_ geometry: ScrollGeometry) {
        self.init(contentHeight: geometry.contentSize.height, containerHeight: geometry.containerSize.height,
                  distanceFromBottom: geometry.contentSize.height + geometry.contentInsets.bottom
                      - geometry.visibleRect.maxY)
    }

    var isAwayFromBottom: Bool { distanceFromBottom > 1 }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.contentHeight == rhs.contentHeight && lhs.containerHeight == rhs.containerHeight
    }
}

/// One scroll-geometry reading used to decide when older history should load.
struct HistoryScrollSample: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
    var visibleHeight: CGFloat

    init(offset: CGFloat, contentHeight: CGFloat, visibleHeight: CGFloat) {
        self.offset = offset
        self.contentHeight = contentHeight
        self.visibleHeight = visibleHeight
    }

    init(_ geometry: ScrollGeometry) {
        self.init(offset: geometry.visibleRect.minY, contentHeight: geometry.contentSize.height,
                  visibleHeight: geometry.visibleRect.height)
    }

    var isNearBottom: Bool { contentHeight - (offset + visibleHeight) < 72 }

    /// A reader at the latest message stays there when the content grows or the visible area
    /// changes height; one reading further up is left in place.
    static func keepsLatestVisible(previous: Self, current: Self) -> Bool {
        previous.isNearBottom
            && (current.contentHeight > previous.contentHeight || current.visibleHeight != previous.visibleHeight)
    }
}

enum HistoryScrollTrigger {
    /// Older pages start loading about a screen before the reader reaches the top.
    static func prefetchDistance(visibleHeight: CGFloat) -> CGFloat {
        max(600, visibleHeight)
    }

    /// Whether the reader is heading into older history. Only the user's own upward
    /// movement starts it; moving down or returning to the latest message ends it.
    static func isReadingHistory(was: Bool, previous: HistoryScrollSample,
                                 current: HistoryScrollSample, userIsScrolling: Bool) -> Bool {
        if userIsScrolling {
            if current.offset < previous.offset { return true }
            // Springing back from the top bounce is not a downward scroll.
            if current.offset > previous.offset, previous.offset >= 0 { return false }
            return was
        }
        return was && !current.isNearBottom
    }

    /// Loads only on the user's own movement; programmatic and layout movement never do.
    static func shouldLoad(readingHistory: Bool, previous: HistoryScrollSample,
                           current: HistoryScrollSample, userIsScrolling: Bool) -> Bool {
        userIsScrolling && readingHistory && current.offset != previous.offset
            && current.offset <= prefetchDistance(visibleHeight: current.visibleHeight)
    }

    /// After a page is prepended and its anchor restored, keeps loading while the reader
    /// still has less than a screen of history above them.
    static func shouldContinueAfterPrepend(readingHistory: Bool, current: HistoryScrollSample) -> Bool {
        readingHistory && current.offset <= prefetchDistance(visibleHeight: current.visibleHeight)
    }
}

struct HistoryScrollGeometry: Equatable {
    let height: CGFloat
    let offset: CGFloat
    /// `visibleRect.minY` rests at `-topInset` under a header, while `ScrollPosition.scrollTo(y:)`
    /// measures from that resting top, so targets must add the inset back.
    let topInset: CGFloat
    let prependRevision: Int

    init(height: CGFloat, offset: CGFloat, topInset: CGFloat = 0, prependRevision: Int) {
        self.height = height
        self.offset = offset
        self.topInset = topInset
        self.prependRevision = prependRevision
    }

    init(_ geometry: ScrollGeometry, prependRevision: Int) {
        self.init(height: geometry.contentSize.height, offset: geometry.visibleRect.minY,
                  topInset: geometry.contentInsets.top, prependRevision: prependRevision)
    }
}

/// Keeps the reader's place when older messages are inserted above them. Inserted rows can
/// finish laying out in a later update than the prepend, and a second `scrollTo` issued before
/// the first lands is dropped, so the target is re-applied until the offset actually matches.
/// A flick's momentum, and its bounce at the top edge, keep pulling the view after a restore
/// lands, so the anchor holds until scrolling comes to rest; only the user's finger ends it early.
struct HistoryPrependAnchor {
    private var pending: (offset: CGFloat, height: CGFloat, attempts: Int)?
    private static let maximumAttempts = 4
    /// About a second of frames: enough to outlast deceleration and the edge bounce.
    private static let maximumMomentumAttempts = 60

    /// The `ScrollPosition.scrollTo(y:)` value to apply for this geometry change, if any.
    /// `userIsScrolling` means a finger on the screen; `momentum` is deceleration or an animation.
    mutating func target(previous: HistoryScrollGeometry, current: HistoryScrollGeometry,
                         userIsScrolling: Bool, momentum: Bool = false) -> CGFloat? {
        if previous.prependRevision != current.prependRevision {
            pending = (previous.offset, previous.height, 0)
        } else if userIsScrolling {
            pending = nil
        }
        guard var restoring = pending else { return nil }
        let offset = restoring.offset + current.height - restoring.height
        if abs(offset - current.offset) < 0.5 {
            if !momentum { pending = nil }
            return nil
        }
        guard restoring.attempts < (momentum ? Self.maximumMomentumAttempts : Self.maximumAttempts) else {
            pending = nil
            return nil
        }
        restoring.attempts += 1
        pending = restoring
        return max(0, offset + current.topInset)
    }
}

private struct UpwardHistoryScrollModifier: ViewModifier {
    let prependRevision: Int
    let perform: () -> Void
    @State private var userIsScrolling = false
    @State private var systemIsScrolling = false
    @State private var readingHistory = false
    @State private var latest: HistoryScrollSample?

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                userIsScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                systemIsScrolling = phase == .animating
            }
            .onScrollGeometryChange(for: HistoryScrollSample.self) { geometry in
                HistoryScrollSample(geometry)
            } action: { previous, current in
                latest = current
                // The app only animates downward (to the latest message), so an animated upward
                // scroll is the user's: a status-bar tap, VoiceOver, or Voice Control.
                let userDriven = userIsScrolling || (systemIsScrolling && current.offset < previous.offset)
                readingHistory = HistoryScrollTrigger.isReadingHistory(
                    was: readingHistory, previous: previous, current: current, userIsScrolling: userDriven
                )
                if HistoryScrollTrigger.shouldLoad(readingHistory: readingHistory, previous: previous,
                                                   current: current, userIsScrolling: userDriven) {
                    perform()
                }
            }
            .onChange(of: prependRevision) { _, _ in
                guard readingHistory else { return }
                Task { @MainActor in
                    // Measure only after the prepend's anchor restoration has been applied.
                    try? await Task.sleep(for: .milliseconds(80))
                    if let latest, HistoryScrollTrigger.shouldContinueAfterPrepend(
                        readingHistory: readingHistory, current: latest
                    ) {
                        perform()
                    }
                }
            }
    }
}

extension View {
    /// Loads older history automatically while the user scrolls up toward the top.
    func onUpwardHistoryScroll(prependRevision: Int, perform: @escaping () -> Void) -> some View {
        modifier(UpwardHistoryScrollModifier(prependRevision: prependRevision, perform: perform))
    }
}

extension ScrollPhase {
    /// A finger is on the scroll view, so its movement is the user's own.
    var isFingerDriven: Bool { self == .tracking || self == .interacting }
    /// Deceleration, the edge bounce, or an animated scroll.
    var isMomentum: Bool { self == .decelerating || self == .animating }
}
