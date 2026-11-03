import Foundation

private final class WeatherBackendFixture: Backend {
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
    /// A reply's `weather` block becomes a forecast card from Open-Meteo data (replayed here): for
    /// the device the message came from, never with a model's numbers, and without weather-site
    /// link cards under it.
    @MainActor
    static func testWeatherCardsRemote() async throws {
        let settings = AppSettings.shared
        let saved = (settings.linkPreviewsEnabled, settings.shareLocation, settings.memoryEnabled)
        settings.linkPreviewsEnabled = true
        settings.shareLocation = false
        settings.memoryEnabled = false
        settings.backend = .copilot
        settings.attachScreen = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false
        defer { (settings.linkPreviewsEnabled, settings.shareLocation, settings.memoryEnabled) = saved }

        let fetchedAt = Date()
        // A real Open-Meteo answer from 2026-11-01, moved to now: its "Now" hour and days stay current.
        let fixture = try weatherFixture(shiftedTo: fetchedAt, Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RichCardTests/open-meteo-seattle.json")))
        // Let earlier tests' deferred stub resets land first, or one could clear the stubs below mid-test.
        try await Task.sleep(for: .milliseconds(200))
        await WeatherCardResolver.shared.setSources(.init(
            geocode: { place in place.lowercased().hasPrefix("seattle")
                ? .init(coordinate: .init(latitude: 47.6062, longitude: -122.3321)) : nil },
            forecast: { _, _ in try WeatherForecast.parse(fixture, fetchedAt: fetchedAt) }
        ))
        await LinkPreviewStore.shared.setCustomFetcher { url in
            let html = "<html><head><meta property=\"og:title\" content=\"Page for \(url.host ?? "")\"></head></html>"
            return (Data(html.utf8), url, "text/html")
        }

        let backend = WeatherBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        let manager = SessionManager()
        manager.sessions = [chat]
        defer { withExtendedLifetime(manager) {} }
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 30000...45000), token = UUID().uuidString
        server.start(port: port, token: token, servesLAN: false)
        defer { server.stop(); chat.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(chat.id)")!
        func post(_ body: String) async throws -> Int {
            var request = URLRequest(url: url.appendingPathComponent("messages"))
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            return ((try await client.data(for: request)).1 as! HTTPURLResponse).statusCode
        }
        func lastReply() async throws -> [String: Any] {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await client.data(for: request)
            let session = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["session"] as! [String: Any]
            return (session["messages"] as! [[String: Any]]).last { $0["role"] as? String == "assistant" }!
        }
        func reply(_ text: String, until done: @escaping () -> Bool) async throws {
            backend.sink?(.textDelta(text))
            backend.sink?(.done)
            try await waitForJournalTest { !chat.isStreaming && done() }
        }

        // From an iPhone sharing its location, with no place named: the iPhone's forecast.
        let located = #""location":{"latitude":47.67,"longitude":-122.38,"label":"Seattle, WA, United States","timeZone":"America/Los_Angeles","age":30,"device":"iPhone"}"#
        let status = try await post(#"{"text":"What's the weather today?",\#(located)}"#)
        precondition(status == 202)
        try await waitForJournalTest { backend.requests.count == 1 }
        try await reply("""
        Clear and cool in Seattle today. See [AccuWeather](https://www.accuweather.com/en/us/seattle/98104/weather-forecast/351409) \
        or the parks at https://www.seattle.gov/parks.

        ```weather
        {}
        ```
        """) { chat.messages.last?.weatherCard != nil && chat.messages.last?.linkPreviews.isEmpty == false }
        let first = chat.messages.last!
        precondition(!first.text.contains("```weather") && first.text.hasPrefix("Clear and cool"), first.text)
        precondition(first.weatherCard?.isAvailable == true && first.weatherCard?.place == "Seattle, WA"
                     && first.weatherCard?.placeNote == "Your iPhone's location"
                     && first.weatherCard?.current?.temperature == 48, "\(String(describing: first.weatherCard))")
        precondition(first.linkPreviews.map(\.domain) == ["seattle.gov"], "no weather-site card under the forecast")

        let snapshot = try await lastReply()
        let card = snapshot["weatherCard"] as! [String: Any]
        precondition(card["status"] as? String == "ok" && card["place"] as? String == "Seattle, WA"
                     && card["placeNote"] as? String == "Your iPhone's location"
                     && (card["hourly"] as? [[String: Any]])?.first?["label"] as? String == "Now"
                     && (card["daily"] as? [[String: Any]])?.count ?? 0 >= 9
                     && card["attribution"] as? String == "Weather data by Open-Meteo.com")
        precondition((snapshot["linkPreviews"] as? [[String: Any]])?.count == 1)

        // A saved reply's weather-site card is dropped from the snapshot too.
        chat.messages[chat.messages.count - 1].linkPreviews.insert(
            LinkPreviewCard(id: "old", url: "https://weather.com/weather/today/l/Seattle+WA",
                            domain: "weather.com", title: "Seattle Weather"), at: 0)
        let resaved = try await lastReply()
        precondition((resaved["linkPreviews"] as? [[String: Any]])?.count == 1)

        let restored = ChatSession(id: chat.id, copilotBackend: WeatherBackendFixture())
        precondition(restored.messages.last { $0.role == .assistant }?.weatherCard == first.weatherCard,
                     "the card is saved with the reply")

        // Typed at the Mac, which shares no location here: nothing to forecast, and the card says so.
        chat.submit("Weather?")
        try await waitForJournalTest { backend.requests.count == 2 }
        try await reply("Here's the forecast.\n\n```weather\n{}\n```") {
            chat.messages.last?.weatherCard != nil && chat.messages.last?.id != first.id
        }
        let nowhere = chat.messages.last!.weatherCard!
        precondition(!nowhere.isAvailable && nowhere.unavailable?.hasPrefix("No place to forecast") == true
                     && nowhere.current == nil, "\(nowhere)")

        // Open-Meteo unreachable: "Forecast unavailable", no numbers.
        await WeatherCardResolver.shared.setSources(.init(
            geocode: { _ in .init(coordinate: .init(latitude: 47.6062, longitude: -122.3321)) },
            forecast: { _, _ in throw URLError(.timedOut) }
        ))
        chat.submit("Weather in Seattle?")
        try await waitForJournalTest { backend.requests.count == 3 }
        try await reply("Seattle:\n```weather\n{\"place\":\"Seattle, WA\"}\n```") {
            chat.messages.last?.weatherCard?.unavailable?.hasPrefix("Couldn't get") == true
        }
        let failedSnapshot = (try await lastReply())["weatherCard"] as! [String: Any]
        precondition(failedSnapshot["status"] as? String == "unavailable" && failedSnapshot["place"] as? String == "Seattle, WA"
                     && failedSnapshot["message"] as? String == "Couldn't get the forecast from Open-Meteo. Ask again in a moment."
                     && failedSnapshot["current"] == nil && failedSnapshot["daily"] == nil)

        // Home hides a weather block while it streams, even before its closing fence.
        precondition(CantripHomeProtocol.visibleText("Sunny.\n\n```weather\n{\"pla", streaming: true) == "Sunny.")
        precondition(CantripHomeProtocol.visibleText("Sunny.\n```weath", streaming: true) == "Sunny.")
        precondition(CantripHomeProtocol.visibleText("Sunny.\n```weather\n{}\n```", streaming: false) == "Sunny.")
        precondition(CantripHomeProtocol.visibleText("Code:\n```swift\nlet x = 1", streaming: true).contains("let x"))
        await WeatherCardResolver.shared.setSources(nil)
        await LinkPreviewStore.shared.setCustomFetcher(nil)
        print("Weather cards: device forecasts, Mac fallback, unavailable states, link filtering and Home streaming passed")
    }
}

/// The fixture's times (current, hourly, daily, sunrise and sunset) moved so its current time is `now`.
private func weatherFixture(shiftedTo now: Date, _ data: Data) throws -> Data {
    var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    guard let current = (json["current"] as? [String: Any])?["time"] as? Double else { return data }
    let offset = now.timeIntervalSince1970.rounded(.down) - current
    for key in ["current", "hourly", "daily"] {
        guard var section = json[key] as? [String: Any] else { continue }
        for (name, value) in section where ["time", "sunrise", "sunset"].contains(name) {
            if let time = value as? Double { section[name] = time + offset }
            if let times = value as? [Double] { section[name] = times.map { $0 + offset } }
        }
        json[key] = section
    }
    return try JSONSerialization.data(withJSONObject: json)
}
