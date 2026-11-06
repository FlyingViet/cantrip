import AppKit
import MapKit
import SwiftUI

// MARK: - Cards under a reply (docs/cards.md)

/// Every card under a reply, drawn from its blocks: one view per block, nothing per card type,
/// the same blocks paired clients draw. Link cards reuse the link preview card (its image comes
/// from the Mac's preview cache).
struct CardDocumentStack: View {
    let cards: [CardDocument]
    let links: [LinkPreviewCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cards) { card in
                if card.style == "link" {
                    if let link = links.first(where: { $0.id == card.id }) {
                        LinkPreviewCardView(card: link)
                    }
                } else {
                    CardPanelView(card: card)
                }
            }
        }
    }
}

enum CardLook {
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let panelTop = Color(red: 0.13, green: 0.19, blue: 0.29)
    static let accent = Color(red: 0.55, green: 0.79, blue: 1.0)

    /// Tones keep at least 4.5:1 contrast on the dark panel.
    static func tone(_ tone: String?) -> Color {
        switch tone {
        case "positive": Color(red: 0.20, green: 0.83, blue: 0.60)
        case "negative": Color(red: 0.97, green: 0.44, blue: 0.44)
        case "warning": Color(red: 0.96, green: 0.72, blue: 0.25)
        case "accent": accent
        default: Color.white.opacity(0.75)
        }
    }

    static func symbolExists(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    static func actionSymbol(_ kind: String) -> String {
        switch kind {
        case "directions": "arrow.triangle.turn.up.right.circle"
        case "call": "phone"
        case "website": "safari"
        default: "arrow.up.right"
        }
    }

    /// Opens public web pages and phone numbers; anything else is ignored.
    static func open(_ raw: String?) {
        guard let raw, let action = CardValidation.safe(.init(kind: "open", label: "", url: raw)),
              let url = URL(string: action.url) else { return }
        NSWorkspace.shared.open(url)
    }

    static func canOpen(_ raw: String?) -> Bool {
        raw.flatMap { CardValidation.safe(.init(kind: "open", label: "", url: $0)) } != nil
    }
}

/// An SF Symbol the card names, else its emoji glyph, else nothing. Multicolor for forecast-style
/// icons (sun, rain); otherwise tinted like the text around it.
struct CardIcon: View {
    let symbol: String?
    var glyph: String? = nil
    var size: CGFloat
    var multicolor = false

    var body: some View {
        if let symbol, CardLook.symbolExists(symbol) {
            Image(systemName: symbol)
                .symbolRenderingMode(multicolor ? .multicolor : .monochrome)
                .font(.system(size: size))
        } else if let glyph, !glyph.isEmpty {
            Text(glyph).font(.system(size: size * 0.9))
        }
    }
}

/// A panel card: dark, up to 680 pt, 16 pt corners; its blocks stacked inside and the source's
/// update time and attribution at the bottom.
struct CardPanelView: View {
    let card: CardDocument

    enum Section {
        case block(CardDocument.Block)
        case map(CardDocument.Block, legend: CardDocument.Block?)

        /// Content blocks sit under a hairline; headers, stats, badges and notices run on.
        var hasDivider: Bool {
            switch self {
            case .map: true
            case .block(let block): ["strip", "chart", "list", "keyValue"].contains(block.type)
            }
        }
    }

    static func sections(_ blocks: [CardDocument.Block]) -> [Section] {
        var sections: [Section] = []
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            index += 1
            if block.type == "map" {
                let next = index < blocks.count ? blocks[index] : nil
                let legend = next?.type == "list" && next?.mapLinked == true ? next : nil
                if legend != nil { index += 1 }
                if !(block.pins ?? []).isEmpty { sections.append(.map(block, legend: legend)) }
            } else if draws(block) {
                sections.append(.block(block))
            }
        }
        return sections
    }

    static func draws(_ block: CardDocument.Block) -> Bool {
        switch block.type {
        case "header": block.title != nil || block.stat != nil
        case "stat": block.value != nil
        case "keyValue": !(block.rows ?? []).isEmpty
        case "strip", "chart", "list": !(block.items ?? []).isEmpty
        case "badges": !(block.badges ?? []).isEmpty
        case "notice": block.title != nil || block.text != nil
        case "progress": block.label != nil || block.startedAt != nil
        default: false
        }
    }

