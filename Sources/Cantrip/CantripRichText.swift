import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Markdown drawn as one selectable text view, so a selection can run across paragraphs, list
/// items and headings (SwiftUI draws each markdown block as its own `Text`, and a selection
/// stops at the block's edge). Fenced code, image lines and tables are separate segments that
/// callers draw as boxes, previews and grids.
///
/// Keep this file identical in Sources/Cantrip (the Mac panel) and Clients/CantripIOS/Sources
/// (iPhone, iPad, Gateway Mac and the Home window).
enum CantripRichText {
    #if canImport(UIKit)
    typealias PlatformFont = UIFont
    typealias PlatformColor = UIColor
    #else
    typealias PlatformFont = NSFont
    typealias PlatformColor = NSColor
    #endif

    enum Segment: Equatable {
        case prose(String)
        case code(String, language: String)
        /// One markdown image line, e.g. `![Chart](cantrip-preview://…)`.
        case image(String)
        /// A top-level table's lines: header, delimiter row and body rows (`CantripMarkdownTable`).
        case table(String)
    }

    enum Size: Hashable {
        case body
        /// Progress notes and other secondary text.
        case small
    }

    private static let imageLine = try! NSRegularExpression(
        pattern: #"^ {0,3}!\[[^\]\r\n]*\]\((<[^>\r\n]+>|[^()\r\n]+)\)[ \t]*\r?$"#
    )

