import Charts
import SwiftUI

// The blocks views brought to cards (docs/views.md "New blocks in resolved cards"): section
// headings, tabs, tables, line and pie charts, and a view's action buttons. Any card may carry the
// first four; `actions` draw only on a view's own screen, which sets `cantripCardActions`.

// MARK: - State and context

/// What a view's screen does with its `actions` buttons: `perform` runs one the person confirmed.
struct CantripCardActionContext {
    var perform: @MainActor (CantripCard.ActionButton) -> Void
    /// The button whose action is on its way to the Mac; the row waits until it's done.
    var runningID: String? = nil
}

extension EnvironmentValues {
    /// Set by a view's screen. Without it (chat, Home's run cards) `actions` blocks aren't drawn.
    @Entry var cantripCardActions: CantripCardActionContext? = nil
}

/// A view's button only asks first: nothing reaches the Mac until the person confirms, and Cancel
/// (or dismissing the question) sends nothing.
struct CantripCardActionFlow: Equatable {
    private(set) var pending: CantripCard.ActionButton?

    /// Shows the confirmation for `button`.
    mutating func choose(_ button: CantripCard.ActionButton) { pending = button }

    /// The confirmation's go-ahead: the button to run, once.
    mutating func confirm(_ button: CantripCard.ActionButton? = nil) -> CantripCard.ActionButton? {
        defer { pending = nil }
        return button ?? pending
    }

    mutating func cancel() { pending = nil }
}

/// The tab chosen in each card's `tabs` block (by card and block), while the app runs, so a view
/// that refreshes in place keeps its tab.
@MainActor final class CantripCardTabSelections: ObservableObject {
    static let shared = CantripCardTabSelections()
    @Published private(set) var selected: [String: Int] = [:]

    func selection(_ key: String) -> Int { selected[key] ?? 0 }

    func select(_ index: Int, for key: String) {
        if selected[key] != index { selected[key] = index }
    }
}

// MARK: - Headings and tabs

/// A chart's or table's title: 13 pt semibold above it.
struct CantripCardBlockTitle: View {
    let title: String
    let isFirst: Bool

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.88))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, isFirst ? 14 : 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// `section`: a grouped-list heading that starts a group.
struct CantripCardSectionHeading: View {
    let block: CantripCard.Block
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = block.title {
                HStack(spacing: 6) {
                    if let symbol = block.symbol, CantripCardStyle.symbolExists(symbol) {
                        Image(systemName: symbol).accessibilityHidden(true)
                    }
                    Text(title)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
            }
            if let subtitle = block.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, isFirst ? 14 : 18)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// `tabs`: a segmented control; the panel shows only the chosen tab's blocks under it.
struct CantripCardTabsControl: View {
    let block: CantripCard.Block
    let isFirst: Bool
    @Binding var selection: Int

    var body: some View {
        let tabs = block.tabs ?? []
        let chosen = Binding(
            get: { Swift.min(Swift.max(0, selection), Swift.max(0, tabs.count - 1)) },
            set: { selection = $0 }
        )
        Picker("Tabs", selection: chosen) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                Text(tab.title ?? "Tab \(index + 1)").tag(index)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 14)
        .padding(.top, isFirst ? 14 : 10)
        .padding(.bottom, 8)
        .accessibilityIdentifier("card.tabs")
    }
}

// MARK: - Table

private struct CantripCardTableWidths: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { Swift.max($0, $1) }
    }
}

/// `table`: a header row and rows of cells with hairlines between them. Columns are as wide as
/// their widest cell (long text wraps), widened to fill the card; a table wider than the card
/// scrolls sideways. VoiceOver reads each row as one element.
struct CantripCardTable: View {
    let block: CantripCard.Block
    let isFirst: Bool
    /// Each column's widest cell, measured on one line.
    @State private var natural: [Int: CGFloat] = [:]
    @State private var available: CGFloat = 0

