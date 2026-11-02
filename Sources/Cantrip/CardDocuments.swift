import Foundation

// MARK: - Card documents

/// One card under a reply, made of a few building blocks every client draws natively, so a new
/// kind of card needs no client code. Values always come from a resolver (weather, places, link
/// previews) or a tool's result; a model only ever writes labels, and a card citing a tool is
/// shown only when its values are found in that tool's output.
struct CardDocument: Codable, Equatable, Sendable, Identifiable {
    struct Source: Codable, Equatable, Sendable {
        /// "resolver", "tool" or "preview".
        var kind: String
        var name: String?
        var attribution: String?
        var url: String?
        var updatedAt: Date?
    }

    /// Opens `url` (https, http or tel only; clients refuse anything else).
    struct Action: Codable, Equatable, Sendable {
        /// "open", "directions", "call" or "website": the icon; every action just opens `url`.
        var kind: String
        var label: String
        var url: String
    }

    struct Badge: Codable, Equatable, Sendable {
        var text: String
        /// "positive", "negative", "warning", "accent" or "neutral".
        var tone: String?
        var symbol: String?
    }

    struct Stat: Codable, Equatable, Sendable {
        var value: String
        var label: String?
        var symbol: String?
        var detail: String?
        var accessibilityLabel: String?
    }

    struct Row: Codable, Equatable, Sendable {
        var key: String
        var value: String
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
        var id: String
        var title: String
        var latitude: Double
        var longitude: Double
        var glyph: String?
        var symbol: String?
    }

    /// `type`: header, stat, keyValue, strip, chart, list, map, image, badges or notice.
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
        /// list: its items are the previous map block's pins (`pinID`), shown as its legend.
        var mapLinked: Bool?
        var attribution: String?
        var imageID: String?
        var aspectRatio: Double?
        var accessibilityLabel: String?

        init(type: String) { self.type = type }
    }

    static let version = 1
    static let blockTypes: Set<String> = ["header", "stat", "keyValue", "strip", "chart", "list", "map", "image", "badges", "notice"]

    var version = CardDocument.version
    var id: String
    /// What it is ("weather", "places", "link", "flights", …): for logs and tests; clients never branch on it.
    var type: String
    /// "panel" (default, dark, up to 680 pt) or "link" (a compact tappable card).
    var style: String?
    var accessibilityLabel: String?
    var action: Action?
    var source: Source?
    /// The card as plain text, for anything that can't draw a block.
    var fallbackText: String?
    var blocks: [Block]

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The paired-client contract: `cards` on a reply, shared by every client.
    var snapshot: [String: Any] {
        guard let data = try? Self.encoder.encode(self),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// The card as text: for clients that can't draw a block, and for an unverified card.
    var plainText: String {
        var lines: [String] = []
        for block in blocks {
            switch block.type {
            case "header":
                lines.append(([block.title] + [block.subtitle]).compactMap { $0 }.joined(separator: " — "))
                lines += block.lines ?? []
                if let stat = block.stat { lines.append(([stat.value] + [stat.label]).compactMap { $0 }.joined(separator: " ")) }
            case "stat":
                lines.append([block.label, block.value, block.detail].compactMap { $0 }.joined(separator: " "))
            case "keyValue":
                lines += (block.rows ?? []).map { "\($0.key): \($0.value)" }
            case "strip":
                lines.append((block.items ?? []).map { [$0.label, $0.value, $0.note].compactMap { $0 }.joined(separator: " ") }
                    .joined(separator: " · "))
            case "chart":
                lines += (block.items ?? []).map { item in
                    [item.label, item.note, [item.lowText, item.highText].compactMap { $0 }.joined(separator: "–")]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                }
            case "list":
                lines += (block.items ?? []).map { item in
                    "• " + [item.title, item.subtitle, item.detail, item.trailing].compactMap { $0 }.joined(separator: " — ")
                }
            case "badges":
                lines.append((block.badges ?? []).map(\.text).joined(separator: " · "))
            case "notice":
                lines.append([block.title, block.text].compactMap { $0 }.joined(separator: ": "))
            default:
                break
            }
        }
        return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }

    func withFallbackText() -> CardDocument {
        var copy = self
        copy.fallbackText = plainText
        return copy
    }
}

