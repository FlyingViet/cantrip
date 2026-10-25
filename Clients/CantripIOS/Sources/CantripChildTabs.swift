import SwiftUI

/// Child tabs: a queued message runs in its own tab (and, in a git repository, its own branch),
/// nested under its parent, and merges back when done. The parent shows one card per child; only
/// the Mac's one-line summary of it reaches the parent's model. Same design as the Mac panel and
/// the browser Remote (Cantrip docs/sessions-and-council.md "Child tabs").
enum CantripChildTabStyle {
    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }

    /// Text colors that keep 4.5:1 contrast on light and dark backgrounds.
    static let lane = adaptive(light: (0.02, 0.44, 0.56), dark: (0.39, 0.82, 1))
    static let ok = adaptive(light: (0.11, 0.48, 0.2), dark: (0.21, 0.78, 0.35))
    static let work = adaptive(light: (0.62, 0.34, 0), dark: (1, 0.62, 0.04))
    static let bad = adaptive(light: (0.77, 0.17, 0.22), dark: (1, 0.41, 0.38))
    /// The request bubble in a card's thread (white text on it is 5.6:1).
    static let bubble = Color(red: 0.23, green: 0.37, blue: 0.8)
    /// Chips and tags that stand out on list rows as well as the transcript.
    static let neutralFill = Color.secondary.opacity(0.16)
    static let glyph = "arrow.triangle.branch"
}

enum CantripChildTabText {
    /// The card's buttons for a conflict, in the Mac's order, limited to what it offers now.
    static func conflictOptions(_ child: CantripRemoteChildResult) -> [(action: String, title: String)] {
        let base = child.baseBranch.map { "\($0)'s" } ?? "the parent's"
        return [("resolve", "Keep both, then run the tests (Recommended)"), ("keepParent", "Keep \(base) version"),
                ("keepChild", "Keep the child's version"), ("leave", "Leave it unmerged; I'll look")]
            .filter { child.actions.contains($0.0) }
    }

    /// Run in this tab instead while the child works; Try Again, Merge Its Work and Discard once it
    /// stopped (Discard only when there is a branch to throw away).
    static func extraActions(_ child: CantripRemoteChildResult) -> [(action: String, title: String)] {
        if child.state.isRunning {
            return child.actions.contains("requeue") ? [("requeue", "Run in this tab instead")] : []
        }
        guard child.state != .conflict else { return [] }
        let titles = ["retry": "Try Again", "merge": "Merge Its Work", "discard": "Discard"]
        return child.actions.compactMap { name in
            guard let title = titles[name], name != "discard" || child.branch != nil else { return nil }
            return (name, title)
        }
    }

    /// "2 files merged cleanly, but both branches changed the same lines in a.swift and b.swift."
    static func conflictLead(_ child: CantripRemoteChildResult) -> String {
        let files = child.conflictFiles.prefix(4).joined(separator: ", ")
            + (child.conflictFiles.count > 4 ? " and \(child.conflictFiles.count - 4) more" : "")
        let clean = child.cleanFileCount
        return clean > 0
            ? "\(clean) \(clean == 1 ? "file" : "files") merged cleanly, but both branches changed the same lines in \(files)."
            : "Both branches changed the same lines in \(files)."
    }

    /// The first line of the request, for the card's tag.
    static func firstLine(_ prompt: String) -> String {
        prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
    }

    static func summary(_ child: CantripRemoteChildResult) -> String {
        let summary = child.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty && child.state == .working ? "Working on it in its own tab." : summary
    }

