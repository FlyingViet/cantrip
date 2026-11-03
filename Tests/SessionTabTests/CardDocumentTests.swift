import Foundation

private final class CardBackendFixture: Backend {
    var requests: [BackendRequest] = []
    var sink: ((BackendEvent) -> Void)?
    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        requests.append(request)
        sink = onEvent
    }
    func cancel() {}
    func reset() {}
}

extension SessionTabTests {
    static var cardFixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }

    /// Generic cards: weather, places and links as blocks, a flight card from a Kiwi result with no
    /// client code, model-written cards shown only when their values are in the cited tool's output,
    /// and older replies still drawn.
    @MainActor
    static func testCardDocuments() async throws {
        try testResolverDocuments()
        try testKiwiFlightCards()
        testModelCardVerification()
        try await testCardsThroughSessions()
        testCardSections()
        print("Generic cards: weather, places, links, Kiwi flights, tool cards, verification, fallback text and old history passed")
    }

    /// The Mac's card view: a map and its legend draw as one section; unknown and empty blocks draw nothing.
    @MainActor
    static func testCardSections() {
        var map = CardDocument.Block(type: "map")
        map.pins = [.init(id: "p1", title: "Cafe", latitude: 37.3, longitude: -121.9)]
        var legend = CardDocument.Block(type: "list")
        legend.mapLinked = true
        legend.items = [.init(id: "p1", title: "Cafe", pinID: "p1")]
        var header = CardDocument.Block(type: "header")
        header.title = "Cafes"
        let sections = CardPanelView.sections([header, map, legend, .init(type: "hologram"), .init(type: "header"), .init(type: "list")])
        precondition(sections.count == 2, "\(sections)")
        guard case .map(_, let linked) = sections[1] else { preconditionFailure("the map takes its legend") }
        precondition(linked?.items?.first?.pinID == "p1" && sections[1].hasDivider && !sections[0].hasDivider)
    }

    static func testResolverDocuments() throws {
        let fixture = try Data(contentsOf: cardFixtures.deletingLastPathComponent()
            .appendingPathComponent("RichCardTests/open-meteo-seattle.json"))
        let now = Date(timeIntervalSince1970: 1_793_571_300)
        let weather = try WeatherForecast.parse(fixture, fetchedAt: now)
            .card(place: "Seattle, WA", note: "Your iPhone's location", unit: "F", now: now).document
        precondition(weather.type == "weather" && weather.blocks.map(\.type) == ["header", "strip", "chart"])
        let header = weather.blocks[0]
        precondition(header.title == "Seattle, WA" && header.subtitle == "Your iPhone's location"
                     && header.stat?.value == "48°" && header.stat?.symbol == "sun.max.fill"
                     && header.lines?.first == "Clear" && header.stat?.accessibilityLabel == "Now 48 degrees Fahrenheit, Clear")
        precondition(weather.blocks[1].items?.count == 13 && weather.blocks[1].items?.first?.label == "Now")
        let chart = weather.blocks[2]
        precondition(chart.kind == "range" && chart.items?.count == 10 && chart.min == 35 && chart.max == 59
                     && chart.items?.first?.lowText == "38°" && chart.items?.first?.highText == "48°", "\(chart)")
        precondition(weather.source?.attribution == "Weather data by Open-Meteo.com" && weather.source?.updatedAt == now)
        precondition(weather.fallbackText?.contains("Seattle, WA") == true && weather.fallbackText?.contains("Today") == true)
        let snapshot = weather.snapshot
        precondition(snapshot["version"] as? Int == 1 && (snapshot["blocks"] as? [[String: Any]])?.count == 3
                     && (snapshot["source"] as? [String: Any])?["updatedAt"] as? String == "2026-11-01T22:15:00Z")
        let encoded = try JSONSerialization.data(withJSONObject: snapshot)
        let decoded = try CardDocument.decoder.decode(CardDocument.self, from: encoded)
        precondition(decoded == weather, "documents round-trip")

        let unavailable = WeatherCard.unavailable(place: "Atlantis", reason: "Couldn't find “Atlantis”.", unit: "F").document
        precondition(unavailable.blocks.map(\.type) == ["header", "notice"]
                     && unavailable.blocks[1].title == "Forecast unavailable" && unavailable.source?.updatedAt == nil)

        let places = PlaceCard(query: "Urgent care", regionName: "Santa Clara, CA", centerLatitude: 37.37, centerLongitude: -121.95,
                               latitudeDelta: 0.04, longitudeDelta: 0.04, places: [
            PlacePin(id: "p1", name: "Concentra Urgent Care", latitude: 37.369, longitude: -121.951, category: "Urgent care clinic",
                     address: "2737 Walsh Ave", phone: "+1 (408) 567-0400", website: "https://www.concentra.com", rating: 4.2,
                     reviewCount: 86, priceLevel: nil, isOpenNow: true, hoursSummary: "Mo-Fr 08:00-17:00"),
            PlacePin(id: "p2", name: "Corner Clinic", latitude: 37.36, longitude: -121.94, category: nil, address: nil, phone: nil,
                     website: "javascript:alert(1)", rating: nil, reviewCount: nil, priceLevel: nil, isOpenNow: false,
                     hoursSummary: nil, isApproximate: true),
        ]).document
        precondition(places.blocks.map(\.type) == ["map", "list"] && places.blocks[1].mapLinked == true)
        precondition(places.blocks[0].pins?.map(\.title) == ["Concentra Urgent Care", "Corner Clinic"]
                     && places.blocks[0].attribution == "Apple Maps · © OpenStreetMap")
        let first = places.blocks[1].items![0], second = places.blocks[1].items![1]
        precondition(first.pinID == "p1" && first.subtitle == "Urgent care clinic" && first.detail == "2737 Walsh Ave"
                     && first.badges?.map(\.text) == ["4.2 (86)", "Open now"] && first.note == "Mo-Fr 08:00-17:00"
                     && first.actions?.map(\.label) == ["Directions", "Call", "Website"]
                     && first.actions?[1].url == "tel:+14085670400", "\(first)")
        precondition(second.actions?.map(\.label) == ["Directions"] && second.note == "Approximate location"
                     && second.tone == "warning" && second.badges?.map(\.text) == ["Closed"], "only safe links become actions")

        let link = LinkPreviewCard(id: "abc", url: "https://www.apple.com/mac-studio/", domain: "apple.com",
                                   title: "Mac Studio", siteName: "Apple", imageID: String(repeating: "a", count: 64)).document
        precondition(link.style == "link" && link.action?.url == "https://www.apple.com/mac-studio/"
                     && link.blocks.map(\.type) == ["image", "header"] && link.blocks[1].subtitle == "apple.com"
                     && link.blocks[1].subtitleImageID == nil, "no icon, no icon field: the card stays as it was")
        // The site's icon goes beside the domain, in the card and in the older linkPreviews snapshot.
        let iconID = "5b4a3928170f6e5d4c3b2a10"
        let instagram = LinkPreviewCard(id: "def", url: "https://www.instagram.com/nasa/", domain: "instagram.com",
                                        title: "NASA (@nasa) • Instagram", siteName: "Instagram", iconID: iconID,
                                        iconChecked: true)
        let iconCard = instagram.document
        precondition(iconCard.blocks.map(\.type) == ["header"] && iconCard.blocks[0].subtitleImageID == iconID
                     && iconCard.blocks[0].subtitle == "instagram.com" && iconCard.blocks[0].symbol == "link"
                     && instagram.snapshot["iconID"] as? String == iconID && instagram.snapshot["iconChecked"] == nil,
                     "a link card names the site's cached icon for its domain line")
        let encodedHeader = try JSONSerialization.jsonObject(with: CardDocument.encoder.encode(iconCard)) as? [String: Any]
        precondition(((encodedHeader?["blocks"] as? [[String: Any]])?.first?["subtitleImageID"] as? String) == iconID)
        // Cards Cantrip didn't build can't point at cached images, icons included.
        var authoredHeader = CardDocument.Block(type: "header")
        authoredHeader.title = "Order"
        authoredHeader.subtitleImageID = iconID
        let authored = CardValidation.sanitized(
            CardDocument(id: "x", type: "order", blocks: [authoredHeader]), allowMaps: false
        )
        precondition(authored?.blocks.first?.subtitleImageID == nil && authored?.blocks.first?.title == "Order",
                     "authored cards lose subtitleImageID")
    }

    static func testKiwiFlightCards() throws {
        let output = try String(contentsOf: cardFixtures.appendingPathComponent("kiwi-search-flight.txt"), encoding: .utf8)
        let activity = ToolActivity(id: "t1", title: "search-flight", toolName: "kiwi-search-flight", state: .succeeded,
                                    input: nil, output: output, fileChanges: [])
        guard let card = ToolCards.card(from: [activity]) else { preconditionFailure("a Kiwi result makes a card") }
        precondition(card.type == "flights" && card.source?.kind == "tool" && card.source?.name == "Kiwi.com")
        precondition(card.blocks[0].title == "SFO → SEA" && card.blocks[0].symbol == "airplane"
                     && card.blocks[0].subtitle?.contains("6 of 12 results") == true, "\(card.blocks[0])")
        let items = card.blocks[1].items ?? []
        precondition(items.count == 6 && items[0].title == "Alaska Airlines · AS630" && items[0].trailing == "258 USD")
        precondition(items[0].subtitle?.hasSuffix("· 2h 13m · Nonstop") == true, items[0].subtitle ?? "")
        precondition(items[0].badges?.map(\.text) == ["Cheapest", "Fastest"] && items[0].actions?.first?.url == "https://kiwi.com/u/hqtj9x")
        precondition(items.dropFirst().allSatisfy { $0.badges == nil }, "one of each mark, though six tie on price")
        // A result cut off by the 20,000-character output limit still yields its complete itineraries.
        let clipped = ToolActivityFactory.detailText(String(output.prefix(4_000)))
        let partial = ToolCards.card(from: [ToolActivity(id: "t2", title: "x", toolName: "mcp__kiwi__search-flight",
                                                         state: .succeeded, input: nil, output: clipped, fileChanges: [])])
        precondition((partial?.blocks[1].items?.count ?? 0) >= 2, "complete itineraries before the cut")
        precondition(ToolCards.card(from: [ToolActivity(id: "t3", title: "x", toolName: "kiwi-search-flight", state: .failed,
                                                        input: nil, output: output, fileChanges: [])]) == nil)
        // Any tool can return a ready card under "cantrip/card".
        let authored = #"{"orders": 1, "cantrip/card": {"type": "package", "blocks": [{"type": "header", "title": "Package"}, {"type": "keyValue", "rows": [{"key": "Status", "value": "Out for delivery"}]}, {"type": "image", "imageID": "x"}, {"type": "script"}]}}"#
        let tool = ToolCards.card(from: [ToolActivity(id: "t4", title: "x", toolName: "track", state: .succeeded, input: nil,
                                                      output: authored, fileChanges: [])])
        precondition(tool?.type == "package" && tool?.blocks.map(\.type) == ["header", "keyValue"] && tool?.source?.kind == "tool",
                     "images and unknown blocks are dropped from cards Cantrip didn't build")
        precondition(tool?.accessibilityLabel == "Package", "a card without a label is named by its header")
    }

    static func testModelCardVerification() {
        let output = #"{"tracking":"1Z999","status":"In transit","eta":"2026-11-04","weight":"2.5 lb","url":"https://ups.example/t/1Z999"}"#
        let activities = [ToolActivity(id: "a", title: "x", toolName: "mcp__parcels__track_package", state: .succeeded,
                                       input: nil, output: output, fileChanges: [])]
        var text = """
        It's on the way.
        ```card
        {"title": "Package 1Z999", "cite": {"tool": "track_package"}, "blocks": [{"type": "keyValue", "rows": [{"key": "Status", "value": "In transit"}, {"key": "Arrives", "value": "Nov 4, 2026"}, {"key": "Weight", "value": "2.5 lb"}]}]}
        ```
        """
        let proposals = ModelCards.extract(from: &text)
        precondition(text == "It's on the way." && proposals.count == 1 && proposals[0].citedTool == "track_package")
        let verified = ModelCards.verified(proposals[0], activities: activities)
        precondition(verified?.blocks.map(\.type) == ["header", "keyValue"] && verified?.source?.name == "track_package")

        var invented = proposals[0]
        invented.card.blocks[1].rows?[2].value = "3.1 lb"
        precondition(ModelCards.verified(invented, activities: activities) == nil, "a number the tool didn't return")
        var badLink = proposals[0]
        badLink.card.blocks[1].items = [CardDocument.Item(title: "Track", actions: [.init(kind: "open", label: "Open",
                                                                                          url: "https://phish.example/x")])]
        precondition(ModelCards.verified(badLink, activities: activities) == nil, "a link the tool didn't return")
        var uncited = proposals[0]
        uncited.citedTool = nil
        precondition(ModelCards.verified(uncited, activities: activities) == nil)
        precondition(ModelCards.verified(proposals[0], activities: []) == nil, "the cited tool must have run")
        precondition(proposals[0].card.plainText.contains("Status: In transit"))
        precondition(ModelCards.decode(#"{"blocks":[{"type":"map","pins":[]}]}"#) == nil, "models can't draw maps")
    }

    @MainActor
    static func testCardsThroughSessions() async throws {
        let settings = AppSettings.shared
        let saved = (settings.linkPreviewsEnabled, settings.memoryEnabled, settings.backend)
        settings.linkPreviewsEnabled = true
        settings.memoryEnabled = false
        settings.backend = .copilot
        defer { (settings.linkPreviewsEnabled, settings.memoryEnabled, settings.backend) = saved }
        // Let earlier tests' deferred stub resets land first, or one could clear this stub mid-test.
        try await Task.sleep(for: .milliseconds(200))
        await LinkPreviewStore.shared.setCustomFetcher { url in
            (Data("<html><head><meta property=\"og:title\" content=\"Page \(url.host ?? "")\"></head></html>".utf8), url, "text/html")
        }
        let output = try String(contentsOf: cardFixtures.appendingPathComponent("kiwi-search-flight.txt"), encoding: .utf8)

        let backend = CardBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        defer { chat.cancel() }
        chat.submit("Flights from SFO to Seattle on Nov 15?")
        try await waitForJournalTest { backend.requests.count == 1 }
        backend.sink?(.activity(ToolActivity(id: "kiwi-1", title: "search-flight", toolName: "kiwi-search-flight",
                                             state: .succeeded, input: nil, output: output, fileChanges: [])))
        backend.sink?(.textDelta("Alaska has the cheapest nonstop at 258 USD: [book it](https://kiwi.com/u/hqtj9x). Also see https://www.seattle.gov/visit."))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming && chat.messages.last?.linkPreviews.isEmpty == false }
        let reply = chat.messages.last!
        precondition(reply.cards.first?.type == "flights" && reply.mainCard?.type == "flights")
        let documents = reply.cardDocuments(linkPreviews: true)
        precondition(documents.map(\.type) == ["flights", "link"] && documents[1].action?.url.contains("seattle.gov") == true,
                     "the booking link's card is dropped; the card already opens it: \(documents.map(\.id))")
        let history = RemoteHistory.message(reply)
        precondition((history["cards"] as? [[String: Any]])?.count == 2 && history["placeCard"] == nil && history["weatherCard"] == nil)

        // An unverifiable model card: no card, its contents stay as plain text.
        chat.submit("Where's my package?")
        try await waitForJournalTest { backend.requests.count == 2 }
        backend.sink?(.textDelta("""
        It shipped.
        ```card
        {"title":"Package","cite":{"tool":"track_package"},"blocks":[{"type":"keyValue","rows":[{"key":"ETA","value":"Nov 9"}]}]}
        ```
        """))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming && chat.messages.last?.text.contains("ETA: Nov 9") == true }
        let fallback = chat.messages.last!
        precondition(fallback.cards.isEmpty && fallback.text == "It shipped.\n\nPackage\nETA: Nov 9" && !fallback.text.contains("```"),
                     fallback.text)

        // Replies saved before generic cards still draw: a stored places reply becomes a map card.
        let old = #"{"id":"\#(UUID().uuidString)","role":"assistant","text":"Try these. https://www.apple.com/mac-studio/","placeCard":{"query":"Cafes","centerLatitude":37.3,"centerLongitude":-121.9,"latitudeDelta":0.04,"longitudeDelta":0.04,"places":[{"id":"p1","name":"Cafe","latitude":37.3,"longitude":-121.9}],"attribution":"Apple Maps · © OpenStreetMap"},"linkPreviews":[{"id":"l1","url":"https://www.apple.com/mac-studio/","domain":"apple.com","title":"Mac Studio"}]}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        let restored = message.cardDocuments(linkPreviews: true)
        precondition(restored.map(\.type) == ["places", "link"] && restored[0].blocks[0].pins?.first?.title == "Cafe",
                     "an apple.com link isn't covered by the places' Apple Maps directions")
        let restoredHistory = RemoteHistory.message(message)
        precondition(restoredHistory["placeCard"] != nil && (restoredHistory["cards"] as? [[String: Any]])?.count == 2,
                     "old clients keep the legacy key, new ones get cards")

        precondition(CantripHomeProtocol.visibleText("Done.\n```card\n{\"title\":\"x\"", streaming: true) == "Done.")
        await LinkPreviewStore.shared.setCustomFetcher(nil)
    }
}