    static let columnGap: CGFloat = 16
    static let maximumColumnWidth: CGFloat = 260
    private static let inset: CGFloat = 14

    /// Each column at its widest cell (up to `maximumColumnWidth`), grown in proportion to fill
    /// `available` when the table is narrower than that.
    static func columnWidths(natural: [CGFloat], available: CGFloat) -> [CGFloat] {
        let capped = natural.map { Swift.min(Swift.max(0, $0), maximumColumnWidth) }
        let total = capped.reduce(0, +)
        let used = total + columnGap * CGFloat(Swift.max(0, capped.count - 1))
        guard total > 0, used < available else { return capped }
        return capped.map { $0 + (available - used) * $0 / total }
    }

    private var rows: [CantripCard.TableRow] { (block.tableRows ?? []).filter { !$0.cells.isEmpty } }
    private var columns: [CantripCard.Column] { block.columns ?? [] }
    private var columnCount: Int { Swift.max(columns.count, rows.map(\.cells.count).max() ?? 0) }

    var body: some View {
        let count = columnCount
        let measured = (0..<count).allSatisfy { natural[$0] != nil }
        let widths = measured
            ? Self.columnWidths(natural: (0..<count).map { natural[$0] ?? 0 }, available: Swift.max(0, available - 2 * Self.inset))
            : nil
        let tableWidth = widths.map { $0.reduce(0, +) + Self.columnGap * CGFloat(Swift.max(0, count - 1)) }
        VStack(alignment: .leading, spacing: 0) {
            if let title = block.title {
                CantripCardBlockTitle(title: title, isFirst: isFirst)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if columns.contains(where: { $0.title != nil }) {
                        header(count: count, widths: widths)
                        hairline(opacity: 0.1, width: tableWidth)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        rowView(row, count: count, widths: widths)
                        if index < rows.count - 1 { hairline(opacity: 0.06, width: tableWidth) }
                    }
                }
                .padding(.horizontal, Self.inset)
                .onPreferenceChange(CantripCardTableWidths.self) { widths in
                    MainActor.assumeIsolated { if natural != widths { natural = widths } }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        }
        .padding(.top, isFirst && block.title == nil ? 6 : 0)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.title ?? block.accessibilityLabel ?? "Table")
    }