    var body: some View {
        let sections = Self.sections(card.blocks)
        let hasMap = card.blocks.contains { $0.type == "map" }
        VStack(alignment: .leading, spacing: 0) {
            if sections.isEmpty {
                Text(card.fallbackText ?? card.plainText)
                    .font(.system(size: 12.5))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0, section.hasDivider { divider }
                switch section {
                case .map(let map, let legend):
                    CardMapView(block: map, legend: legend)
                case .block(let block):
                    CardBlockView(block: block, isFirst: index == 0)
                }
            }
            footer
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 680, alignment: .leading)
        .background(hasMap ? AnyShapeStyle(CardLook.panel)
                           : AnyShapeStyle(LinearGradient(colors: [CardLook.panelTop, CardLook.panel],
                                                          startPoint: .top, endPoint: .bottom)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.accessibilityLabel ?? card.blocks.first { $0.type == "header" }?.title ?? "Card")
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
    }

    @ViewBuilder private var footer: some View {
        let updated = card.source?.updatedAt
        let attribution = card.source?.attribution
        if updated != nil || attribution != nil {
            divider
            HStack(spacing: 6) {
                if let updated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                }
                Spacer(minLength: 6)
                if let attribution {
                    if CardLook.canOpen(card.source?.url) {
                        Button { CardLook.open(card.source?.url) } label: { Text(attribution).underline() }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(.isLink)
                    } else {
                        Text(attribution)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Blocks

struct CardBlockView: View {
    let block: CardDocument.Block
    let isFirst: Bool

    var body: some View {
        switch block.type {
        case "header": header
        case "stat": stat
        case "keyValue": keyValue
        case "strip": strip
        case "chart": chart
        case "list": list
        case "badges":
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array((block.badges ?? []).enumerated()), id: \.offset) { _, badge in CardBadgeView(badge: badge) }
            }
            .padding(.horizontal, 14)
            .padding(.top, isFirst ? 14 : 4)
            .padding(.bottom, 12)
        case "notice": notice
        case "progress": CardProgressView(block: block, isFirst: isFirst)
        default: EmptyView()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if CardLook.symbolExists(block.symbol), let symbol = block.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(block.tone.map(CardLook.tone) ?? CardLook.accent)
                    .frame(width: 22)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let title = block.title {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                }
                if let subtitle = block.subtitle {
                    Group {
                        if CardLook.symbolExists(block.subtitleSymbol), let symbol = block.subtitleSymbol {
                            Label(subtitle, systemImage: symbol).labelStyle(.titleAndIcon)
                        } else {
                            Text(subtitle)
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.75))
                }
                ForEach(Array((block.lines ?? []).enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: index == 0 ? 13 : 12))
                        .foregroundStyle(.white.opacity(index == 0 ? 0.88 : 0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let stat = block.stat {
                HStack(spacing: 6) {
                    CardIcon(symbol: stat.symbol, size: 28, multicolor: true)
                    Text(stat.value)
                        .font(.system(size: 40, weight: .light))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stat.accessibilityLabel ?? stat.value)
            }
        }
        .padding(14)
    }

    private var stat: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label = block.label {
                Text(label.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.62))
            }
            HStack(spacing: 8) {
                CardIcon(symbol: block.symbol, size: 22)
                    .foregroundStyle(CardLook.accent)
                Text(block.value ?? "")
                    .font(.system(size: 30))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if let detail = block.detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, isFirst ? 14 : 0)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(block.accessibilityLabel ?? [block.label, block.value, block.detail].compactMap { $0 }.joined(separator: ", "))
    }

    private var keyValue: some View {
        let rows = block.rows ?? []
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.key).foregroundStyle(.white.opacity(0.78))
                    Spacer(minLength: 8)
                    Text(row.value).fontWeight(.semibold).multilineTextAlignment(.trailing)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.key): \(row.value)")
                if index < rows.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 14)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 4) {
                        Text(item.label ?? "")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                        CardIcon(symbol: item.symbol, glyph: item.glyph, size: 18, multicolor: true)
                            .frame(height: 22)
                        Text(item.note ?? " ")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CardLook.tone(item.tone ?? "accent"))
                        Text(item.value ?? "")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                    }
                    .frame(width: 52)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityLabel ?? [item.label, item.value, item.note].compactMap { $0 }.joined(separator: ", "))
                }
            }
            .padding(10)
        }
        .accessibilityLabel(block.accessibilityLabel ?? "")
    }

    private var chart: some View {
        let items = block.items ?? []
        let lowest = block.min ?? items.compactMap { $0.low ?? $0.high }.min() ?? 0
        let span = Swift.max(1e-9, (block.max ?? items.compactMap { $0.high ?? $0.low }.max() ?? 1) - lowest)
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let low = item.low ?? lowest
                let high = item.high ?? low
                let start = Swift.min(1, Swift.max(0, (low - lowest) / span))
                HStack(spacing: 8) {
                    Text(item.label ?? "")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .frame(width: 50, alignment: .leading)
                    CardIcon(symbol: item.symbol, glyph: item.glyph, size: 16, multicolor: true)
                        .frame(width: 26)
                    Text(item.note ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CardLook.tone(item.tone ?? "accent"))
                        .frame(width: 36, alignment: .leading)
                    Text(item.lowText ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                    WeatherRangeBar(range: start...Swift.min(1, Swift.max(start, (high - lowest) / span)))
                        .frame(height: 5)
                    Text(item.highText ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.accessibilityLabel ?? [item.label, item.lowText, item.highText].compactMap { $0 }.joined(separator: ", "))
                if index < items.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 14)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.accessibilityLabel ?? "")
    }

    private var list: some View {
        let items = block.items ?? []
        return VStack(alignment: .leading, spacing: 0) {
            if let title = block.title {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .accessibilityAddTraits(.isHeader)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                CardItemRow(item: item, compact: false)
                if index < items.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 14)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var notice: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                CardIcon(symbol: block.symbol, size: 14)
                    .foregroundStyle(CardLook.tone(block.tone))
                    .accessibilityHidden(true)
                Text(block.title ?? "").font(.system(size: 13.5, weight: .semibold))
            }
            if let text = block.text {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, isFirst ? 14 : -6)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }
}

