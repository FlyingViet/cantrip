import Foundation
import CoreLocation
import SwiftUI
import AppKit

// MARK: - Weather block

/// Fenced `weather` / `cantrip-weather` JSON a reply ends with: only the place. Cantrip fetches
/// the forecast itself (Open-Meteo), so a card never shows a number the model wrote.
struct WeatherBlockProposal: Equatable, Sendable {
    var place: String?
}

enum WeatherBlock {
    static let maximumPlaceLength = 120

    /// Strips every weather block from `text` and returns the last valid one.
    static func extract(from text: inout String) -> WeatherBlockProposal? {
        guard text.range(of: "weather", options: .caseInsensitive) != nil,
              let regex = try? NSRegularExpression(
                pattern: #"```(?:cantrip-weather|weather)[ \t]*\r?\n(.*?)```"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
              ) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return nil }
        var latest: WeatherBlockProposal?
        for match in matches.reversed() {
            if latest == nil, let payload = Range(match.range(at: 1), in: text) {
                latest = decode(String(text[payload]))
            }
            if let whole = Range(match.range, in: text) { text.removeSubrange(whole) }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return latest
    }

    /// `{"place": "Santa Clara, CA"}` (or `near` / `location`), `{}` for "where I am", or a bare
    /// JSON string. Nil for anything else.
    static func decode(_ raw: String) -> WeatherBlockProposal? {
        let json = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8), data.count <= 4 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if let place = value as? String { return WeatherBlockProposal(place: clean(place)) }
        guard let object = value as? [String: Any] else { return nil }
        let place = ["place", "near", "location"].lazy.compactMap { object[$0] as? String }.first
        return WeatherBlockProposal(place: place.flatMap(clean))
    }

    static func clean(_ place: String) -> String? {
        let flattened = place.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = String(flattened.prefix(maximumPlaceLength)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Card

/// A reply's forecast card. Every number comes from Open-Meteo; when the forecast can't be
/// fetched the card says so (`unavailable`) instead of showing anything.
struct WeatherCard: Codable, Equatable, Sendable {
    struct Current: Codable, Equatable, Sendable {
        var temperature: Int
        var feelsLike: Int?
        var code: Int
        var isDay: Bool
        var precipitationChance: Int?
    }

    struct Hour: Codable, Equatable, Sendable {
        var time: Date
        var temperature: Int
        var code: Int
        var isDay: Bool
        var precipitationChance: Int?
    }

    struct Day: Codable, Equatable, Sendable {
        /// yyyy-MM-dd in the place's time zone.
        var date: String
        var high: Int
        var low: Int
        var code: Int
        var precipitationChance: Int?
    }

    var place: String
    /// Whose location it is when the reply didn't name a place the user typed ("Your iPhone's location").
    var placeNote: String?
    /// Why there's no forecast; nil when there is one.
    var unavailable: String?
    /// "F" or "C".
    var unit: String = "F"
    var timeZone: String?
    var updatedAt: Date?
    var current: Current?
    var hours: [Hour] = []
    var days: [Day] = []

    static let attribution = "Weather data by Open-Meteo.com"
    static let attributionURL = "https://open-meteo.com/"
    static let hourCount = 12
    static let dayCount = 10

    var isAvailable: Bool { unavailable == nil && current != nil }

    static func unavailable(place: String, note: String? = nil, reason: String, unit: String) -> WeatherCard {
        WeatherCard(place: place, placeNote: note, unavailable: reason, unit: unit)
    }
}

/// Labels, conditions and symbols shared by the snapshot, the Mac's card and `cantrip weather`.
struct WeatherPresentation: Equatable {
    struct Hour: Equatable {
        var label: String
        var time: Date
        var temperature: Int
        var condition: String
        var symbol: String
        var precipitationChance: Int?
    }

    struct Day: Equatable {
        var label: String
        var date: String
        var high: Int
        var low: Int
        var condition: String
        var symbol: String
        var precipitationChance: Int?
    }

    var hours: [Hour]
    var days: [Day]
    var condition: String
    var symbol: String

    init(_ card: WeatherCard, locale: Locale = .current) {
        let zone = card.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let hourFormat = DateFormatter()
        hourFormat.locale = locale
        hourFormat.timeZone = zone
        hourFormat.setLocalizedDateFormatFromTemplate("j")
        var hours: [Hour] = []
        if let current = card.current {
            hours.append(Hour(label: "Now", time: card.updatedAt ?? Date(), temperature: current.temperature,
                              condition: WeatherCondition.text(current.code),
                              symbol: WeatherCondition.symbol(current.code, isDay: current.isDay),
                              precipitationChance: current.precipitationChance))
        }
        hours += card.hours.prefix(WeatherCard.hourCount).map {
            Hour(label: hourFormat.string(from: $0.time), time: $0.time, temperature: $0.temperature,
                 condition: WeatherCondition.text($0.code), symbol: WeatherCondition.symbol($0.code, isDay: $0.isDay),
                 precipitationChance: $0.precipitationChance)
        }
        let dayParse = DateFormatter()
        dayParse.locale = Locale(identifier: "en_US_POSIX")
        dayParse.timeZone = zone
        dayParse.dateFormat = "yyyy-MM-dd"
        let dayFormat = DateFormatter()
        dayFormat.locale = locale
        dayFormat.timeZone = zone
        dayFormat.setLocalizedDateFormatFromTemplate("EEE")
        days = card.days.prefix(WeatherCard.dayCount).enumerated().map { index, day in
            let label = index == 0 ? "Today" : dayParse.date(from: day.date).map(dayFormat.string(from:)) ?? day.date
            return Day(label: label, date: day.date, high: day.high, low: day.low,
                       condition: WeatherCondition.text(day.code), symbol: WeatherCondition.symbol(day.code, isDay: true),
                       precipitationChance: day.precipitationChance)
        }
        self.hours = hours
        condition = card.current.map { WeatherCondition.text($0.code) } ?? ""
        symbol = card.current.map { WeatherCondition.symbol($0.code, isDay: $0.isDay) } ?? "cloud"
    }

    static func unitName(_ unit: String) -> String { unit == "C" ? "degrees Celsius" : "degrees Fahrenheit" }
}

/// WMO weather interpretation codes, as Open-Meteo reports them.
enum WeatherCondition {
    static func text(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45: return "Fog"
        case 48: return "Freezing fog"
        case 51: return "Light drizzle"
        case 53: return "Drizzle"
        case 55: return "Heavy drizzle"
        case 56: return "Light freezing drizzle"
        case 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66: return "Light freezing rain"
        case 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80: return "Light showers"
        case 81: return "Showers"
        case 82: return "Heavy showers"
        case 85: return "Snow showers"
        case 86: return "Heavy snow showers"
        case 95: return "Thunderstorms"
        case 96: return "Thunderstorms with hail"
        case 99: return "Thunderstorms with heavy hail"
        default: return "Unknown"
        }
    }

    /// An SF Symbol name; the web and Windows clients map the same names to their own icons.
    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63: return "cloud.rain.fill"
        case 65: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81: return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 82: return "cloud.heavyrain.fill"
        case 95: return "cloud.bolt.rain.fill"
        case 96, 99: return "cloud.hail.fill"
        default: return "cloud.fill"
        }
    }
}