// MARK: - Resolver cards

extension WeatherCard {
    /// The forecast as generic blocks: header with the big temperature, the hourly strip, the
    /// 10 days as a range chart, and the source's attribution and update time.
    var document: CardDocument {
        var header = CardDocument.Block(type: "header")
        header.title = place
        header.subtitle = placeNote
        header.subtitleSymbol = placeNote == nil ? nil : "location.fill"
        let source = CardDocument.Source(kind: "resolver", name: "Open-Meteo", attribution: Self.attribution,
                                         url: Self.attributionURL, updatedAt: isAvailable ? updatedAt : nil)
        guard isAvailable, let current else {
            var notice = CardDocument.Block(type: "notice")
            notice.symbol = "exclamationmark.icloud"
            notice.title = "Forecast unavailable"
            notice.text = unavailable ?? "Ask again in a moment."
            notice.tone = "warning"
            return CardDocument(id: "weather-" + place.lowercased(), type: "weather",
                                accessibilityLabel: "Weather for \(place)", source: source,
                                blocks: [header, notice]).withFallbackText()
        }
        let presented = WeatherPresentation(self)
        let unitName = WeatherPresentation.unitName(unit)
        func chance(_ value: Int?) -> String? { value.flatMap { $0 >= 10 ? "\($0)%" : nil } }
        func spokenChance(_ value: Int?) -> String {
            value.flatMap { $0 >= 10 ? ", \($0) percent chance of precipitation" : nil } ?? ""
        }
        var detail: [String] = []
        if let today = days.first {
            detail.append("H \(today.high)°  L \(today.low)°")
            if let chance = today.precipitationChance { detail.append("\(chance)% precip.") }
        }
        if let feels = current.feelsLike, abs(feels - current.temperature) >= 3 { detail.append("Feels like \(feels)°") }
        header.lines = [presented.condition] + (detail.isEmpty ? [] : [detail.joined(separator: " · ")])
        header.stat = CardDocument.Stat(value: "\(current.temperature)°", symbol: presented.symbol,
                                        accessibilityLabel: "Now \(current.temperature) \(unitName), \(presented.condition)")

        var strip = CardDocument.Block(type: "strip")
        strip.accessibilityLabel = "Hourly forecast"
        strip.items = presented.hours.map { hour in
            var item = CardDocument.Item()
            item.label = hour.label
            item.symbol = hour.symbol
            item.value = "\(hour.temperature)°"
            item.note = chance(hour.precipitationChance)
            item.accessibilityLabel = "\(hour.label), \(hour.temperature) \(unitName), \(hour.condition)"
                + spokenChance(hour.precipitationChance)
            return item
        }

        var chart = CardDocument.Block(type: "chart")
        chart.kind = "range"
        chart.accessibilityLabel = "\(presented.days.count)-day forecast"
        chart.min = Double(presented.days.map(\.low).min() ?? 0)
        chart.max = Double(presented.days.map(\.high).max() ?? 1)
        chart.items = presented.days.map { day in
            var item = CardDocument.Item()
            item.label = day.label
            item.symbol = day.symbol
            item.note = chance(day.precipitationChance)
            item.low = Double(day.low)
            item.high = Double(day.high)
            item.lowText = "\(day.low)°"
            item.highText = "\(day.high)°"
            item.accessibilityLabel = "\(day.label), \(day.condition), high \(day.high), low \(day.low) \(unitName)"
                + spokenChance(day.precipitationChance)
            return item
        }
        return CardDocument(id: "weather-" + place.lowercased(), type: "weather",
                            accessibilityLabel: "Weather for \(place)", source: source,
                            blocks: [header, strip, chart]).withFallbackText()
    }
}

