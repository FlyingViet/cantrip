import Foundation
import XCTest
@testable import Hermes

/// `cards` as the Mac sends them (docs/cards.md in the Cantrip repo): blocks decoded leniently,
/// older Macs' separate weather, place and link fields drawn as the same blocks, and actions
/// that only ever open web pages or phone numbers.
final class CantripCardTests: XCTestCase {
    private let flights = #"""
    {"version":1,"id":"flights-1","type":"flights","accessibilityLabel":"Flights SFO to SEA",
     "fallbackText":"SFO → SEA",
     "source":{"kind":"tool","name":"Kiwi.com","attribution":"Flights from Kiwi.com","url":"https://www.kiwi.com/","updatedAt":"2026-11-02T00:32:44Z"},
     "blocks":[{"type":"header","title":"SFO → SEA","subtitle":"Sun, Nov 15 · 1 traveler","symbol":"airplane"},
               {"type":"list","items":[{"id":"a","title":"Alaska Airlines · AS630","subtitle":"3:08 PM → 5:21 PM · 2h 13m · Nonstop",
                 "trailing":"258 USD","symbol":"airplane","badges":[{"text":"Cheapest","tone":"positive"}],
                 "actions":[{"kind":"open","label":"Book","url":"https://kiwi.com/u/hqtj9x"}],
                 "accessibilityLabel":"Alaska Airlines · AS630, price 258 USD, Cheapest"}]}]}
    """#

    private let places = #"""
    {"version":1,"id":"places-p1","type":"places","accessibilityLabel":"Places for Matcha cafes",
     "blocks":[{"type":"map","latitude":37.35,"longitude":-121.95,"latitudeDelta":0.06,"longitudeDelta":0.06,
                "pins":[{"id":"p1","title":"Matcha Cafe Maiko","latitude":37.3496,"longitude":-121.9389,"symbol":"cup.and.saucer.fill","glyph":"☕"},
                        {"id":"bad","title":"Nowhere","latitude":120,"longitude":0}]},
               {"type":"list","mapLinked":true,"title":"Matcha cafes","items":[{"id":"p1","pinID":"p1","title":"Matcha Cafe Maiko",
                 "actions":[{"kind":"directions","label":"Directions","url":"https://maps.apple.com/?q=Maiko"},{"kind":"call","label":"Call","url":"tel:+14085550100"}]}]}]}
    """#

    private func message(_ fields: String) throws -> CantripRemoteMessage {
        try JSONDecoder().decode(CantripRemoteMessage.self, from: Data("""
        {"id":"m1","role":"assistant","text":"Here.","thinking":"","activities":[]\(fields)}
        """.utf8))
    }

    func testDecodesTheMacsCards() throws {
        let reply = try message(#","cards":[\#(flights),\#(places)]"#)
        let cards = try XCTUnwrap(reply.cards)
        XCTAssertEqual(cards.map(\.type), ["flights", "places"])
        XCTAssertEqual(cards[0].blocks.map(\.type), ["header", "list"])
        XCTAssertEqual(cards[0].blocks[1].items?.first?.trailing, "258 USD")
        XCTAssertEqual(cards[0].blocks[1].items?.first?.badges?.first?.tone, "positive")
        XCTAssertEqual(cards[0].source?.attribution, "Flights from Kiwi.com")
        XCTAssertEqual(CantripCardStyle.updatedText(cards[0].source?.updatedAt)?.hasPrefix("Updated "), true)

        let sections = CantripCardPanel.sections(cards[1].blocks)
        XCTAssertEqual(sections.count, 1, "a map and its legend draw as one section")
        guard case .map(let map, let legend) = sections[0] else { return XCTFail("expected the map section") }
        XCTAssertEqual(CantripCardMapView.pins(map).map(\.id), ["p1"], "pins off the globe are dropped")
        XCTAssertEqual(legend?.title, "Matcha cafes")

        let turn = ChatTurn(role: .assistant, text: "Here.", cards: cards)
        let restored = try JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(turn))
        XCTAssertEqual(restored.cards, cards, "a saved chat turn keeps its cards")
    }

    /// Build cards: a progress block the app ticks itself from `startedAt`, with the bar and time left
    /// from the Mac's estimate or the tool's step counter, then the result and total time.
    func testBuildCardProgress() throws {
        let running = #"""
        {"version":1,"id":"build-c1","type":"build","accessibilityLabel":"xcodebuild test · Hermes, Testing",
         "source":{"kind":"build","name":"xcodebuild test · Hermes"},
         "blocks":[{"type":"header","title":"xcodebuild test · Hermes","subtitle":"CantripIOS","symbol":"hammer"},
                   {"type":"progress","status":"running","label":"Testing","tone":"accent","startedAt":"2026-11-04T20:00:00.000Z",
                    "expectedSeconds":185,"detail":"Usually 3m 05s (4 earlier runs)"}]}
        """#
        let reply = try message(#","cards":[\#(running)]"#)
        let card = try XCTUnwrap(reply.cards?.first)
        let block = card.blocks[1]
        XCTAssertEqual(block.type, "progress")
        XCTAssertEqual(block.expectedSeconds, 185)
        XCTAssertEqual(CantripCardPanel.sections(card.blocks).count, 2)
        let start = try XCTUnwrap(CantripCardProgress.date(block.startedAt))
        var progress = CantripCardProgress(block: block, now: start.addingTimeInterval(65))
        XCTAssertTrue(progress.isRunning)
        XCTAssertEqual(progress.elapsed, "1:05")
        XCTAssertEqual(progress.remaining, "About 2:00 left")
        XCTAssertEqual(progress.fraction ?? 0, 65.0 / 185, accuracy: 0.001)
        progress = CantripCardProgress(block: block, now: start.addingTimeInterval(200))
        XCTAssertNil(progress.fraction, "past the estimate the bar is indeterminate")
        XCTAssertEqual(progress.remaining, "Longer than usual")

        var stepped = block
        stepped.fraction = 0.25
        stepped.expectedSeconds = nil
        progress = CantripCardProgress(block: stepped, now: start.addingTimeInterval(30))
        XCTAssertEqual(progress.fraction, 0.25)
        XCTAssertNil(progress.remaining)

        var first = block
        first.expectedSeconds = nil
        progress = CantripCardProgress(block: first, now: start.addingTimeInterval(3_729))
        XCTAssertNil(progress.fraction, "no estimate yet: an indeterminate bar, never a made-up percentage")
        XCTAssertEqual(progress.elapsed, "1:02:09")

        var done = block
        done.status = "failed"
        done.label = "Failed"
        done.tone = "negative"
        done.finishedAt = "2026-11-04T20:00:47.000Z"
        progress = CantripCardProgress(block: done, now: start.addingTimeInterval(9_999))
        XCTAssertFalse(progress.isRunning)
        XCTAssertEqual(progress.elapsed, "0:47")
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertTrue(progress.accessibilityLabel.hasPrefix("Failed, took "))

        var ended = block
        ended.status = "ended"
        progress = CantripCardProgress(block: ended, now: start.addingTimeInterval(60))
        XCTAssertNil(progress.elapsed, "an unknown end shows no made-up duration")
        XCTAssertFalse(progress.showsBar)

        let turn = ChatTurn(role: .assistant, text: "", cards: [card])
        let restored = try JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(turn))
        XCTAssertEqual(restored.cards, [card], "a saved turn keeps its build card")
    }

    /// A reply's builds arrive as one card: the leading build's live progress, a build running
    /// beside it, and earlier steps as rows with their results.
    func testCombinedBuildCard() throws {
        let combined = #"""
        {"version":1,"id":"build-a","type":"build","accessibilityLabel":"xcodebuild test · Hermes, Testing, and 3 other steps",
         "blocks":[{"type":"header","title":"xcodebuild test · Hermes","subtitle":"CantripIOS","symbol":"hammer"},
                   {"type":"progress","status":"running","label":"Testing","tone":"accent","startedAt":"2026-11-04T20:00:00.000Z"},
                   {"type":"progress","status":"running","label":"make build","tone":"accent","startedAt":"2026-11-04T20:00:10.000Z"},
                   {"type":"list","title":"Earlier steps","items":[
                     {"id":"a","title":"xcodebuild build · Hermes","note":"Succeeded","tone":"positive","trailing":"2:21"},
                     {"id":"b","title":"xcodebuild test · Hermes","note":"Failed · Exit code 65","tone":"negative","trailing":"1:37"}]}]}
        """#
        let card = try XCTUnwrap(try message(#","cards":[\#(combined)]"#).cards?.first)
        XCTAssertEqual(card.blocks.map(\.type), ["header", "progress", "progress", "list"])
        XCTAssertEqual(CantripCardPanel.sections(card.blocks).count, 4)
        XCTAssertEqual(card.blocks[2].label, "make build")
        let rows = try XCTUnwrap(card.blocks[3].items)
        XCTAssertEqual(rows.map(\.note), ["Succeeded", "Failed · Exit code 65"])
        XCTAssertEqual(rows.map(\.tone), ["positive", "negative"])
        XCTAssertEqual(rows.map(\.trailing), ["2:21", "1:37"])
    }

    /// Without a fraction the bar's segment sweeps one way, in from past the left end and out past
    /// the right, from the clock: the same moment always draws the same place.
    func testIndeterminateBarSweepsOneWay() {
        let period = CantripCardProgressBar.sweepSeconds
        let width = CantripCardProgressBar.sweepWidth
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(CantripCardProgressBar.sweepOffset(at: start), -width, accuracy: 0.0001, "starts hidden past the left end")
        XCTAssertEqual(CantripCardProgressBar.sweepOffset(at: start.addingTimeInterval(period / 2)), (1 - width) / 2, accuracy: 0.0001)
        XCTAssertEqual(CantripCardProgressBar.sweepOffset(at: start.addingTimeInterval(period * 0.9999)), 1, accuracy: 0.001,
                       "ends gone past the right end")
        var previous = -Double.infinity
        for step in 0..<100 {
            let offset = CantripCardProgressBar.sweepOffset(at: start.addingTimeInterval(period * Double(step) / 100))
            XCTAssertGreaterThan(offset, previous, "never turns back within a pass")
            previous = offset
        }
        XCTAssertEqual(CantripCardProgressBar.sweepOffset(at: start.addingTimeInterval(period)), -width, accuracy: 0.0001,
                       "the next pass starts from the left again")
    }

    func testMalformedCardsNeverFailTheMessage() throws {
        let reply = try message(#"""
        ,"cards":[{"id":"x","blocks":[{"type":"chart","items":[{"label":"Mon","low":"cold","high":50},{"label":"Tue","low":40,"high":55}]},
                                      {"type":"hologram","title":"New"},{"type":"header"},{"type":"image","imageID":"../../etc"},{"title":"no type"},
                                      {"type":"keyValue","rows":"oops"}]},
                  "not a card",
                  {"id":"y","fallbackText":"Just text","blocks":[{"type":"hologram"}]}]
        """#)
        XCTAssertEqual(reply.text, "Here.")
        let cards = try XCTUnwrap(reply.cards)
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].blocks.first?.items?.map(\.label), ["Tue"], "a malformed item drops alone")
        XCTAssertEqual(cards[0].blocks.map(\.type), ["chart", "hologram", "header", "image", "keyValue"])
        XCTAssertEqual(CantripCardPanel.sections(cards[0].blocks).count, 1,
                       "unknown blocks, an empty header, a bad image id and malformed rows draw nothing")
        XCTAssertTrue(cards[1].blocks.isEmpty)
        XCTAssertTrue(CantripCardPanel.sections(cards[2].blocks).isEmpty, "the panel shows its fallback text instead")
        XCTAssertEqual(cards[2].fallbackText, "Just text")
    }

    func testOlderMacsCardsDrawAsTheSameBlocks() throws {
        let weather = try JSONDecoder().decode(CantripWeatherCard.self, from: Data(#"""
        {"place":"Seattle, WA","placeNote":"Your iPhone's location","status":"ok","unit":"F","updatedAt":"2026-11-01T22:15:00Z",
         "current":{"temperature":48,"feelsLike":45,"condition":"Clear","symbol":"sun.max.fill"},"today":{"high":48,"low":38,"precipitationChance":1},
         "hourly":[{"label":"Now","temperature":48,"condition":"Clear","symbol":"sun.max.fill"},
                   {"label":"3 PM","temperature":47,"condition":"Light rain","symbol":"cloud.rain.fill","precipitationChance":40}],
         "daily":[{"date":"2026-11-01","label":"Today","high":48,"low":38,"condition":"Fog","symbol":"cloud.fog.fill"},
                  {"date":"2026-11-02","label":"Mon","high":53,"low":35,"condition":"Cloudy","symbol":"cloud.fill","precipitationChance":62}]}
        """#.utf8))
        let place = CantripPlacePin(id: "p1", name: "Maiko", latitude: 37.35, longitude: -121.94, category: "Cafe", address: "1310 Lafayette St",
                                    phone: "(408) 555-0100", website: "https://example.com/maiko", rating: 4.6, reviewCount: 312,
                                    priceLevel: "$$", isOpenNow: true)
        let placeCard = CantripPlaceCard(query: "Matcha", centerLatitude: 37.35, centerLongitude: -121.94,
                                         latitudeDelta: 0.05, longitudeDelta: 0.05, places: [place])
        let link = CantripLinkPreview(id: "l1", url: "https://www.apple.com/mac-studio/", title: "Mac Studio", domain: "apple.com")
        let cards = CantripCard.forReply(cards: nil, weather: weather, places: placeCard, links: [link])
        XCTAssertEqual(cards.map(\.type), ["weather", "places", "link"])

        let header = try XCTUnwrap(cards[0].header)
        XCTAssertEqual(header.title, "Seattle, WA")
        XCTAssertEqual(header.lines, ["Clear", "H 48°  L 38° · 1% precip. · Feels like 45°"])
        XCTAssertEqual(header.stat?.value, "48°")
        XCTAssertEqual(header.stat?.accessibilityLabel, "Now 48 degrees Fahrenheit, Clear")
        XCTAssertEqual(cards[0].blocks.map(\.type), ["header", "strip", "chart"])
        XCTAssertEqual(cards[0].blocks[1].items?.map(\.note), [nil, "40%"])
        XCTAssertEqual(cards[0].blocks[2].min, 35)
        XCTAssertEqual(cards[0].blocks[2].max, 53)
        XCTAssertEqual(cards[0].source?.attribution, "Weather data by Open-Meteo.com")

        let item = try XCTUnwrap(cards[1].blocks.last?.items?.first)
        XCTAssertEqual(cards[1].blocks.last?.mapLinked, true)
        XCTAssertEqual(item.subtitle, "Cafe · $$")
        XCTAssertEqual(item.badges?.compactMap(\.text), ["4.6 (312)", "Open now"])
        XCTAssertEqual(item.actions?.compactMap(\.label), ["Directions", "Call", "Website"])
        XCTAssertEqual(item.actions?[1].url, "tel:4085550100")

        XCTAssertEqual(cards[2].linkPreview?.url, "https://www.apple.com/mac-studio/")
        XCTAssertEqual(cards[2].linkPreview?.domain, "apple.com")

        let current = try message(#","cards":[],"weatherCard":{"place":"Old"}"#)
        XCTAssertTrue(CantripCard.forReply(cards: current.cards, weather: current.weatherCard, places: nil, links: nil).isEmpty,
                      "a current Mac's cards replace the older fields, even when it chose none")
    }

    func testActionsOpenOnlyWebPagesAndPhoneNumbers() {
        XCTAssertNotNil(CantripCardStyle.actionURL("https://kiwi.com/u/abc"))
        XCTAssertNotNil(CantripCardStyle.actionURL("tel:+14085550100"))
        XCTAssertNil(CantripCardStyle.actionURL("tel:+1;ext=javascript"))
        XCTAssertNil(CantripCardStyle.actionURL("javascript:alert(1)"))
        XCTAssertNil(CantripCardStyle.actionURL("file:///etc/passwd"))
        XCTAssertNil(CantripCardStyle.actionURL("http://localhost:8080/"))
        XCTAssertNil(CantripCardStyle.actionURL("https://mac.tailnet.ts.net/"))
        XCTAssertNil(CantripCardStyle.actionURL(nil))
        let link = CantripCard(id: "l", type: "link", style: "link", accessibilityLabel: nil,
                               action: .init(kind: "open", label: "Open", url: "javascript:alert(1)"), blocks: [])
        XCTAssertNil(link.linkPreview, "a link card that wouldn't open isn't drawn")
    }
}
