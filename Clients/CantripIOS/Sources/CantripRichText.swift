import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Markdown drawn as one selectable text view, so a selection can run across paragraphs, list
/// items, headings and tables (SwiftUI draws each markdown block as its own `Text`, and a
/// selection stops at the block's edge). Fenced code and image lines are separate segments that
/// callers draw as boxes and previews.
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
    }

    enum Size: Hashable {
        case body
        /// Progress notes and other secondary text.
        case small
    }

    private static let imageLine = try! NSRegularExpression(
        pattern: #"^ {0,3}!\[[^\]\r\n]*\]\((<[^>\r\n]+>|[^()\r\n]+)\)[ \t]*\r?$"#
    )

    /// `markdown` cut into prose, top-level code fences and image lines, in order. Fences
    /// indented under a list item stay in the prose so the list keeps its numbering.
    static func segments(_ markdown: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var fence: (mark: Character, count: Int, language: String, lines: [String], separate: Bool)?
        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.prose(text)) }
            prose = []
        }
        for line in markdown.components(separatedBy: "\n") {
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
    /// code, links, lists with hanging indents, quotes, and tables as tab-aligned columns.
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

    private static func render(_ markdown: String, style: Style) -> NSAttributedString {
        let base = PlatformFont.systemFont(ofSize: style.size)
        let color = style.secondary ? secondaryColor : labelColor
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: base, .foregroundColor: color])
        }
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

#if canImport(UIKit)
/// Read-only attributed text with native range selection (handles, Copy, Look Up, Translate)
/// that sizes to its width like `Text`.
struct CantripSelectableText: UIViewRepresentable {
    let text: NSAttributedString
    var onOpenURL: (URL) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
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
    }
}
#else
/// Read-only attributed text with native selection (drag, Copy, Look Up) that sizes to its width
/// like `Text`.
struct CantripSelectableText: NSViewRepresentable {
    let text: NSAttributedString
    var onOpenURL: (URL) -> Void = { url in NSWorkspace.shared.open(url) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
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

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            onOpenURL(url)
            return true
        }
    }
}
#endif
