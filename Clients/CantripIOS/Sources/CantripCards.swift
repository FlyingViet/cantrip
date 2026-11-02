import Foundation
import MapKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Card model

/// A card under a reply (`cards` on a Cantrip message; docs/cards.md in the Cantrip repo): a few
/// building blocks the Mac filled from a resolver or a checked tool result. Each block is drawn
/// once below, so a new kind of card needs no app code. Decoding never fails the message:
/// malformed fields read as absent and unknown blocks are skipped.
struct CantripCard: Codable, Equatable, Identifiable, Sendable {
    struct Action: Codable, Equatable, Sendable {
        var kind: String?
        var label: String?
        var url: String?
    }

    struct Source: Codable, Equatable, Sendable {
        var kind: String?
        var name: String?
        var attribution: String?
        var url: String?
        var updatedAt: String?
    }

    struct Badge: Codable, Equatable, Sendable {
        var text: String?
        var tone: String?
        var symbol: String?
    }

    struct Stat: Codable, Equatable, Sendable {
        var value: String?
        var label: String?
        var symbol: String?
        var detail: String?
        var accessibilityLabel: String?
    }

    struct Row: Codable, Equatable, Sendable {
        var key: String?
        var value: String?
        var symbol: String?
    }

    /// An entry in a strip, chart or list; each block uses the fields it needs.
    struct Item: Codable, Equatable, Sendable {
        var id: String?
        var label: String?
        var title: String?
        var subtitle: String?
        var detail: String?
        var symbol: String?
        var glyph: String?
        var value: String?
        var note: String?
        var tone: String?
        var low: Double?
        var high: Double?
        var lowText: String?
        var highText: String?
        var trailing: String?
        var pinID: String?
        var badges: [Badge]?
        var actions: [Action]?
        var accessibilityLabel: String?
    }

    struct Pin: Codable, Equatable, Sendable {
        var id: String?
        var title: String?
        var latitude: Double?
        var longitude: Double?
        var glyph: String?
        var symbol: String?
    }

    struct Block: Codable, Equatable, Sendable {
        var type: String
        var title: String?
        var subtitle: String?
        var subtitleSymbol: String?
        var symbol: String?
        var lines: [String]?
        var stat: Stat?
        var value: String?
        var label: String?
        var detail: String?
        var text: String?
        var tone: String?
        var kind: String?
        var rows: [Row]?
        var items: [Item]?
        var badges: [Badge]?
        var min: Double?
        var max: Double?
        var pins: [Pin]?
        var latitude: Double?
        var longitude: Double?
        var latitudeDelta: Double?
        var longitudeDelta: Double?
        var mapLinked: Bool?
        var attribution: String?
        var imageID: String?
        var accessibilityLabel: String?

        init(type: String) { self.type = type }

        private enum Keys: String, CodingKey {
            case type, title, subtitle, subtitleSymbol, symbol, lines, stat, value, label, detail, text, tone, kind, rows, items
            case badges, min, max, pins, latitude, longitude, latitudeDelta, longitudeDelta, mapLinked, attribution, imageID
            case accessibilityLabel
        }

        init(from decoder: Decoder) throws {
            type = ""
            guard let c = try? decoder.container(keyedBy: Keys.self) else { return }
            func text(_ key: Keys) -> String? {
                (try? c.decodeIfPresent(String.self, forKey: key))?.flatMap { $0.isEmpty ? nil : String($0.prefix(400)) }
            }
            func number(_ key: Keys) -> Double? { (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil }
            func list<T: Decodable>(_ key: Keys, max: Int = 24) -> [T]? {
                guard let values = (try? c.decodeIfPresent([CantripLossy<T>].self, forKey: key)) ?? nil else { return nil }
                return Array(values.compactMap(\.value).prefix(max))
            }
            type = text(.type) ?? ""
            title = text(.title)
            subtitle = text(.subtitle)
            subtitleSymbol = text(.subtitleSymbol)
            symbol = text(.symbol)
            lines = list(.lines, max: 4)
            stat = (try? c.decodeIfPresent(Stat.self, forKey: .stat)) ?? nil
            value = text(.value)
            label = text(.label)
            detail = text(.detail)
            self.text = text(.text)
            tone = text(.tone)
            kind = text(.kind)
            rows = list(.rows, max: 20)
            items = list(.items)
            badges = list(.badges, max: 8)
            min = number(.min)
            max = number(.max)
            pins = list(.pins)
            latitude = number(.latitude)
            longitude = number(.longitude)
            latitudeDelta = number(.latitudeDelta)
            longitudeDelta = number(.longitudeDelta)
            mapLinked = (try? c.decodeIfPresent(Bool.self, forKey: .mapLinked)) ?? nil
            attribution = text(.attribution)
            imageID = text(.imageID)
            accessibilityLabel = text(.accessibilityLabel)
        }
    }

