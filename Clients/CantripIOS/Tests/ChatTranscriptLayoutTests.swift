import SwiftUI
import MarkdownUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
private final class TranscriptLayoutModel: ObservableObject {
    @Published var heights: [CGFloat] = [120, 900, 80, 600]
    @Published var viewportHeight: CGFloat = 500
    @Published var scrollRequest = 0
    @Published var markdown = ""
}

private struct TranscriptLayoutHarness: View {
    @ObservedObject var model: TranscriptLayoutModel

    var body: some View {
        ChatTranscriptScrollView(scrollRequest: model.scrollRequest) {
            ForEach(model.heights.indices, id: \.self) { index in
                Text("Message \(index)")
                    .frame(maxWidth: .infinity)
                    .frame(height: model.heights[index])
            }
            if !model.markdown.isEmpty {
                Markdown(model.markdown)
            }
        }
        .frame(height: model.viewportHeight)
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

    func testExplicitSendReturnsToLatestMessage() async throws {
        let model = TranscriptLayoutModel()
        let (window, controller) = try host(model)
        defer { window.isHidden = true }
        let scroll = try await settle(controller)
        scroll.setContentOffset(.zero, animated: false)
        model.scrollRequest += 1
        assertAtBottom(try await settle(controller))
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
}
