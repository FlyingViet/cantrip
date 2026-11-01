import SwiftUI

/// A reply's forecast card (`weatherCard` on a Cantrip message): Open-Meteo numbers the Mac
/// fetched for the reply's `weather` block, with labels and SF Symbols ready to show. Decoding
/// never fails the message: a malformed card just shows less.
struct CantripWeatherCard: Codable, Equatable, Sendable {
    struct Current: Codable, Equatable, Sendable {
        let temperature: Int
        var feelsLike: Int?
        var condition: String
        var symbol: String
        var precipitationChance: Int?
    }

    struct Today: Codable, Equatable, Sendable {
        let high: Int
        let low: Int
        var precipitationChance: Int?
    }

    struct Hour: Codable, Equatable, Sendable {
        let label: String
        let temperature: Int
        var condition: String
        var symbol: String
        var precipitationChance: Int?
    }

    struct Day: Codable, Equatable, Sendable {
        let date: String
        let label: String
        let high: Int
        let low: Int
        var condition: String
        var symbol: String
        var precipitationChance: Int?
    }

    var place: String = "Weather"
    var placeNote: String?
    var status: String = "unavailable"
    var message: String?
    var unit: String = "F"
    var updatedAt: Date?
    var current: Current?
    var today: Today?
    var hourly: [Hour] = []
    var daily: [Day] = []
    var attribution: String = "Weather data by Open-Meteo.com"
    var attributionURL: URL = URL(string: "https://open-meteo.com/")!

    var isAvailable: Bool { status == "ok" && current != nil }

    private enum Keys: String, CodingKey {
        case place, placeNote, status, message, unit, updatedAt, current, today, hourly, daily, attribution, attributionURL
    }

    init(place: String, placeNote: String? = nil, status: String, message: String? = nil, unit: String = "F",
         updatedAt: Date? = nil, current: Current? = nil, today: Today? = nil, hourly: [Hour] = [], daily: [Day] = []) {
        self.place = place
        self.placeNote = placeNote
        self.status = status
        self.message = message
        self.unit = unit
        self.updatedAt = updatedAt
        self.current = current
        self.today = today
        self.hourly = hourly
        self.daily = daily
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: Keys.self) else { return }
        func text(_ key: Keys) -> String? {
            (try? container.decodeIfPresent(String.self, forKey: key))?.flatMap { $0.isEmpty ? nil : $0 }
        }
        place = text(.place).map { String($0.prefix(120)) } ?? "Weather"
        placeNote = text(.placeNote)
        status = text(.status) ?? "unavailable"
        message = text(.message)
        unit = text(.unit) == "C" ? "C" : "F"
        updatedAt = text(.updatedAt).flatMap { ISO8601DateFormatter().date(from: $0) }
        current = try? container.decodeIfPresent(Current.self, forKey: .current)
        today = try? container.decodeIfPresent(Today.self, forKey: .today)
        hourly = Array(((try? container.decodeIfPresent([Hour].self, forKey: .hourly)) ?? nil)?.prefix(13) ?? [])
        daily = Array(((try? container.decodeIfPresent([Day].self, forKey: .daily)) ?? nil)?.prefix(10) ?? [])
        attribution = text(.attribution) ?? attribution
        // Only Open-Meteo's own page: the attribution link never goes anywhere else.
        if let raw = text(.attributionURL), raw.hasPrefix("https://open-meteo.com/"), let url = URL(string: raw) {
            attributionURL = url
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(place, forKey: .place)
        try container.encodeIfPresent(placeNote, forKey: .placeNote)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encode(unit, forKey: .unit)
        try container.encodeIfPresent(updatedAt.map { ISO8601DateFormatter().string(from: $0) }, forKey: .updatedAt)
        try container.encodeIfPresent(current, forKey: .current)
        try container.encodeIfPresent(today, forKey: .today)
        try container.encode(hourly, forKey: .hourly)
        try container.encode(daily, forKey: .daily)
        try container.encode(attribution, forKey: .attribution)
        try container.encode(attributionURL.absoluteString, forKey: .attributionURL)
    }

    static func unitName(_ unit: String) -> String { unit == "C" ? "degrees Celsius" : "degrees Fahrenheit" }

    /// Shown under a percentage only when rain or snow is reasonably likely.
    static func chanceText(_ chance: Int?) -> String? {
        guard let chance, chance >= 10 else { return nil }
        return "\(chance)%"
    }

