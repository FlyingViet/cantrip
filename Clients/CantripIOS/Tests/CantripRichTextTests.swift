import SwiftUI
import UIKit
import XCTest
@testable import Hermes

/// Reply markdown as one selectable text: prose, top-level code fences, image lines and tables,
/// attributed text that keeps lists, headings, tables and links, and tables drawn as grids.
final class CantripRichTextTests: XCTestCase {
    private let answer = """
    The build passed after one fix.

    - **Cause:** a stale cache in `DerivedData`.
    - **Fix:** the pruner now removes it.

    | Step | Time |
    |---|---:|
    | Build | 4 min |
    | Tests | 12 min |
    """

    /// A real reply's benchmark table: four columns, with first-column labels too long for one line
    /// on a phone.
    private let benchmark = """
    Splash 1.7.0 has been live on the Studio since 1:24 AM. It's faster at generating text, with one slowdown in a rare case.

    | Test | 1.6.1 | 1.7.0 | Change |
    |---|---|---|---|
    | Chat speed | 79.8 tok/s | 91.4 tok/s | +15% |
    | Code speed | 172.8 tok/s | 193.4 tok/s | +12%, same output |
    | 2 requests at once | 136.7 tok/s | 157.2 tok/s | +15% |
    | 4 requests at once | 224.8 tok/s | 257.9 tok/s | +15% |
    | Reading a 32k / 62k prompt | 24.5 s / 56.4 s | 24.0 s / 56.9 s | Same |
    | Follow-up on a cached 62k chat | 0.11 s | 0.05 s | Faster |
    | 128K follow-up when memory is full | 137.5 s (cache lost) | 0.17 s | Much faster |
    | 128K follow-up after editing the last message | 0.18 s | 7.0–8.5 s | **Slower** |
    | Genre sorting | 41/50 correct, 67 s | 42/50 correct, 50 s | 25% faster |
    | Privacy checks | 38/38, median 524 ms | 38/38, median 535 ms | Same |
    | Memory at idle / peak | 19.45 / 29.3 GB | 19.67 / 29.3 GB | Same |
    | Lowest free memory on the Studio | 25% | 29% | Better |
    | SSD writes per test run | 5.57 GB | 5.42 GB | Same |
    """

    func testSegmentsSplitTopLevelFencesAndImageLines() {
        let text = """
        Intro paragraph.

        ```swift
        let x = 1
        ```

        ![Chart](cantrip-preview://abc)

        1. Item
           ```
           nested
           ```
        2. Next
        """
        XCTAssertEqual(CantripRichText.segments(text), [
            .prose("Intro paragraph."),
            .code("let x = 1", language: "swift"),
            .image("![Chart](cantrip-preview://abc)"),
            .prose("1. Item\n   ```\n   nested\n   ```\n2. Next"),
        ])
        XCTAssertEqual(CantripRichText.segments("Streaming:\n\n```\npartial"),
                       [.prose("Streaming:"), .code("partial", language: "")])
        XCTAssertEqual(CantripRichText.segments("One.\n\nTwo.\n\n- three"), [.prose("One.\n\nTwo.\n\n- three")],
                       "Paragraphs and lists share one text view, so a selection can cross them")
    }