    var id: String
    var type: String?
    var style: String?
    var accessibilityLabel: String?
    var action: Action?
    var source: Source?
    var fallbackText: String?
    var blocks: [Block]

    init(id: String, type: String?, style: String? = nil, accessibilityLabel: String?, action: Action? = nil,
         source: Source? = nil, fallbackText: String? = nil, blocks: [Block]) {
        self.id = id
        self.type = type
        self.style = style
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.source = source
        self.fallbackText = fallbackText
        self.blocks = blocks
    }

    private enum Keys: String, CodingKey {
        case id, type, style, accessibilityLabel, action, source, fallbackText, blocks
    }

    init(from decoder: Decoder) throws {
        id = UUID().uuidString
        blocks = []
        guard let c = try? decoder.container(keyedBy: Keys.self) else { return }
        func text(_ key: Keys) -> String? {
            (try? c.decodeIfPresent(String.self, forKey: key))?.flatMap { $0.isEmpty ? nil : $0 }
        }
        id = text(.id) ?? id
        type = text(.type)
        style = text(.style)
        accessibilityLabel = text(.accessibilityLabel)
        action = (try? c.decodeIfPresent(Action.self, forKey: .action)) ?? nil
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? nil
        fallbackText = text(.fallbackText).map { String($0.prefix(4_000)) }
        let decoded = (try? c.decodeIfPresent([CantripLossy<Block>].self, forKey: .blocks)) ?? nil
        blocks = Array((decoded ?? []).compactMap(\.value).filter { !$0.type.isEmpty }.prefix(12))
    }

    var isLink: Bool { style == "link" }

    var header: Block? { blocks.first { $0.type == "header" } }

    var spokenLabel: String { accessibilityLabel ?? header?.title ?? "Card" }

    /// A link card as the link preview the app already draws: the whole card opens `action.url`.
    var linkPreview: CantripLinkPreview? {
        guard isLink, let raw = action?.url, let url = URL(string: raw), CantripLinkPreview.isSafeWebURL(url) else { return nil }
        let domain = header?.subtitle ?? url.host ?? raw
        let imageID = blocks.first { $0.type == "image" }?.imageID.flatMap { CantripLinkPreview.validImageID($0) ? $0 : nil }
        return CantripLinkPreview(id: id, url: raw, title: header?.title ?? domain, domain: domain, imageID: imageID)
    }