    private static let tableDelimiter = try! NSRegularExpression(
        pattern: #"^ {0,3}\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*\r?$"#
    )
    private static let listOrQuoteStart = try! NSRegularExpression(pattern: #"^ {0,3}([-*+]|\d{1,9}[.)])([ \t]|$)|^ {0,3}>"#)

    /// A table row's cells: split at pipes that aren't escaped, without the outer pipes.
    static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in text {
            if character == "|", !escaped {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// `markdown` cut into prose, top-level code fences, image lines and tables, in order. Fences
    /// and tables inside a list item or quote stay in the prose so the list keeps its numbering.
    static func segments(_ markdown: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var fence: (mark: Character, count: Int, language: String, lines: [String], separate: Bool)?
        // Inside a list item or quote, until a blank line ends it.
        var nested = false
        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.prose(text)) }
            prose = []
        }
        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                let closes = trimmed.prefix(while: { $0 == open.mark }).count >= open.count
                    && trimmed.allSatisfy { $0 == open.mark }
                if open.separate {
                    if closes {
                        segments.append(.code(open.lines.joined(separator: "\n"), language: open.language))
                        fence = nil
                    } else {
                        fence?.lines.append(line)
                    }
                } else {
                    prose.append(line)
                    if closes { fence = nil }
                }
                continue
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
                if count >= 3, !(first == "`" && info.contains("`")) {
                    let separate = line.prefix(while: { $0 == " " }).count < 2
                    if separate { flushProse() } else { prose.append(line) }
                    let language = info.split(separator: " ").first.map(String.init) ?? ""
                    fence = (first, count, language, [], separate)
                    continue
                }
            }
            if line.contains("!["),
               imageLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                flushProse()
                segments.append(.image(trimmed))
                continue
            }
            let indent = line.prefix(while: { $0 == " " }).count
            if trimmed.isEmpty {
                nested = false
            } else if indent >= 2 || matches(listOrQuoteStart, line) {
                nested = true
            }
            if !nested, trimmed.contains("|"), index < lines.count, lines[index].contains("|"),
               matches(tableDelimiter, lines[index]), tableCells(line).count == tableCells(lines[index]).count {
                flushProse()
                var table = [line, lines[index]]
                index += 1
                while index < lines.count, lines[index].contains("|"),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    table.append(lines[index])
                    index += 1
                }
                segments.append(.table(table.joined(separator: "\n")))
                continue
            }
            prose.append(line)
        }
        if let open = fence, open.separate {
            // Still streaming: the fence hasn't closed yet.
            segments.append(.code(open.lines.joined(separator: "\n"), language: open.language))
        }
        flushProse()
        return segments
    }

    // MARK: - Attributed text

    struct Style: Hashable {
        var size: CGFloat
        var secondary = false

        var key: String { "\(size)|\(secondary)" }
    }

    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 300
        return cache
    }()

    /// `markdown` (prose only; see `segments`) as attributed text: headings, emphasis, inline
    /// code, links, lists with hanging indents, quotes, and tables nested in a list or quote as
    /// tab-aligned columns.
    static func attributed(_ markdown: String, style: Style) -> NSAttributedString {
        let key = "\(style.key)\u{0}\(markdown)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let result = render(markdown, style: style)
        cache.setObject(result, forKey: key)
        return result
    }

    /// A code fence's text: monospaced, wrapping, no markdown.
    static func attributedCode(_ code: String, style: Style) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.size * 0.12
        return NSAttributedString(string: code, attributes: [
            .font: PlatformFont.monospacedSystemFont(ofSize: style.size * 0.85, weight: .regular),
            .foregroundColor: style.secondary ? secondaryColor : labelColor,
            .paragraphStyle: paragraph,
        ])
    }

    private final class Block {
        let identity: Int
        /// Innermost first, as `PresentationIntent` lists them.
        let components: [PresentationIntent.IntentType]
        let content = NSMutableAttributedString()

        init(identity: Int, components: [PresentationIntent.IntentType]) {
            self.identity = identity
            self.components = components
        }

        var headerLevel: Int? {
            for component in components { if case .header(let level) = component.kind { return level } }
            return nil
        }
        var isCode: Bool { components.contains { if case .codeBlock = $0.kind { return true }; return false } }
        var isRule: Bool { components.contains { $0.kind == .thematicBreak } }
        var quoteDepth: Int { components.filter { $0.kind == .blockQuote }.count }
        /// List items around this block, innermost first.
        var listItems: [PresentationIntent.IntentType] {
            components.filter { if case .listItem = $0.kind { return true }; return false }
        }
        var outerList: Int? {
            components.last { $0.kind == .orderedList || $0.kind == .unorderedList }?.identity
        }
        var table: PresentationIntent.IntentType? {
            components.first { if case .table = $0.kind { return true }; return false }
        }
        var row: PresentationIntent.IntentType? {
            components.first {
                if case .tableRow = $0.kind { return true }
                return $0.kind == .tableHeaderRow
            }
        }
        var column: Int {
            for component in components { if case .tableCell(let column) = component.kind { return column } }
            return 0
        }
    }

    private static func blocks(_ markdown: String, style: Style) -> [Block]? {
        let color = style.secondary ? secondaryColor : labelColor
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return nil }
        var blocks: [Block] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity ?? -1
            if blocks.last?.identity != identity { blocks.append(Block(identity: identity, components: components)) }
            let block = blocks[blocks.count - 1]
            var text = String(parsed[run.range].characters)
            let inline = run.inlinePresentationIntent ?? []
            let inTable = block.table != nil
            if inline.contains(.softBreak) {
                text = " "
            } else if inline.contains(.lineBreak)
                        || (inline.contains(.inlineHTML)
                            && text.range(of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil) {
                text = inTable ? " " : "\u{2028}"
            }
            block.content.append(NSAttributedString(string: text, attributes: inlineAttributes(
                inline, link: run.link, block: block, style: style, color: color)))
        }
        return blocks
    }

    private static func render(_ markdown: String, style: Style) -> NSAttributedString {
        let base = PlatformFont.systemFont(ofSize: style.size)
        let color = style.secondary ? secondaryColor : labelColor
        guard let blocks = blocks(markdown, style: style) else {
            return NSAttributedString(string: markdown, attributes: [.font: base, .foregroundColor: color])
        }

        let out = NSMutableAttributedString()
        var previous: Block?
        // Each "\n" ends the paragraph before it, so it takes that paragraph's style.
        var ending: [NSAttributedString.Key: Any] = [.font: base]
        func newline() {
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: ending)) }
        }
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            if let table = block.table {
                var cells: [Block] = []
                while index < blocks.count, blocks[index].table?.identity == table.identity {
                    cells.append(blocks[index])
                    index += 1
                }
                let spacing = out.length == 0 ? 0 : style.size * 0.75
                newline()
                let rendered = renderTable(cells, kind: table.kind, style: style, color: color, spacingBefore: spacing)
                out.append(rendered)
                if rendered.length > 0 {
                    ending = [.font: base, .paragraphStyle: rendered.attribute(
                        .paragraphStyle, at: rendered.length - 1, effectiveRange: nil) as Any]
                }
                previous = cells.last
                continue
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = style.size * 0.15
            paragraph.paragraphSpacingBefore = previous.map { spacing(before: block, after: $0, size: style.size) } ?? 0
            let line = NSMutableAttributedString()
            let list = listLayout(block, style: style)
            var indent = CGFloat(block.quoteDepth) * style.size + list.indent
            paragraph.firstLineHeadIndent = indent
            if let item = block.listItems.first, previous?.listItems.first?.identity != item.identity {
                // The item's first paragraph carries its marker, right-aligned before the text;
                // later paragraphs line up under the text.
                let marker = NSAttributedString(string: list.marker + "\t", attributes: [
                    .font: list.markerFont, .foregroundColor: color,
                ])
                paragraph.firstLineHeadIndent = indent - list.gap - ceil(marker.size().width)
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                line.append(marker)
            }
            if block.isCode {
                indent += style.size * 0.5
                paragraph.firstLineHeadIndent = indent
                paragraph.lineSpacing = style.size * 0.12
            }
            paragraph.headIndent = indent
            let content = NSMutableAttributedString(attributedString: block.content)
            while content.string.hasSuffix("\n") { content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1)) }
            line.append(content)
            newline()
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            out.append(line)
            ending = [.font: base, .paragraphStyle: paragraph]
            previous = block
            index += 1
        }
        return out
    }

    private static func spacing(before block: Block, after previous: Block, size: CGFloat) -> CGFloat {
        if block.headerLevel != nil { return size * 1.1 }
        if previous.headerLevel != nil { return size * 0.4 }
        if let list = block.outerList, list == previous.outerList {
            // Items of one list sit close; a second paragraph in an item gets a little more room.
            return block.listItems.first?.identity == previous.listItems.first?.identity ? size * 0.45 : size * 0.3
        }
        return size * 0.75
    }

    /// Where a list paragraph's text starts (each level as wide as its widest marker plus a gap)
    /// and its innermost item's marker.
    private static func listLayout(_ block: Block, style: Style)
        -> (indent: CGFloat, gap: CGFloat, marker: String, markerFont: PlatformFont) {
        let gap = min(style.size * 0.45, 10)
        let font = PlatformFont.monospacedDigitSystemFont(ofSize: style.size, weight: .regular)
        var levels: [(ordered: Bool, ordinal: Int)] = []
        for (index, component) in block.components.enumerated() {
            guard case .listItem(let ordinal) = component.kind else { continue }
            let ordered = index + 1 < block.components.count && block.components[index + 1].kind == .orderedList
            levels.insert((ordered, ordinal), at: 0)
        }
        guard let innermost = levels.last else { return (0, gap, "", font) }
        var indent = min(style.size * 0.5, 12)
        for (depth, level) in levels.enumerated() {
            let widest = level.ordered ? "88." : bullet(depth)
            indent += ceil(NSAttributedString(string: widest, attributes: [.font: font]).size().width) + gap
        }
        let marker = innermost.ordered ? "\(innermost.ordinal)." : bullet(levels.count - 1)
        return (indent, gap, marker, font)
    }

    private static func bullet(_ depth: Int) -> String { ["•", "◦", "▪"][depth % 3] }

    private static func inlineAttributes(_ inline: InlinePresentationIntent, link: URL?, block: Block,
                                         style: Style, color: PlatformColor) -> [NSAttributedString.Key: Any] {
        var size = style.size
        var bold = inline.contains(.stronglyEmphasized)
        var weight: PlatformFont.Weight = bold ? .semibold : .regular
        if let level = block.headerLevel {
            size *= [1.5, 1.3, 1.15, 1.05, 1, 1][min(max(level, 1), 6) - 1]
            weight = .semibold
            bold = true
        }
        if block.table != nil, block.row?.kind == .tableHeaderRow {
            weight = .semibold
            bold = true
        }
        var font: PlatformFont
        var attributes: [NSAttributedString.Key: Any] = [:]
        if block.isCode || inline.contains(.code) {
            font = PlatformFont.monospacedSystemFont(ofSize: size * (block.isCode ? 0.85 : 0.92), weight: bold ? .semibold : .regular)
            attributes[.backgroundColor] = codeBackground
        } else {
            font = PlatformFont.systemFont(ofSize: size, weight: weight)
            if inline.contains(.emphasized) { font = italic(font) }
        }
        attributes[.font] = font
        attributes[.foregroundColor] = block.isRule ? tertiaryColor : block.quoteDepth > 0 ? secondaryColor : color
        if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link { attributes[.link] = link }
        return attributes
    }

    /// Rows of tab-separated cells, with tab stops from the widest cell in each column, so a
    /// copied table pastes as columns.
    private static func renderTable(_ cells: [Block], kind: PresentationIntent.Kind, style: Style,
                                    color: PlatformColor, spacingBefore: CGFloat) -> NSAttributedString {
        var rows: [[Block]] = []
        var rowID: Int?
        for cell in cells {
            if cell.row?.identity != rowID || rows.isEmpty { rows.append([]); rowID = cell.row?.identity }
            rows[rows.count - 1].append(cell)
        }
        let columns = (rows.map { $0.map(\.column).max() ?? 0 }.max() ?? 0) + 1
        var widths = Array(repeating: CGFloat(0), count: columns)
        for row in rows {
            for cell in row { widths[cell.column] = max(widths[cell.column], ceil(cell.content.size().width)) }
        }
        var alignments: [PresentationIntent.TableColumn.Alignment] = []
        if case .table(let described) = kind { alignments = described.map(\.alignment) }
        let gap = style.size * 1.2
        var stops: [NSTextTab] = []
        var x: CGFloat = 0
        for column in 0..<columns {
            if column > 0 {
                let alignment = column < alignments.count ? alignments[column] : .left
                switch alignment {
                case .right: stops.append(NSTextTab(textAlignment: .right, location: x + widths[column]))
                case .center: stops.append(NSTextTab(textAlignment: .center, location: x + widths[column] / 2))
                default: stops.append(NSTextTab(textAlignment: .left, location: x))
                }
            }
            x += widths[column] + gap
        }
        let out = NSMutableAttributedString()
        for (number, row) in rows.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = stops
            paragraph.lineSpacing = style.size * 0.1
            paragraph.paragraphSpacingBefore = number == 0 ? spacingBefore : style.size * 0.3
            let line = NSMutableAttributedString()
            var column = 0
            for cell in row.sorted(by: { $0.column < $1.column }) {
                while column < cell.column {
                    line.append(NSAttributedString(string: "\t", attributes: [.font: PlatformFont.systemFont(ofSize: style.size)]))
                    column += 1
                }
                line.append(cell.content)
            }
            line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
            if number > 0 { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph])) }
            out.append(line)
        }
        return out
    }

    // MARK: - Tables

    /// A top-level table (`Segment.table`) as cells for `CantripMarkdownTable`.
    final class Table {
        /// Every row, the header included, has one cell per column.
        let header: [NSAttributedString]
        let rows: [[NSAttributedString]]
        let metrics: TableMetrics

        init(header: [NSAttributedString], rows: [[NSAttributedString]], metrics: TableMetrics) {
            self.header = header
            self.rows = rows
            self.metrics = metrics
        }

        /// The header and rows as tab-separated lines, so a copied table pastes as columns.
        var tabSeparated: String {
            ([header] + rows).map { row in
                row.map { CantripRichText.plain($0.string).replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t")
            }.joined(separator: "\n")
        }

        /// A body row for VoiceOver: each cell after its column's heading, in order.
        func spoken(_ row: Int) -> String {
            rows[row].enumerated().compactMap { column, cell in
                let text = CantripRichText.plain(cell.string).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                let title = CantripRichText.plain(header[column].string).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? text : "\(title): \(text)"
            }.joined(separator: ", ")
        }
    }

    /// Joins a slash to the character after it inside a word ("tok/s", "41/50"), so a narrow
    /// column wraps between words instead of after the slash.
    static let wordJoiner = "\u{2060}"

    /// `text` without the word joiners table cells add.
    static func plain(_ text: String) -> String { text.replacingOccurrences(of: wordJoiner, with: "") }

    /// A table's columns: each one's widest cell on one line (`natural`) and its longest word
    /// (`minimum`), so cells wrap between words rather than inside them.
    struct TableMetrics: Hashable {
        var natural: [CGFloat]
        var minimum: [CGFloat]
        var gap: CGFloat
        /// The widest a column gets in a table that scrolls sideways.
        var widest: CGFloat

        /// The columns side by side, with the gaps between them.
        func width(_ widths: [CGFloat]) -> CGFloat {
            widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
        }

        /// Columns that fit in `available`: one line each when they can, else each column narrowed
        /// in proportion to how much of it wraps, down to its longest word. Nil when even that
        /// is too wide.
        func fitting(_ available: CGFloat) -> [CGFloat]? {
            let room = available - gap * CGFloat(max(0, natural.count - 1))
            let most = natural.reduce(0, +)
            let least = minimum.reduce(0, +)
            if most <= room { return natural }
            guard least <= room, most > least else { return nil }
            let share = (room - least) / (most - least)
            return zip(natural, minimum).map { $1 + ($0 - $1) * share }
        }

        /// Columns for a table that scrolls sideways: one line up to `widest`, wrapping beyond it.
        var scrolling: [CGFloat] { zip(natural, minimum).map { max($1, min($0, widest)) } }
    }

    private static let tables: NSCache<NSString, Table> = {
        let cache = NSCache<NSString, Table>()
        cache.countLimit = 100
        return cache
    }()
    private static let word = try! NSRegularExpression(pattern: #"\S+"#)

    /// One `Segment.table` as cells, or nil when it doesn't parse as a table.
    static func table(_ markdown: String, style: Style) -> Table? {
        let key = "\(style.key)\u{0}\(markdown)" as NSString
        if let hit = tables.object(forKey: key) { return hit }
        guard let cells = blocks(markdown, style: style)?.filter({ $0.table != nil }),
              let kind = cells.first?.table?.kind, cells.first?.row?.kind == .tableHeaderRow else { return nil }
        var rows: [[Block]] = []
        var rowID: Int?
        for cell in cells {
            if cell.row?.identity != rowID || rows.isEmpty { rows.append([]); rowID = cell.row?.identity }
            rows[rows.count - 1].append(cell)
        }
        var alignments: [PresentationIntent.TableColumn.Alignment] = []
        if case .table(let described) = kind { alignments = described.map(\.alignment) }
        let columns = max(alignments.count, (cells.map(\.column).max() ?? 0) + 1)
        let grid: [[NSAttributedString]] = rows.map { row in
            (0..<columns).map { column in
                let content = NSMutableAttributedString(
                    attributedString: row.first { $0.column == column }?.content ?? NSAttributedString())
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = style.size * 0.1
                switch column < alignments.count ? alignments[column] : .left {
                case .right: paragraph.alignment = .right
                case .center: paragraph.alignment = .center
                default: paragraph.alignment = .natural
                }
                content.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: content.length))
                let string = content.string as NSString
                for index in stride(from: string.length - 2, through: 1, by: -1) where string.character(at: index) == 0x2F {
                    let around = [string.character(at: index - 1), string.character(at: index + 1)]
                    guard !around.contains(where: { UnicodeScalar($0).map(CharacterSet.whitespaces.contains) ?? true }) else { continue }
                    content.insert(NSAttributedString(string: wordJoiner, attributes: content.attributes(at: index, effectiveRange: nil)),
                                   at: index + 1)
                }
                return content
            }
        }
        // Text measures a little differently in each text system: a point of slack keeps a
        // column that fits on one line from wrapping its last word.
        var natural = Array(repeating: CGFloat(0), count: columns)
        var minimum = natural
        let longestWord = style.size * 8
        for row in grid {
            for (column, cell) in row.enumerated() {
                natural[column] = max(natural[column], ceil(cell.size().width) + 1)
                let string = cell.string as NSString
                for match in word.matches(in: cell.string, range: NSRange(location: 0, length: string.length)) {
                    let width = ceil(cell.attributedSubstring(from: match.range).size().width) + 1
                    minimum[column] = max(minimum[column], min(width, longestWord))
                }
            }
        }
        natural = zip(natural, minimum).map { max($0, $1) }
        let table = Table(header: grid[0], rows: Array(grid.dropFirst()), metrics: TableMetrics(
            natural: natural, minimum: minimum, gap: style.size * 0.75, widest: style.size * 14))
        tables.setObject(table, forKey: key)
        return table
    }

    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    // MARK: - Platform

    #if canImport(UIKit)
    static var labelColor: PlatformColor { .label }
    static var secondaryColor: PlatformColor { .secondaryLabel }
    static var tertiaryColor: PlatformColor { .tertiaryLabel }
    static var codeBackground: PlatformColor { .tertiarySystemFill }

    private static func italic(_ font: PlatformFont) -> PlatformFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
    #else
    static var labelColor: PlatformColor { .labelColor }
    static var secondaryColor: PlatformColor { .secondaryLabelColor }
    static var tertiaryColor: PlatformColor { .tertiaryLabelColor }
    static var codeBackground: PlatformColor { .quaternaryLabelColor }

    private static func italic(_ font: PlatformFont) -> PlatformFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
    #endif
}