extension WeatherCard {
    /// The paired-client contract (`weatherCard` on a reply), shared with the web UI, Cantrip
    /// Agent and Cantrip Gateway: labels and icons come ready, in the place's time zone.
    var snapshot: [String: Any] {
        var result: [String: Any] = [
            "place": place,
            "status": isAvailable ? "ok" : "unavailable",
            "unit": unit,
            "attribution": Self.attribution,
            "attributionURL": Self.attributionURL,
        ]
        if let placeNote { result["placeNote"] = placeNote }
        guard isAvailable, let current else {
            result["message"] = unavailable ?? "Forecast unavailable."
            return result
        }
        let iso = ISO8601DateFormatter()
        let presented = WeatherPresentation(self)
        if let timeZone { result["timeZone"] = timeZone }
        if let updatedAt { result["updatedAt"] = iso.string(from: updatedAt) }
        var now: [String: Any] = [
            "temperature": current.temperature, "condition": presented.condition, "symbol": presented.symbol,
            "code": current.code, "isDay": current.isDay,
        ]
        now["feelsLike"] = current.feelsLike
        now["precipitationChance"] = current.precipitationChance
        result["current"] = now
        if let today = days.first {
            var item: [String: Any] = ["high": today.high, "low": today.low]
            item["precipitationChance"] = today.precipitationChance
            result["today"] = item
        }
        result["hourly"] = presented.hours.map { hour -> [String: Any] in
            var item: [String: Any] = [
                "time": iso.string(from: hour.time), "label": hour.label, "temperature": hour.temperature,
                "condition": hour.condition, "symbol": hour.symbol,
            ]
            item["precipitationChance"] = hour.precipitationChance
            return item
        }
        result["daily"] = presented.days.map { day -> [String: Any] in
            var item: [String: Any] = [
                "date": day.date, "label": day.label, "high": day.high, "low": day.low,
                "condition": day.condition, "symbol": day.symbol,
            ]
            item["precipitationChance"] = day.precipitationChance
            return item
        }
        return result
    }