    /// The cards to draw for a reply: `cards` from a current Mac, else ones built from the separate
    /// weather, place and link fields an older Mac (or older saved history) carries.
    static func forReply(cards: [CantripCard]?, weather: CantripWeatherCard?, places: CantripPlaceCard?,
                         links: [CantripLinkPreview]?) -> [CantripCard] {
        if let cards { return cards }
        var result: [CantripCard] = []
        if let weather { result.append(CantripCard(legacyWeather: weather)) }
        if let places, !places.places.isEmpty { result.append(CantripCard(legacyPlaces: places)) }
        result += (links ?? []).map(CantripCard.init(legacyLink:))
        return result
    }
}

/// Decodes one element of a list without failing the rest.
struct CantripLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Older Macs' cards as blocks (the same blocks the Mac builds now)

extension CantripCard {
    init(legacyWeather card: CantripWeatherCard) {
        var header = Block(type: "header")
        header.title = card.place
        header.subtitle = card.placeNote
        header.subtitleSymbol = card.placeNote == nil ? nil : "location.fill"
        let updated = card.isAvailable ? card.updatedAt.map { ISO8601DateFormatter().string(from: $0) } : nil
        let source = Source(kind: "resolver", name: "Open-Meteo", attribution: card.attribution,
                            url: card.attributionURL.absoluteString, updatedAt: updated)
        guard card.isAvailable, let current = card.current else {
            var notice = Block(type: "notice")
            notice.symbol = "exclamationmark.icloud"
            notice.title = "Forecast unavailable"
            notice.text = card.message ?? "Ask again in a moment."
            notice.tone = "warning"
            self.init(id: "weather-" + card.place.lowercased(), type: "weather", accessibilityLabel: "Weather for \(card.place)",
                      source: source, blocks: [header, notice])
            return
        }
        let unitName = CantripWeatherCard.unitName(card.unit)
        header.lines = [current.condition] + (card.detailLine.isEmpty ? [] : [card.detailLine])
        header.stat = Stat(value: "\(current.temperature)°", symbol: current.symbol,
                           accessibilityLabel: "Now \(current.temperature) \(unitName), \(current.condition)")
        var strip = Block(type: "strip")
        strip.accessibilityLabel = "Hourly forecast"
        strip.items = card.hourly.map { hour in
            Item(label: hour.label, symbol: hour.symbol, value: "\(hour.temperature)°",
                 note: CantripWeatherCard.chanceText(hour.precipitationChance), accessibilityLabel: card.spokenHour(hour))
        }
        var chart = Block(type: "chart")
        chart.kind = "range"
        chart.accessibilityLabel = "\(card.daily.count)-day forecast"
        chart.min = card.daily.map(\.low).min().map(Double.init)
        chart.max = card.daily.map(\.high).max().map(Double.init)
        chart.items = card.daily.map { day in
            Item(label: day.label, symbol: day.symbol, note: CantripWeatherCard.chanceText(day.precipitationChance),
                 low: Double(day.low), high: Double(day.high), lowText: "\(day.low)°", highText: "\(day.high)°",
                 accessibilityLabel: card.spokenDay(day))
        }
        self.init(id: "weather-" + card.place.lowercased(), type: "weather", accessibilityLabel: "Weather for \(card.place)",
                  source: source, blocks: [header, strip, chart])
    }

    init(legacyPlaces card: CantripPlaceCard) {
        var map = Block(type: "map")
        map.latitude = card.centerLatitude
        map.longitude = card.centerLongitude
        map.latitudeDelta = card.latitudeDelta
        map.longitudeDelta = card.longitudeDelta
        map.accessibilityLabel = "Map of " + (card.places.count == 1 ? card.places[0].name : "\(card.places.count) places")
        map.pins = card.places.map {
            Pin(id: $0.id, title: $0.name, latitude: $0.latitude, longitude: $0.longitude, symbol: $0.pinSymbol)
        }
        var list = Block(type: "list")
        list.mapLinked = true
        list.title = card.query.isEmpty ? nil : card.query
        list.items = card.places.map(Self.item(for:))
        self.init(id: "places-" + (card.places.first?.id ?? card.query), type: "places",
                  accessibilityLabel: card.query.isEmpty ? "Recommended places" : "Places for \(card.query)", blocks: [map, list])
    }