// MARK: - Sizing

extension CantripRichText {
    /// A text view's size for a SwiftUI proposal, like `Text`: a zero width (the minimum) takes
    /// no room, no width or an unlimited one (the ideal) is the unwrapped text, and a width wraps
    /// the text to it. `measure` lays the text out at a width (nil = unwrapped); sizes are cached
    /// by width until the text changes.
    static func fit(_ proposal: ProposedViewSize, cache: inout [CGFloat: CGSize],
                    measure: (CGFloat?) -> CGSize) -> CGSize {
        guard let proposed = proposal.width else { return cached(-1, &cache) { measure(nil) } }
        if proposed <= 0 { return .zero }
        if !proposed.isFinite { return cached(-1, &cache) { measure(nil) } }
        return cached(proposed, &cache) { CGSize(width: proposed, height: measure(proposed).height) }
    }

    private static func cached(_ key: CGFloat, _ cache: inout [CGFloat: CGSize], _ make: () -> CGSize) -> CGSize {
        if let size = cache[key] { return size }
        let size = make()
        cache[key] = size
        return size
    }

    /// `text` laid out at `width` (nil = unwrapped) by a private TextKit stack, with the same
    /// zero line padding as the views.
    static func measure(_ text: NSAttributedString, width: CGFloat?) -> CGSize {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width ?? 100_000, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
}

// MARK: - Views

/// Prose markdown (no code fences or image lines; see `CantripRichText.segments`) as one
/// selectable text view at the body or small text size.
struct CantripMarkdownText: View {
    let markdown: String
    var size: CantripRichText.Size = .body
    var secondary = false
    var onOpenURL: (URL) -> Void = { _ in }
    #if canImport(UIKit)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    var body: some View {
        CantripSelectableText(text: CantripRichText.attributed(markdown, style: style), onOpenURL: onOpenURL)
    }

