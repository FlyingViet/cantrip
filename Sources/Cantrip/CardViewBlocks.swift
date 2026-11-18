import Charts
import SwiftUI

// MARK: - View blocks (docs/views.md): sections, tabs, tables, line and pie charts

/// A chart's or table's optional title above it.
struct CardBlockTitle<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
    }
}

/// A grouped-list heading that starts a group of blocks.
struct CardSectionView: View {
    let block: CardDocument.Block
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if CardLook.symbolExists(block.symbol), let symbol = block.symbol {
                    Image(systemName: symbol).accessibilityHidden(true)
                }
                Text(block.title ?? "")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))
            .accessibilityAddTraits(.isHeader)
            if let subtitle = block.subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, isFirst ? 14 : 18)
        .padding(.bottom, 4)
    }
}

/// Which tab each card's tabs show, while Cantrip runs (a view that refreshes keeps its tab).
@MainActor final class CardTabSelections: ObservableObject {
    static let shared = CardTabSelections()
    @Published var selected: [String: Int] = [:]
}

/// A segmented control; only the chosen tab's blocks show.
struct CardTabsView: View {
    let block: CardDocument.Block
    let panels: [[CardDocument.Block]]
    let stateKey: String
    @ObservedObject private var selections = CardTabSelections.shared

    var body: some View {
        let tabs = Array((block.tabs ?? []).prefix(panels.count))
        let chosen = Swift.min(selections.selected[stateKey] ?? 0, Swift.max(0, tabs.count - 1))
        VStack(alignment: .leading, spacing: 0) {
            Picker(block.accessibilityLabel ?? "Sections", selection: Binding(
                get: { chosen }, set: { selections.selected[stateKey] = $0 }
            )) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in Text(tab.title).tag(index) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if panels.indices.contains(chosen) {
                ForEach(Array(panels[chosen].enumerated()), id: \.offset) { index, child in
                    CardBlockView(block: child, isFirst: false, stateKey: "\(stateKey):\(chosen):\(index)")
                }
            }
        }
    }
}

/// Columns with headings; scrolls sideways when it doesn't fit. Each row reads as one sentence.
struct CardTableView: View {
    let block: CardDocument.Block

    private func alignment(_ column: CardDocument.Column) -> Alignment {
        switch column.align {
        case "trailing": .trailing
        case "center": .center
        default: .leading
        }
    }

    var body: some View {
        let columns = Array((block.columns ?? []).prefix(6))
        let rows = Array((block.tableRows ?? []).prefix(50))
        CardBlockTitle(title: block.title) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            Text(column.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.62))
                                .gridColumnAlignment(alignment(column).horizontal)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityHidden(true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Divider().overlay(Color.white.opacity(0.08))
                        GridRow {
                            ForEach(Array(columns.indices), id: \.self) { index in
                                let cell = row.cells.indices.contains(index) ? row.cells[index] : nil
                                Text(cell?.text ?? "")
                                    .font(.system(size: 13, weight: index == 0 ? .semibold : .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(cell?.tone.map(CardLook.tone) ?? .white)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 7)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel ?? row.cells.map(\.text).joined(separator: ", "))
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.title ?? block.accessibilityLabel ?? "Table")
    }
}

enum CardChartPalette {
    static let colors: [Color] = [0x4C9DFF, 0x34C759, 0xFFCC00, 0xAF52DE, 0x5AC8FA, 0xFF9F0A, 0xFF6482, 0x8E8E93].map { hex in
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func color(_ item: CardDocument.Item, index: Int) -> Color {
        item.tone.map(CardLook.tone) ?? colors[index % colors.count]
    }
}

/// One line through the points in order on the block's min…max scale.
struct CardLineChartView: View {
    let block: CardDocument.Block

    var body: some View {
        let items = Array((block.items ?? []).filter { $0.high != nil }.prefix(60))
        let values = items.compactMap(\.high)
        let low = Swift.min(block.min ?? values.min() ?? 0, values.min() ?? 0)
        let high = Swift.max(block.max ?? values.max() ?? 1, values.max() ?? 1)
        CardBlockTitle(title: block.title) {
            Chart(Array(items.enumerated()), id: \.offset) { index, item in
                LineMark(x: .value("Point", index), y: .value("Value", item.high ?? 0))
                    .foregroundStyle(CardChartPalette.colors[0])
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Point", index), y: .value("Value", item.high ?? 0))
                    .foregroundStyle(CardChartPalette.colors[0])
                    .symbolSize(18)
                    .accessibilityLabel(item.label ?? "")
                    .accessibilityValue(item.highText ?? "")
            }
            .chartYScale(domain: low...(high > low ? high : low + 1))
            .chartXAxis {
                AxisMarks(values: Self.labelled(items.count)) { value in
                    AxisValueLabel {
                        if let index = value.as(Int.self), items.indices.contains(index) {
                            Text(items[index].label ?? "").foregroundStyle(.white.opacity(0.62))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.1))
                    AxisValueLabel().foregroundStyle(.white.opacity(0.62))
                }
            }
            .frame(height: 140)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .accessibilityLabel(block.title ?? block.accessibilityLabel ?? "Line chart")
    }

    /// The first, middle and last points carry labels.
    static func labelled(_ count: Int) -> [Int] {
        count <= 3 ? Array(0..<count) : [0, (count - 1) / 2, count - 1]
    }
}

/// A donut with a legend: each slice's label, value and share.
struct CardPieChartView: View {
    let block: CardDocument.Block

    var body: some View {
        let items = Array((block.items ?? []).filter { ($0.high ?? 0) > 0 }.prefix(8))
        let total = items.reduce(0) { $0 + ($1.high ?? 0) }
        CardBlockTitle(title: block.title) {
            HStack(alignment: .center, spacing: 16) {
                Chart(Array(items.enumerated()), id: \.offset) { index, item in
                    SectorMark(angle: .value("Value", item.high ?? 0), innerRadius: .ratio(0.62), angularInset: 1)
                        .foregroundStyle(CardChartPalette.color(item, index: index))
                }
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        let percent = total > 0 ? Int(((item.high ?? 0) / total * 100).rounded()) : 0
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(CardChartPalette.color(item, index: index)).frame(width: 10, height: 10)
                            Text(item.label ?? "").lineLimit(1)
                            Spacer(minLength: 6)
                            Text(item.highText ?? "").monospacedDigit()
                            Text("\(percent)%").monospacedDigit().foregroundStyle(.white.opacity(0.62)).frame(width: 40, alignment: .trailing)
                        }
                        .font(.system(size: 13))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.accessibilityLabel ?? "\(item.label ?? ""), \(item.highText ?? ""), \(percent) percent")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.title ?? block.accessibilityLabel ?? "Pie chart")
    }
}