extension PlaceCard {
    /// A map block with the pins, and its legend: a list of the places with their actions.
    var document: CardDocument {
        var map = CardDocument.Block(type: "map")
        map.latitude = centerLatitude
        map.longitude = centerLongitude
        map.latitudeDelta = latitudeDelta
        map.longitudeDelta = longitudeDelta
        map.attribution = attribution
        map.accessibilityLabel = "Map of " + (places.count == 1 ? places[0].name : "\(places.count) places")
        map.pins = places.map {
            CardDocument.Pin(id: $0.id, title: $0.name, latitude: $0.latitude, longitude: $0.longitude,
                             glyph: PlaceSymbol.glyph(for: $0.pinSymbol), symbol: $0.pinSymbol)
        }
        var list = CardDocument.Block(type: "list")
        list.mapLinked = true
        list.title = query
        list.items = places.map(\.cardItem)
        return CardDocument(id: "places-" + (places.first?.id ?? query), type: "places",
                            accessibilityLabel: query.isEmpty ? "Recommended places" : "Places for \(query)",
                            blocks: [map, list]).withFallbackText()
    }
}

extension PlacePin {
    var cardItem: CardDocument.Item {
        var item = CardDocument.Item()
        item.id = id
        item.pinID = id
        item.title = name
        item.symbol = pinSymbol
        item.glyph = PlaceSymbol.glyph(for: pinSymbol)
        let subtitle = [category, priceLevel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        item.subtitle = subtitle.isEmpty ? nil : subtitle
        item.detail = address
        var badges: [CardDocument.Badge] = []
        if let rating {
            let reviews = reviewCount.map { " (\($0))" } ?? ""
            badges.append(.init(text: String(format: "%.1f", rating) + reviews, tone: "warning", symbol: "star.fill"))
        }
        if let isOpenNow {
            badges.append(.init(text: isOpenNow ? "Open now" : "Closed", tone: isOpenNow ? "positive" : "negative"))
        }
        item.badges = badges.isEmpty ? nil : badges
        if isApproximate == true {
            item.note = "Approximate location"
            item.tone = "warning"
        } else if let listedName, !listedName.isEmpty {
            item.note = "Listed as \(listedName)"
        } else if let hoursSummary, !hoursSummary.isEmpty {
            item.note = hoursSummary
        }
        var actions = [CardDocument.Action(kind: "directions", label: "Directions", url: appleMapsURL)]
        if let phone, !phone.isEmpty {
            let digits = phone.filter { $0.isNumber || $0 == "+" }
            if !digits.isEmpty { actions.append(.init(kind: "call", label: "Call", url: "tel:" + digits)) }
        }
        if let website, let url = URL(string: website), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            actions.append(.init(kind: "website", label: "Website", url: website))
        }
        item.actions = actions
        var spoken = [name] + [subtitle].filter { !$0.isEmpty }
        spoken += badges.map { $0.symbol == "star.fill" ? "rated \($0.text)" : $0.text }
        if let address { spoken.append(address) }
        item.accessibilityLabel = spoken.joined(separator: ", ")
        return item
    }
}

extension LinkPreviewCard {
    /// A compact tappable card: the page's image (cached on the Mac) and title.
    var document: CardDocument {
        var blocks: [CardDocument.Block] = []
        if let imageID, !imageID.isEmpty {
            var image = CardDocument.Block(type: "image")
            image.imageID = imageID
            image.accessibilityLabel = title
            blocks.append(image)
        }
        var header = CardDocument.Block(type: "header")
        header.title = title
        header.subtitle = domain
        header.symbol = imageID == nil ? "link" : nil
        blocks.append(header)
        return CardDocument(id: id, type: "link", style: "link", accessibilityLabel: "\(title), \(domain)",
                            action: .init(kind: "open", label: "Open", url: url),
                            source: .init(kind: "preview", name: siteName ?? domain), blocks: blocks).withFallbackText()
    }
}

// MARK: - Tool cards

/// Cards built from a tool's own result: no model involved, so every value is the tool's.
enum ToolCards {
    /// The namespaced key a tool can put in its JSON result to return a ready card (MCP servers
    /// can do this next to, or instead of, an MCP Apps HTML view).
    static let toolCardKey = "cantrip/card"