    var style: CantripRichText.Style {
        CantripRichText.Style(size: Self.pointSize(size, dynamicTypeSize: dynamicTypeSizeValue), secondary: secondary)
    }

    #if canImport(UIKit)
    private var dynamicTypeSizeValue: DynamicTypeSize { dynamicTypeSize }

    static func pointSize(_ size: CantripRichText.Size, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return UIFont.preferredFont(forTextStyle: size == .body ? .body : .subheadline, compatibleWith: traits).pointSize
    }
    #else
    private var dynamicTypeSizeValue: DynamicTypeSize { .large }

    static func pointSize(_ size: CantripRichText.Size, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        NSFont.preferredFont(forTextStyle: size == .body ? .body : .callout).pointSize
    }
    #endif
}

/// A code fence in a rounded box; its text selects like the prose around it.
struct CantripCodeBlockText: View {
    let code: String
    var size: CantripRichText.Size = .body
    var secondary = false
    #if canImport(UIKit)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var points: CGFloat { CantripMarkdownText.pointSize(size, dynamicTypeSize: dynamicTypeSize) }
    #else
    private var points: CGFloat { CantripMarkdownText.pointSize(size, dynamicTypeSize: .large) }
    #endif

    var body: some View {
        CantripSelectableText(text: CantripRichText.attributedCode(
            code, style: CantripRichText.Style(size: points, secondary: secondary)))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A top-level markdown table (`CantripRichText.Segment.table`) as a grid. Columns are as wide as
/// their cells on one line, narrowed to fit by wrapping between words; a table too wide even then
/// scrolls sideways. Each cell selects like the prose and its menu adds Copy Table (tab-separated
/// columns); VoiceOver reads each row as its cells in order, each after its column's heading.
struct CantripMarkdownTable: View {
    let markdown: String
    var size: CantripRichText.Size = .body
    var secondary = false
    var onOpenURL: (URL) -> Void = { _ in }
    #if canImport(UIKit)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// A step below the prose (subheadline, or footnote in notes), so a phone fits more columns.
    private var points: CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return UIFont.preferredFont(forTextStyle: size == .body ? .subheadline : .footnote, compatibleWith: traits).pointSize
    }
    #else
    private var points: CGFloat { CantripMarkdownText.pointSize(size, dynamicTypeSize: .large) }
    #endif
    @Environment(\.displayScale) private var displayScale

    static let inset: CGFloat = 10

    var body: some View {
        if let table = CantripRichText.table(markdown, style: CantripRichText.Style(size: points, secondary: secondary)) {
            ViewThatFits(in: .horizontal) {
                grid(table, scrolls: false)
                ScrollView(.horizontal) { grid(table, scrolls: true) }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Table")
        } else {
            CantripMarkdownText(markdown: markdown, size: size, secondary: secondary, onOpenURL: onOpenURL)
        }
    }

    private func grid(_ table: CantripRichText.Table, scrolls: Bool) -> some View {
        let copy = table.tabSeparated
        return VStack(alignment: .leading, spacing: 0) {
            row(table.header, table: table, scrolls: scrolls)
                .accessibilityHidden(true)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                row(cells, table: table, scrolls: scrolls)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Color.primary.opacity(index == 0 ? 0.22 : 0.1))
                            .frame(height: 1 / displayScale)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(table.spoken(index))
                    .accessibilityAction(named: "Copy Table") { CantripRichText.copy(copy) }
            }
        }
        .padding(.horizontal, Self.inset)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ cells: [NSAttributedString], table: CantripRichText.Table, scrolls: Bool) -> some View {
        CantripTableRowLayout(metrics: table.metrics, scrolls: scrolls) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                CantripSelectableText(text: cell, onOpenURL: onOpenURL, copyTable: table.tabSeparated)
            }
        }
        .padding(.vertical, points * 0.4)
    }
}

