import SwiftUI
import MarkdownUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
private final class TranscriptLayoutModel: ObservableObject {
    @Published var heights: [CGFloat] = [120, 900, 80, 600]
    @Published var viewportHeight: CGFloat = 500
    @Published var viewportWidth: CGFloat?
    @Published var scrollRequest = 0
    @Published var markdown = ""
    @Published var prompt = ""
    @Published var history: [HistoryRow] = []
    @Published var prependRevision = 0
    @Published var topInset: CGFloat = 0
    var historyRequests = 0
    var prependAnchor: UUID?
    /// When set, each history request prepends one row of this height, like a loaded page.
    var pageHeight: CGFloat?
    var pagesRemaining = 0
    var pageLoading = false
    var overlappingRequests = 0

    func requestHistory() {
        historyRequests += 1
        guard let pageHeight else { return }
        if pageLoading { overlappingRequests += 1; return }
        guard pagesRemaining > 0 else { return }
        pageLoading = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            prependAnchor = history.first?.id ?? UUID()
            history.insert(.init(height: pageHeight), at: 0)
            pagesRemaining -= 1
            prependRevision += 1
            pageLoading = false
        }
    }

    struct HistoryRow: Identifiable {
        let id = UUID()
        let height: CGFloat
    }
}

private struct TranscriptLayoutHarness: View {
    @ObservedObject var model: TranscriptLayoutModel

    var body: some View {
        ChatTranscriptScrollView(scrollRequest: model.scrollRequest,
                                 prependRevision: model.prependRevision,
                                 prependAnchor: model.prependAnchor,
                                 loadOlder: { model.requestHistory() }) {
            ForEach(model.history) { row in
                Text("History message")
                    .frame(maxWidth: .infinity)
                    .frame(height: row.height)
                    .id(row.id)
            }
            ForEach(model.heights.indices, id: \.self) { index in
                Text("Message \(index)")
                    .frame(maxWidth: .infinity)
                    .frame(height: model.heights[index])
            }
            if !model.markdown.isEmpty {
                Markdown(model.markdown)
            }
            if !model.prompt.isEmpty {
                PromptTextView(text: model.prompt)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: model.topInset) }
        .frame(width: model.viewportWidth, height: model.viewportHeight)
    }
}

@MainActor
final class ChatTranscriptLayoutTests: XCTestCase {
    private func host(
        _ model: TranscriptLayoutModel
    ) throws -> (UIWindow, UIHostingController<TranscriptLayoutHarness>) {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: TranscriptLayoutHarness(model: model))
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (window, controller)
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func settle(_ controller: UIViewController) async throws -> UIScrollView {
        try await Task.sleep(for: .milliseconds(250))
        controller.view.layoutIfNeeded()
        return try XCTUnwrap(scrollView(in: controller.view))
    }

    private func assertAtBottom(
        _ scroll: UIScrollView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let maxOffset = max(
            -scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        )
        XCTAssertEqual(scroll.contentOffset.y, maxOffset, accuracy: 2, file: file, line: line)
    }

    func testOpensAtActualEndOfVariableHeightTranscript() async throws {
        let model = TranscriptLayoutModel()
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        assertAtBottom(try await settle(controller))
        XCTAssertEqual(model.historyRequests, 0)
    }

    func testHistoryTriggerPrefetchesOnlyWhileTheUserHeadsIntoOlderHistory() {
        func sample(_ offset: CGFloat, height: CGFloat = 5000) -> HistoryScrollSample {
            HistoryScrollSample(offset: offset, contentHeight: height, visibleHeight: 500)
        }
        func reading(_ was: Bool, _ from: CGFloat, _ to: CGFloat, user: Bool) -> Bool {
            HistoryScrollTrigger.isReadingHistory(was: was, previous: sample(from), current: sample(to),
                                                  userIsScrolling: user)
        }
        func loads(_ reading: Bool, _ from: CGFloat, _ to: CGFloat, user: Bool = true) -> Bool {
            HistoryScrollTrigger.shouldLoad(readingHistory: reading, previous: sample(from),
                                            current: sample(to), userIsScrolling: user)
        }
        func continues(_ reading: Bool, _ offset: CGFloat) -> Bool {
            HistoryScrollTrigger.shouldContinueAfterPrepend(readingHistory: reading, current: sample(offset))
        }
        XCTAssertEqual(HistoryScrollTrigger.prefetchDistance(visibleHeight: 500), 600)
        XCTAssertEqual(HistoryScrollTrigger.prefetchDistance(visibleHeight: 900), 900)

        XCTAssertTrue(reading(false, 700, 650, user: true), "The user's upward scroll starts reading history")
        XCTAssertFalse(reading(false, 700, 650, user: false), "Programmatic or layout movement never does")
        XCTAssertFalse(reading(true, 650, 700, user: true), "Scrolling down stops automatic loading")
        XCTAssertTrue(reading(true, -30, 0, user: true), "Springing back from the top bounce keeps reading")
        XCTAssertTrue(reading(true, 0, 300, user: false), "A restored prepend anchor keeps reading")
        XCTAssertFalse(reading(true, 300, 4500, user: false), "Returning to the latest message ends it")

        XCTAssertTrue(loads(true, 700, 590), "Loading starts about a screen before the top")
        XCTAssertTrue(loads(true, 0, -20), "Pulling past the top of a short transcript loads")
        XCTAssertFalse(loads(true, 900, 800), "Far from the top nothing loads yet")
        XCTAssertFalse(loads(false, 500, 100), "Not reading history, nothing loads")
        XCTAssertFalse(loads(true, 0, 300, user: false), "Programmatic or layout movement never loads")
        XCTAssertTrue(continues(true, 300), "A short restored page chains the next page")
        XCTAssertFalse(continues(true, 700), "A screen of history above the reader is enough")
        XCTAssertFalse(continues(false, 0), "Once the reader turns back, pages stop")
    }