    var detailLine: String {
        var parts: [String] = []
        if let today {
            parts.append("H \(today.high)°  L \(today.low)°")
            if let chance = today.precipitationChance { parts.append("\(chance)% precip.") }
        }
        if let current, let feels = current.feelsLike, abs(feels - current.temperature) >= 3 {
            parts.append("Feels like \(feels)°")
        }
        return parts.joined(separator: " · ")
    }

    func spokenHour(_ hour: Hour) -> String {
        var text = "\(hour.label), \(hour.temperature) \(Self.unitName(unit)), \(hour.condition)"
        if let chance = hour.precipitationChance, chance >= 10 { text += ", \(chance) percent chance of precipitation" }
        return text
    }

    func spokenDay(_ day: Day) -> String {
        var text = "\(day.label), \(day.condition), high \(day.high), low \(day.low) \(Self.unitName(unit))"
        if let chance = day.precipitationChance, chance >= 10 { text += ", \(chance) percent chance of precipitation" }
        return text
    }

    /// Where a day's low-to-high bar starts and ends on the week's scale (0...1).
    func range(of day: Day) -> ClosedRange<Double> {
        let lowest = daily.map(\.low).min() ?? day.low
        let highest = daily.map(\.high).max() ?? day.high
        let span = Double(max(1, highest - lowest))
        let start = min(1, max(0, Double(day.low - lowest) / span))
        let end = min(1, max(start, Double(day.high - lowest) / span))
        return start...end
    }
}

/// The map card's container (680 pt, 16 pt corners, dark panel) with a forecast inside.
struct CantripWeatherCardView: View {
    let card: CantripWeatherCard
    @Environment(\.openURL) private var openURL

    static let panel = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let rain = Color(red: 0.55, green: 0.79, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if card.isAvailable {
                divider
                hourlyStrip
                divider
                dailyList
            }
            divider
            footer
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 680, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.13, green: 0.19, blue: 0.29), Self.panel],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Weather for \(card.place)")
        .accessibilityIdentifier("chat.weatherCard")
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(card.place)
                    .font(.headline)
                    .lineLimit(2)
                if let note = card.placeNote {
                    Label(note, systemImage: "location.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .labelStyle(.titleAndIcon)
                }
                if card.isAvailable, let current = card.current {
                    Text(current.condition)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.88))
                    if !card.detailLine.isEmpty {
                        Text(card.detailLine)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                } else {
                    Label("Forecast unavailable", systemImage: "exclamationmark.icloud")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    Text(card.message ?? "Ask again in a moment.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if card.isAvailable, let current = card.current {
                HStack(spacing: 6) {
                    Image(systemName: current.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 28))
                    Text("\(current.temperature)°")
                        .font(.system(size: 40, weight: .light))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Now \(current.temperature) \(CantripWeatherCard.unitName(card.unit)), \(current.condition)")
            }
        }
        .padding(14)
    }

    private var hourlyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(card.hourly.enumerated()), id: \.offset) { _, hour in
                    VStack(spacing: 4) {
                        Text(hour.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: hour.symbol)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 18))
                            .frame(height: 22)
                        Text(CantripWeatherCard.chanceText(hour.precipitationChance) ?? " ")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Self.rain)
                        Text("\(hour.temperature)°")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(width: 52)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(card.spokenHour(hour))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .accessibilityLabel("Hourly forecast")
    }

    private var dailyList: some View {
        VStack(spacing: 0) {
            ForEach(Array(card.daily.enumerated()), id: \.offset) { index, day in
                HStack(spacing: 8) {
                    Text(day.label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .frame(width: 50, alignment: .leading)
                    Image(systemName: day.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 16))
                        .frame(width: 26)
                    Text(CantripWeatherCard.chanceText(day.precipitationChance) ?? "")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.rain)
                        .frame(width: 36, alignment: .leading)
                    Text("\(day.low)°")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                    CantripWeatherRangeBar(range: card.range(of: day))
                        .frame(height: 5)
                    Text("\(day.high)°")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(card.spokenDay(day))
                if index < card.daily.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 14)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if card.isAvailable, let updated = card.updatedAt {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
            }
            Spacer(minLength: 6)
            Button {
                openURL(card.attributionURL)
            } label: {
                Text(card.attribution).underline()
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A day's low-to-high span on the 10 days' scale.
struct CantripWeatherRangeBar: View {
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.78, blue: 0.98),
                                                  Color(red: 1.0, green: 0.80, blue: 0.25)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(5, geometry.size.width * (range.upperBound - range.lowerBound)))
                    .offset(x: geometry.size.width * range.lowerBound)
            }
        }
        .accessibilityHidden(true)
    }
}