/// A table row: its cells side by side at the table's column widths for the proposed width
/// (`TableMetrics`), as tall as its tallest cell. Every row of a table gets the same proposal,
/// so their columns line up.
struct CantripTableRowLayout: Layout {
    let metrics: CantripRichText.TableMetrics
    /// Columns for a sideways-scrolling table, whatever the proposal.
    let scrolls: Bool

    /// Without a width (the ideal size), the narrowest the columns go.
    func widths(_ proposed: CGFloat?) -> [CGFloat] {
        if scrolls { return metrics.scrolling }
        guard let proposed, proposed.isFinite else { return metrics.minimum }
        return metrics.fitting(proposed) ?? metrics.minimum
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(proposal.width)
        var height: CGFloat = 0
        for (subview, width) in zip(subviews, widths) {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
        }
        return CGSize(width: metrics.width(widths), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(proposal.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: nil))
            x += width + metrics.gap
        }
    }
}

#if canImport(UIKit)
/// Copies without the word joiners table cells add (`CantripRichText.wordJoiner`).
final class CantripTextView: UITextView {
    override func copy(_ sender: Any?) {
        super.copy(sender)
        if let copied = UIPasteboard.general.string, copied.contains(CantripRichText.wordJoiner) {
            UIPasteboard.general.string = CantripRichText.plain(copied)
        }
    }
}