    private static func item(for place: CantripPlacePin) -> Item {
        let subtitle = [place.category, place.priceLevel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        var badges: [Badge] = []
        if let rating = place.rating {
            badges.append(Badge(text: String(format: "%.1f", rating) + (place.reviewCount.map { " (\($0))" } ?? ""),
                                tone: "warning", symbol: "star.fill"))
        }
        if let open = place.isOpenNow { badges.append(Badge(text: open ? "Open now" : "Closed", tone: open ? "positive" : "negative")) }
        var item = Item(id: place.id, title: place.name, subtitle: subtitle.isEmpty ? nil : subtitle, detail: place.address,
                        symbol: place.pinSymbol, pinID: place.id, badges: badges.isEmpty ? nil : badges)
        if place.approximate == true {
            item.note = "Approximate location"
            item.tone = "warning"
        } else if let listed = place.listedName, !listed.isEmpty {
            item.note = "Listed as \(listed)"
        } else if let hours = place.hoursSummary, !hours.isEmpty {
            item.note = hours
        }
        var actions = [Action(kind: "directions", label: "Directions", url: place.resolvedMapsURL?.absoluteString)]
        let digits = (place.phone ?? "").filter { "0123456789+".contains($0) }
        if !digits.isEmpty { actions.append(Action(kind: "call", label: "Call", url: "tel:" + digits)) }
        if let website = place.website, let url = URL(string: website), CantripLinkPreview.isSafeWebURL(url) {
            actions.append(Action(kind: "website", label: "Website", url: website))
        }
        item.actions = actions
        var spoken = [place.name] + [subtitle].filter { !$0.isEmpty }
        spoken += badges.compactMap { badge in badge.symbol == "star.fill" ? badge.text.map { "rated \($0)" } : badge.text }
        if let address = place.address { spoken.append(address) }
        item.accessibilityLabel = spoken.joined(separator: ", ")
        return item
    }

    init(legacyLink link: CantripLinkPreview) {
        var blocks: [Block] = []
        if let imageID = link.imageID, !imageID.isEmpty {
            var image = Block(type: "image")
            image.imageID = imageID
            blocks.append(image)
        }
        var header = Block(type: "header")
        header.title = link.title
        header.subtitle = link.domain
        blocks.append(header)
        self.init(id: link.id, type: "link", style: "link", accessibilityLabel: "\(link.title), \(link.domain)",
                  action: Action(kind: "open", label: "Open", url: link.url), blocks: blocks)
    }
}

// MARK: - Shared look

enum CantripCardStyle {
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

    static func symbolExists(_ name: String) -> Bool {
        #if os(macOS)
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        UIImage(systemName: name) != nil
        #endif
    }

    static func actionSymbol(_ kind: String?) -> String {
        switch kind {
        case "directions": "arrow.triangle.turn.up.right.circle"
        case "call": "phone"
        case "website": "safari"
        default: "arrow.up.right"
        }
    }

    /// https and http pages (not local or tailnet hosts) and phone numbers; nothing else opens.
    static func actionURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw) else { return nil }
        if url.scheme?.lowercased() == "tel" {
            let digits = raw.dropFirst(4)
            return !digits.isEmpty && digits.allSatisfy({ "0123456789+".contains($0) }) ? url : nil
        }
        return CantripLinkPreview.isSafeWebURL(url) ? url : nil
    }

    static func updatedText(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        return "Updated \(date.formatted(date: .omitted, time: .shortened))"
    }
}

/// An SF Symbol the card names, else its emoji glyph, else nothing. Multicolor for forecast-style
/// icons (sun, rain); otherwise tinted like the text around it.
struct CantripCardIcon: View {
    let symbol: String?
    var glyph: String? = nil
    var size: CGFloat
    var multicolor = false

    var body: some View {
        if let symbol, CantripCardStyle.symbolExists(symbol) {
            Image(systemName: symbol)
                .symbolRenderingMode(multicolor ? .multicolor : .monochrome)
                .font(.system(size: size))
        } else if let glyph, !glyph.isEmpty {
            Text(glyph).font(.system(size: size * 0.9))
        }
    }
}

// MARK: - Cards under a reply

struct CantripCardStack: View {
    let cards: [CantripCard]
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cards) { card in
                if card.isLink {
                    if let preview = card.linkPreview {
                        CantripLinkPreviewCardView(card: preview, remote: remote)
                    }
                } else {
                    CantripCardPanel(card: card, remote: remote)
                }
            }
        }
    }
}

/// A panel card: the map card's container (680 pt, 16 pt corners, dark panel) with its blocks
/// stacked inside, the source's update time and attribution at the bottom.
struct CantripCardPanel: View {
    let card: CantripCard
    @ObservedObject var remote: CantripRemoteModel
    @Environment(\.openURL) private var openURL

    enum Section {
        case block(CantripCard.Block)
        case map(CantripCard.Block, legend: CantripCard.Block?)

        /// Content blocks sit under a hairline; headers, stats, badges and notices run on.
        var hasDivider: Bool {
            switch self {
            case .map: true
            case .block(let block): ["strip", "chart", "list", "keyValue"].contains(block.type)
            }
        }
    }