    /// The banner atop a child tab's conversation.
    static func banner(_ child: CantripRemoteChildTab) -> String {
        "Child tab of \(child.parentTitle)"
            + (child.branch.map { " · \($0) → \(child.baseBranch ?? "the parent's branch")" } ?? "")
            + (child.statusLine.isEmpty ? "" : " · \(child.statusLine)")
    }

    static func statusIcon(_ state: CantripChildTabState) -> (symbol: String, tint: Color?) {
        switch state {
        case .working, .merging: return ("circle.dotted", CantripChildTabStyle.work)
        case .needsInput: return ("questionmark.circle.fill", CantripChildTabStyle.work)
        case .finished: return ("clock", nil)
        case .merged, .noChanges: return ("checkmark", CantripChildTabStyle.ok)
        case .conflict: return ("exclamationmark.triangle.fill", CantripChildTabStyle.work)
        case .failed: return ("exclamationmark.circle.fill", CantripChildTabStyle.bad)
        case .unmerged, .stopped, .discarded, .other: return ("minus.circle", nil)
        case .requeued: return ("arrow.uturn.backward", nil)
        }
    }
}

/// A child tab's card in its parent: the lane and a tag with the request (tap to show the request,
/// the child's replies and its files), the summary, a merge question on a conflict, and status.
struct CantripChildTabCard: View {
    let child: CantripRemoteChildResult
    let parentID: String
    @ObservedObject var remote: CantripRemoteModel
    /// Opens a tab in this window or lane; nil hides Open.
    var onOpenTab: ((String) -> Void)?
    @State private var expanded = false
    @State private var confirmingDiscard = false
    @State private var confirmingRequeue = false

    private var isListed: Bool { remote.sessions.contains { $0.id == child.id } }
    private var isBusy: Bool { remote.isMutating || remote.childActionInFlight != nil || !remote.isConnected }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            threadToggle
            if expanded { thread }
            let summary = CantripChildTabText.summary(child)
            if !summary.isEmpty {
                Text(TurnView.markdown(summary))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if child.state == .conflict { question }
            CantripChildFlowLayout(spacing: 10, lineSpacing: 6) {
                statusChip
                if onOpenTab != nil {
                    Button(isListed ? "Open Tab" : "Open Conversation") { perform("open") }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 32)
                        .disabled(isBusy && !isListed)
                        .accessibilityLabel("\(isListed ? "Open Tab" : "Open Conversation"): \(child.title)")
                }
                ForEach(CantripChildTabText.extraActions(child), id: \.action) { action, title in
                    Button(title) { run(action) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(action == "discard" ? .red : .accentColor)
                        .disabled(isBusy)
                }
                if let key = remote.childActionInFlight, key.hasPrefix("\(child.id)/") {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cantrip-child-card-\(child.id)")
        .alert("Discard “\(child.title)”?", isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { perform("discard") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(child.branch.map { "Its work on \($0) is deleted. The conversation stays in history." }
                 ?? "The conversation stays in history.")
        }
        .alert("Run “\(child.title)” in this tab instead?", isPresented: $confirmingRequeue) {
            Button("Run Here Instead") { perform("requeue") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The child tab stops\(child.branch.map { " and its work on \($0) is deleted" } ?? ""). The request goes back to the front of this tab's queue.")
        }
    }

    private func run(_ action: String) {
        switch action {
        case "discard": confirmingDiscard = true
        case "requeue": confirmingRequeue = true
        default: perform(action)
        }
    }

    private func perform(_ action: String) {
        if action == "open", isListed {
            onOpenTab?(child.id)
            return
        }
        Task {
            let done = await remote.performChildAction(action, childID: child.id, parentID: parentID)
            if done, action == "open" { onOpenTab?(child.id) }
        }
    }

    private var threadToggle: some View {
        let firstLine = CantripChildTabText.firstLine(child.prompt)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            CantripChildFlowLayout(spacing: 6, lineSpacing: 4, shrinksToFit: 140) {
                Label("Child tab · \(child.title)", systemImage: CantripChildTabStyle.glyph)
                    .lineLimit(1)
                    .foregroundStyle(CantripChildTabStyle.lane)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(CantripChildTabStyle.lane.opacity(0.13), in: Capsule())
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.left")
                    Text(verbatim: firstLine).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(CantripChildTabStyle.neutralFill, in: Capsule())
            }
            .font(.caption.weight(.semibold))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Child tab \(child.title): \(firstLine)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows the request and the child tab's replies")
        .accessibilityIdentifier("cantrip-child-thread-\(child.id)")
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: child.prompt)
                .font(.callout)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(CantripChildTabStyle.bubble, in: RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 32)
            ForEach(Array(child.replies.enumerated()), id: \.offset) { _, reply in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: child.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(TurnView.markdown(reply))
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            if !child.files.isEmpty {
                Text(filesText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if onOpenTab != nil {
                Button("Open the full conversation") { perform("open") }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 32)
                    .disabled(isBusy && !isListed)
                    .accessibilityLabel("Open the full conversation of \(child.title)")
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2)
        }
    }

    /// Each file in monospace with its line counts.
    private var filesText: AttributedString {
        var text = AttributedString()
        for (index, file) in child.files.prefix(8).enumerated() {
            if index > 0 { text += AttributedString(" · ") }
            var path = AttributedString(file.path)
            path.font = .system(.caption, design: .monospaced)
            text += path
            text += AttributedString(" +\(file.added) −\(file.removed)")
        }
        if child.files.count > 8 { text += AttributedString(" · \(child.files.count - 8) more") }
        return text
    }

    private var question: some View {
        let base = child.baseBranch ?? "the parent's branch"
        return VStack(alignment: .leading, spacing: 8) {
            Text("Merge needs your answer")
                .font(.callout.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text("Merging **\(child.title)** into `\(base)`. \(CantripChildTabText.conflictLead(child))")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let excerpt = child.conflictExcerpt, !excerpt.isEmpty {
                ScrollView(.horizontal) {
                    excerptText(excerpt)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Conflicting lines")
                .accessibilityValue(excerpt)
            }
            if let note = child.note, !note.isEmpty {
                Text(verbatim: note).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(CantripChildTabText.conflictOptions(child), id: \.action) { action, title in
                if action == "resolve" {
                    Button { perform(action) } label: { optionLabel(title) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                } else {
                    Button { perform(action) } label: { optionLabel(title) }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cantrip-child-question-\(child.id)")
    }

    private func optionLabel(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 32)
    }

    /// Context lines dim, the parent's side green, the child's side in the lane color.
    private func excerptText(_ excerpt: String) -> Text {
        var text = AttributedString()
        for (index, line) in excerpt.components(separatedBy: "\n").enumerated() {
            if index > 0 { text += AttributedString("\n") }
            var part = AttributedString(line)
            part.foregroundColor = line.hasPrefix(" ") || line == "…" ? .secondary
                : line.hasPrefix("child ") ? CantripChildTabStyle.lane : CantripChildTabStyle.ok
            text += part
        }
        return Text(text)
    }

    private var statusChip: some View {
        let icon = CantripChildTabText.statusIcon(child.state)
        return Label(child.statusLine, systemImage: icon.symbol)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .lineLimit(2)
            .foregroundStyle(icon.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(icon.tint.map { AnyShapeStyle($0.opacity(0.13)) }
                        ?? AnyShapeStyle(CantripChildTabStyle.neutralFill), in: Capsule())
    }
}

/// The top of a child tab's conversation: whose child it is, its branch and its state.
struct CantripChildTabBanner: View {
    let child: CantripRemoteChildTab
    var onOpenParent: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: CantripChildTabStyle.glyph)
                .foregroundStyle(CantripChildTabStyle.lane)
                .accessibilityHidden(true)
            Text(verbatim: CantripChildTabText.banner(child))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let onOpenParent {
                Button("Open Parent", action: onOpenParent)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 32)
                    .accessibilityLabel("Open the parent tab, \(child.parentTitle)")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cantrip-child-banner")
    }
}

/// A queued message's suggested plan ("Independent: can run in a child tab").
struct CantripQueuePlanChip: View {
    let plan: CantripRemoteQueuePlan

    var body: some View {
        let fork = plan.kind == .fork
        Text(verbatim: plan.reason)
            .font(.caption.weight(.semibold))
            .lineLimit(2)
            .foregroundStyle(fork ? AnyShapeStyle(CantripChildTabStyle.lane) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fork ? AnyShapeStyle(CantripChildTabStyle.lane.opacity(0.13))
                        : AnyShapeStyle(CantripChildTabStyle.neutralFill), in: Capsule())
            .accessibilityLabel("Plan: \(plan.reason)")
    }
}

/// A child tab's mark in tab lists, before its title.
struct CantripChildTabGlyph: View {
    var body: some View {
        Image(systemName: CantripChildTabStyle.glyph)
            .font(.caption.weight(.semibold))
            .foregroundStyle(CantripChildTabStyle.lane)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Child tabs sit indented under their parent with a guide line, like the Mac and browser lists.
    @ViewBuilder func cantripChildTabIndent(_ session: CantripRemoteSession, by indent: CGFloat = 18) -> some View {
        if session.isChildTab {
            padding(.leading, indent)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 2)
                        .padding(.vertical, 3)
                        .padding(.leading, indent / 2 - 1)
                        .accessibilityHidden(true)
                }
        } else {
            self
        }
    }
}

/// Lays its views out left to right, wrapping onto new lines like text.
struct CantripChildFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6
    /// A view that doesn't fit the rest of a line shrinks to fit it (text truncates) when at least
    /// this much is left, instead of wrapping. Nil always wraps.
    var shrinksToFit: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> [Row] {
        let limit = width ?? .infinity
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > limit {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: limit, height: nil))
                size.width = min(size.width, limit)
            }
            if !row.items.isEmpty, row.width + spacing + size.width > limit {
                let left = limit - row.width - spacing
                if let minimum = shrinksToFit, left >= minimum {
                    size = subviews[index].sizeThatFits(ProposedViewSize(width: left, height: nil))
                    size.width = min(size.width, left)
                } else {
                    rows.append(row)
                    row = Row()
                }
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
