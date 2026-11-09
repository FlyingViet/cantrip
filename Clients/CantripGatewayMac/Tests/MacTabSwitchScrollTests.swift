import AppKit
import SwiftUI
import XCTest
@testable import Hermes

/// Opening a tab on the Mac shows its latest message, however its transcript arrives: the
/// previous tab's rows for a frame (the view model syncs a beat later), then the cached rows,
/// then the Mac's refresh, then images loading. A reader who scrolls up meanwhile is left there.
@MainActor
private final class TabSwitchModel: ObservableObject {
    @Published var tab = "A"
    @Published var rows: [CGFloat] = Array(repeating: 90, count: 30)
}

private struct TabSwitchHarness: View {
    @ObservedObject var model: TabSwitchModel

    var body: some View {
        // Fresh per tab, as MacHomeChatView's `.id(transcriptIdentity)`.
        ChatTranscriptScrollView {
            ForEach(Array(model.rows.enumerated()), id: \.offset) { index, height in
                Text("\(model.tab) message \(index)")
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            }
        }
        .id(model.tab)
        .frame(width: 640, height: 720)
    }
}

@MainActor
final class MacTabSwitchScrollTests: XCTestCase {
    private var window: NSWindow?
    private var hosting: NSView?

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private func host(_ model: TabSwitchModel) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: TabSwitchHarness(model: model))
        window.contentView = hosting
        window.orderFront(nil)
        self.window = window
        self.hosting = hosting
        settle()
    }

    private func settle(_ seconds: TimeInterval = 1.2) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            window?.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func scrollView() throws -> NSScrollView {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 1_000 { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(hosting.flatMap(find), "the transcript is an NSScrollView")
    }

    /// Points of transcript below the visible area.
    private func distance() throws -> CGFloat {
        let scroll = try scrollView()
        let document = scroll.documentView?.frame.height ?? 0
        let clip = scroll.contentView.bounds
        let bottomInset = scroll.contentView.contentInsets.bottom
        return scroll.documentView?.isFlipped == false
            ? clip.minY + bottomInset
            : document + bottomInset - clip.maxY
    }

    private func switchTab(_ model: TabSwitchModel, to tab: String, cached: [CGFloat], refreshed: [CGFloat]? = nil) {
        model.tab = tab
        DispatchQueue.main.async { model.rows = cached }
        settle(0.3)
        if let refreshed { model.rows = refreshed }
    }

    func testEachTabOpensAtItsLatestMessage() throws {
        let model = TabSwitchModel()
        host(model)
        XCTAssertLessThan(try distance(), 2, "the first tab opens at its latest message")

        switchTab(model, to: "B", cached: Array(repeating: 120, count: 40))
        settle()
        XCTAssertLessThan(try distance(), 2, "a longer cached tab")

        switchTab(model, to: "C", cached: Array(repeating: 60, count: 20))
        settle()
        XCTAssertLessThan(try distance(), 2, "a shorter cached tab")

        switchTab(model, to: "D", cached: [], refreshed: Array(repeating: 110, count: 40))
        settle()
        XCTAssertLessThan(try distance(), 2, "a tab whose transcript arrives after the switch")

        switchTab(model, to: "E", cached: Array(repeating: 100, count: 20), refreshed: Array(repeating: 100, count: 30))
        settle()
        XCTAssertLessThan(try distance(), 2, "a refresh with newer messages")

        switchTab(model, to: "F", cached: Array(repeating: 100, count: 30))
        settle(1.5)
        var grown = model.rows
        for index in stride(from: 2, to: 30, by: 3) { grown[index] = 420 }
        model.rows = grown
        settle()
        XCTAssertLessThan(try distance(), 2, "images loading after the tab opened, above and below the fold")
    }

    func testReaderScrollingUpAsATabOpensIsLeftInPlace() throws {
        let model = TabSwitchModel()
        host(model)
        switchTab(model, to: "B", cached: Array(repeating: 100, count: 40))
        let scroll = try scrollView()
        let flipped = scroll.documentView?.isFlipped != false
        let readingAt = flipped ? CGFloat(600) : (scroll.documentView?.frame.height ?? 0) - 600 - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: readingAt))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(0.1)
        let before = scroll.contentView.bounds.minY
        var grown = model.rows
        for index in stride(from: 30, to: 40, by: 2) { grown[index] = 300 }
        model.rows = grown
        settle(2.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, before, accuracy: 2, "newer messages loading don't pull the reader down")
        XCTAssertGreaterThan(try distance(), 500)
    }
}