    private func header(count: Int, widths: [CGFloat]?) -> some View {
        HStack(alignment: .bottom, spacing: Self.columnGap) {
            ForEach(0..<count, id: \.self) { column in
                cell(column: column, widths: widths) {
                    Text(column < columns.count ? columns[column].title ?? "" : "")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(.vertical, 7)
        .accessibilityHidden(true)
    }

    private func rowView(_ row: CantripCard.TableRow, count: Int, widths: [CGFloat]?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.columnGap) {
            ForEach(0..<count, id: \.self) { column in
                let value = column < row.cells.count ? row.cells[column] : CantripCard.Cell()
                cell(column: column, widths: widths) { cellContent(value) }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel ?? spoken(row))
    }

    private func cellContent(_ cell: CantripCard.Cell) -> some View {
        HStack(spacing: 4) {
            if let symbol = cell.symbol, CantripCardStyle.symbolExists(symbol) {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(cell.text ?? "")
        }
        .font(.footnote)
        .foregroundStyle(cell.tone == nil ? Color.white.opacity(0.92) : CantripCardStyle.tone(cell.tone))
    }

    /// A cell at its column's width, measuring its one-line width for the column.
    private func cell<Content: View>(column: Int, widths: [CGFloat]?, @ViewBuilder content: () -> Content) -> some View {
        let content = content()
        let alignment = alignment(column)
        return content
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .fixedSize(horizontal: widths == nil, vertical: true)
            .frame(width: widths?[column], alignment: alignment)
            .background(alignment: .leading) {
                content.fixedSize().hidden().background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: CantripCardTableWidths.self, value: [column: proxy.size.width])
                    }
                }
            }
    }

    private func alignment(_ column: Int) -> Alignment {
        switch column < columns.count ? columns[column].align : nil {
        case "trailing": .trailing
        case "center": .center
        default: .leading
        }
    }

    private func hairline(opacity: Double, width: CGFloat?) -> some View {
        Rectangle()
            .fill(Color.white.opacity(opacity))
            .frame(width: width, height: 1)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func spoken(_ row: CantripCard.TableRow) -> String {
        row.cells.enumerated().compactMap { index, cell in
            guard let text = cell.text, !text.isEmpty else { return nil }
            guard index < columns.count, let title = columns[index].title, !title.isEmpty else { return text }
            return "\(title): \(text)"
        }.joined(separator: ", ")
    }
}

// MARK: - Charts

/// `chart` `line`: one line through the points in order, the `min`…`max` scale, and the first,
/// middle and last labels under it; each point is an accessibility element.
struct CantripCardLineChart: View {
    struct Point: Identifiable, Equatable {
        /// The item's place in the chart, its x position.
        let id: Int
        let value: Double
        let spoken: String
    }

    let block: CantripCard.Block

    static func points(_ block: CantripCard.Block) -> [Point] {
        (block.items ?? []).enumerated().compactMap { index, item in
            guard let value = item.high, value.isFinite else { return nil }
            let spoken = item.accessibilityLabel ?? [item.label, item.highText].compactMap { $0 }.joined(separator: ", ")
            return Point(id: index, value: value, spoken: spoken)
        }
    }

    /// The items labeled under the line: the first, middle and last.
    static func labeledPositions(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return Array(Set([0, (count - 1) / 2, count - 1])).sorted()
    }

    /// `min`…`max`, widened to every point (and to a span when they're all equal).
    static func scale(_ block: CantripCard.Block, points: [Point]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        let lower = Swift.min(block.min ?? values.min() ?? 0, values.min() ?? .infinity)
        let upper = Swift.max(block.max ?? values.max() ?? 1, values.max() ?? -.infinity)
        return upper > lower ? lower...upper : lower...(lower + 1)
    }

    var body: some View {
        let points = Self.points(block)
        let items = block.items ?? []
        let scale = Self.scale(block, points: points)
        Chart(points) { point in
            LineMark(x: .value("Item", point.id), y: .value("Value", point.value))
                .foregroundStyle(CantripCardStyle.accent)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .accessibilityHidden(true)
            PointMark(x: .value("Item", point.id), y: .value("Value", point.value))
                .foregroundStyle(CantripCardStyle.accent)
                .symbolSize(30)
                .accessibilityLabel(point.spoken)
        }
        .chartXScale(domain: 0...Swift.max(1, items.count - 1))
        .chartYScale(domain: scale)
        .chartXAxis {
            AxisMarks(values: Self.labeledPositions(count: items.count)) { value in
                let index = value.as(Int.self) ?? 0
                AxisValueLabel(anchor: index == 0 ? .topLeading : index == items.count - 1 ? .topTrailing : .top) {
                    Text(items.indices.contains(index) ? items[index].label ?? "" : "")
                }
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.72))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [scale.lowerBound, scale.upperBound]) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.14))
                AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName))
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.62))
            }
        }
        .frame(height: 170)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.accessibilityLabel ?? block.title ?? "Line chart")
    }
}

/// `chart` `pie`: a donut (the item's tone, else the palette in order) with a legend of each
/// slice's label, value and share.
struct CantripCardPieChart: View {
    struct Slice: Identifiable, Equatable {
        /// The item's place, which picks its palette color.
        let id: Int
        let label: String
        let value: Double
        let text: String?
        let tone: String?
        let percent: String
        let spoken: String
    }

    let block: CantripCard.Block

