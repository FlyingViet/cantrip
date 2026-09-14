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
    @State private var position = ScrollPosition(edge: .bottom)

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
        .onUpwardHistoryScroll(perform: loadOlder)
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
            if endedUserScroll {
                followsBottom = context.geometry.contentSize.height
                    - context.geometry.visibleRect.maxY < 72
            }
        }
        .onChange(of: scrollRequest) { _, _ in
            scrollToLatest()
        }
        .onScrollGeometryChange(for: HistoryScrollGeometry.self) { geometry in
            HistoryScrollGeometry(geometry, prependRevision: prependRevision)
        } action: { previous, current in
            guard previous.prependRevision != current.prependRevision, prependAnchor != nil else { return }
            followsBottom = false
            position.scrollTo(y: max(0, previous.offset + current.height - previous.height))
        }
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
}

struct HistoryScrollTrigger {
    static func shouldLoad(previous: CGFloat, current: CGFloat, userIsScrolling: Bool) -> Bool {
        userIsScrolling && current < previous && current <= 120
    }
}

struct HistoryScrollGeometry: Equatable {
    let height: CGFloat
    let offset: CGFloat
    let prependRevision: Int

    init(_ geometry: ScrollGeometry, prependRevision: Int) {
        height = geometry.contentSize.height
        offset = geometry.visibleRect.minY
        self.prependRevision = prependRevision
    }
}

private struct UpwardHistoryScrollModifier: ViewModifier {
    let perform: () -> Void
    @State private var userIsScrolling = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                userIsScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.visibleRect.minY
            } action: { previous, current in
                if HistoryScrollTrigger.shouldLoad(previous: previous, current: current,
                                                   userIsScrolling: userIsScrolling) {
                    perform()
                }
            }
    }
}

extension View {
    func onUpwardHistoryScroll(perform: @escaping () -> Void) -> some View {
        modifier(UpwardHistoryScrollModifier(perform: perform))
    }
}
