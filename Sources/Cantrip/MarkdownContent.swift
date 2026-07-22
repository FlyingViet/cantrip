import SwiftUI
import AppKit

/// Lightweight block-level markdown renderer for assistant responses:
/// headings, bullet/numbered lists (with nesting), fenced code, block
/// quotes, tables (monospaced), rules, and inline md within paragraphs.
struct MarkdownContent: View {
    let text: String

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    // MARK: - Blocks

    enum Block {
        case paragraph(String)
        case heading(Int, String)
        case list([ListItem])
        case code(String)
        case quote(String)
        case table([[String]])   // rows of cells; first row = header
        case image(String)       // file path (may contain ~) or URL
        case rule
    }

    struct ListItem {
        let marker: String   // "•" or "3."
        let text: String
        let indent: Int      // nesting level
    }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .system(size: 17, weight: .bold)
                     : level == 2 ? .system(size: 15, weight: .semibold)
                     : .system(size: 13.5, weight: .semibold))
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(Self.inline(item.text))
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case .code(let code):
            CodeBlockView(code: code)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                Text(Self.inline(text))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .table(let rows):
            renderTable(rows)
        case .image(let target):
            ImageBlock(target: target)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .rule:
            Divider()
        }
    }

    @ViewBuilder
    private func renderTable(_ rows: [[String]]) -> some View {
        if let header = rows.first {
            let columns = header.count
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        Text(Self.inline(header[c]))
                            .font(.callout.weight(.semibold))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.dropFirst().enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            Text(Self.inline(c < row.count ? row[c] : ""))
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Inline

    private static let htmlBreakRegex = try? NSRegularExpression(
        pattern: "<br\\s*/?>",
        options: .caseInsensitive)

    static func inline(_ text: String) -> AttributedString {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let text = htmlBreakRegex?.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "\n"
        ) ?? text
        return (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // MARK: - Parser

    private static let mdImageRegex = try? NSRegularExpression(
        pattern: "!\\[[^\\]]*\\]\\(([^)]+)\\)")
    private static let imagePathRegex = try? NSRegularExpression(
        pattern: "[~/][^\\s\"'`)\\]]+\\.(?:png|jpe?g|gif|webp|heic|tiff?|bmp|svg)",
        options: [.caseInsensitive])

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var listItems: [ListItem] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        func flushList() {
            if !listItems.isEmpty {
                blocks.append(.list(listItems))
                listItems = []
            }
        }
        func flushAll() { flushParagraph(); flushList() }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let leadingSpaces = raw.prefix(while: { $0 == " " }).count

            // Fenced code
            if trimmed.hasPrefix("```") {
                flushAll()
                var code: [String] = []
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1 // skip closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            // Blank line
            if trimmed.isEmpty { flushAll(); i += 1; continue }
            // Markdown image(s): ![alt](target)
            if trimmed.contains("!["), let regex = Self.mdImageRegex {
                let ns = trimmed as NSString
                let range = NSRange(location: 0, length: ns.length)
                let matches = regex.matches(in: trimmed, range: range)
                if !matches.isEmpty {
                    flushAll()
                    for match in matches {
                        blocks.append(.image(ns.substring(with: match.range(at: 1))
                            .trimmingCharacters(in: .whitespaces)))
                    }
                    let residual = regex.stringByReplacingMatches(
                        in: trimmed, range: range, withTemplate: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !residual.isEmpty { blocks.append(.paragraph(residual)) }
                    i += 1
                    continue
                }
            }
            // Heading
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level <= 6, trimmed.dropFirst(level).hasPrefix(" ") {
                    flushAll()
                    blocks.append(.heading(min(level, 3),
                                           String(trimmed.dropFirst(level + 1))))
                    i += 1
                    continue
                }
            }
            // Rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll(); blocks.append(.rule); i += 1; continue
            }
            // Quote
            if trimmed.hasPrefix(">") {
                flushAll()
                var quote: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quote.append(q.dropFirst().trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            // Table
            if trimmed.hasPrefix("|") {
                flushAll()
                var rows: [[String]] = []
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    guard rowLine.hasPrefix("|") else { break }
                    var cells = rowLine.components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if cells.first?.isEmpty == true { cells.removeFirst() }
                    if cells.last?.isEmpty == true { cells.removeLast() }
                    // Skip the |---|---| separator row.
                    let isSeparator = !cells.isEmpty && cells.allSatisfy { cell in
                        cell.contains("-") &&
                        cell.allSatisfy { "-: ".contains($0) }
                    }
                    if !isSeparator { rows.append(cells) }
                    i += 1
                }
                if !rows.isEmpty { blocks.append(.table(rows)) }
                continue
            }
            // Bullet item
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                listItems.append(ListItem(marker: "•",
                                          text: String(trimmed.dropFirst(2)),
                                          indent: leadingSpaces / 2))
                i += 1
                continue
            }
            // Numbered item ("3. text" or "3) text")
            if let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }),
               !trimmed[..<dot].isEmpty,
               trimmed[..<dot].allSatisfy(\.isNumber),
               trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                listItems.append(ListItem(
                    marker: String(trimmed[...dot]),
                    text: trimmed[trimmed.index(after: dot)...]
                        .trimmingCharacters(in: .whitespaces),
                    indent: leadingSpaces / 2))
                i += 1
                continue
            }
            // Continuation of a list item (indented text under it)
            if !listItems.isEmpty && leadingSpaces >= 2 {
                let last = listItems.removeLast()
                listItems.append(ListItem(marker: last.marker,
                                          text: last.text + " " + trimmed,
                                          indent: last.indent))
                i += 1
                continue
            }
            // Plain paragraph line
            flushList()
            paragraph.append(trimmed)
            i += 1
        }
        flushAll()

        // Preview bare image paths mentioned anywhere in the text
        // (e.g. "PNG: ~/cat-meowing.png") if the file actually exists.
        if let regex = imagePathRegex {
            let already = Set(blocks.compactMap { block -> String? in
                if case .image(let target) = block { return target }
                return nil
            })
            let ns = text as NSString
            var found: [String] = []
            for match in regex.matches(in: text,
                                       range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: match.range)
                if !already.contains(path), !found.contains(path),
                   FileManager.default.fileExists(
                       atPath: (path as NSString).expandingTildeInPath) {
                    found.append(path)
                }
            }
            for path in found.prefix(4) { blocks.append(.image(path)) }
        }
        return blocks
    }
}

/// Monospaced code box with a copy button (checkmark feedback on click).
private struct CodeBlockView: View {
    let code: String
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .padding(.trailing, 26) // room for the button
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 6))
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Copy")
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// Inline preview of a local image file or remote URL; click opens it.
private struct ImageBlock: View {
    let target: String

    var body: some View {
        if target.hasPrefix("http"), let url = URL(string: target) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: 440, maxHeight: 280, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            let path = (target as NSString).expandingTildeInPath
            if let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white.opacity(0.15)))
                    .onTapGesture {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .help("\(path) — click to open, right-click to copy")
                    .contextMenu {
                        Button("Copy Image") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.writeObjects([nsImage])
                        }
                        Button("Copy as File") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
                        }
                        Button("Copy Path") {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(path, forType: .string)
                        }
                        Divider()
                        Button("Open") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: path)])
                        }
                    }
            } else {
                Label(target, systemImage: "photo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