    static let palette: [Color] = [0x4C9DFF, 0x34C759, 0xFFCC00, 0xAF52DE, 0x5AC8FA, 0xFF9F0A, 0xFF6482, 0x8E8E93].map { rgb in
        Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    static func color(_ slice: Slice) -> Color {
        slice.tone.map(CantripCardStyle.tone) ?? palette[slice.id % palette.count]
    }

    /// The items with a positive value; a pie with nothing to share draws nothing.
    static func slices(_ block: CantripCard.Block) -> [Slice] {
        let items = block.items ?? []
        let values = items.map { item in item.high.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        let total = values.compactMap { $0 }.reduce(0, +)
        guard total > 0 else { return [] }
        return items.enumerated().compactMap { index, item in
            guard let value = values[index] else { return nil }
            let percent = (value / total).formatted(.percent.precision(.fractionLength(0)))
            let base = [item.label, item.highText].compactMap { $0 }.joined(separator: ", ")
            return Slice(id: index, label: item.label ?? "", value: value, text: item.highText, tone: item.tone,
                         percent: percent, spoken: item.accessibilityLabel ?? (base.isEmpty ? percent : "\(base), \(percent)"))
        }
    }

    var body: some View {
        let slices = Self.slices(block)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                donut(slices).frame(width: 140, height: 140)
                legend(slices).frame(minWidth: 220)
            }
            VStack(alignment: .leading, spacing: 14) {
                donut(slices).frame(width: 160, height: 160).frame(maxWidth: .infinity)
                legend(slices)
            }
        }
        .padding(14)
    }

    private func donut(_ slices: [Slice]) -> some View {
        Chart(slices) { slice in
            SectorMark(angle: .value("Value", slice.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(Self.color(slice))
        }
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }

    private func legend(_ slices: [Slice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(slices) { slice in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Self.color(slice))
                        .frame(width: 10, height: 10)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(slice.label)
                        .foregroundStyle(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let text = slice.text {
                        Text(text).fontWeight(.semibold).monospacedDigit()
                    }
                    Text(slice.percent)
                        .foregroundStyle(.white.opacity(0.62))
                        .monospacedDigit()
                        .frame(minWidth: 38, alignment: .trailing)
                }
                .font(.footnote)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(slice.spoken)
            }
        }
    }
}

// MARK: - Actions

/// `actions`: a wrapping row of bordered buttons (`prominent` filled). Choosing one asks first
/// (`confirmTitle`, `confirmMessage`, the button's label to go ahead, Cancel); only then does the
/// view's screen post it.
struct CantripCardActionsRow: View {
    let block: CantripCard.Block
    let isFirst: Bool
    @Environment(\.cantripCardActions) private var context
    @State private var flow = CantripCardActionFlow()

    var body: some View {
        let buttons = CantripCard.ActionButton.shown(block.buttons)
        CantripChildFlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                CantripCardActionButton(button: button, isRunning: context?.runningID == button.id) {
                    flow.choose(button)
                }
                .disabled(context == nil || context?.runningID != nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, isFirst ? 14 : 6)
        .padding(.bottom, 14)
        .alert(
            flow.pending.map { $0.confirmTitle ?? $0.title } ?? "",
            isPresented: Binding(get: { flow.pending != nil }, set: { if !$0 { flow.cancel() } }),
            presenting: flow.pending
        ) { button in
            Button(button.title) {
                if let chosen = flow.confirm(button) { context?.perform(chosen) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { flow.cancel() }
        } message: { button in
            if let message = button.confirmMessage { Text(message) }
        }
    }
}

private struct CantripCardActionButton: View {
    let button: CantripCard.ActionButton
    let isRunning: Bool
    let action: () -> Void

    /// Filled buttons keep white text at AA contrast (5.4:1) on this blue.
    private static let prominentFill = Color(red: 0.0, green: 0.40, blue: 0.85)

    var body: some View {
        if button.style == "prominent" {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .tint(Self.prominentFill)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .tint(CantripCardStyle.accent)
        }
    }

    private var label: some View {
        Label {
            Text(button.title)
        } icon: {
            if isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: button.systemImage)
            }
        }
        .font(.subheadline.weight(.semibold))
        .accessibilityIdentifier("card.action.\(button.id ?? "")")
    }
}