/// Read-only attributed text with native range selection (handles, Copy, Look Up, Translate)
/// that sizes to its width like `Text`.
struct CantripSelectableText: UIViewRepresentable {
    let text: NSAttributedString
    var onOpenURL: (URL) -> Void = { _ in }
    /// A table cell's whole table as tab-separated text, offered as Copy Table in the edit menu.
    var copyTable: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = CantripTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.copyTable = copyTable
        // Same text (often a new copy of it): leave the view alone, so layout doesn't restart.
        if context.coordinator.text?.isEqual(to: text) != true {
            context.coordinator.text = text
            context.coordinator.sizes = [:]
            view.attributedText = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        CantripRichText.fit(proposal, cache: &context.coordinator.sizes) { width in
            let fitted = uiView.sizeThatFits(CGSize(width: width ?? 100_000, height: .greatestFiniteMagnitude))
            return CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: NSAttributedString?
        var sizes: [CGFloat: CGSize] = [:]
        var onOpenURL: (URL) -> Void = { _ in }
        var copyTable: String?

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.onOpenURL(url) }
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            // Web links get the system preview; app links (tabs, previews) only open on tap.
            if case .link(let url) = textItem.content, url.scheme != "https", url.scheme != "http" { return nil }
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let table = copyTable else { return nil }
            var actions = suggestedActions
            actions.insert(UIAction(title: "Copy Table", image: UIImage(systemName: "tablecells")) { _ in
                CantripRichText.copy(table)
            }, at: min(1, actions.count))
            return UIMenu(children: actions)
        }
    }
}
#else
/// Copies without the word joiners table cells add (`CantripRichText.wordJoiner`).
final class CantripTextView: NSTextView {
    override func copy(_ sender: Any?) {
        super.copy(sender)
        let pasteboard = NSPasteboard.general
        if let copied = pasteboard.string(forType: .string), copied.contains(CantripRichText.wordJoiner) {
            pasteboard.clearContents()
            pasteboard.setString(CantripRichText.plain(copied), forType: .string)
        }
    }
}