    /// The newest tool result in `activities` that makes a card.
    static func card(from activities: [ToolActivity], now: Date = Date()) -> CardDocument? {
        for activity in flattened(activities).reversed() where activity.state == .succeeded {
            guard let output = activity.output else { continue }
            if let card = toolAuthoredCard(output: output, toolName: activity.toolName, now: now) { return card }
            if isFlightSearch(activity.toolName), let card = KiwiFlightCards.card(from: output, now: now) { return card }
        }
        return nil
    }

    static func flattened(_ activities: [ToolActivity]) -> [ToolActivity] {
        activities.flatMap { [$0] + flattened($0.children) }
    }

    static func normalized(_ toolName: String) -> String {
        toolName.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func isFlightSearch(_ toolName: String) -> Bool {
        normalized(toolName).hasSuffix("searchflight")
    }

    /// `{"cantrip/card": {...}}` anywhere at the top of a JSON result.
    static func toolAuthoredCard(output: String, toolName: String, now: Date) -> CardDocument? {
        guard output.contains(toolCardKey), let object = JSONPrefix.firstObject(in: output),
              var raw = object[toolCardKey] as? [String: Any] else { return nil }
        raw["version"] = CardDocument.version
        if raw["id"] == nil { raw["id"] = "tool-card" }
        if raw["type"] == nil { raw["type"] = "custom" }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              var card = try? CardDocument.decoder.decode(CardDocument.self, from: data),
              let clean = CardValidation.sanitized(card, allowMaps: true) else { return nil }
        card = clean
        card.source = CardDocument.Source(kind: "tool", name: card.source?.name ?? toolName,
                                          attribution: card.source?.attribution, url: card.source?.url, updatedAt: now)
        return card.withFallbackText()
    }
}

/// Reads JSON from the start of a tool's text output, which may have more text after it or be
/// cut off: the first whole object, or the whole objects at the start of an array.
enum JSONPrefix {
    static func firstObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = matchingEnd(in: text, from: start) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    /// The complete objects in the array named `key` in the first object, even if the text is cut off.
    static func objects(inArray key: String, of text: String) -> [[String: Any]] {
        if let whole = firstObject(in: text), let array = whole[key] as? [[String: Any]] { return array }
        guard let keyRange = text.range(of: "\"\(key)\""),
              let open = text[keyRange.upperBound...].firstIndex(of: "[") else { return [] }
        var results: [[String: Any]] = []
        var cursor = text.index(after: open)
        while let start = text[cursor...].firstIndex(where: { !$0.isWhitespace && $0 != "," }), text[start] == "{",
              let end = matchingEnd(in: text, from: start) {
            if let object = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any] {
                results.append(object)
            }
            cursor = text.index(after: end)
        }
        return results
    }

