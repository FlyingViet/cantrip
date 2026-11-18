import SwiftUI

// Tasks → Views as a grid of thumbnails, and the Views, Upcoming and Tasks sections that fold away
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
    case views, upcoming, tasks

    var defaultsKey: String { "home.tasks.\(rawValue)Collapsed" }

    var title: String {
        switch self {
        case .views: "Views"
        case .upcoming: "Upcoming"
        case .tasks: "Tasks"
        }
    }

    /// What the section holds, for VoiceOver's hint.
    private var contents: String { self == .upcoming ? "upcoming items" : title.lowercased() }

    func noun(_ count: Int) -> String {
        let word = switch self {
        case .views: "view"
        case .upcoming: "item"
        case .tasks: "task"
        }
        return "\(count) \(word)\(count == 1 ? "" : "s")"
    }

    /// Upcoming always says how many it holds; Views and Tasks only while folded.
    var alwaysCounts: Bool { self == .upcoming }

    func isCollapsed(in defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }

    func setCollapsed(_ collapsed: Bool, in defaults: UserDefaults = .standard) {
        if collapsed { defaults.set(true, forKey: defaultsKey) } else { defaults.removeObject(forKey: defaultsKey) }
    }

    /// "Views · 6" when folded; just the title when open ("Upcoming · 12" either way).
    func headerText(count: Int, collapsed: Bool) -> String { collapsed || alwaysCounts ? "\(title) · \(count)" : title }

    func spokenLabel(count: Int) -> String { "\(title), \(noun(count))" }

    func hint(collapsed: Bool) -> String { collapsed ? "Shows the \(contents)" : "Hides the \(contents)" }
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
                if collapsed || section.alwaysCounts {
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
        .accessibilityHint(section.hint(collapsed: collapsed))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("home.tasks.section.\(section.rawValue)")
    }
}

/// The views as thumbnails, as many columns as the width allows. Each opens its view's screen.
///
/// The grid is one row of the Tasks list, and a list row takes one navigation link and one context
/// menu for everything in it: every thumbnail opened the same view, and every long press or right
/// click showed the first one's menu. So each thumbnail is a plain button that names its view (the
/// list's one destination pushes it), with its own ⋯ menu button for Pin, controls the row keeps apart.
struct CantripHomeViewGridView: View {
    let views: [CantripHomeViewSummary]
    @ObservedObject var remote: CantripRemoteModel
    /// Opens a view's screen by its ID.
    let open: (String) -> Void
    @State private var width: CGFloat = 0

    var body: some View {
        grid(columns: CantripHomeViewGrid.columns(width: width))
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

    private func togglePin(_ view: CantripHomeViewSummary) {
        Task { _ = try? await remote.setHomeViewPinned(id: view.id, pinned: !view.pinned) }
    }

    private func grid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CantripHomeViewGrid.spacing, alignment: .top),
                                 count: columns),
                  alignment: .leading, spacing: CantripHomeViewGrid.spacing) {
            ForEach(views) { view in
                Button {
                    // Only a tap opens it: a swipe's lift over a card doesn't.
                    guard CantripSwipeTaps.allowsTap() else { return }
                    open(view.id)
                } label: {
                    CantripHomeViewThumbnail(view: view, detail: remote.homeViewThumbnails[view.id], remote: remote,
                                             height: CantripHomeViewGrid.thumbnailHeight(for: width))
                }
                .buttonStyle(.plain)
                .viewThumbnailAccessibility(view)
                .accessibilityAction(named: view.pinned ? "Unpin" : "Pin") { togglePin(view) }
                .overlay(alignment: .topTrailing) {
                    Menu {
                        Button {
                            togglePin(view)
                        } label: {
                            Label(view.pinned ? "Unpin" : "Pin", systemImage: view.pinned ? "pin.slash" : "pin")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .padding(2)
                    .accessibilityLabel("More for \(view.name)")
                    .accessibilityIdentifier("home.view.menu.\(view.id)")
                }
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
            // Room for the grid's ⋯ menu button over the corner.
            .padding(.trailing, 24)
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
    /// A thumbnail as one button for VoiceOver: the view's name, pin, lock, subtitle and state.
    func viewThumbnailAccessibility(_ view: CantripHomeViewSummary) -> some View {
        accessibilityLabel(view.spokenLabel)
            // A plain-style button in a Mac list reports no role of its own; it opens like a button.
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("home.view.\(view.id)")
    }
}
