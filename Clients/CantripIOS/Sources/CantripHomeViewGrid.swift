import SwiftUI

// Tasks → Views as a grid of thumbnails, and the Views and Tasks sections that fold away
// (docs/views.md, "Clients"). Every client lays the grid out with the same column rule and picks
// the same preview blocks.

enum CantripHomeViewGrid {
    static let spacing: CGFloat = 12

    /// The narrowest a thumbnail gets: narrower on a phone so two fit side by side.
    static func minimumWidth(for width: CGFloat) -> CGFloat { width < 600 ? 160 : 240 }

    /// Columns for a grid `width` points wide: as many as fit at the minimum width, 1…6.
    static func columns(width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let fitting = Int(((width + spacing) / (minimumWidth(for: width) + spacing)).rounded(.down))
        return Swift.min(Swift.max(fitting, 1), 6)
    }

    /// A thumbnail's height: rows line up, and a phone's narrower cards get a little less.
    static func thumbnailHeight(for width: CGFloat) -> CGFloat { width < 600 ? 176 : 196 }

    static let previewSkipped: Set<String> = ["header", "section", "actions", "notice", "badges", "progress", "image", "map"]

    /// What a thumbnail shows of a view's card: up to two stats and the first chart, else the first
    /// table, list or key-value block cut to three rows. A `tabs` block contributes its first tab only
    /// (the card is flat: a tab owns the blocks after it), the way the view's screen opens.
    static func previewBlocks(_ card: CantripCard) -> [CantripCard.Block] {
        let blocks = CantripCardPanel.entries(card.blocks, selectedTab: { _ in 0 }).compactMap { entry -> (Int, CantripCard.Block)? in
            if case .block(let block) = entry.section, !previewSkipped.contains(block.type) { return (entry.index, block) }
            return nil
        }
        var chosen: [(Int, CantripCard.Block)] = Array(blocks.filter { $0.1.type == "stat" }.prefix(2))
        if let chart = blocks.first(where: { $0.1.type == "chart" }) { chosen.append(chart) }
        if chosen.isEmpty, let rows = blocks.first(where: { ["table", "list", "keyValue"].contains($0.1.type) }) {
            var block = rows.1
            block.tableRows = block.tableRows.map { Array($0.prefix(3)) }
            block.items = block.items.map { Array($0.prefix(3)) }
            block.rows = block.rows.map { Array($0.prefix(3)) }
            chosen = [(rows.0, block)]
        }
        return chosen.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/// Which Tasks-screen sections are folded, remembered on this device.
enum CantripHomeListSection: String, CaseIterable {
    case views, tasks

    var defaultsKey: String { self == .views ? "home.tasks.viewsCollapsed" : "home.tasks.tasksCollapsed" }
    var title: String { self == .views ? "Views" : "Tasks" }

    func noun(_ count: Int) -> String {
        let word = self == .views ? "view" : "task"
        return "\(count) \(word)\(count == 1 ? "" : "s")"
    }

    func isCollapsed(in defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }

    func setCollapsed(_ collapsed: Bool, in defaults: UserDefaults = .standard) {
        if collapsed { defaults.set(true, forKey: defaultsKey) } else { defaults.removeObject(forKey: defaultsKey) }
    }

    /// "Views · 6" when folded; just the title when open.
    func headerText(count: Int, collapsed: Bool) -> String { collapsed ? "\(title) · \(count)" : title }

    func spokenLabel(count: Int) -> String { "\(title), \(noun(count))" }
}

/// A section's header: one button that folds the section, saying how many it holds while folded.
struct CantripHomeSectionHeader: View {
    let section: CantripHomeListSection
    let count: Int
    @Binding var collapsed: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if collapsed {
                    Text("· \(count)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .textCase(nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.spokenLabel(count: count))
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(collapsed ? "Shows the \(section.title.lowercased())" : "Hides the \(section.title.lowercased())")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("home.tasks.section.\(section.rawValue)")
    }
}

/// The views as thumbnails, as many columns as the width allows. Each opens its view's screen.
struct CantripHomeViewGridView: View {
    let views: [CantripHomeViewSummary]
    @ObservedObject var remote: CantripRemoteModel
    /// Shows Home's Chat (a view's `ask` button puts its question there).
    let showChat: () -> Void
    @State private var width: CGFloat = 0

    var body: some View {
        let columns = CantripHomeViewGrid.columns(width: width)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CantripHomeViewGrid.spacing, alignment: .top),
                                 count: columns),
                  alignment: .leading, spacing: CantripHomeViewGrid.spacing) {
            ForEach(views) { view in
                // A link (not a button and a destination): it pushes in the iPad's split detail too.
                NavigationLink {
                    CantripHomeViewScreen(remote: remote, summary: view, showChat: showChat)
                } label: {
                    CantripHomeViewThumbnail(view: view, detail: remote.homeViewThumbnails[view.id], remote: remote,
                                             height: CantripHomeViewGrid.thumbnailHeight(for: width))
                }
                .buttonStyle(.plain)
                // The card is the whole target; a list row's chevron beside each one would only take width.
                .navigationLinkIndicatorVisibility(.hidden)
                .viewThumbnailAccessibility(view)
                .contextMenu {
                    Button {
                        Task { _ = try? await remote.setHomeViewPinned(id: view.id, pinned: !view.pinned) }
                    } label: {
                        Label(view.pinned ? "Unpin" : "Pin", systemImage: view.pinned ? "pin.slash" : "pin")
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityIdentifier("home.views.grid")
        .task(id: views.map(\.id)) {
            // Thumbnails follow the Mac while the grid shows; the remote only fetches what changed.
            while !Task.isCancelled {
                await remote.refreshHomeViewThumbnails()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// A view as a card: its icon, name, pin and lock, its subtitle, and a small live preview of its
/// first stats and chart drawn by the card block views. Its link is one button for VoiceOver
/// (`viewThumbnailAccessibility`).
struct CantripHomeViewThumbnail: View {
    let view: CantripHomeViewSummary
    let detail: CantripHomeViewDetail?
    @ObservedObject var remote: CantripRemoteModel
    var height: CGFloat = 196
    static let previewScale: CGFloat = 0.62

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: view.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                Text(view.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if view.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(45))
                }
                if view.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let line = view.detailLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            preview
            if view.refreshing {
                Label("Refreshing…", systemImage: "arrow.clockwise")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let problem = view.problems.first {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The card's preview blocks at about 60%, on the card's own dark panel; never touchable.
    @ViewBuilder private var preview: some View {
        let blocks = detail.map { CantripHomeViewGrid.previewBlocks($0.card) } ?? []
        GeometryReader { geometry in
            if blocks.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(CantripCardStyle.panel.opacity(detail == nil ? 0.35 : 0.6))
                    .overlay {
                        if detail != nil {
                            Image(systemName: view.symbol)
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        CantripCardBlockView(block: block, isFirst: index == 0, remote: remote)
                    }
                }
                .frame(width: geometry.size.width / Self.previewScale, alignment: .topLeading)
                .scaleEffect(Self.previewScale, anchor: .topLeading)
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background(LinearGradient(colors: [CantripCardStyle.panelTop, CantripCardStyle.panel],
                                           startPoint: .top, endPoint: .bottom))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// A thumbnail's link as one button for VoiceOver: the view's name, pin, lock, subtitle and state.
    func viewThumbnailAccessibility(_ view: CantripHomeViewSummary) -> some View {
        accessibilityLabel(view.spokenLabel)
            // A plain-style link in a Mac list reports no role of its own; it opens like a button.
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("home.view.\(view.id)")
    }
}
