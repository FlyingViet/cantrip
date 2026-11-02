import AppKit
import SwiftUI
import XCTest
@testable import Hermes

/// Cantrip Memory files rendered as Markdown on the Mac (the shared reader from Hermes).
@MainActor
final class MemoryMarkdownMacTests: XCTestCase {
    private let sample = """
    # Cantrip — self-maintenance
    Queries reach you through **Cantrip**. See [the docs](https://example.com/docs) and ![a diagram](https://outside.example/d.png).

    ## Build / test
    - `make test` runs every suite
    - `make app` stages `.Cantrip.app.pending`

    | Setting | Value |
    |---|---|
    | Backend | Copilot |
    | Memory | On |

    ```sh
    make -C ~/Coding/Cantrip app
    ```

    > Packaging alone does not activate new host APIs.
    """

    func testPagesEndAtLineBreaksOnTheMac() {
        let page = CantripMemoryPage(
            document: CantripMemoryEntry(id: "self.md", category: .notes, bytes: 400, modifiedAt: 0, characterLimit: nil),
            text: "# Notes\n```sh\nmake te", offset: 0, nextOffset: 21, revision: "r1"
        )
        let aligned = CantripMemoryMarkdown.aligned(page)
        XCTAssertEqual(aligned.text, "# Notes\n```sh\n")
        XCTAssertEqual(aligned.nextOffset, 14)
        XCTAssertEqual(CantripMemoryMarkdown.fence(after: aligned.text, startingIn: nil),
                       CantripMemoryMarkdown.Fence(marker: "`", count: 3))
    }

    /// Renders for review. Set TEST_RUNNER_MEMORY_MARKDOWN_ARTIFACT_DIR (pass
    /// TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testMemoryMarkdownMacScreenshot() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_MEMORY_MARKDOWN_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_MEMORY_MARKDOWN_ARTIFACT_DIR to render memory Markdown on the Mac.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let view = CantripMemoryMarkdownText(text: sample)
            .padding()
            .frame(width: 620, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.setContentSize(host.fittingSize)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 621, "Formatted memory stays within the reader's width")
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("mac-memory-formatted.png"))
    }
}
