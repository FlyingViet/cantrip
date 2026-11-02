import Foundation
import XCTest
@testable import Hermes

/// `weatherCard` as the Mac sends it (`WeatherCard.snapshot`): decoded leniently, never failing
/// the message, and shown with spoken labels.
final class CantripWeatherCardTests: XCTestCase {
    private let snapshot = #"""
    {"attribution":"Weather data by Open-Meteo.com","attributionURL":"https://open-meteo.com/",
     "current":{"code":0,"condition":"Clear","feelsLike":45,"isDay":true,"precipitationChance":0,"symbol":"sun.max.fill","temperature":48},
     "daily":[{"condition":"Fog","date":"2026-11-01","high":48,"label":"Today","low":38,"precipitationChance":1,"symbol":"cloud.fog.fill"},
              {"condition":"Cloudy","date":"2026-11-02","high":53,"label":"Mon","low":35,"precipitationChance":8,"symbol":"cloud.fill"},
              {"condition":"Showers","date":"2026-11-03","high":55,"label":"Tue","low":43,"precipitationChance":62,"symbol":"cloud.sun.rain.fill"}],
     "hourly":[{"condition":"Clear","label":"Now","precipitationChance":0,"symbol":"sun.max.fill","temperature":48,"time":"2026-11-01T22:15:00Z"},
               {"condition":"Light rain","label":"3 PM","precipitationChance":40,"symbol":"cloud.rain.fill","temperature":47,"time":"2026-11-01T23:00:00Z"}],
     "place":"Seattle, WA","placeNote":"Your iPhone's location","status":"ok","timeZone":"America/Los_Angeles",
     "today":{"high":48,"low":38,"precipitationChance":1},"unit":"F","updatedAt":"2026-11-01T22:15:00Z"}
    """#

    private func decode(_ json: String) throws -> CantripWeatherCard {
        try JSONDecoder().decode(CantripWeatherCard.self, from: Data(json.utf8))
    }

    func testDecodesTheMacSnapshot() throws {
        let card = try decode(snapshot)
        XCTAssertTrue(card.isAvailable)
        XCTAssertEqual(card.place, "Seattle, WA")
        XCTAssertEqual(card.placeNote, "Your iPhone's location")
        XCTAssertEqual(card.current?.temperature, 48)
        XCTAssertEqual(card.current?.symbol, "sun.max.fill")
        XCTAssertEqual(card.hourly.map(\.label), ["Now", "3 PM"])
        XCTAssertEqual(card.daily.map(\.label), ["Today", "Mon", "Tue"])
        XCTAssertEqual(card.updatedAt, ISO8601DateFormatter().date(from: "2026-11-01T22:15:00Z"))
        XCTAssertEqual(card.detailLine, "H 48°  L 38° · 1% precip. · Feels like 45°")
        XCTAssertEqual(card.attributionURL.absoluteString, "https://open-meteo.com/")

        let restored = try JSONDecoder().decode(CantripWeatherCard.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(restored, card, "a saved chat turn keeps its card")
    }

    func testSpokenLabelsAndRanges() throws {
        let card = try decode(snapshot)
        XCTAssertEqual(card.spokenHour(card.hourly[1]),
                       "3 PM, 47 degrees Fahrenheit, Light rain, 40 percent chance of precipitation")
        XCTAssertEqual(card.spokenHour(card.hourly[0]), "Now, 48 degrees Fahrenheit, Clear")
        XCTAssertEqual(card.spokenDay(card.daily[2]),
                       "Tue, Showers, high 55, low 43 degrees Fahrenheit, 62 percent chance of precipitation")
        XCTAssertNil(CantripWeatherCard.chanceText(8))
        XCTAssertEqual(CantripWeatherCard.chanceText(62), "62%")
        // The 10 days run from 35° to 55°: Tuesday's 43-55 bar covers the top 60%.
        let tuesday = card.range(of: card.daily[2])
        XCTAssertEqual(tuesday.lowerBound, 0.4, accuracy: 0.001)
        XCTAssertEqual(tuesday.upperBound, 1.0, accuracy: 0.001)
        XCTAssertEqual(card.range(of: card.daily[1]).lowerBound, 0, accuracy: 0.001)
    }

    func testUnavailableAndMalformedCardsNeverFailTheMessage() throws {
        let unavailable = try decode(#"""
        {"place":"Seattle, WA","status":"unavailable","message":"Couldn't get the forecast from Open-Meteo. Ask again in a moment.","unit":"F"}
        """#)
        XCTAssertFalse(unavailable.isAvailable)
        XCTAssertEqual(unavailable.message, "Couldn't get the forecast from Open-Meteo. Ask again in a moment.")
        XCTAssertNil(unavailable.current)

        let mangled = try decode(#"""
        {"place":42,"status":"ok","current":{"temperature":"hot"},"hourly":"soon","daily":[{"label":1}],
         "attributionURL":"https://tracker.example/x"}
        """#)
        XCTAssertFalse(mangled.isAvailable, "no number the Mac didn't send")
        XCTAssertEqual(mangled.place, "Weather")
        XCTAssertTrue(mangled.hourly.isEmpty && mangled.daily.isEmpty)
        XCTAssertEqual(mangled.attributionURL.absoluteString, "https://open-meteo.com/", "the link only goes to Open-Meteo")
        XCTAssertNoThrow(try decode("[1,2,3]"))
    }

    func testRemoteMessageCarriesTheCard() throws {
        let message = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data("""
        {"id":"m1","role":"assistant","text":"Clear in Seattle today.","thinking":"","activities":[],"weatherCard":\(snapshot)}
        """.utf8))
        XCTAssertEqual(message.weatherCard?.place, "Seattle, WA")
        let broken = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data("""
        {"id":"m2","role":"assistant","text":"Here.","thinking":"","activities":[],"weatherCard":{"current":{"temperature":"x"}}}
        """.utf8))
        XCTAssertEqual(broken.text, "Here.")
        XCTAssertEqual(broken.weatherCard?.isAvailable, false)
    }
}
