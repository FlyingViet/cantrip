import SwiftUI
import AppKit

/// Text colors for child tabs that keep 4.5:1 contrast in light and dark panels.
enum ChildTabColors {
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    static let lane = adaptive(light: (0.02, 0.44, 0.56), dark: (0.39, 0.82, 1))
    static let ok = adaptive(light: (0.11, 0.48, 0.2), dark: (0.21, 0.78, 0.35))
    static let work = adaptive(light: (0.62, 0.34, 0), dark: (1, 0.62, 0.04))
    static let bad = adaptive(light: (0.77, 0.17, 0.22), dark: (1, 0.41, 0.38))
    /// The request bubble in a card's thread (white text on it is 5.6:1).
    static let bubble = Color(red: 0.23, green: 0.37, blue: 0.8)
}

/// A child tab's card in its parent: lane and thread tag (expands to the request, the child's
/// replies and its files), the summary, a merge question on a conflict, and status.
struct ChildTabCard: View {
    let record: ChildTab
    let isOpen: Bool
    let action: (String, ChildTab) -> Void
    @State private var expanded = false

    private var firstLine: String {
        record.prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? record.prompt
    }

    private var summaryText: String {
        record.displaySummary.isEmpty && record.state == .working ? "Working on it in its own tab." : record.displaySummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Label("Child tab · \(record.title)", systemImage: "arrow.triangle.branch")
                        .foregroundStyle(ChildTabColors.lane)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ChildTabColors.lane.opacity(0.13), in: Capsule())
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.left")
                        Text(verbatim: firstLine).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                }
                .font(.caption.weight(.semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the request and replies" : "Show the request and the child tab's replies")
            .accessibilityLabel("Child tab \(record.title): \(firstLine)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the request and the child tab's replies")
            if expanded { thread }
            if !summaryText.isEmpty {
                Text(Self.inline(summaryText))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if record.state == .conflict { question }
            HStack(spacing: 10) {
                statusChip
                Button(isOpen ? "Open Tab" : "Open Conversation") { action("open", record) }
                    .buttonStyle(.link)
                    .font(.caption.weight(.semibold))
                ForEach(extraActions, id: \.0) { name, title in
                    Button(title) { action(name, record) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Inline Markdown (code, bold, links) as the transcript shows it; plain text if it doesn't parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: record.prompt)
                .font(.callout)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(ChildTabColors.bubble, in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
            ForEach(Array(record.replies.enumerated()), id: \.offset) { _, reply in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: record.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(Self.inline(reply))
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            if !record.files.isEmpty {
                Text(filesText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Button("Open the Full Conversation") { action("open", record) }
                .buttonStyle(.link)
                .font(.caption.weight(.semibold))
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(.quaternary).frame(width: 2)
        }
    }

    private var question: some View {
        let base = record.baseBranch ?? "the parent's branch"
        let files = record.conflictFiles.prefix(4).joined(separator: ", ")
            + (record.conflictFiles.count > 4 ? " and \(record.conflictFiles.count - 4) more" : "")
        let clean = record.cleanFileCount
        let lead = clean > 0
            ? "\(clean) \(clean == 1 ? "file" : "files") merged cleanly, but both branches changed the same lines in \(files)."
            : "Both branches changed the same lines in \(files)."
        return VStack(alignment: .leading, spacing: 8) {
            Text("Merge needs your answer")
                .font(.callout.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("Merging **\(record.title)** into `\(base)`. \(lead)")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let excerpt = record.conflictExcerpt {
                ScrollView(.horizontal) {
                    excerptText(excerpt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("Conflicting lines")
            }
            if let note = record.note {
                Text(verbatim: note).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(options, id: \.0) { name, title in
                if name == "resolve" {
                    Button { action(name, record) } label: { Text(title).frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { action(name, record) } label: { Text(title).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
    }

    private func excerptText(_ excerpt: String) -> Text {
        var text = AttributedString()
        for (index, line) in excerpt.components(separatedBy: "\n").enumerated() {
            if index > 0 { text += AttributedString("\n") }
            var part = AttributedString(line)
            part.foregroundColor = line.hasPrefix(" ") || line == "…" ? .secondary
                : line.hasPrefix("child ") ? ChildTabColors.lane : ChildTabColors.ok
            text += part
        }
        return Text(text)
    }

    /// Each file in monospace with its line counts.
    private var filesText: AttributedString {
        var text = AttributedString()
        for (index, file) in record.files.prefix(8).enumerated() {
            if index > 0 { text += AttributedString(" · ") }
            var path = AttributedString(file.path)
            path.font = .system(.caption, design: .monospaced)
            text += path
            text += AttributedString(" +\(file.added) −\(file.removed)")
        }
        if record.files.count > 8 { text += AttributedString(" · \(record.files.count - 8) more") }
        return text
    }

    private var options: [(String, String)] {
        let base = record.baseBranch.map { "\($0)'s" } ?? "the parent's"
        return [("resolve", "Keep Both, Then Run the Tests (Recommended)"), ("keepParent", "Keep \(base) Version"),
                ("keepChild", "Keep the Child's Version"), ("leave", "Leave It Unmerged; I'll Look")]
            .filter { record.actions.contains($0.0) }
    }

    /// Run in This Tab Instead while it works; Try Again, Merge Its Work and Discard once it stopped.
    private var extraActions: [(String, String)] {
        if record.state.isRunning {
            return record.actions.contains("requeue") ? [("requeue", "Run in This Tab Instead")] : []
        }
        guard record.state != .conflict else { return [] }
        let titles = ["retry": "Try Again", "merge": "Merge Its Work", "discard": "Discard"]
        return record.actions.compactMap { name in
            guard let title = titles[name], name != "discard" || record.branch != nil else { return nil }
            return (name, title)
        }
    }

    private var statusChip: some View {
        let (icon, color): (String, Color?) = {
            switch record.state {
            case .working, .merging: return ("circle.dotted", ChildTabColors.work)
            case .needsInput: return ("questionmark.circle.fill", ChildTabColors.work)
            case .finished: return ("clock", nil)
            case .merged, .noChanges: return ("checkmark", ChildTabColors.ok)
            case .conflict: return ("exclamationmark.triangle.fill", ChildTabColors.work)
            case .failed: return ("exclamationmark.circle.fill", ChildTabColors.bad)
            case .unmerged, .stopped, .discarded: return ("minus.circle", nil)
            case .requeued: return ("arrow.uturn.backward", nil)
            }
        }()
        return Label(record.statusLine, systemImage: icon)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.map { AnyShapeStyle($0.opacity(0.13)) } ?? AnyShapeStyle(.quaternary), in: Capsule())
            .lineLimit(1)
    }
}

/// The top of a child tab's transcript: whose child it is, its branch, and its state.
struct ChildTabBanner: View {
    let record: ChildTab
    let openParent: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(ChildTabColors.lane)
                .accessibilityHidden(true)
            Text(verbatim: "Child tab of \(record.parentTitle)"
                 + (record.branch.map { " · \($0) → \(record.baseBranch ?? "the parent's branch")" } ?? "")
                 + " · \(record.statusLine)")
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Open Parent", action: openParent)
                .buttonStyle(.link)
                .accessibilityLabel("Open the parent tab, \(record.parentTitle)")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
    }
}