/// Read-only attributed text with native selection (drag, Copy, Look Up) that sizes to its width
/// like `Text`.
struct CantripSelectableText: NSViewRepresentable {
    let text: NSAttributedString
    var onOpenURL: (URL) -> Void = { url in NSWorkspace.shared.open(url) }
    /// A table cell's whole table as tab-separated text, offered as Copy Table in the context menu.
    var copyTable: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = CantripTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        context.coordinator.copyTable = copyTable
        // Same text (often a new copy of it): leave the view alone, so layout doesn't restart.
        if context.coordinator.text?.isEqual(to: text) != true {
            context.coordinator.text = text
            context.coordinator.sizes = [:]
            view.textStorage?.setAttributedString(text)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        // Measured off-screen: resizing the view's own container here, inside AppKit's
        // constraints pass, can send a split view into a layout loop.
        CantripRichText.fit(proposal, cache: &context.coordinator.sizes) { width in
            CantripRichText.measure(text, width: width)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: NSAttributedString?
        var sizes: [CGFloat: CGSize] = [:]
        var onOpenURL: (URL) -> Void = { _ in }
        var copyTable: String?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            onOpenURL(url)
            return true
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard copyTable != nil else { return menu }
            let item = NSMenuItem(title: "Copy Table", action: #selector(copyTableText), keyEquivalent: "")
            item.target = self
            let copy = menu.items.firstIndex { $0.action == #selector(NSText.copy(_:)) }
            menu.insertItem(item, at: copy.map { $0 + 1 } ?? 0)
            return menu
        }

        @objc func copyTableText() {
            if let copyTable { CantripRichText.copy(copyTable) }
        }
    }
}
#endif