    /// What `cantrip weather` prints: the same numbers the card shows, for the model's text.
    var textSummary: String {
        let degree = "°\(unit)"
        let heading = "Weather for \(place)" + (placeNote.map { " (\($0))" } ?? "")
        guard isAvailable, let current else {
            return heading + ": forecast unavailable. \(unavailable ?? "") Don't state forecast numbers; the card says it's unavailable."
        }
        let presented = WeatherPresentation(self)
        func chance(_ value: Int?) -> String { value.map { "\($0)% chance of precipitation" } ?? "no precipitation chance given" }
        let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let stamp = DateFormatter()
        stamp.timeZone = zone
        stamp.setLocalizedDateFormatFromTemplate("j:mm zzz")
        var lines = [heading + ", from Open-Meteo, updated \(updatedAt.map(stamp.string(from:)) ?? "now"):"]
        var nowLine = "Now: \(current.temperature)\(degree), \(presented.condition.lowercased())"
        if let feels = current.feelsLike { nowLine += ", feels like \(feels)\(degree)" }
        lines.append(nowLine + "; \(chance(current.precipitationChance)) this hour")
        if let today = presented.days.first {
            lines.append("Today: high \(today.high)\(degree), low \(today.low)\(degree), \(today.condition.lowercased()), \(chance(today.precipitationChance))")
        }
        let hourly = presented.hours.dropFirst().map {
            "\($0.label) \($0.temperature)° \($0.condition.lowercased())" + ($0.precipitationChance.map { " (\($0)%)" } ?? "")
        }
        if !hourly.isEmpty { lines.append("Next \(hourly.count) hours: " + hourly.joined(separator: "; ")) }
        let daily = presented.days.map {
            "\($0.label) \($0.date): high \($0.high)°, low \($0.low)°, \($0.condition.lowercased())"
                + ($0.precipitationChance.map { ", \($0)%" } ?? "")
        }
        if !daily.isEmpty { lines.append("Next \(daily.count) days: " + daily.joined(separator: "; ")) }
        lines.append("These are exactly the numbers on the reply's weather card; quote only these.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Forecast data

/// One Open-Meteo answer, before it's cut to "now" for a card.
struct WeatherForecast: Equatable, Sendable {
    var timeZone: String
    var current: WeatherCard.Current
    var hours: [WeatherCard.Hour]
    var days: [WeatherCard.Day]
    var fetchedAt: Date

    struct Malformed: Error {}

    /// Parses `/v1/forecast` with `timeformat=unixtime`.
    static func parse(_ data: Data, fetchedAt: Date) throws -> WeatherForecast {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let daily = root["daily"] as? [String: Any],
              let temperature = number(current["temperature_2m"]),
              let code = number(current["weather_code"]) else { throw Malformed() }
        let zone = root["timezone"] as? String ?? "GMT"
        let times = (hourly["time"] as? [Any] ?? []).map(number)
        let hourTemperatures = (hourly["temperature_2m"] as? [Any] ?? []).map(number)
        let hourCodes = (hourly["weather_code"] as? [Any] ?? []).map(number)
        let hourChances = (hourly["precipitation_probability"] as? [Any] ?? []).map(number)
        let hourDay = (hourly["is_day"] as? [Any] ?? []).map(number)
        var hours: [WeatherCard.Hour] = []
        for index in times.indices {
            guard let time = times[index], let temperature = value(hourTemperatures, index),
                  let code = value(hourCodes, index) else { continue }
            hours.append(WeatherCard.Hour(time: Date(timeIntervalSince1970: time), temperature: rounded(temperature),
                                          code: Int(code), isDay: (value(hourDay, index) ?? 1) == 1,
                                          precipitationChance: value(hourChances, index).map(rounded)))
        }
        let dayTimes = (daily["time"] as? [Any] ?? []).map(number)
        let highs = (daily["temperature_2m_max"] as? [Any] ?? []).map(number)
        let lows = (daily["temperature_2m_min"] as? [Any] ?? []).map(number)
        let dayCodes = (daily["weather_code"] as? [Any] ?? []).map(number)
        let dayChances = (daily["precipitation_probability_max"] as? [Any] ?? []).map(number)
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: (root["utc_offset_seconds"] as? Int) ?? 0)
        format.dateFormat = "yyyy-MM-dd"
        var days: [WeatherCard.Day] = []
        for index in dayTimes.indices {
            guard let time = dayTimes[index], let high = value(highs, index), let low = value(lows, index),
                  let code = value(dayCodes, index) else { continue }
            days.append(WeatherCard.Day(date: format.string(from: Date(timeIntervalSince1970: time)),
                                        high: rounded(high), low: rounded(low), code: Int(code),
                                        precipitationChance: value(dayChances, index).map(rounded)))
        }
        guard !days.isEmpty else { throw Malformed() }
        let nowTime = number(current["time"]).map { Date(timeIntervalSince1970: $0) } ?? fetchedAt
        let hourChance = hours.last(where: { $0.time <= nowTime })?.precipitationChance
        return WeatherForecast(
            timeZone: zone,
            current: WeatherCard.Current(temperature: rounded(temperature),
                                         feelsLike: number(current["apparent_temperature"]).map(rounded),
                                         code: Int(code), isDay: (number(current["is_day"]) ?? 1) == 1,
                                         precipitationChance: hourChance),
            hours: hours, days: days, fetchedAt: fetchedAt
        )
    }

    /// The card for `now`: the next 12 whole hours after it and the days from today on.
    func card(place: String, note: String?, unit: String, now: Date) -> WeatherCard {
        let zone = TimeZone(identifier: timeZone) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = { () -> String in
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = zone
            format.dateFormat = "yyyy-MM-dd"
            return format.string(from: now)
        }()
        return WeatherCard(
            place: place, placeNote: note, unavailable: nil, unit: unit, timeZone: timeZone, updatedAt: fetchedAt,
            current: current,
            hours: Array(hours.filter { $0.time > now }.prefix(WeatherCard.hourCount)),
            days: Array(days.filter { $0.date >= today }.prefix(WeatherCard.dayCount))
        )
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, !(raw is NSNull), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func value(_ list: [Double?], _ index: Int) -> Double? { index < list.count ? list[index] : nil }
    private static func rounded(_ value: Double) -> Int { Int(value.rounded()) }
}

// MARK: - Resolver

/// Turns a weather block into a card: finds the place, then fetches (or reuses, for 10 minutes)
/// its forecast from Open-Meteo. Shared with `cantrip weather`, so a reply quoting that command
/// and its card show the same numbers.
actor WeatherCardResolver {
    static let shared = WeatherCardResolver()

    struct Coordinate: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        /// About 1 km: all Open-Meteo ever sees, whatever the device's precision.
        var rounded: Coordinate {
            Coordinate(latitude: (latitude * 100).rounded() / 100, longitude: (longitude * 100).rounded() / 100)
        }
    }

    /// A place Cantrip already knows: the device the message came from, or the Mac.
    struct KnownPlace: Equatable, Sendable {
        var label: String?
        var coordinate: Coordinate
        /// Shown on the card: "Your iPhone's location", "The Mac's location".
        var note: String
    }

    struct Context: Equatable, Sendable {
        var device: KnownPlace?
        var mac: KnownPlace?
        var unit: String
    }

    struct Geocoded: Equatable, Sendable {
        var coordinate: Coordinate
    }

    struct Sources: Sendable {
        var geocode: @Sendable (String) async -> Geocoded?
        var forecast: @Sendable (Coordinate, String) async throws -> WeatherForecast
    }

    static let forecastLifetime: TimeInterval = 10 * 60
    static let geocodeLifetime: TimeInterval = 24 * 3_600

    private var sources: Sources?
    private var forecasts: [String: WeatherForecast] = [:]
    private var pending: [String: Task<WeatherForecast, Error>] = [:]
    private var geocoded: [String: (result: Geocoded, at: Date)] = [:]

    init(sources: Sources? = nil) {
        self.sources = sources
    }

    func setSources(_ sources: Sources?) {
        self.sources = sources
        forecasts = [:]
        pending = [:]
        geocoded = [:]
    }

    /// A reply's card, or nil when it had no weather block.
    static func resolve(_ proposal: WeatherBlockProposal?, context: Context?) async -> WeatherCard? {
        guard let proposal, let context else { return nil }
        return await shared.resolve(proposal, context: context)
    }

    func resolve(_ proposal: WeatherBlockProposal, context: Context, now: Date = Date()) async -> WeatherCard {
        let named = proposal.place.flatMap(WeatherBlock.clean)
        let place: String
        let note: String?
        let coordinate: Coordinate
        if let named {
            let known = [context.device, context.mac].compactMap { $0 }.first { Self.samePlace(named, $0.label) }
            note = known?.note
            place = Self.displayName(named)
            if let parsed = Self.coordinate(in: named) {
                coordinate = parsed
            } else if let found = await geocode(named) {
                coordinate = found.coordinate
            } else if let known {
                coordinate = known.coordinate
            } else {
                return .unavailable(place: place, reason: "Couldn't find “\(place)” to get its forecast.", unit: context.unit)
            }
        } else if let known = context.device ?? context.mac {
            place = known.label.map(Self.displayName) ?? (context.device != nil ? "Your location" : "The Mac's location")
            note = known.note
            coordinate = known.coordinate
        } else {
            return .unavailable(place: "Weather",
                                reason: "No place to forecast: name a place, or share this device's location.",
                                unit: context.unit)
        }
        do {
            let forecast = try await forecast(at: coordinate.rounded, unit: context.unit, now: now)
            return forecast.card(place: place, note: note, unit: context.unit, now: now)
        } catch {
            return .unavailable(place: place, note: note,
                                reason: "Couldn't get the forecast from Open-Meteo. Ask again in a moment.",
                                unit: context.unit)
        }
    }

    private func forecast(at coordinate: Coordinate, unit: String, now: Date) async throws -> WeatherForecast {
        let key = String(format: "%.2f,%.2f,%@", coordinate.latitude, coordinate.longitude, unit)
        if let cached = forecasts[key], abs(now.timeIntervalSince(cached.fetchedAt)) < Self.forecastLifetime {
            return cached
        }
        if let running = pending[key] { return try await running.value }
        let source = activeSources
        let task = Task { try await source.forecast(coordinate, unit) }
        pending[key] = task
        defer { pending[key] = nil }
        let fresh = try await task.value
        forecasts[key] = fresh
        if forecasts.count > 64,
           let oldest = forecasts.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            forecasts.removeValue(forKey: oldest)
        }
        return fresh
    }

    private func geocode(_ place: String) async -> Geocoded? {
        let key = place.lowercased()
        if let hit = geocoded[key], Date().timeIntervalSince(hit.at) < Self.geocodeLifetime { return hit.result }
        guard let found = await activeSources.geocode(place) else { return nil }
        geocoded[key] = (found, Date())
        return found
    }

    private var activeSources: Sources {
        if let sources { return sources }
        // Tests never reach the network: a forecast there is "unavailable" unless a test supplies one.
        if ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"] != nil {
            return Sources(geocode: { _ in nil }, forecast: { _, _ in throw URLError(.notConnectedToInternet) })
        }
        return Self.live
    }

