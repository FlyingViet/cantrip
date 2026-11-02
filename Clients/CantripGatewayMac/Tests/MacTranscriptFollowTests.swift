import AppKit
import SwiftUI
import XCTest
@testable import Hermes

/// The shared transcript on macOS stays on the latest message when something opens below it
/// (a question card, pinned subagents, queued messages), without pulling up a reader who has
/// scrolled away from the end.
@MainActor
private final class TranscriptPanelModel: ObservableObject {
    @Published var panelHeight: CGFloat = 0
    @Published var rows = 30
}

private struct TranscriptPanelHarness: View {
    @ObservedObject var model: TranscriptPanelModel

    var body: some View {
        VStack(spacing: 0) {
            ChatTranscriptScrollView {
                ForEach(0..<model.rows, id: \.self) { row in
                    Text("Message \(row)")
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                        .id(row)
                }
            }
            Color.orange.frame(height: model.panelHeight)
        }
        .frame(width: 640, height: 720)
    }
}

@MainActor
final class MacTranscriptFollowTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private func host(_ model: TranscriptPanelModel) throws -> NSScrollView {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: TranscriptPanelHarness(model: model))
        window.contentView = hosting
        window.orderFront(nil)
        self.window = window
        settle()
        return try XCTUnwrap(Self.scrollView(in: hosting), "the transcript is an NSScrollView")
    }

    private func settle(_ seconds: TimeInterval = 1.2) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            window?.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 1_000 { return scroll }
        return view.subviews.lazy.compactMap(scrollView).first
    }

    /// Points of transcript below the visible area.
    private func distanceFromBottom(_ scroll: NSScrollView) -> CGFloat {
        let document = scroll.documentView?.frame.height ?? 0
        let clip = scroll.contentView.bounds
        let bottomInset = scroll.contentView.contentInsets.bottom
        return scroll.documentView?.isFlipped == false
            ? clip.minY + bottomInset
            : document + bottomInset - clip.maxY
    }

    func testLatestMessageStaysVisibleWhenAPanelOpensAndClosesBelow() throws {
        let model = TranscriptPanelModel()
        let scroll = try host(model)
        XCTAssertLessThan(distanceFromBottom(scroll), 2, "opens at the latest message")

        model.panelHeight = 330
        settle()
        XCTAssertLessThan(distanceFromBottom(scroll), 2, "a card opening below keeps the latest message in view")

        model.rows += 3
        settle()
        XCTAssertLessThan(distanceFromBottom(scroll), 2, "and new messages keep following")

        model.panelHeight = 0
        settle()
        XCTAssertLessThan(distanceFromBottom(scroll), 2, "the card closing leaves the latest message in view")
    }

    func testReaderAboveTheEndIsLeftInPlaceWhenAPanelOpens() throws {
        let model = TranscriptPanelModel()
        let scroll = try host(model)
        let flipped = scroll.documentView?.isFlipped != false
        let readingAt = flipped ? CGFloat(600) : (scroll.documentView?.frame.height ?? 0) - 600 - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: readingAt))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        let before = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(distanceFromBottom(scroll), 500, "reading well above the latest message")

        model.panelHeight = 330
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, before, accuracy: 2, "the reader's place doesn't move")
        XCTAssertGreaterThan(distanceFromBottom(scroll), 500)
    }

    func testFollowRule() {
        func sample(offset: CGFloat, content: CGFloat = 5_000, visible: CGFloat = 600) -> HistoryScrollSample {
            HistoryScrollSample(offset: offset, contentHeight: content, visibleHeight: visible)
        }
        let atEnd = sample(offset: 4_400)
        XCTAssertTrue(HistoryScrollSample.keepsLatestVisible(previous: atEnd, current: sample(offset: 4_400, content: 5_200)),
                      "content grew under a reader at the end")
        XCTAssertTrue(HistoryScrollSample.keepsLatestVisible(previous: atEnd, current: sample(offset: 4_400, visible: 300)),
                      "the visible area got shorter (a card opened below)")
        XCTAssertFalse(HistoryScrollSample.keepsLatestVisible(previous: atEnd, current: sample(offset: 4_300)),
                       "scrolling alone never follows")
        XCTAssertFalse(HistoryScrollSample.keepsLatestVisible(previous: sample(offset: 2_000), current: sample(offset: 2_000, visible: 300)),
                       "a reader further up is left in place")
    }
}