/// What a `progress` block shows at a moment: its elapsed time, bar and time left are worked
/// out here from the block's times, so only the block redraws as they change.
struct CardProgress: Equatable {
    var label: String
    var tone: String?
    var isRunning: Bool
    /// "1:23"; nil when the block has no times to count from.
    var elapsed: String?
    var elapsedSeconds: TimeInterval?
    /// 0–1, or nil for an indeterminate bar while running (no step counter or estimate).
    var fraction: Double?
    var showsBar: Bool
    var detail: String?
    /// "About 1:20 left" or "Longer than usual".
    var remaining: String?

    init(block: CardDocument.Block, now: Date) {
        let started = Self.date(block.startedAt)
        let finished = Self.date(block.finishedAt)
        isRunning = block.status == "running" && finished == nil
        label = block.label ?? (isRunning ? "Running" : "Done")
        tone = block.tone
        detail = block.detail
        let end = isRunning ? now : finished
        if let started, let end {
            let seconds = max(0, end.timeIntervalSince(started))
            elapsedSeconds = seconds
            elapsed = Self.clock(seconds)
        }
        let expected = block.expectedSeconds.flatMap { $0 > 0 ? $0 : nil }
        if isRunning {
            showsBar = true
            if let step = block.fraction {
                fraction = min(1, max(0, step))
            } else if let expected, let seconds = elapsedSeconds, seconds < expected {
                fraction = seconds / expected
            }
            if let expected, let seconds = elapsedSeconds {
                remaining = seconds < expected ? "About \(Self.clock(expected - seconds)) left" : "Longer than usual"
            }
        } else {
            showsBar = block.status != "ended" && finished != nil
            fraction = 1
        }
    }