    /// "Your iPhone's location", "Your browser's location".
    static func deviceNote(_ device: String?) -> String {
        guard let device, !device.isEmpty else { return "Your device's location" }
        return "Your \(device)'s location"
    }

    // MARK: Matching places

    /// "Seattle, WA" and "Seattle, WA, United States (47.61, -122.33)" are the same place.
    static func samePlace(_ named: String, _ label: String?) -> Bool {
        guard let label else { return false }
        func city(_ text: String) -> String {
            let plain = text.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            return (plain.split(separator: ",").first.map(String.init) ?? plain)
                .trimmingCharacters(in: .whitespaces).lowercased()
        }
        let a = city(named), b = city(label)
        return !a.isEmpty && a == b
    }

    /// The card's title: without coordinates in parentheses or a trailing "United States".
    static func displayName(_ raw: String) -> String {
        var parts = raw.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count > 1, let last = parts.last?.lowercased(),
           ["united states", "united states of america", "usa", "us"].contains(last) {
            parts.removeLast()
        }
        let name = parts.joined(separator: ", ")
        return name.isEmpty ? raw : String(name.prefix(80))
    }

    /// "47.61, -122.33" as a place.
    static func coordinate(in text: String) -> Coordinate? {
        let numbers = text.replacingOccurrences(of: #"[()]"#, with: "", options: .regularExpression)
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard numbers.count == 2, let latitude = Double(numbers[0]), let longitude = Double(numbers[1]),
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    // MARK: Live sources

    static let live = Sources(
        geocode: { place in await geocodeLive(place) },
        forecast: { coordinate, unit in try await fetchOpenMeteo(coordinate, unit: unit) }
    )

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    static func forecastURL(_ coordinate: Coordinate, unit: String) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "temperature_unit", value: unit == "C" ? "celsius" : "fahrenheit"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(WeatherCard.dayCount)),
            URLQueryItem(name: "forecast_hours", value: String(WeatherCard.hourCount + 2)),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        return components.url!
    }

