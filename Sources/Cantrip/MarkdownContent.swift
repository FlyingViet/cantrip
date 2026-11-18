import SwiftUI
import AppKit

/// An assistant reply's markdown. Prose between code fences and images is one selectable text
/// view (`CantripRichText`), so a selection runs across paragraphs, lists, headings and tables;
/// code fences keep their Copy box, and images (and image files the text mentions) preview below.
struct MarkdownContent: View {
    let text: String
    var size: CantripRichText.Size = .body
    /// Progress notes: secondary color.
    var secondary = false
    /// False shows each image's description instead of loading it, and previews no mentioned image
    /// files (Private Local loads nothing).
    var loadsImages = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        let segments = CantripRichText.segments(Self.separatingImages(text))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    CantripMarkdownText(markdown: TabMentions.markdown(prose), size: size,
                                        secondary: secondary) { openURL($0) }
                case .code(let code, _):
                    CodeBlockView(code: code)
                case .image(let line):
                    if loadsImages {
                        ImageBlock(target: Self.imageTarget(line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Label(Self.unloadedLabel(line), systemImage: "photo")
                            .font(size == .body ? .callout : .caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(loadsImages ? Self.mentionedImages(in: text, shown: segments) : [], id: \.self) { path in
                ImageBlock(target: path)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A note as one line of inline markdown (code spans, bold); plain while a token is incomplete.
    static func inlineNote(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: TabMentions.markdown(text),
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // MARK: - Images

    private static let mdImageRegex = try? NSRegularExpression(
        pattern: "!\\[[^\\]]*\\]\\(([^)]+)\\)")
    private static let imagePathRegex = try? NSRegularExpression(
        pattern: "[~/][^\\s\"'`)\\]]+\\.(?:png|jpe?g|gif|webp|heic|tiff?|bmp|svg)",
        options: [.caseInsensitive])

    /// Every markdown image on its own line (outside code fences), so it previews as a block
    /// even when the line also has text.
    static func separatingImages(_ text: String) -> String {
        guard text.contains("!["), let regex = mdImageRegex else { return text }
        var output: [String] = []
        var fence: Character?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "`" || first == "~", trimmed.hasPrefix(String(repeating: first, count: 3)) {
                fence = fence == nil ? first : (fence == first ? nil : fence)
                output.append(line)
                continue
            }
            let ns = line as NSString
            let matches = fence == nil && line.contains("![")
                ? regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) : []
            guard !matches.isEmpty else { output.append(line); continue }
            let residual = regex.stringByReplacingMatches(
                in: line, range: NSRange(location: 0, length: ns.length), withTemplate: ""
            ).trimmingCharacters(in: .whitespaces)
            if !residual.isEmpty { output.append(contentsOf: [residual, ""]) }
            for match in matches { output.append(contentsOf: [ns.substring(with: match.range), ""]) }
        }
        return output.joined(separator: "\n")
    }

    static func imageTarget(_ line: String) -> String {
        guard let regex = mdImageRegex,
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        else { return line }
        var target = (line as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
        return target
    }

    /// What shows instead of an image line that isn't loaded (as on the other clients).
    static func unloadedLabel(_ line: String) -> String {
        let target = imageTarget(line).lowercased()
        let label = target.hasPrefix("https://") || target.hasPrefix("http://") ? "Image not loaded" : "Image on the Mac"
        let alt = line.firstIndex(of: "[").flatMap { open in
            line[line.index(after: open)...].firstIndex(of: "]").map { String(line[line.index(after: open)..<$0]) }
        }?.trimmingCharacters(in: .whitespaces) ?? ""
        return alt.isEmpty ? label : "\(label): \(alt)"
    }

    /// Bare image paths mentioned anywhere in the text (e.g. "PNG: ~/cat.png") whose files exist,
    /// up to four, skipping ones already shown.
    static func mentionedImages(in text: String, shown segments: [CantripRichText.Segment]) -> [String] {
        guard let regex = imagePathRegex else { return [] }
        let already = Set(segments.compactMap { segment -> String? in
            if case .image(let line) = segment { return imageTarget(line) }
            return nil
        })
        let ns = text as NSString
        var found: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: match.range)
            if !already.contains(path), !found.contains(path),
               FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) {
                found.append(path)
            }
        }
        return Array(found.prefix(4))
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