    func testChainedPagesLoadUntilAScreenAboveTheReaderWithoutJumping() async throws {
        let model = TranscriptLayoutModel()
        model.pageHeight = 100
        model.pagesRemaining = 40
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        let scroll = try await settle(controller)
        scroll.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
        _ = try await settle(controller)
        XCTAssertEqual(model.historyRequests, 0, "Opening and positioning never prefetch")
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        _ = try await settle(controller)
        scroll.setContentOffset(CGPoint(x: 0, y: 60), animated: false)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
        let start = scroll.contentOffset.y
        let startHeight = scroll.contentSize.height
        for _ in 0..<20 { _ = try await settle(controller) }
        let loaded = model.history.count
        XCTAssertGreaterThanOrEqual(loaded, 3, "Short pages keep loading without another gesture")
        XCTAssertLessThan(loaded, 40, "Loading stops once a screen of history sits above the reader")
        XCTAssertGreaterThan(scroll.contentOffset.y,
                             HistoryScrollTrigger.prefetchDistance(visibleHeight: scroll.bounds.height) - 1)
        XCTAssertEqual(scroll.contentOffset.y, start + scroll.contentSize.height - startHeight, accuracy: 3,
                       "Every prepended page keeps the message being read in place")
        XCTAssertEqual(model.overlappingRequests, 0)

        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        _ = try await settle(controller)
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + 200), animated: false)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
        for _ in 0..<4 { _ = try await settle(controller) }
        XCTAssertEqual(model.history.count, loaded, "Scrolling down never loads older history")

        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        _ = try await settle(controller)
        scroll.setContentOffset(CGPoint(x: 0, y: 20), animated: false)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
        for _ in 0..<20 { _ = try await settle(controller) }
        XCTAssertGreaterThan(model.history.count, loaded, "Scrolling up again continues through history")
    }

    func testProgrammaticScrollAndLayoutChangesNeverLoadHistory() async throws {
        let model = TranscriptLayoutModel()
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        let scroll = try await settle(controller)
        scroll.setContentOffset(.zero, animated: false)
        _ = try await settle(controller)
        model.heights[0] += 200
        model.viewportHeight = 300
        _ = try await settle(controller)
        XCTAssertEqual(model.historyRequests, 0)
    }

    func testUserScrollNearTopInvokesHistoryLoader() async throws {
        let model = TranscriptLayoutModel()
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        let scroll = try await settle(controller)
        scroll.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
        _ = try await settle(controller)
        scroll.delegate?.scrollViewWillBeginDragging?(scroll)
        _ = try await settle(controller)
        scroll.setContentOffset(CGPoint(x: 0, y: 60), animated: false)
        _ = try await settle(controller)
        XCTAssertGreaterThan(model.historyRequests, 0)
        scroll.delegate?.scrollViewDidEndDragging?(scroll, willDecelerate: false)
    }

    func testSystemScrollToTopLoadsHistory() async throws {
        let model = TranscriptLayoutModel()
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        let scroll = try await settle(controller)
        scroll.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        _ = try await settle(controller)
        XCTAssertEqual(model.historyRequests, 0)
        // A status-bar tap, VoiceOver, or Voice Control scrolls up with an animation, not a drag.
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: true)
        for _ in 0..<4 { _ = try await settle(controller) }
        XCTAssertGreaterThan(model.historyRequests, 0)
    }

    func testStreamingGrowthFollowsActualContentWithoutAnimatedOvershoot() async throws {
        let model = TranscriptLayoutModel()
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        _ = try await settle(controller)
        for height: CGFloat in [800, 1300, 1700] {
            model.heights[3] = height
            assertAtBottom(try await settle(controller))
        }
    }

    func testReplacingOptimisticMessagesClampsToShorterTranscript() async throws {
        let model = TranscriptLayoutModel()
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        _ = try await settle(controller)
        model.heights = [120, 650]
        assertAtBottom(try await settle(controller))
        model.heights = [60]
        assertAtBottom(try await settle(controller))
    }

    func testKeyboardAndComposerResizeKeepLatestMessageVisible() async throws {
        let model = TranscriptLayoutModel()
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        _ = try await settle(controller)
        model.viewportHeight = 240
        assertAtBottom(try await settle(controller))
        model.viewportHeight = 600
        assertAtBottom(try await settle(controller))
    }

    func testWindowWidthChangesReflowStreamingMarkdownAndKeepLatestVisible() async throws {
        let model = TranscriptLayoutModel()
        model.markdown = String(repeating: "A **streaming reply** that wraps with the window. ", count: 180)
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        for width: CGFloat in [320, 744, 480, 320] {
            model.viewportWidth = width
            model.markdown += "\n\nMore output from the running agent."
            let scroll = try await settle(controller)
            XCTAssertEqual(scroll.bounds.width, width, accuracy: 1)
            XCTAssertLessThanOrEqual(scroll.contentSize.width, width + 1)
            assertAtBottom(scroll)
        }
    }

    func testExplicitSendReturnsToLatestMessage() async throws {
        let model = TranscriptLayoutModel()
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        let scroll = try await settle(controller)
        scroll.setContentOffset(.zero, animated: false)
        model.scrollRequest += 1
        assertAtBottom(try await settle(controller))
    }

    func testPrependingOlderMessagesKeepsPreviousFirstMessageAtTop() async throws {
        let model = TranscriptLayoutModel()
        model.heights = []
        model.history = [.init(height: 300), .init(height: 800), .init(height: 200)]
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        let scroll = try await settle(controller)
        scroll.setContentOffset(.zero, animated: false)
        _ = try await settle(controller)
        model.prependAnchor = model.history.first?.id
        model.history.insert(contentsOf: [.init(height: 120), .init(height: 450)], at: 0)
        model.prependRevision += 1
        let updated = try await settle(controller)
        XCTAssertEqual(updated.contentOffset.y + updated.adjustedContentInset.top, 120 + 14 + 450 + 14,
                       accuracy: 3, "History should stay anchored to the previously visible message")
        let offset = updated.contentOffset.y
        model.history.append(.init(height: 600))
        let streaming = try await settle(controller)
        XCTAssertEqual(streaming.contentOffset.y, offset, accuracy: 2,
                       "New output must not pull someone reading older history back to the bottom")
    }

    func testPrependAnchorAddsTheHeaderInsetAndFollowsLateLayout() {
        var anchor = HistoryPrependAnchor()
        func geometry(_ offset: CGFloat, _ height: CGFloat, revision: Int) -> HistoryScrollGeometry {
            HistoryScrollGeometry(height: height, offset: offset, topInset: 110, prependRevision: revision)
        }
        func target(_ previous: HistoryScrollGeometry, _ current: HistoryScrollGeometry, user: Bool = false) -> CGFloat? {
            anchor.target(previous: previous, current: current, userIsScrolling: user)
        }
        XCTAssertNil(target(geometry(-110, 1219, revision: 0), geometry(-110, 1219, revision: 0)))
        XCTAssertEqual(target(geometry(-110, 1219, revision: 0), geometry(-110, 6295, revision: 1)), 5076,
                       "scrollTo(y:) is measured from the resting top under the header")
        XCTAssertEqual(target(geometry(-110, 6295, revision: 1), geometry(-110, 6317, revision: 1)), 5098,
                       "Rows that finish laying out after the prepend are included")
        XCTAssertEqual(target(geometry(-110, 6317, revision: 1), geometry(4966, 6317, revision: 1)), 5098,
                       "A restore that landed on a superseded target is re-applied")
        XCTAssertNil(target(geometry(4966, 6317, revision: 1), geometry(4988, 6317, revision: 1)))
        XCTAssertNil(target(geometry(4988, 6317, revision: 1), geometry(4988, 6900, revision: 1)),
                     "Once restored, later growth (such as streaming below) is left alone")

        XCTAssertNil(target(geometry(100, 1000, revision: 1), geometry(600, 1500, revision: 2)),
                     "A prepend the scroll anchor already absorbed needs no correction")
        XCTAssertNil(target(geometry(600, 1500, revision: 2), geometry(600, 2000, revision: 2)))

        XCTAssertEqual(target(geometry(0, 1000, revision: 2), geometry(0, 1500, revision: 3)), 610)
        XCTAssertNil(target(geometry(0, 1500, revision: 3), geometry(-40, 1500, revision: 3), user: true),
                     "The user's own scrolling is never fought")
        XCTAssertNil(target(geometry(-40, 1500, revision: 3), geometry(-40, 1800, revision: 3)))

        XCTAssertNotNil(target(geometry(0, 1000, revision: 3), geometry(0, 9000, revision: 4)))
        for _ in 0..<3 { _ = target(geometry(0, 9000, revision: 4), geometry(0, 9000, revision: 4)) }
        XCTAssertNil(target(geometry(0, 9000, revision: 4), geometry(0, 9000, revision: 4)),
                     "An unreachable target (clamped content) gives up after a few attempts")
    }

    func testPrependKeepsReadingPositionUnderAHeaderInset() async throws {
        let model = TranscriptLayoutModel()
        model.topInset = 110
        model.heights = []
        model.history = [.init(height: 300), .init(height: 800), .init(height: 200)]
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        let scroll = try await settle(controller)
        XCTAssertEqual(scroll.adjustedContentInset.top, 110, accuracy: 1)
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top + 60), animated: false)
        _ = try await settle(controller)
        let offset = scroll.contentOffset.y
        let height = scroll.contentSize.height
        model.prependAnchor = model.history.first?.id
        model.history.insert(contentsOf: [.init(height: 120), .init(height: 450)], at: 0)
        model.prependRevision += 1
        let updated = try await settle(controller)
        XCTAssertEqual(updated.contentOffset.y, offset + updated.contentSize.height - height, accuracy: 2,
                       "Older messages inserted above keep the visible text in place under the header")
    }

    func testAutomaticPrependPreservesPartiallyScrolledPromptOffset() async throws {
        let model = TranscriptLayoutModel()
        model.heights = []
        model.history = [.init(height: 300), .init(height: 800), .init(height: 200)]
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        let scroll = try await settle(controller)
        scroll.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        _ = try await settle(controller)
        let offset = scroll.contentOffset.y
        let height = scroll.contentSize.height
        model.prependAnchor = model.history.first?.id
        model.history.insert(contentsOf: [.init(height: 120), .init(height: 450)], at: 0)
        model.prependRevision += 1
        let updated = try await settle(controller)
        XCTAssertEqual(updated.contentOffset.y, offset + updated.contentSize.height - height, accuracy: 3)
    }

    func testLongMarkdownCanGrowAndCollapseWithoutTrailingBlankSpace() async throws {
        let model = TranscriptLayoutModel()
        model.markdown = String(repeating: """
        ## Reply

        Here is a paragraph with **important details** and a [link](https://example.com).

        | Item | Result |
        | --- | --- |
        | Chat | Ready |

        ```swift
        let message = "Hello"
        ```


        """, count: 12)
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        assertAtBottom(try await settle(controller))
        model.markdown += "\n\n" + String(repeating: "Streaming more text. ", count: 100)
        assertAtBottom(try await settle(controller))
        model.markdown = "**Done.**"
        assertAtBottom(try await settle(controller))
    }

    func testMegabytePromptKeepsTranscriptLayoutBounded() async throws {
        let model = TranscriptLayoutModel()
        model.heights = []
        model.prompt = String(repeating: "Long prompt 👩🏽‍💻 cafe\u{301}\n", count: 50_000)
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        let scroll = try await settle(controller)
        XCTAssertLessThan(scroll.contentSize.height, 600, "Only the bounded preview should be laid out")
        assertAtBottom(scroll)
        model.heights = [80]
        model.scrollRequest += 1
        assertAtBottom(try await settle(controller))
    }

    func testPromptPagesPreserveFullUnicodeText() {
        let text = String(repeating: "Long prompt 👩🏽‍💻 cafe\u{301}\n", count: 50_000)
        let prompt = PromptText(text)
        XCTAssertTrue(prompt.isLong)
        XCTAssertEqual(prompt.preview.count, PromptText.previewLimit)
        var start = text.startIndex
        var restored = ""
        while start < text.endIndex {
            let page = prompt.page(from: start)
            XCTAssertLessThanOrEqual(page.text.count, PromptText.pageLimit)
            XCTAssertGreaterThan(page.end, start)
            restored += page.text
            start = page.end
        }
        XCTAssertEqual(restored, text)
        XCTAssertFalse(PromptText(String(repeating: "x", count: 1_200)).isLong)
        XCTAssertTrue(PromptText(String(repeating: "x", count: 1_201)).isLong)
    }
}
