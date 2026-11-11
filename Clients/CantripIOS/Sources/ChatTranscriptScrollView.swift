import SwiftUI

enum ChatTranscriptLayout {
    /// Space between transcript rows; a thread line drawn beside a row crosses it to the next.
    static let rowSpacing: CGFloat = 14
}

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
    #if os(macOS)
    /// A transcript that just opened (a tab switch) keeps its latest message in view until the
    /// reader scrolls, whatever loads into it meanwhile.
    @State private var holdsLatest = true
    #endif

    /// The transcript's end. The Mac scrolls to it through a `ScrollViewProxy`: setting
    /// `position` to the bottom edge does nothing while it already reads "bottom" (as it does when
    /// a transcript opens, and after each follow), and macOS 26 doesn't hold the end on its own.
    static var endID: String { "chat.transcript.end" }

    var body: some View {
        ScrollViewReader { proxy in
            transcript(proxy)
        }
    }

    private func transcript(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                // Lazy height estimates drift with long Markdown replies and replaced
                // optimistic messages. Measure the transcript before anchoring its end.
                #if os(macOS)
                // No scroll targets: `position` then tracks the reader's offset, not the row at
                // the top, which SwiftUI would scroll back to when the transcript changes. A fast
                // scroll reports that row late, so a reply arriving mid-scroll pulled the reader back.
                VStack(alignment: .leading, spacing: ChatTranscriptLayout.rowSpacing, content: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                #else
                VStack(alignment: .leading, spacing: ChatTranscriptLayout.rowSpacing, content: content)
                    .scrollTargetLayout()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                #endif
                Color.clear.frame(height: 1).id(Self.endID)
            }
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
            #if os(macOS)
            if userIsScrolling { holdsLatest = false }
            #endif
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
            scrollToLatest(proxy)
        }
        #if os(iOS)
        // The bottom anchor leaves a transcript at its top when it starts shorter than the
        // viewport and then grows past it (a tab opening on iPhone Duo's short, wide window
        // before its full transcript arrives), so move a reader who follows it to the end.
        .onScrollGeometryChange(for: TranscriptFollowSample.self) { TranscriptFollowSample($0) } action: { _, current in
            guard current.isAwayFromBottom, canFollow else { return }
            followToLatest(proxy)
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
        // was already there. A transcript that just opened stays on it through every size change
        // until the reader scrolls: its first layout can land short of the end (macOS 26), and the
        // rule above would then leave it there as the rest loads. A scroll issued mid-layout can
        // land short, so it's re-applied.
        .onScrollGeometryChange(for: HistoryScrollSample.self) { HistoryScrollSample($0) } action: { previous, current in
            if HistoryScrollSample.readerMovedUp(previous: previous, current: current) { holdsLatest = false }
            guard HistoryScrollSample.keepsLatestVisible(previous: previous, current: current, holdingLatest: holdsLatest),
                  !prependAnchorState.isRestoring, !scrollPhase.isFingerDriven else { return }
            followToLatest(proxy)
        }
        // The first layout can also finish short of the end without any geometry callback, so
        // settle on the end a few times as the transcript opens.
        .task {
            for delay in [150, 350, 900, 2000] {
                guard (try? await Task.sleep(for: .milliseconds(delay))) != nil else { return }
                if holdsLatest, canFollow { toLatest(proxy) }
            }
        }
        #endif
        .overlay(alignment: .bottomTrailing) {
            if !followsBottom {
                Button { scrollToLatest(proxy) } label: {
                    Label("Latest", systemImage: "arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .accessibilityLabel("Scroll to latest message")
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        followsBottom = true
        #if os(macOS)
        holdsLatest = true
        #endif
        toLatest(proxy)
    }

    private func toLatest(_ proxy: ScrollViewProxy) {
        #if os(macOS)
        proxy.scrollTo(Self.endID, anchor: .bottom)
        #else
        position.scrollTo(edge: .bottom)
        #endif
    }

    /// Older history that has finished loading doesn't stop the transcript following its end again
    /// once the reader is back there; only the moment its anchor is being restored does.
    private var canFollow: Bool { followsBottom && !userIsScrolling && !prependAnchorState.isRestoring }

    /// A `scrollTo` issued mid-transition (a tab sliding in) can be dropped, so check again shortly
    /// after and re-apply until the end is actually showing.
    private func followToLatest(_ proxy: ScrollViewProxy) {
        toLatest(proxy)
        follow.generation += 1
        let generation = follow.generation
        Task { @MainActor in
            for delay in [120, 250, 500] {
                guard (try? await Task.sleep(for: .milliseconds(delay))) != nil,
                      generation == follow.generation, follow.distanceFromBottom > 1, canFollow else { return }
                toLatest(proxy)
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
    /// changes height; one reading further up is left in place. A transcript holding its latest
    /// message (opened and not scrolled since) goes back to it on any size change.
    static func keepsLatestVisible(previous: Self, current: Self, holdingLatest: Bool = false) -> Bool {
        let resized = current.visibleHeight != previous.visibleHeight
        if holdingLatest { return resized || current.contentHeight != previous.contentHeight }
        return previous.isNearBottom && (current.contentHeight > previous.contentHeight || resized)
    }

    /// The reader moved toward older messages: the transcript moved up while nothing changed size.
    /// Layout and the app's own scrolls move it only down, or along with a size change.
    static func readerMovedUp(previous: Self, current: Self) -> Bool {
        current.offset < previous.offset - 0.5
            && current.contentHeight == previous.contentHeight && current.visibleHeight == previous.visibleHeight
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

    var isRestoring: Bool { pending != nil }
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
        // Past the restored place toward the latest message is the reader's own scroll (momentum
        // and the top edge's bounce only pull the other way): leave them there.
        if current.offset > offset + 24 {
            pending = nil
            return nil
        }
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
