import Foundation

private final class RichCardBackendFixture: Backend {
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
    @MainActor
    static func testRichCardsRemote() async throws {
        let settings = AppSettings.shared
        let savedLinkPreviews = settings.linkPreviewsEnabled
        settings.linkPreviewsEnabled = true
        defer { settings.linkPreviewsEnabled = savedLinkPreviews }

        let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
        await LinkPreviewStore.shared.setCustomFetcher { url in
            if url.absoluteString == "https://www.apple.com/shop/buy-mac/mac-studio" {
                let html = """
                <html><head>
                <meta property="og:title" content="Shop Mac Studio">
                <meta property="og:site_name" content="Apple">
                <meta property="og:image" content="https://store.storeimages.cdn-apple.com/mac-studio.jpg">
                </head></html>
                """
                return (Data(html.utf8), url, "text/html")
            }
            return (jpegBytes, url, "image/jpeg")
        }
        await PlaceCardResolver.shared.setCustomLookup { proposal, _ in
            PlaceCard(
                query: proposal.query ?? "Urgent care near Santa Clara",
                regionName: proposal.near,
                centerLatitude: 37.3692363,
                centerLongitude: -121.9511819,
                latitudeDelta: 0.04,
                longitudeDelta: 0.04,
                places: [
                    PlacePin(
                        id: "concentra-sc",
                        name: "Concentra Urgent Care",
                        latitude: 37.3692363,
                        longitude: -121.9511819,
                        category: "Urgent care clinic",
                        address: "2737 Walsh Ave, Santa Clara, CA 95051",
                        phone: "+1-408-567-0400",
                        website: "https://www.concentra.com",
                        rating: 4.2,
                        reviewCount: 86,
                        priceLevel: nil,
                        isOpenNow: true,
                        hoursSummary: "Mo-Fr 08:00-17:00"
                    )
                ]
            )
        }
        defer {
            Task {
                await LinkPreviewStore.shared.setCustomFetcher(nil)
                await PlaceCardResolver.shared.setCustomLookup(nil)
            }
        }

        let backend = RichCardBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        let manager = SessionManager()
        manager.sessions = [chat]
        defer { withExtendedLifetime(manager) {} }
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 30000...45000)
        let token = UUID().uuidString
        server.start(port: port, token: token, servesLAN: false)
        defer { server.stop(); chat.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        chat.submit("Find urgent care near Santa Clara and Mac Studio order link")
        try await waitForJournalTest { backend.requests.count == 1 }
        let replyText = """
        Order at https://www.apple.com/shop/buy-mac/mac-studio (internal https://mac-mini.example-tailnet.ts.net/status stays plain).

        ```places
        {"query":"Urgent care near Santa Clara","near":"Santa Clara, CA","places":[
          {"name":"Concentra Urgent Care","address":"2737 Walsh Ave, Santa Clara, CA 95051","category":"Urgent care clinic"}
        ]}
        ```
        """
        backend.sink?(.textDelta(replyText))
        backend.sink?(.done)
        try await waitForJournalTest {
            guard !chat.isStreaming, let last = chat.messages.last else { return false }
            return last.placeCard != nil && !last.linkPreviews.isEmpty
        }

        let assistant = chat.messages.last!
        precondition(!assistant.text.contains("```places"), "Places block must be stripped from assistant text")
        precondition(assistant.linkPreviews.count == 1, "Only public URL should be unfurled")
        precondition(assistant.linkPreviews[0].title == "Shop Mac Studio")
        precondition(assistant.linkPreviews[0].domain == "apple.com")
        precondition(assistant.placeCard?.places.first?.name == "Concentra Urgent Care")

        // Verify Codable round-trip on transcript reload
        let restored = ChatSession(id: chat.id, copilotBackend: RichCardBackendFixture())
        let restoredAssistant = restored.messages.last { $0.role == .assistant }
        precondition(restoredAssistant?.linkPreviews == assistant.linkPreviews, "Link previews must persist in transcript")
        precondition(restoredAssistant?.placeCard == assistant.placeCard, "Place card must persist in transcript")

        // Verify Remote API snapshot and image/tile endpoints
        let base = URL(string: "http://127.0.0.1:\(port)/")!
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ path: String, auth: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: path, relativeTo: base)!)
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            let http = response as! HTTPURLResponse
            return (http.statusCode, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }

        let sessionResp = try await call("api/v1/sessions/\(chat.id)")
        precondition(sessionResp.0 == 200)
        let messages = (sessionResp.1["session"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        let remoteMsg = messages.last { ($0["role"] as? String) == "assistant" }!
        let remoteLinks = remoteMsg["linkPreviews"] as? [[String: Any]] ?? []
        precondition(remoteLinks.count == 1 && remoteLinks[0]["title"] as? String == "Shop Mac Studio")
        let remotePlace = remoteMsg["placeCard"] as? [String: Any]
        let remotePlaces = remotePlace?["places"] as? [[String: Any]] ?? []
        precondition(remotePlaces.count == 1 && remotePlaces[0]["name"] as? String == "Concentra Urgent Care")

        let imageID = remoteLinks[0]["imageID"] as! String
        let unauthImg = try await call("api/v1/link-previews/image?id=\(imageID)", auth: false)
        precondition(unauthImg.0 == 401, "Preview image endpoint requires auth")
        let imgResp = try await call("api/v1/link-previews/image?id=\(imageID)")
        precondition(imgResp.0 == 200 && imgResp.1["data"] as? String == jpegBytes.base64EncodedString())

        await MapTileProxy.shared.setCustomFetcher { _, _, _ in MapTileProxy.fallbackTilePNG }
        defer { Task { await MapTileProxy.shared.setCustomFetcher(nil) } }
        let unauthTile = try await call("api/v1/map-tile?z=12&x=661&y=1591&format=json", auth: false)
        precondition(unauthTile.0 == 401, "Map tile endpoint requires auth")
        let badTile = try await call("api/v1/map-tile?z=25&x=0&y=0&format=json")
        precondition(badTile.0 == 400, "Out-of-range zoom level must return 400")
        let tileResp = try await call("api/v1/map-tile?z=12&x=661&y=1591&format=json")
        precondition(tileResp.0 == 200 && tileResp.1["data"] as? String == MapTileProxy.fallbackTilePNG.base64EncodedString())
        await LinkPreviewStore.shared.setCustomFetcher(nil)
        await PlaceCardResolver.shared.setCustomLookup(nil)
        await MapTileProxy.shared.setCustomFetcher(nil)
        print("Rich cards: link previews, SSRF guard, place cards, transcript persistence, and authenticated image/tile routes passed")
    }
}