    /// The index of the brace or bracket closing the one at `start`, skipping strings.
    static func matchingEnd(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// A flight card from a Kiwi.com search result (`search-flight`): the route, then the first few
/// itineraries with times, duration, stops and price, the cheapest and fastest marked, each
/// opening its booking page.
enum KiwiFlightCards {
    static let maximumItineraries = 6

    static func card(from output: String, now: Date = Date()) -> CardDocument? {
        let itineraries = JSONPrefix.objects(inArray: "itineraries", of: output)
            .filter { ($0["outbound"] as? [String: Any]) != nil && $0["price"] is NSNumber }
        guard !itineraries.isEmpty else { return nil }
        let head = JSONPrefix.firstObject(in: output) ?? [:]
        let shown = Array(itineraries.prefix(maximumItineraries))
        // One of each mark, on the first itinerary that earns it (ties are common).
        let prices = shown.map { ($0["price"] as? NSNumber)?.doubleValue ?? .infinity }
        let durations = shown.map { ($0["totalDurationSeconds"] as? NSNumber)?.intValue ?? .max }
        let cheapest = prices.firstIndex(of: prices.min() ?? .infinity)
        let fastest = durations.firstIndex(of: durations.min() ?? .max)
        let first = shown[0]["outbound"] as? [String: Any] ?? [:]
        let route = [first["from"] as? String, first["to"] as? String].compactMap { $0 }

        var header = CardDocument.Block(type: "header")
        header.symbol = "airplane"
        header.title = route.count == 2 ? "\(route[0]) → \(route[1])" : "Flights"
        var subtitle: [String] = []
        if let departure = (first["departureTime"] as? String).flatMap(localDate) { subtitle.append(dayFormat.string(from: departure)) }
        if let passengers = head["passengers"] as? [String: Any] {
            let adults = (passengers["adults"] as? NSNumber)?.intValue ?? 0
            let others = ((passengers["children"] as? NSNumber)?.intValue ?? 0) + ((passengers["infants"] as? NSNumber)?.intValue ?? 0)
            let total = adults + others
            if total > 0 { subtitle.append(total == 1 ? "1 traveler" : "\(total) travelers") }
        }
        if let count = (head["resultsCount"] as? NSNumber)?.intValue, count > shown.count {
            subtitle.append("\(shown.count) of \(count) results")
        }
        header.subtitle = subtitle.isEmpty ? nil : subtitle.joined(separator: " · ")

        var list = CardDocument.Block(type: "list")
        list.items = shown.enumerated().map { index, itinerary in
            item(for: itinerary, index: index, cheapest: cheapest, fastest: fastest)
        }
        let title = header.title ?? "Flights"
        return CardDocument(id: "flights-" + (shown[0]["id"] as? String ?? title), type: "flights",
                            accessibilityLabel: "Flights \(title.replacingOccurrences(of: " → ", with: " to "))",
                            source: .init(kind: "tool", name: "Kiwi.com", attribution: "Flights from Kiwi.com",
                                          url: "https://www.kiwi.com/", updatedAt: now),
                            blocks: [header, list]).withFallbackText()
    }

    private static func item(for itinerary: [String: Any], index: Int, cheapest: Int?, fastest: Int?) -> CardDocument.Item {
        var item = CardDocument.Item()
        item.id = itinerary["id"] as? String ?? "itinerary-\(index)"
        let outbound = itinerary["outbound"] as? [String: Any] ?? [:]
        let segments = outbound["segments"] as? [[String: Any]] ?? []
        let carriers = segments.compactMap { $0["carrierName"] as? String }.reduce(into: [String]()) { names, name in
            if !names.contains(name) { names.append(name) }
        }
        let numbers = segments.compactMap { $0["flightNumber"] as? String }
        item.title = ([carriers.joined(separator: " + ")] + [numbers.joined(separator: ", ")])
            .filter { !$0.isEmpty }.joined(separator: " · ")
        if item.title?.isEmpty != false { item.title = "Flight \(index + 1)" }
        item.symbol = "airplane"
        item.subtitle = legSummary(outbound)
        if let inbound = itinerary["inbound"] as? [String: Any] { item.detail = "Return " + legSummary(inbound) }
        let price = (itinerary["price"] as? NSNumber)?.doubleValue
        item.trailing = itinerary["priceFormatted"] as? String ?? price.map { String(format: "%.0f", $0) }
        var badges: [CardDocument.Badge] = []
        if index == cheapest { badges.append(.init(text: "Cheapest", tone: "positive")) }
        if index == fastest { badges.append(.init(text: "Fastest", tone: "accent")) }
        item.badges = badges.isEmpty ? nil : badges
        if let booking = itinerary["bookingUrl"] as? String, let url = URL(string: booking), url.scheme == "https" {
            item.actions = [.init(kind: "open", label: "Book", url: booking)]
        }
        item.accessibilityLabel = [item.title, item.subtitle, item.detail, item.trailing.map { "price \($0)" }]
            .compactMap { $0 }.joined(separator: ", ") + badges.map { ", \($0.text)" }.joined()
        return item
    }

    /// "3:08 PM → 5:21 PM · 2h 13m · Nonstop" (times are local to each airport, as Kiwi gives them).
    static func legSummary(_ leg: [String: Any]) -> String {
        var parts: [String] = []
        if let departure = (leg["departureTime"] as? String).flatMap(localDate),
           let arrival = (leg["arrivalTime"] as? String).flatMap(localDate) {
            parts.append("\(timeFormat.string(from: departure)) → \(timeFormat.string(from: arrival))")
        }
        if let seconds = (leg["durationSeconds"] as? NSNumber)?.intValue, seconds > 0 {
            parts.append(seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : "\(seconds / 60)m")
        }
        let stops = (leg["stops"] as? NSNumber)?.intValue ?? 0
        if stops == 0 {
            parts.append("Nonstop")
        } else {
            let via = (leg["route"] as? [String]).map { $0.dropFirst().dropLast().joined(separator: ", ") } ?? ""
            parts.append(stops == 1 ? "1 stop" + (via.isEmpty ? "" : " (\(via))") : "\(stops) stops" + (via.isEmpty ? "" : " (\(via))"))
        }
        return parts.joined(separator: " · ")
    }

    private static func localDate(_ text: String) -> Date? { isoLocal.date(from: String(text.prefix(19))) }

    /// Kiwi's local times carry no offset: read and print them in one fixed zone so they stay local.
    private static let isoLocal: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return format
    }()

    private static let timeFormat: DateFormatter = {
        let format = DateFormatter()
        format.timeZone = TimeZone(identifier: "UTC")
        format.setLocalizedDateFormatFromTemplate("jmm")
        return format
    }()

    private static let dayFormat: DateFormatter = {
        let format = DateFormatter()
        format.timeZone = TimeZone(identifier: "UTC")
        format.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return format
    }()
}

// MARK: - Model-written cards

/// A fenced `card` block a reply ends with: labels by the model, values from a tool result it
/// cites. Shown only when every number in it is found in that result; otherwise its content
/// stays in the reply as plain text.
enum ModelCards {
    struct Proposal: Equatable {
        var card: CardDocument
        var citedTool: String?
    }