    /// "0:42", "3:05", "1:02:09".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func spoken(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds.rounded(.down)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    private static let fractional = BuildRun.isoFormatter
    private static let whole = ISO8601DateFormatter()

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return fractional.date(from: text) ?? whole.date(from: text)
    }

    var accessibilityLabel: String {
        var parts = [label]
        if let elapsedSeconds { parts.append((isRunning ? "running for " : "took ") + Self.spoken(elapsedSeconds)) }
        if let remaining { parts.append(remaining) }
        if let detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

/// A `progress` block: label and elapsed time, a bar, then where the estimate comes from. While
/// it runs a once-a-second timeline redraws just this block; the transcript around it doesn't.
struct CardProgressView: View {
    let block: CardDocument.Block
    let isFirst: Bool

    var body: some View {
        if block.status == "running", block.finishedAt == nil, let started = CardProgress.date(block.startedAt) {
            TimelineView(.periodic(from: started, by: 1)) { context in
                content(CardProgress(block: block, now: context.date))
            }
        } else {
            content(CardProgress(block: block, now: Date()))
        }
    }

    private func content(_ progress: CardProgress) -> some View {
        let color = progress.isRunning ? CardLook.accent : CardLook.tone(progress.tone)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(progress.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Spacer(minLength: 8)
                if let elapsed = progress.elapsed {
                    Text(elapsed)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                }
            }
            if progress.showsBar {
                CardProgressBar(fraction: progress.fraction, color: color)
                    .frame(height: 5)
            }
            if progress.detail != nil || progress.remaining != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let detail = progress.detail {
                        Text(detail).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let remaining = progress.remaining {
                        Text(remaining).monospacedDigit()
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.78))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, isFirst ? 14 : 0)
        .padding(.bottom, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.accessibilityLabel)
    }
}

/// A thin bar: filled to `fraction`, or, when there's no fraction, a segment that sweeps in
/// from the left edge and out the right, over and over (a still, dim bar under Reduce Motion).
/// The sweep's place comes from the clock rather than a running animation: a repeating animation
/// started on appear also replayed the bar's position from before the card's layout settled, so
/// its segment floated off the track. The track clips the segment as well.
struct CardProgressBar: View {
    let fraction: Double?
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One pass, and the segment's share of the track (web and Windows: `.cd-progress-bar` CSS).
    static let sweepSeconds: TimeInterval = 1.6
    static let sweepWidth = 0.35

    /// The segment's leading edge at `date`, as a share of the track: from −`sweepWidth`
    /// (hidden past the left end) to 1 (gone past the right), easing in and out.
    static func sweepOffset(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: sweepSeconds) / sweepSeconds
        let eased = phase < 0.5 ? 2 * phase * phase : 1 - 2 * (1 - phase) * (1 - phase)
        return -sweepWidth + eased * (1 + sweepWidth)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                if let fraction {
                    Capsule().fill(color).frame(width: max(5, proxy.size.width * fraction))
                } else if reduceMotion {
                    Capsule().fill(color.opacity(0.35))
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                        Capsule().fill(color)
                            .frame(width: proxy.size.width * Self.sweepWidth)
                            .offset(x: proxy.size.width * Self.sweepOffset(at: context.date))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }
}

struct CardBadgeView: View {
    let badge: CardDocument.Badge

    var body: some View {
        let color = CardLook.tone(badge.tone)
        HStack(spacing: 3) {
            if CardLook.symbolExists(badge.symbol), let symbol = badge.symbol {
                Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
            }
            Text(badge.text)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(badge.tone == nil || badge.tone == "neutral" ? Color.white.opacity(0.1) : color.opacity(0.16)))
        .fixedSize()
    }
}

