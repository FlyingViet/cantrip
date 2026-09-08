import SwiftUI

struct ChatTranscriptScrollView<Content: View>: View {
    var scrollRequest = 0
    var dismissKeyboard: () -> Void = {}
    @ViewBuilder var content: () -> Content

    @State private var followsBottom = true
    @State private var userIsScrolling = false
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        ScrollView {
            // Lazy height estimates drift with long Markdown replies and replaced
            // optimistic messages. Measure the transcript before anchoring its end.
            VStack(alignment: .leading, spacing: 14, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(followsBottom ? .bottom : .top, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollDismissesKeyboard(.interactively)
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