    static func extract(from text: inout String) -> [Proposal] {
        guard text.range(of: "card", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(pattern: #"```(?:cantrip-card|card)[ \t]*\r?\n(.*?)```"#,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return [] }
        var proposals: [Proposal] = []
        for match in matches.reversed() {
            if let payload = Range(match.range(at: 1), in: text), let proposal = decode(String(text[payload])) {
                proposals.insert(proposal, at: 0)
            }
            if let whole = Range(match.range, in: text) { text.removeSubrange(whole) }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return proposals
    }

    /// `{"title", "subtitle", "cite": {"tool"}, "blocks": [...]}`; `title`/`subtitle` become a header.
    static func decode(_ raw: String) -> Proposal? {
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8), data.count <= 32 * 1024,
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let cited = ((object["cite"] as? [String: Any])?["tool"] as? String) ?? object["tool"] as? String
        var blocks = object["blocks"] as? [Any] ?? []
        if let title = object["title"] as? String {
            var header: [String: Any] = ["type": "header", "title": title]
            header["subtitle"] = object["subtitle"] as? String
            blocks.insert(header, at: 0)
        }
        object = ["version": CardDocument.version, "id": "model-card", "type": object["type"] as? String ?? "custom",
                  "blocks": blocks]
        guard JSONSerialization.isValidJSONObject(object),
              let clean = try? JSONSerialization.data(withJSONObject: object),
              let card = try? CardDocument.decoder.decode(CardDocument.self, from: clean),
              let sanitized = CardValidation.sanitized(card, allowMaps: false) else { return nil }
        return Proposal(card: sanitized, citedTool: cited)
    }

    /// The card, sourced to the cited tool, when every value in it is in that tool's output.
    static func verified(_ proposal: Proposal, activities: [ToolActivity], now: Date = Date()) -> CardDocument? {
        guard let cited = proposal.citedTool.map(ToolCards.normalized), !cited.isEmpty else { return nil }
        let outputs = ToolCards.flattened(activities).filter { activity in
            let name = ToolCards.normalized(activity.toolName)
            return activity.state == .succeeded && (name == cited || name.hasSuffix(cited) || cited.hasSuffix(name))
        }.compactMap(\.output)
        guard !outputs.isEmpty, CardVerifier.isVerified(proposal.card, against: outputs.joined(separator: "\n")) else { return nil }
        var card = proposal.card
        card.source = .init(kind: "tool", name: proposal.citedTool, updatedAt: now)
        return card.withFallbackText()
    }
}

/// Checks a model-written card against a tool's output: every number (in labels too) and every
/// link must appear in it. Words are labels and pass.
enum CardVerifier {
    static func isVerified(_ card: CardDocument, against output: String) -> Bool {
        let available = numbers(in: output)
        let lowered = output.lowercased()
        for token in numberTokens(in: card) {
            if token.contains(":") {
                guard lowered.contains(token) || lowered.contains("0" + token) else { return false }
                continue
            }
            guard let value = Double(token.replacingOccurrences(of: ",", with: "")),
                  available.contains(where: { abs($0 - value) < 0.005 }) else { return false }
        }
        for url in links(in: card) where !output.contains(url) { return false }
        return true
    }

    /// Every number in the tool's output; a hyphen after a digit is a separator ("2026-11-04"), not a sign.
    static func numbers(in text: String) -> [Double] {
        matches(#"(?<![\d.])-?\d+(?:\.\d+)?"#, in: text).compactMap(Double.init)
    }

    /// Times ("7:05") stay whole; other numbers drop thousands separators ("1,234" → 1234).
    static func numberTokens(in card: CardDocument) -> [String] {
        let texts = strings(in: card)
        var tokens: [String] = []
        for text in texts {
            tokens += matches(#"\d{1,2}:\d{2}|\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?"#, in: text)
        }
        return tokens
    }

    static func strings(in card: CardDocument) -> [String] {
        var texts: [String] = []
        for block in card.blocks {
            texts += [block.title, block.subtitle, block.value, block.label, block.detail, block.text].compactMap { $0 }
            texts += block.lines ?? []
            if let stat = block.stat { texts += [stat.value, stat.label, stat.detail].compactMap { $0 } }
            texts += (block.rows ?? []).flatMap { [$0.key, $0.value] }
            texts += (block.badges ?? []).map(\.text)
            for item in block.items ?? [] {
                texts += [item.label, item.title, item.subtitle, item.detail, item.value, item.note, item.lowText,
                          item.highText, item.trailing].compactMap { $0 }
                texts += (item.badges ?? []).map(\.text)
                if let low = item.low { texts.append(String(low)) }
                if let high = item.high { texts.append(String(high)) }
            }
        }
        return texts
    }

    static func links(in card: CardDocument) -> [String] {
        ([card.action] + card.blocks.flatMap { ($0.items ?? []).flatMap { $0.actions ?? [] } }).compactMap { $0?.url }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

/// Limits for cards that don't come from Cantrip's own resolvers: known blocks only, bounded
/// sizes, safe links, no images (only the Mac's cache serves them).
enum CardValidation {
    static func sanitized(_ card: CardDocument, allowMaps: Bool) -> CardDocument? {
        var copy = card
        copy.version = CardDocument.version
        copy.style = card.style == "link" ? "link" : nil
        copy.action = card.action.flatMap(safe)
        copy.accessibilityLabel = card.accessibilityLabel.map { clip($0) }
        copy.blocks = card.blocks.prefix(12).compactMap { block -> CardDocument.Block? in
            guard CardDocument.blockTypes.contains(block.type), block.type != "image",
                  allowMaps || block.type != "map" else { return nil }
            var block = block
            block.title = block.title.map { clip($0) }
            block.subtitle = block.subtitle.map { clip($0) }
            block.text = block.text.map { clip($0, 400) }
            block.lines = block.lines.map { Array($0.prefix(4)).map { clip($0) } }
            block.rows = block.rows.map { Array($0.prefix(20)) }
            block.badges = block.badges.map { Array($0.prefix(8)) }
            block.pins = block.pins.map { Array($0.prefix(20)).filter { abs($0.latitude) <= 90 && abs($0.longitude) <= 180 } }
            block.imageID = nil
            block.items = block.items.map { items in
                Array(items.prefix(24)).map { item in
                    var item = item
                    item.title = item.title.map { clip($0) }
                    item.subtitle = item.subtitle.map { clip($0) }
                    item.detail = item.detail.map { clip($0) }
                    item.actions = item.actions.map { $0.prefix(4).compactMap(safe) }
                    return item
                }
            }
            return block
        }
        return copy.blocks.isEmpty ? nil : copy
    }

    static func safe(_ action: CardDocument.Action) -> CardDocument.Action? {
        guard let url = URL(string: action.url), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" || scheme == "tel" else { return nil }
        if scheme != "tel", !LinkPreviewSecurity.isAllowed(url: url) { return nil }
        return CardDocument.Action(kind: action.kind, label: clip(action.label, 40), url: action.url)
    }

    static func clip(_ text: String, _ limit: Int = 200) -> String { String(text.prefix(limit)) }
}

// MARK: - Choosing a reply's cards

/// At most one main card per reply (a weather or places block, else a verified or tool card),
/// then link cards for links it doesn't already cover.
enum CardComposer {
    static func mainCard(weather: WeatherCard?, places: PlaceCard?, cards: [CardDocument]) -> CardDocument? {
        if let places, !places.places.isEmpty { return places.document }
        if let weather { return weather.document }
        return cards.first
    }

    /// Links the main card already covers: its places, a weather site under a forecast, or a page
    /// on the same site as one of its actions.
    static func visibleLinks(_ previews: [LinkPreviewCard], main: CardDocument?) -> [LinkPreviewCard] {
        guard let main else { return previews }
        // Pages the card opens: not directions (every place's would cover all of maps.apple.com's site).
        var actions: [CardDocument.Action] = main.action.map { [$0] } ?? []
        for block in main.blocks {
            for item in block.items ?? [] { actions += item.actions ?? [] }
        }
        var pages: [String] = actions.filter { $0.kind == "open" || $0.kind == "website" }.map(\.url)
        if let page = main.source?.url { pages.append(page) }
        let targets: [URL] = pages.compactMap { URL(string: $0) }
        return previews.filter { preview in
            guard let url = URL(string: preview.url) else { return true }
            if main.type == "weather", WeatherLinkFilter.isWeatherSite(url, title: preview.title) { return false }
            return !targets.contains { target in
                guard ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { return false }
                return PlaceLinkFilter.sameSite(url, target)
            }
        }
    }

    /// Before previews are fetched: drop links the main card covers.
    static func uncovered(_ links: [LinkPreviewExtractor.Link], main: CardDocument?) -> [LinkPreviewExtractor.Link] {
        guard let main else { return links }
        let kept = Set(visibleLinks(links.map {
            LinkPreviewCard(id: $0.url.absoluteString, url: $0.url.absoluteString, domain: "", title: $0.label ?? "")
        }, main: main).map(\.id))
        return links.filter { kept.contains($0.url.absoluteString) }
    }

    static func documents(main: CardDocument?, links: [LinkPreviewCard]) -> [CardDocument] {
        [main].compactMap { $0 } + visibleLinks(links, main: main).map(\.document)
    }

    /// The weather block and generic cards, as every backend learns them (tabs' system message, Home's protocol).
    static func richCardGuidance(command: String) -> String {
        WeatherCardResolver.agentGuidance(command: command) + "\n\n" + agentGuidance
    }

    /// Taught to every backend next to the places and weather blocks.
    static let agentGuidance = """
    Cards: Cantrip shows at most one card under a reply, built only from data it can check: the \
    `places` and `weather` blocks above, and results of tools it knows (flight searches get a card \
    by themselves). To show other structured results from a tool you called (prices, packages, \
    schedules), end your reply with a fenced `card` JSON block that cites the tool:
    ```card
    {"title":"Order 1234","cite":{"tool":"<the tool's name>"},"blocks":[{"type":"keyValue","rows":[{"key":"Status","value":"Shipped"}]},{"type":"list","items":[{"title":"Item","subtitle":"Detail","trailing":"$12.99"}]}]}
    ```
    Blocks: header {title, subtitle}, stat {value, label}, keyValue {rows: [{key, value}]}, list \
    {items: [{title, subtitle, trailing}]}, badges {badges: [{text}]}. Write the labels yourself, but \
    copy every number, time and link exactly as the tool returned it: Cantrip shows the card only \
    when each one is in that tool's output, and otherwise shows its contents as plain text. Use a \
    card only when the answer's core is structured data that's easier to see than read, never for prose.
    """
}