    func testAttributedTextKeepsStructureAsPlainText() throws {
        let style = CantripRichText.Style(size: 17)
        let text = CantripRichText.attributed("# Title\n\nLine one\nline two<br>after\n\n- a\n- b\n  - c\n\n1. first\n2. second", style: style)
        XCTAssertEqual(text.string, "Title\nLine one line two\u{2028}after\n•\ta\n•\tb\n◦\tc\n1.\tfirst\n2.\tsecond")
        let title = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(title.pointSize, 17)
        let item = try XCTUnwrap(text.attribute(.paragraphStyle, at: (text.string as NSString).range(of: "•\ta").location,
                                                effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(item.headIndent, item.firstLineHeadIndent, "List items wrap under their text, not the bullet")

        let table = CantripRichText.attributed(answer, style: style)
        XCTAssertTrue(table.string.contains("Step\tTime\nBuild\t4 min\nTests\t12 min"), table.string)
        let row = try XCTUnwrap(table.attribute(.paragraphStyle, at: (table.string as NSString).range(of: "Build").location,
                                                effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(row.tabStops.first?.alignment, .right, "Right-aligned columns stay right-aligned")

        let link = CantripRichText.attributed("See [the log](https://example.com/log).", style: style)
        XCTAssertEqual(link.attribute(.link, at: (link.string as NSString).range(of: "the log").location,
                                      effectiveRange: nil) as? URL, URL(string: "https://example.com/log"))
    }

    func testTopLevelTablesAreTheirOwnSegments() {
        XCTAssertEqual(CantripRichText.segments(answer), [
            .prose("The build passed after one fix.\n\n- **Cause:** a stale cache in `DerivedData`.\n- **Fix:** the pruner now removes it."),
            .table("| Step | Time |\n|---|---:|\n| Build | 4 min |\n| Tests | 12 min |"),
        ])
        XCTAssertEqual(CantripRichText.segments("Results:\n| a | b |\n|---|---|\n| 1 | 2 |\nAfter."),
                       [.prose("Results:"), .table("| a | b |\n|---|---|\n| 1 | 2 |"), .prose("After.")])
        let nested = "1. Item\n\n   | a | b |\n   |---|---|\n   | 1 | 2 |"
        XCTAssertEqual(CantripRichText.segments(nested), [.prose(nested)], "A table in a list item stays in its list")
        XCTAssertEqual(CantripRichText.segments("a | b\n|---|---|---|"), [.prose("a | b\n|---|---|---|")],
                       "A header and delimiter row with different column counts isn't a table")
        XCTAssertEqual(CantripRichText.tableCells(#"| a \| b | `c` |"#), [#"a \| b"#, "`c`"])
    }

    func testWideTableWrapsIntoColumnsThatFitAPhone() throws {
        guard case .table(let markdown) = CantripRichText.segments(benchmark).last else {
            return XCTFail("\(CantripRichText.segments(benchmark))")
        }
        let table = try XCTUnwrap(CantripRichText.table(markdown, style: CantripRichText.Style(size: 17)))
        XCTAssertEqual(table.header.map(\.string), ["Test", "1.6.1", "1.7.0", "Change"])
        XCTAssertEqual(table.rows.count, 13)
        let metrics = table.metrics
        let phone: CGFloat = 330
        XCTAssertGreaterThan(metrics.width(metrics.natural), phone, "On one line each, the columns are wider than a phone")
        let widths = try XCTUnwrap(metrics.fitting(phone))
        XCTAssertEqual(metrics.width(widths), phone, accuracy: 0.5)
        for (width, minimum) in zip(widths, metrics.minimum) {
            XCTAssertGreaterThanOrEqual(width, minimum, "Cells wrap between words, not inside them")
        }
        let label = table.rows[7][0]
        XCTAssertEqual(label.string, "128K follow-up after editing the last message")
        let wrapped = CantripRichText.measure(label, width: widths[0])
        XCTAssertLessThanOrEqual(wrapped.width, widths[0])
        XCTAssertGreaterThan(wrapped.height, 17 * 2, "The long label wraps within its column")
        XCTAssertEqual(metrics.fitting(4000), metrics.natural, "With room, every cell stays on one line")
        XCTAssertNil(metrics.fitting(150), "Too narrow even word by word: the table scrolls sideways")
        XCTAssertTrue(zip(metrics.scrolling, metrics.minimum).allSatisfy { $0 <= max(metrics.widest, $1) })

        XCTAssertEqual(table.tabSeparated.components(separatedBy: "\n").count, 14)
        XCTAssertTrue(table.tabSeparated.hasPrefix("Test\t1.6.1\t1.7.0\tChange\nChat speed\t79.8 tok/s\t91.4 tok/s\t+15%\n"))
        XCTAssertTrue(table.tabSeparated.contains("\n128K follow-up after editing the last message\t0.18 s\t7.0–8.5 s\tSlower\n"),
                      "Copy Table pastes as columns, without the markdown")
        let speed = table.rows[3][1]
        XCTAssertEqual(CantripRichText.plain(speed.string), "224.8 tok/s")
        let full = CantripRichText.measure(speed, width: nil).width
        let speedWrapped = CantripRichText.measure(speed, width: full - 2)
        XCTAssertLessThan(speedWrapped.width, full * 0.7, "\"224.8 tok/s\" wraps at its space, not after the slash")
        XCTAssertEqual(table.spoken(7),
                       "Test: 128K follow-up after editing the last message, 1.6.1: 0.18 s, 1.7.0: 7.0–8.5 s, Change: Slower")
    }

    /// The reply view at iPhone width: every cell is its own text, each column's cells start at
    /// the same x, each row's cells at the same y, and nothing runs past the screen. The old
    /// renderer drew the table as tab-aligned lines in the prose's text view, which wrapped
    /// mid-row and broke the columns.
    @MainActor
    func testReplyTableColumnsLineUpAtPhoneWidth() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let width: CGFloat = 393
        let controller = UIHostingController(rootView:
            ScrollView {
                ChatAssistantText(text: benchmark, images: [], remote: CantripRemoteModel())
                    .padding(16)
            }
            .frame(width: width)
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1600)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(400))
        controller.view.layoutIfNeeded()

        func textViews(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        let views = textViews(controller.view)
        func frame(_ text: String) throws -> CGRect {
            let view = try XCTUnwrap(views.first { $0.text.replacingOccurrences(of: "\u{2060}", with: "") == text },
                                     "No cell \"\(text)\" in \(views.map(\.text))")
            return view.convert(view.bounds, to: window)
        }
        let column1 = try ["1.6.1", "79.8 tok/s", "137.5 s (cache lost)", "0.18 s", "5.57 GB"].map(frame)
        XCTAssertEqual(Set(column1.map { $0.minX.rounded() }).count, 1, "\(column1)")
        let row = try ["128K follow-up after editing the last message", "0.18 s", "7.0–8.5 s", "Slower"].map(frame)
        XCTAssertEqual(Set(row.map { $0.minY.rounded() }).count, 1, "\(row)")
        XCTAssertEqual(row.map(\.minX), row.map(\.minX).sorted())
        XCTAssertGreaterThan(row[0].height, row[1].height, "The long label wraps; its row's values stay on one line")
        for view in views {
            XCTAssertLessThanOrEqual(view.convert(view.bounds, to: window).maxX, width - 16 + 0.5, view.text)
        }
    }
}