/// One entry of a list: title and trailing value, a subtitle with badges, details, a note, and
/// buttons for its actions. In a map's legend (`compact`) it selects its pin.
struct CardItemRow: View {
    let item: CardDocument.Item
    let compact: Bool
    var isSelected = false
    var onFocus: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let onFocus {
                Button(action: onFocus) { info.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows it on the map")
            } else {
                info
            }
            let actions = (item.actions ?? []).filter { CardLook.canOpen($0.url) }
            if !actions.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        Button { CardLook.open(action.url) } label: {
                            Label(action.label, systemImage: CardLook.actionSymbol(action.kind))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                                .contentShape(Capsule())
                                .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .help(action.url)
                        .accessibilityLabel("\(action.label), \(item.title ?? item.label ?? "")")
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, compact ? 11 : 14)
        .padding(.vertical, compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if !compact {
                    CardIcon(symbol: item.symbol, glyph: item.glyph, size: 14)
                        .foregroundStyle(CardLook.accent)
                }
                Text(item.title ?? item.label ?? "")
                    .font(.system(size: compact ? 13 : 13.5, weight: .semibold))
                    .lineLimit(compact ? 1 : 2)
                Spacer(minLength: 6)
                if let trailing = item.trailing {
                    Text(trailing)
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                }
            }
            if item.subtitle != nil || !(item.badges ?? []).isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 4) {
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    ForEach(Array((item.badges ?? []).enumerated()), id: \.offset) { _, badge in CardBadgeView(badge: badge) }
                }
            }
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: compact ? 10.5 : 11.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(compact ? 1 : 2)
            }
            if let note = item.note {
                Text(note)
                    .font(.system(size: compact ? 10.5 : 11))
                    .foregroundStyle(item.tone == nil ? Color.white.opacity(0.6) : CardLook.tone(item.tone))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel ?? [item.title, item.subtitle, item.detail, item.trailing].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - Map block

/// A map block with its legend (a list whose items name the pins): MapKit with labelled pins,
/// the legend floating beside the pins on wide cards and under the map on narrow ones.
struct CardMapView: View {
    let pins: [CardDocument.Pin]
    let items: [CardDocument.Item]
    let legendTitle: String?
    let attribution: String
    @State private var position: MapCameraPosition
    @State private var currentRegion: MKCoordinateRegion
    @State private var selectedPinID: String?
    @State private var cardWidth: CGFloat = 0
    @State private var mapSize: CGSize = .zero

    /// Below this width the legend moves under the map, so the map keeps about 200 pt for pins.
    static let stackedBelowWidth: CGFloat = 600
    static let listWidth: CGFloat = 248
    static let pinLabelMaxWidth: CGFloat = 150

    init(block: CardDocument.Block, legend: CardDocument.Block?) {
        let pins = (block.pins ?? []).filter { abs($0.latitude) <= 90 && abs($0.longitude) <= 180 }
        self.pins = pins
        items = legend?.items ?? []
        legendTitle = legend?.title
        attribution = block.attribution ?? "© OpenStreetMap · Apple Maps"
        let lats = pins.map(\.latitude), lons = pins.map(\.longitude)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: block.latitude ?? ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
                                           longitude: block.longitude ?? ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(block.latitudeDelta ?? 0, 0.01), longitudeDelta: max(block.longitudeDelta ?? 0, 0.01)))
        _currentRegion = State(initialValue: region)
        _position = State(initialValue: .region(region))
        _selectedPinID = State(initialValue: pins.first?.id)
    }

    private var stacked: Bool { items.isEmpty || (cardWidth > 0 && cardWidth < Self.stackedBelowWidth) }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        mapSurface
                        zoomButtons.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10)
                        attributionPill.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(8)
                    }
                    .frame(height: items.isEmpty ? 260 : 220)
                    .clipped()
                    if !items.isEmpty {
                        Divider().overlay(Color.white.opacity(0.12))
                        legend
                    }
                }
            } else {
                ZStack(alignment: .topLeading) {
                    mapSurface
                    // The floating legend (top-left) scrolls when it's taller than the map.
                    ViewThatFits(in: .vertical) {
                        legend
                        ScrollView { legend }
                    }
                    .frame(width: Self.listWidth)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CardLook.panel.opacity(0.94)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(12)
                    zoomButtons.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(12)
                    attributionPill.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(10)
                }
                .frame(height: 310)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attribution)
    }

    private func coordinate(_ pin: CardDocument.Pin) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
    }

    /// Nudges that keep pins whose capsules would overlap (close places) readable.
    private var pinOffsets: [String: CGSize] {
        guard mapSize != .zero else { return [:] }
        let points = PlaceMapFit.screenPoints(pins.map(coordinate), region: currentRegion, size: mapSize)
        let offsets = PlaceMapFit.labelOffsets(points: points, widths: pins.map { PlaceMapFit.pinWidth($0.title) },
                                               bounds: CGRect(origin: .zero, size: mapSize))
        return Dictionary(zip(pins.map(\.id), offsets), uniquingKeysWith: { first, _ in first })
    }

    private var mapSurface: some View {
        let offsets = pinOffsets
        return Map(position: $position) {
            ForEach(pins, id: \.id) { pin in
                Annotation(pin.title, coordinate: coordinate(pin), anchor: .bottom) {
                    Button {
                        selectedPinID = pin.id
                        CardLook.open(directionsURL(for: pin))
                    } label: {
                        HStack(spacing: 5) {
                            Group {
                                if CardLook.symbolExists(pin.symbol), let symbol = pin.symbol {
                                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                                } else {
                                    Text(pin.glyph ?? "📍").font(.system(size: 9))
                                }
                            }
                            .foregroundStyle(.white)
                            .frame(width: 10, height: 10)
                            .padding(5)
                            .background(Color(red: 0.90, green: 0.35, blue: 0.35), in: Circle())
                            Text(pin.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(maxWidth: Self.pinLabelMaxWidth)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.leading, 3)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(selectedPinID == pin.id ? 0.88 : 0.72)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(selectedPinID == pin.id ? 0.55 : 0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(pin.title)
                    .accessibilityLabel("Pin for \(pin.title)")
                    .offset(offsets[pin.id] ?? .zero)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .environment(\.colorScheme, .dark)
        .onMapCameraChange { context in
            currentRegion = context.region
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            mapSize = size
            fit(pins)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let legendTitle {
                Text(legendTitle.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .accessibilityAddTraits(.isHeader)
                Divider().overlay(Color.white.opacity(0.1))
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Divider().overlay(Color.white.opacity(0.1))
                }
                let pin = pins.first { $0.id == (item.pinID ?? item.id) }
                let onFocus: (() -> Void)? = pin.map { pin in { focus(on: pin) } }
                CardItemRow(item: item, compact: true, isSelected: pin != nil && selectedPinID == pin?.id, onFocus: onFocus)
            }
        }
    }

    private var zoomButtons: some View {
        VStack(spacing: 1) {
            Button { zoom(by: 0.5) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom in")
            Divider().frame(width: 22).overlay(Color.white.opacity(0.16))
            Button { zoom(by: 2.0) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom out")
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CardLook.panel.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }

    private var attributionPill: some View {
        Text(attribution)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.65)))
    }

    /// The map area pins may use: right of the floating legend, below the map's top edge by a
    /// pin's height (pins hang above their coordinate), and clear of the attribution.
    private var pinInsets: PlaceMapFit.Insets {
        // Half the widest pin label, as an annotation is centred on its coordinate.
        let longest = pins.map(\.title.count).max() ?? 0
        let halfPin = (min(Double(longest) * 6.4, Double(Self.pinLabelMaxWidth)) + 36) / 2
        let left = stacked ? 10 : 12 + Double(Self.listWidth) + 8
        return PlaceMapFit.Insets(top: 12 + 28, left: left + halfPin, bottom: 12 + 22, right: 12 + halfPin)
    }

    /// Shows `pins` in the uncovered map area; a single pin keeps a street-level zoom.
    private func fit(_ pins: [CardDocument.Pin], minimumMeters: Double = 2_000) {
        guard let rect = PlaceMapFit.rect(for: pins.map(coordinate), size: mapSize,
                                          insets: pinInsets, minimumMeters: minimumMeters) else { return }
        position = .rect(rect)
    }

    private func focus(on pin: CardDocument.Pin) {
        selectedPinID = pin.id
        guard mapSize != .zero else { return }
        fit([pin], minimumMeters: 3_000)
    }

    private func zoom(by factor: Double) {
        let latDelta = min(max(currentRegion.span.latitudeDelta * factor, 0.002), 60)
        let lonDelta = min(max(currentRegion.span.longitudeDelta * factor, 0.002), 60)
        let next = MKCoordinateRegion(center: currentRegion.center, span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
        currentRegion = next
        position = .region(next)
    }

    /// A pin opens its place's directions, as the place card always has.
    private func directionsURL(for pin: CardDocument.Pin) -> String? {
        let item = items.first { ($0.pinID ?? $0.id) == pin.id }
        return item?.actions?.first { $0.kind == "directions" }?.url
    }
}