    static func sections(_ blocks: [CantripCard.Block]) -> [Section] {
        var sections: [Section] = []
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            index += 1
            if block.type == "map" {
                let next = index < blocks.count ? blocks[index] : nil
                let legend = next?.type == "list" && next?.mapLinked == true ? next : nil
                if legend != nil { index += 1 }
                if !CantripCardMapView.pins(block).isEmpty { sections.append(.map(block, legend: legend)) }
            } else if draws(block) {
                sections.append(.block(block))
            }
        }
        return sections
    }

    static func draws(_ block: CantripCard.Block) -> Bool {
        switch block.type {
        case "header": block.title != nil || block.stat?.value != nil
        case "stat": block.value != nil
        case "keyValue": !(block.rows ?? []).filter { $0.key != nil || $0.value != nil }.isEmpty
        case "strip", "chart", "list": !(block.items ?? []).isEmpty
        case "badges": !(block.badges ?? []).filter { $0.text != nil }.isEmpty
        case "notice": block.title != nil || block.text != nil
        case "image": block.imageID.map(CantripLinkPreview.validImageID) ?? false
        default: false
        }
    }

    private var hasMap: Bool { card.blocks.contains { $0.type == "map" } }

    private var identifier: String {
        switch card.type {
        case "weather": "chat.weatherCard"
        case "places": "chat.placeCard"
        default: "chat.card.\(card.type ?? "custom")"
        }
    }

    var body: some View {
        let sections = Self.sections(card.blocks)
        VStack(alignment: .leading, spacing: 0) {
            if sections.isEmpty {
                Text(card.fallbackText ?? card.spokenLabel)
                    .font(.footnote)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0, section.hasDivider { divider }
                switch section {
                case .map(let map, let legend):
                    CantripCardMapView(block: map, legend: legend)
                case .block(let block):
                    CantripCardBlockView(block: block, isFirst: index == 0, remote: remote)
                }
            }
            footer
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 680, alignment: .leading)
        .background(hasMap ? AnyShapeStyle(CantripCardStyle.panel)
                           : AnyShapeStyle(LinearGradient(colors: [CantripCardStyle.panelTop, CantripCardStyle.panel],
                                                          startPoint: .top, endPoint: .bottom)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.spokenLabel)
        .accessibilityIdentifier(identifier)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
    }

    @ViewBuilder private var footer: some View {
        let updated = CantripCardStyle.updatedText(card.source?.updatedAt)
        let attribution = card.source?.attribution
        if updated != nil || attribution != nil {
            divider
            HStack(spacing: 6) {
                if let updated { Text(updated) }
                Spacer(minLength: 6)
                if let attribution {
                    if let url = CantripCardStyle.actionURL(card.source?.url) {
                        Button { openURL(url) } label: { Text(attribution).underline() }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(.isLink)
                    } else {
                        Text(attribution)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Blocks

struct CantripCardBlockView: View {
    let block: CantripCard.Block
    let isFirst: Bool
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        switch block.type {
        case "header": header
        case "stat": stat
        case "keyValue": keyValue
        case "strip": strip
        case "chart": chart
        case "list": list
        case "badges":
            CantripChildFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array((block.badges ?? []).enumerated()), id: \.offset) { _, badge in CantripCardBadge(badge: badge) }
            }
            .padding(.horizontal, 14)
            .padding(.top, isFirst ? 14 : 4)
            .padding(.bottom, 12)
        case "notice": notice
        case "image": CantripCardImage(imageID: block.imageID ?? "", label: block.accessibilityLabel, remote: remote)
        default: EmptyView()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if let symbol = block.symbol, CantripCardStyle.symbolExists(symbol) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CantripCardStyle.accent)
                    .frame(width: 22)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let title = block.title {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                }
                if let subtitle = block.subtitle {
                    Group {
                        if let symbol = block.subtitleSymbol, CantripCardStyle.symbolExists(symbol) {
                            Label(subtitle, systemImage: symbol).labelStyle(.titleAndIcon)
                        } else {
                            Text(subtitle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                }
                ForEach(Array((block.lines ?? []).enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(index == 0 ? .subheadline : .footnote)
                        .foregroundStyle(.white.opacity(index == 0 ? 0.88 : 0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let stat = block.stat, let value = stat.value {
                HStack(spacing: 6) {
                    CantripCardIcon(symbol: stat.symbol, size: 28, multicolor: true)
                    Text(value)
                        .font(.system(size: 40, weight: .light))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stat.accessibilityLabel ?? value)
            }
        }
        .padding(14)
    }

    private var stat: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label = block.label {
                Text(label.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.62))
            }
            HStack(spacing: 8) {
                CantripCardIcon(symbol: block.symbol, size: 22)
                    .foregroundStyle(CantripCardStyle.accent)
                Text(block.value ?? "")
                    .font(.system(size: 30))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            if let detail = block.detail {
                Text(detail).font(.footnote).foregroundStyle(.white.opacity(0.75))
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
                    Text(row.key ?? "").foregroundStyle(.white.opacity(0.78))
                    Spacer(minLength: 8)
                    Text(row.value ?? "")
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.key ?? ""): \(row.value ?? "")")
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
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        CantripCardIcon(symbol: item.symbol, glyph: item.glyph, size: 18, multicolor: true)
                            .frame(height: 22)
                        Text(item.note ?? " ")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(CantripCardStyle.tone(item.tone ?? "accent"))
                        Text(item.value ?? "")
                            .font(.subheadline.weight(.semibold))
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
        let lows = items.compactMap { $0.low ?? $0.high }
        let highs = items.compactMap { $0.high ?? $0.low }
        let lowest = block.min ?? lows.min() ?? 0
        let span = Swift.max(1e-9, (block.max ?? highs.max() ?? 1) - lowest)
        return VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let low = item.low ?? lowest
                let high = item.high ?? low
                let start = Swift.min(1, Swift.max(0, (low - lowest) / span))
                HStack(spacing: 8) {
                    Text(item.label ?? "")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .frame(width: 50, alignment: .leading)
                    CantripCardIcon(symbol: item.symbol, glyph: item.glyph, size: 16, multicolor: true)
                        .frame(width: 26)
                    Text(item.note ?? "")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CantripCardStyle.tone(item.tone ?? "accent"))
                        .frame(width: 36, alignment: .leading)
                    Text(item.lowText ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                    CantripWeatherRangeBar(range: start...Swift.min(1, Swift.max(start, (high - lowest) / span)))
                        .frame(height: 5)
                    Text(item.highText ?? "")
                        .font(.subheadline.weight(.semibold))
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
                    .font(.caption2.weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .accessibilityAddTraits(.isHeader)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                CantripCardItemRow(item: item, compact: false)
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
                CantripCardIcon(symbol: block.symbol, size: 15)
                    .foregroundStyle(CantripCardStyle.tone(block.tone))
                    .accessibilityHidden(true)
                Text(block.title ?? "").font(.subheadline.weight(.semibold))
            }
            if let text = block.text {
                Text(text)
                    .font(.footnote)
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

struct CantripCardBadge: View {
    let badge: CantripCard.Badge

    var body: some View {
        let color = CantripCardStyle.tone(badge.tone)
        HStack(spacing: 3) {
            if let symbol = badge.symbol, CantripCardStyle.symbolExists(symbol) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(badge.text ?? "")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(badge.tone == nil || badge.tone == "neutral" ? Color.white.opacity(0.1) : color.opacity(0.16)))
    }
}

/// One entry of a list: title and trailing value, a subtitle with badges, details, a note, and
/// buttons for its actions. In a map's legend (`compact`) it selects its pin.
struct CantripCardItemRow: View {
    let item: CantripCard.Item
    let compact: Bool
    var isSelected = false
    var onFocus: (() -> Void)? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let onFocus {
                Button(action: onFocus) { info.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows it on the map")
            } else {
                info
            }
            let actions = (item.actions ?? []).compactMap { action in CantripCardStyle.actionURL(action.url).map { (action, $0) } }
            if !actions.isEmpty {
                CantripChildFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, entry in
                        Button { openURL(entry.1) } label: {
                            Label(entry.0.label ?? "Open", systemImage: CantripCardStyle.actionSymbol(entry.0.kind))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(entry.0.label ?? "Open"), \(item.title ?? item.label ?? "")")
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
                    CantripCardIcon(symbol: item.symbol, glyph: item.glyph, size: 15)
                        .foregroundStyle(CantripCardStyle.accent)
                }
                Text(item.title ?? item.label ?? "")
                    .font(compact ? .system(size: 13, weight: .semibold) : .subheadline.weight(.semibold))
                    .lineLimit(compact ? 1 : 2)
                Spacer(minLength: 6)
                if let trailing = item.trailing {
                    Text(trailing)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if item.subtitle != nil || !(item.badges ?? []).isEmpty {
                CantripChildFlowLayout(spacing: 5, lineSpacing: 4) {
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.system(size: compact ? 11 : 12))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    ForEach(Array((item.badges ?? []).enumerated()), id: \.offset) { _, badge in CantripCardBadge(badge: badge) }
                }
            }
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: compact ? 10.5 : 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(compact ? 1 : 2)
            }
            if let note = item.note {
                Text(note)
                    .font(.system(size: compact ? 10.5 : 11.5))
                    .foregroundStyle(item.tone == nil ? Color.white.opacity(0.6) : CantripCardStyle.tone(item.tone))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel ?? [item.title, item.subtitle, item.detail, item.trailing].compactMap { $0 }.joined(separator: ", "))
    }
}

struct CantripCardImage: View {
    let imageID: String
    let label: String?
    @ObservedObject var remote: CantripRemoteModel
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 184)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
        .task(id: "\(remote.usageIdentity)/\(imageID)") {
            image = try? await remote.linkPreviewImage(id: imageID)
        }
    }
}

// MARK: - Map block

/// A map block with its legend (a list whose items name the pins): MapKit with labelled pins,
/// the legend floating beside the pins on wide cards and under the map on narrow ones.
struct CantripCardMapView: View {
    struct MapPin: Identifiable {
        let id: String
        let title: String
        let coordinate: CLLocationCoordinate2D
        let symbol: String?
        let glyph: String?
    }

    let pins: [MapPin]
    let items: [CantripCard.Item]
    let legendTitle: String?
    let attribution: String
    @Environment(\.openURL) private var openURL
    @State private var position: MapCameraPosition
    @State private var currentRegion: MKCoordinateRegion
    @State private var selectedPinID: String?
    @State private var availableWidth: CGFloat = 0
    @State private var mapSize: CGSize = .zero

    static let listWidth: CGFloat = 244
    static let pinLabelMaxWidth: CGFloat = 150
    static let floatingOverlayMinWidth: CGFloat = 600

    static func pins(_ block: CantripCard.Block) -> [MapPin] {
        (block.pins ?? []).enumerated().compactMap { index, pin in
            guard let lat = pin.latitude, let lon = pin.longitude, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
            return MapPin(id: pin.id ?? "pin-\(index)", title: pin.title ?? "", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                          symbol: pin.symbol, glyph: pin.glyph)
        }
    }

    init(block: CantripCard.Block, legend: CantripCard.Block?) {
        let pins = Self.pins(block)
        self.pins = pins
        items = legend?.items ?? []
        legendTitle = legend?.title
        attribution = block.attribution ?? "© OpenStreetMap · Apple Maps"
        let lats = pins.map(\.coordinate.latitude), lons = pins.map(\.coordinate.longitude)
        let center = CLLocationCoordinate2D(latitude: block.latitude ?? ((lats.min() ?? 0) + (lats.max() ?? 0)) / 2,
                                            longitude: block.longitude ?? ((lons.min() ?? 0) + (lons.max() ?? 0)) / 2)
        let region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(
            latitudeDelta: max(block.latitudeDelta ?? ((lats.max() ?? 0) - (lats.min() ?? 0)) * 1.4, 0.01),
            longitudeDelta: max(block.longitudeDelta ?? ((lons.max() ?? 0) - (lons.min() ?? 0)) * 1.4, 0.01)))
        _currentRegion = State(initialValue: region)
        _position = State(initialValue: .region(region))
        _selectedPinID = State(initialValue: pins.first?.id)
    }

    /// The legend floats over the map only when the map keeps room for its pins beside it
    /// (about 200 pt); narrower cards, folded or unfolded, put the legend under the map.
    private var usesFloatingOverlay: Bool { !items.isEmpty && availableWidth >= Self.floatingOverlayMinWidth }

    var body: some View {
        Group {
            if usesFloatingOverlay {
                wideOverlay
            } else {
                stacked
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .accessibilityElement(children: .contain)
    }

    private var wideOverlay: some View {
        ZStack(alignment: .topLeading) {
            mapSurface
            // Scrolls when the legend is taller than the map.
            ViewThatFits(in: .vertical) {
                legend
                ScrollView { legend }
            }
            .frame(width: Self.listWidth)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CantripCardStyle.panel.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(12)
            zoomButtons
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(12)
            attributionPill
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(10)
        }
        .frame(height: 310)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                mapSurface
                zoomButtons
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
                attributionPill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
            .frame(height: items.isEmpty ? 240 : 196)
            .clipped()
            if !items.isEmpty {
                Divider().overlay(Color.white.opacity(0.12))
                legend
            }
        }
    }

    /// Nudges that keep pins whose capsules would overlap (close places) readable.
    private var pinOffsets: [String: CGSize] {
        guard mapSize != .zero else { return [:] }
        let points = CantripPlaceMapFit.screenPoints(pins.map(\.coordinate), region: currentRegion, size: mapSize)
        let offsets = CantripPlaceMapFit.labelOffsets(points: points, widths: pins.map { CantripPlaceMapFit.pinWidth($0.title) },
                                                      bounds: CGRect(origin: .zero, size: mapSize))
        return Dictionary(zip(pins.map(\.id), offsets), uniquingKeysWith: { first, _ in first })
    }

    private var mapSurface: some View {
        let offsets = pinOffsets
        return Map(position: $position) {
            ForEach(pins) { pin in
                Annotation(pin.title, coordinate: pin.coordinate, anchor: .bottom) {
                    Button {
                        selectedPinID = pin.id
                        if let url = directionsURL(for: pin) { openURL(url) }
                    } label: {
                        HStack(spacing: 5) {
                            Group {
                                if let symbol = pin.symbol, CantripCardStyle.symbolExists(symbol) {
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
                    .accessibilityLabel("Pin for \(pin.title)")
                    .offset(offsets[pin.id] ?? .zero)
                }
                .annotationTitles(.hidden)
            }
        }
        .cantripSwipeExempt()
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
                    .font(.caption2.weight(.bold))
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
                CantripCardItemRow(item: item, compact: true, isSelected: pin != nil && selectedPinID == pin?.id, onFocus: onFocus)
            }
        }
    }

    private var zoomButtons: some View {
        VStack(spacing: 1) {
            Button { zoom(by: 0.5) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom in")
            Divider().frame(width: 22).overlay(Color.white.opacity(0.16))
            Button { zoom(by: 2.0) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom out")
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CantripCardStyle.panel.opacity(0.92)))
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

    /// The map area pins may use: right of the floating legend, below the top edge by a pin's
    /// height (pins hang above their coordinate), and clear of the attribution.
    private var pinInsets: CantripPlaceMapFit.Insets {
        // Half the widest pin label, as an annotation is centred on its coordinate.
        let longest = pins.map(\.title.count).max() ?? 0
        let halfPin = (min(Double(longest) * 6.4, Double(Self.pinLabelMaxWidth)) + 36) / 2
        let edge = usesFloatingOverlay ? 12.0 : 10.0
        let left = usesFloatingOverlay ? edge + Double(Self.listWidth) + 8 : edge
        return CantripPlaceMapFit.Insets(top: edge + 28, left: left + halfPin, bottom: edge + 22, right: edge + halfPin)
    }

    /// Shows `pins` in the uncovered map area; a single pin keeps a street-level zoom.
    private func fit(_ pins: [MapPin], minimumMeters: Double = 2_000) {
        guard let rect = CantripPlaceMapFit.rect(for: pins.map(\.coordinate), size: mapSize,
                                                 insets: pinInsets, minimumMeters: minimumMeters) else { return }
        position = .rect(rect)
    }

    private func focus(on pin: MapPin) {
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
    private func directionsURL(for pin: MapPin) -> URL? {
        let item = items.first { ($0.pinID ?? $0.id) == pin.id }
        let action = item?.actions?.first { $0.kind == "directions" }
        return CantripCardStyle.actionURL(action?.url)
    }
}
