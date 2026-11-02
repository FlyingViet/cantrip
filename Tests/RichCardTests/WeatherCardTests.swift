import Foundation

extension RichCardTests {
    static func testWeatherCards() async throws {
        testWeatherBlockExtraction()
        try testWeatherForecastParsing()
        try await testWeatherResolver()
        testWeatherLinkFilter()
        print("Weather cards: block parsing, Open-Meteo parsing, place choice, caching, unavailable states and link filtering passed")
    }

    static func testWeatherBlockExtraction() {
        var text = """
        It's clear in Seattle today.

        ```weather
        {"place":"Seattle, WA"}
        ```
        """
        precondition(WeatherBlock.extract(from: &text) == WeatherBlockProposal(place: "Seattle, WA"))
        precondition(text == "It's clear in Seattle today.", text)

        var empty = "Here you go.\n```cantrip-weather\n{}\n```"
        precondition(WeatherBlock.extract(from: &empty) == WeatherBlockProposal(place: nil), "{} means where the user is")
        precondition(empty == "Here you go.")
        precondition(WeatherBlock.decode(#""Tokyo""#) == WeatherBlockProposal(place: "Tokyo"))
        precondition(WeatherBlock.decode(#"{"near":"Austin, TX"}"#) == WeatherBlockProposal(place: "Austin, TX"))
        precondition(WeatherBlock.decode(#"{"place":"Paris\n\t France"}"#) == WeatherBlockProposal(place: "Paris France"))
        precondition(WeatherBlock.decode(#"{"place":"\#(String(repeating: "x", count: 300))"}"#)?.place?.count == 120)
        precondition(WeatherBlock.decode("not json") == nil && WeatherBlock.decode("[1,2]") == nil)

        var broken = "Text\n```weather\n{oops\n```\nMore"
        precondition(WeatherBlock.extract(from: &broken) == nil, "a malformed block makes no card")
        precondition(!broken.contains("oops"), "and still never shows")
        var two = "```weather\n{\"place\":\"A\"}\n```\nmid\n```weather\n{\"place\":\"B\"}\n```"
        precondition(WeatherBlock.extract(from: &two)?.place == "B" && two == "mid")
        var none = "```swift\nlet weather = 1\n```"
        precondition(WeatherBlock.extract(from: &none) == nil && none.contains("let weather"))
    }

    static func seattleFixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("open-meteo-seattle.json"))
    }

    /// 2:15 PM PST on Sunday, November 1, 2026: the fixture's "current" time.
    static let fixtureNow = Date(timeIntervalSince1970: 1_793_571_300)

    static func testWeatherForecastParsing() throws {
        let forecast = try WeatherForecast.parse(try seattleFixture(), fetchedAt: fixtureNow)
        precondition(forecast.timeZone == "America/Los_Angeles")
        precondition(forecast.current == WeatherCard.Current(temperature: 48, feelsLike: 45, code: 0, isDay: true,
                                                             precipitationChance: 0), "\(forecast.current)")
        precondition(forecast.days.count == 10 && forecast.days[0].date == "2026-11-01"
                     && forecast.days[0].high == 48 && forecast.days[0].low == 38 && forecast.days[0].code == 45
                     && forecast.days[3].precipitationChance == 62, "\(forecast.days.prefix(4))")
        precondition(forecast.hours.count == 14)
        do {
            _ = try WeatherForecast.parse(Data(#"{"error":true,"reason":"bad"}"#.utf8), fetchedAt: fixtureNow)
            preconditionFailure("an error answer is not a forecast")
        } catch is WeatherForecast.Malformed {}

        let card = forecast.card(place: "Seattle, WA", note: "Your iPhone's location", unit: "F", now: fixtureNow)
        precondition(card.isAvailable && card.hours.count == 12 && card.days.count == 10)
        precondition(card.hours.allSatisfy { $0.time > fixtureNow }, "the strip starts after now")
        let presented = WeatherPresentation(card, locale: Locale(identifier: "en_US"))
        let hourLabels = presented.hours.map { $0.label.replacingOccurrences(of: "\u{202F}", with: " ") }
        precondition(presented.hours.count == 13 && hourLabels[0] == "Now" && hourLabels[1] == "3 PM"
                     && hourLabels[12] == "2 AM", "\(hourLabels)")
        precondition(presented.days[0].label == "Today" && presented.days[1].label == "Mon"
                     && presented.days[0].condition == "Fog" && presented.days[0].symbol == "cloud.fog.fill")
        precondition(presented.condition == "Clear" && presented.symbol == "sun.max.fill")
        precondition(WeatherCondition.symbol(0, isDay: false) == "moon.stars.fill"
                     && WeatherCondition.symbol(95, isDay: true) == "cloud.bolt.rain.fill"
                     && WeatherCondition.text(73) == "Snow" && WeatherCondition.text(12) == "Unknown")

        let snapshot = card.snapshot
        precondition(snapshot["status"] as? String == "ok" && snapshot["place"] as? String == "Seattle, WA"
                     && snapshot["placeNote"] as? String == "Your iPhone's location" && snapshot["unit"] as? String == "F"
                     && snapshot["attribution"] as? String == "Weather data by Open-Meteo.com"
                     && snapshot["timeZone"] as? String == "America/Los_Angeles")
        let current = snapshot["current"] as! [String: Any]
        precondition(current["temperature"] as? Int == 48 && current["symbol"] as? String == "sun.max.fill"
                     && current["condition"] as? String == "Clear" && current["feelsLike"] as? Int == 45)
        let today = snapshot["today"] as! [String: Any]
        precondition(today["high"] as? Int == 48 && today["low"] as? Int == 38 && today["precipitationChance"] as? Int == 1)
        let hourly = snapshot["hourly"] as! [[String: Any]], daily = snapshot["daily"] as! [[String: Any]]
        precondition(hourly.count == 13 && hourly[0]["label"] as? String == "Now" && daily.count == 10
                     && daily[0]["label"] as? String == "Today" && daily[0]["date"] as? String == "2026-11-01")
        let encoded = try JSONSerialization.data(withJSONObject: snapshot)
        precondition(encoded.count < 8 * 1024, "the snapshot stays small: \(encoded.count)")

        let decoded = try JSONDecoder().decode(WeatherCard.self, from: JSONEncoder().encode(card))
        precondition(decoded == card, "cards survive the transcript")

        let summary = card.textSummary
        precondition(summary.contains("Weather for Seattle, WA (Your iPhone's location), from Open-Meteo")
                     && summary.contains("Now: 48°F, clear, feels like 45°F")
                     && summary.contains("Today: high 48°F, low 38°F") && summary.contains("Next 12 hours: ")
                     && summary.contains("Next 10 days: ") && summary.contains("quote only these"), summary)

        let missing = WeatherCard.unavailable(place: "Atlantis", reason: "Couldn't find “Atlantis”.", unit: "F")
        let missingSnapshot = missing.snapshot
        precondition(!missing.isAvailable && missingSnapshot["status"] as? String == "unavailable"
                     && missingSnapshot["message"] as? String == "Couldn't find “Atlantis”."
                     && missingSnapshot["current"] == nil && missingSnapshot["hourly"] == nil)
        precondition(missing.textSummary.contains("forecast unavailable") && !missing.textSummary.contains("°"))
    }

    final class WeatherCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var forecasts: [WeatherCardResolver.Coordinate] = []
        private var geocodes: [String] = []
        func forecast(_ coordinate: WeatherCardResolver.Coordinate) { lock.withLock { forecasts.append(coordinate) } }
        func geocode(_ place: String) { lock.withLock { geocodes.append(place) } }
        var forecastCalls: [WeatherCardResolver.Coordinate] { lock.withLock { forecasts } }
        var geocodeCalls: [String] { lock.withLock { geocodes } }
    }

    static func testWeatherResolver() async throws {
        let fixture = try seattleFixture()
        let calls = WeatherCalls()
        let failing = WeatherCalls()
        let resolver = WeatherCardResolver(sources: .init(
            geocode: { place in
                calls.geocode(place)
                return place.lowercased().hasPrefix("seattle")
                    ? .init(coordinate: .init(latitude: 47.6062, longitude: -122.3321)) : nil
            },
            forecast: { coordinate, unit in
                precondition(unit == "F")
                calls.forecast(coordinate)
                return try WeatherForecast.parse(fixture, fetchedAt: fixtureNow)
            }
        ))
        let iPhone = WeatherCardResolver.KnownPlace(label: "Seattle, WA, United States",
                                                     coordinate: .init(latitude: 47.67, longitude: -122.38),
                                                     note: WeatherCardResolver.deviceNote("iPhone"))
        let mac = WeatherCardResolver.KnownPlace(label: "Santa Clara, CA, United States",
                                                  coordinate: .init(latitude: 37.354, longitude: -121.957),
                                                  note: "The Mac's location")
        let fromPhone = WeatherCardResolver.Context(device: iPhone, mac: mac, unit: "F")

        // The reply names the device's place: geocoded like `cantrip weather` would, noted as the device's.
        let named = await resolver.resolve(.init(place: "Seattle, WA, United States (47.67, -122.38)"),
                                           context: fromPhone, now: fixtureNow)
        precondition(named.isAvailable && named.place == "Seattle, WA" && named.placeNote == "Your iPhone's location",
                     "\(named.place) \(String(describing: named.placeNote))")
        precondition(calls.forecastCalls == [.init(latitude: 47.61, longitude: -122.33)], "only ~1 km coordinates leave the Mac")

        // Within 10 minutes the same place reuses the forecast; after that it's fetched again.
        _ = await resolver.resolve(.init(place: "Seattle, WA"), context: fromPhone, now: fixtureNow.addingTimeInterval(300))
        precondition(calls.forecastCalls.count == 1 && calls.geocodeCalls.count == 2, "\(calls.geocodeCalls)")
        _ = await resolver.resolve(.init(place: "Seattle, WA"), context: fromPhone, now: fixtureNow.addingTimeInterval(660))
        precondition(calls.forecastCalls.count == 2)
        _ = await resolver.resolve(.init(place: "seattle, wa"), context: fromPhone, now: fixtureNow.addingTimeInterval(700))
        precondition(calls.geocodeCalls.count == 2, "places are geocoded once a day")

        // No place: the device, else the Mac, else nothing to forecast.
        let here = await resolver.resolve(.init(place: nil), context: fromPhone, now: fixtureNow)
        precondition(here.place == "Seattle, WA" && here.placeNote == "Your iPhone's location"
                     && calls.forecastCalls.last == .init(latitude: 47.67, longitude: -122.38))
        let macOnly = await resolver.resolve(.init(place: nil), context: .init(device: nil, mac: mac, unit: "F"),
                                             now: fixtureNow)
        precondition(macOnly.place == "Santa Clara, CA" && macOnly.placeNote == "The Mac's location" && macOnly.isAvailable)
        let nowhere = await resolver.resolve(.init(place: nil), context: .init(device: nil, mac: nil, unit: "F"),
                                             now: fixtureNow)
        precondition(!nowhere.isAvailable && nowhere.unavailable?.hasPrefix("No place to forecast") == true)

        // A place the geocoder can't find: the device's or Mac's own coordinates when it's theirs, else unavailable.
        let macNamed = await resolver.resolve(.init(place: "Santa Clara, CA"), context: fromPhone, now: fixtureNow)
        precondition(macNamed.isAvailable && macNamed.placeNote == "The Mac's location"
                     && calls.forecastCalls.last == .init(latitude: 37.35, longitude: -121.96))
        let unknown = await resolver.resolve(.init(place: "Atlantis"), context: fromPhone, now: fixtureNow)
        precondition(!unknown.isAvailable && unknown.place == "Atlantis"
                     && unknown.unavailable == "Couldn't find “Atlantis” to get its forecast.")
        let coordinates = await resolver.resolve(.init(place: "47.6062, -122.3321"), context: fromPhone, now: fixtureNow)
        precondition(coordinates.isAvailable && coordinates.place == "47.6062, -122.3321"
                     && WeatherCardResolver.coordinate(in: "47.6062, -122.3321")?.rounded == .init(latitude: 47.61, longitude: -122.33))

        // Open-Meteo down: the card says so and shows no numbers.
        let down = WeatherCardResolver(sources: .init(
            geocode: { _ in .init(coordinate: .init(latitude: 1, longitude: 2)) },
            forecast: { coordinate, _ in failing.forecast(coordinate); throw URLError(.timedOut) }
        ))
        let failed = await down.resolve(.init(place: "Seattle, WA"), context: fromPhone, now: fixtureNow)
        precondition(!failed.isAvailable && failed.place == "Seattle, WA" && failed.placeNote == "Your iPhone's location"
                     && failed.current == nil && failed.days.isEmpty
                     && failed.unavailable == "Couldn't get the forecast from Open-Meteo. Ask again in a moment.")
        _ = await down.resolve(.init(place: "Seattle, WA"), context: fromPhone, now: fixtureNow)
        precondition(failing.forecastCalls.count == 2, "a failure isn't cached")

        precondition(WeatherCardResolver.displayName("Paris, Île-de-France, France") == "Paris, Île-de-France, France")
        precondition(WeatherCardResolver.samePlace("SEATTLE", "Seattle, WA (47.61, -122.33)")
                     && !WeatherCardResolver.samePlace("Tacoma, WA", "Seattle, WA"))
        let urls = WeatherCardResolver.forecastURLs(.init(latitude: 47.61, longitude: -122.33), unit: "C")
        let now = urls.now.absoluteString, daily = urls.daily.absoluteString
        precondition(now.hasPrefix("https://api.open-meteo.com/v1/forecast?latitude=47.61&longitude=-122.33")
                     && now.contains("current=") && now.contains("hourly=") && !now.contains("daily=")
                     && daily.contains("daily=") && !daily.contains("current=") && !daily.contains("hourly=")
                     && [now, daily].allSatisfy { $0.contains("temperature_unit=celsius") && $0.contains("forecast_days=10")
                         && $0.contains("timeformat=unixtime") && !$0.contains("forecast_hours") }, now + " " + daily)
        let combined = try WeatherCardResolver.merged(
            now: Data(#"{"timezone":"UTC","current":{"temperature_2m":1}}"#.utf8),
            daily: Data(#"{"daily":{"time":[1]}}"#.utf8))
        let object = try JSONSerialization.jsonObject(with: combined) as! [String: Any]
        precondition(object["current"] != nil && (object["daily"] as? [String: Any])?["time"] != nil)
    }

    static func testWeatherLinkFilter() {
        let weatherLinks = [
            "https://weather.com/weather/today/l/Seattle+WA", "https://www.accuweather.com/en/us/seattle/98104/weather-forecast/351409",
            "https://www.wunderground.com/forecast/us/wa/seattle", "https://forecast.weather.gov/MapClick.php?lat=47.6",
            "https://www.timeanddate.com/weather/usa/seattle", "https://www.weathercentral.com/weather/us/wa/seattle",
        ]
        for raw in weatherLinks {
            precondition(WeatherLinkFilter.isWeatherSite(URL(string: raw)!), raw)
        }
        precondition(WeatherLinkFilter.isWeatherSite(URL(string: "https://example.com/today")!, label: "Seattle forecast"))
        precondition(!WeatherLinkFilter.isWeatherSite(URL(string: "https://www.yelp.com/biz/cafe-seattle")!, label: "Cafe"))

        let links = [
            LinkPreviewExtractor.Link(url: URL(string: weatherLinks[1])!, label: "AccuWeather"),
            LinkPreviewExtractor.Link(url: URL(string: "https://www.seattle.gov/parks")!, label: "Parks"),
        ]
        precondition(WeatherLinkFilter.uncovered(links, hasWeatherCard: true).map(\.label) == ["Parks"])
        precondition(WeatherLinkFilter.uncovered(links, hasWeatherCard: false).count == 2)
        let previews = [
            LinkPreviewCard(id: "a", url: weatherLinks[0], domain: "weather.com", title: "Seattle, WA 10-Day Forecast"),
            LinkPreviewCard(id: "b", url: "https://www.seattle.gov/parks", domain: "seattle.gov", title: "Seattle Parks"),
        ]
        let card = WeatherCard.unavailable(place: "Seattle, WA", reason: "x", unit: "F")
        precondition(WeatherLinkFilter.visible(previews, weatherCard: card).map(\.id) == ["b"])
        precondition(WeatherLinkFilter.visible(previews, weatherCard: nil).count == 2)
    }
}