    private static func fetchOpenMeteo(_ coordinate: Coordinate, unit: String) async throws -> WeatherForecast {
        let (data, response) = try await session.data(from: forecastURL(coordinate, unit: unit))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 512 * 1024 else {
            throw URLError(.badServerResponse)
        }
        return try WeatherForecast.parse(data, fetchedAt: Date())
    }

    @MainActor
    private static func geocodeLive(_ place: String) async -> Geocoded? {
        let geocoder = CLGeocoder()
        let found: CLLocation? = await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask { @MainActor in try? await geocoder.geocodeAddressString(place).first?.location }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        geocoder.cancelGeocode()
        guard let coordinate = found?.coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return Geocoded(coordinate: Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    // MARK: Guidance

    /// Taught to every backend in tabs (system message) and in Cantrip Home's protocol.
    static func agentGuidance(command: String) -> String {
        """
        When the user asks about the weather (now, today, this week, rain, snow, temperature, \
        what to wear), end your reply with a fenced `weather` JSON block naming the place, so \
        Cantrip can show a forecast card under your text:
        ```weather
        {"place":"Santa Clara, CA"}
        ```
        Use the place the user asked about; otherwise where they are: the device location in the \
        message's context, or the Mac's location. Cantrip fetches the forecast for the card itself \
        (Open-Meteo: now, the next 12 hours and 10 days). For any forecast numbers in your text, run \
        `\(command) weather "Santa Clara, CA"`, which prints exactly what the card will show. Never \
        state temperatures, chances of rain or other forecast figures from anywhere else or from \
        memory; if you can't run the command, leave the numbers to the card. Keep the text short \
        and don't link to weather websites.
        """
    }

    /// Fahrenheit unless the Mac is set to Celsius (System Settings › Language & Region).
    static var preferredUnit: String {
        switch UserDefaults.standard.string(forKey: "AppleTemperatureUnit") {
        case "Celsius": return "C"
        case "Fahrenheit": return "F"
        default: return Locale.current.measurementSystem == .us ? "F" : "C"
        }
    }
}

// MARK: - Link previews under a weather card

/// A weather card replaces links to weather sites: their previews would only repeat it.
enum WeatherLinkFilter {
    static let weatherHosts: Set<String> = [
        "wunderground.com", "timeanddate.com", "noaa.gov", "windy.com", "ventusky.com", "meteoblue.com",
        "open-meteo.com", "metoffice.gov.uk", "yr.no", "windfinder.com", "meteo.fr",
    ]

    static func isWeatherSite(_ url: URL, label: String? = nil, title: String? = nil) -> Bool {
        let host = (url.host ?? "").lowercased()
        if host.contains("weather") || weatherHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        let path = url.path.lowercased()
        if path.contains("weather") || path.contains("forecast") { return true }
        return [label, title].compactMap { $0?.lowercased() }.contains {
            $0.contains("weather") || $0.contains("forecast")
        }
    }

    static func visible(_ previews: [LinkPreviewCard], weatherCard: WeatherCard?) -> [LinkPreviewCard] {
        guard weatherCard != nil else { return previews }
        return previews.filter { preview in
            guard let url = URL(string: preview.url) else { return true }
            return !isWeatherSite(url, title: preview.title + " " + (preview.siteName ?? ""))
        }
    }

    static func uncovered(_ links: [LinkPreviewExtractor.Link], hasWeatherCard: Bool) -> [LinkPreviewExtractor.Link] {
        hasWeatherCard ? links.filter { !isWeatherSite($0.url, label: $0.label) } : links
    }
}

// MARK: - Mac card view

struct WeatherCardView: View {
    let card: WeatherCard

    static let panel = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let rain = Color(red: 0.49, green: 0.77, blue: 1.0)

    var body: some View {
        let presented = WeatherPresentation(card)
        VStack(alignment: .leading, spacing: 0) {
            header(presented)
            if card.isAvailable {
                Divider().overlay(Color.white.opacity(0.1))
                hourly(presented)
                Divider().overlay(Color.white.opacity(0.1))
                daily(presented)
            }
            Divider().overlay(Color.white.opacity(0.1))
            footer
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 680, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.13, green: 0.19, blue: 0.28), Self.panel],
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
    }

    private func header(_ presented: WeatherPresentation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(card.place).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                if let note = card.placeNote {
                    Label(note, systemImage: "location.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.72))
                }
                if card.isAvailable, let current = card.current {
                    Text(presented.condition).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                    Text(detailLine(current)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                } else {
                    Label("Forecast unavailable", systemImage: "exclamationmark.icloud")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.top, 4)
                    Text(card.unavailable ?? "Ask again in a moment.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                }
            }
            Spacer(minLength: 8)
            if card.isAvailable, let current = card.current {
                HStack(spacing: 6) {
                    Image(systemName: presented.symbol).symbolRenderingMode(.multicolor).font(.system(size: 26))
                    Text("\(current.temperature)°").font(.system(size: 38, weight: .light)).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Now \(current.temperature) \(WeatherPresentation.unitName(card.unit)), \(presented.condition)")
            }
        }
        .padding(14)
    }

    private func detailLine(_ current: WeatherCard.Current) -> String {
        var parts: [String] = []
        if let today = card.days.first {
            parts.append("H \(today.high)°  L \(today.low)°")
            if let chance = today.precipitationChance { parts.append("\(chance)% precip.") }
        }
        if let feels = current.feelsLike, abs(feels - current.temperature) >= 3 { parts.append("Feels like \(feels)°") }
        return parts.joined(separator: " · ")
    }

    private func hourly(_ presented: WeatherPresentation) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(presented.hours.enumerated()), id: \.offset) { _, hour in
                    VStack(spacing: 5) {
                        Text(hour.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        Image(systemName: hour.symbol).symbolRenderingMode(.multicolor).font(.system(size: 17))
                            .frame(height: 20)
                        Text(chanceText(hour.precipitationChance))
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Self.rain)
                        Text("\(hour.temperature)°").font(.system(size: 13.5, weight: .semibold)).monospacedDigit()
                    }
                    .frame(width: 48)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(hourLabel(hour))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }

    private func daily(_ presented: WeatherPresentation) -> some View {
        let lowest = presented.days.map(\.low).min() ?? 0
        let highest = presented.days.map(\.high).max() ?? 1
        return VStack(spacing: 0) {
            ForEach(Array(presented.days.enumerated()), id: \.offset) { index, day in
                HStack(spacing: 10) {
                    Text(day.label).font(.system(size: 13, weight: .medium)).frame(width: 46, alignment: .leading)
                    Image(systemName: day.symbol).symbolRenderingMode(.multicolor).font(.system(size: 15))
                        .frame(width: 24)
                    Text(chanceText(day.precipitationChance))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Self.rain)
                        .frame(width: 34, alignment: .leading)
                    Text("\(day.low)°").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit().frame(width: 34, alignment: .trailing)
                    WeatherRangeBar(low: day.low, high: day.high, lowest: lowest, highest: highest)
                        .frame(height: 5)
                    Text("\(day.high)°").font(.system(size: 13, weight: .semibold))
                        .monospacedDigit().frame(width: 34, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(dayLabel(day))
                if index < presented.days.count - 1 {
                    Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 14)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let updated = card.updatedAt {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
            }
            Spacer(minLength: 6)
            Button(WeatherCard.attribution) {
                if let url = URL(string: WeatherCard.attributionURL) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.plain)
            .underline()
            .accessibilityAddTraits(.isLink)
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.68))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func chanceText(_ chance: Int?) -> String {
        guard let chance, chance >= 10 else { return " " }
        return "\(chance)%"
    }

    private func hourLabel(_ hour: WeatherPresentation.Hour) -> String {
        var text = "\(hour.label), \(hour.temperature) \(WeatherPresentation.unitName(card.unit)), \(hour.condition)"
        if let chance = hour.precipitationChance, chance >= 10 { text += ", \(chance) percent chance of precipitation" }
        return text
    }

    private func dayLabel(_ day: WeatherPresentation.Day) -> String {
        var text = "\(day.label), \(day.condition), high \(day.high), low \(day.low) \(WeatherPresentation.unitName(card.unit))"
        if let chance = day.precipitationChance, chance >= 10 { text += ", \(chance) percent chance of precipitation" }
        return text
    }
}

/// A day's low-to-high span on the week's scale, like the map card's other compact chrome.
struct WeatherRangeBar: View {
    let low: Int
    let high: Int
    let lowest: Int
    let highest: Int

    var body: some View {
        GeometryReader { geometry in
            let span = Double(max(1, highest - lowest))
            let start = Double(low - lowest) / span
            let end = Double(high - lowest) / span
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.78, blue: 0.98),
                                                  Color(red: 1.0, green: 0.80, blue: 0.25)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(5, geometry.size.width * (end - start)))
                    .offset(x: geometry.size.width * start)
            }
        }
        .accessibilityHidden(true)
    }
}
