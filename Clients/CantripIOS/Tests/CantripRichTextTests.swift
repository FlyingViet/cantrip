import UIKit
import XCTest
@testable import Hermes

/// Reply markdown as one selectable text: prose, top-level code fences and image lines, and
/// attributed text that keeps lists, headings, tables and links.
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
}
