import Foundation

@main
struct RichCardTests {
    static func main() async throws {
        testLinkPreviewSecurity()
        testLinkPreviewExtractor()
        testLinkPreviewHTMLParser()
        try await testLinkPreviewStore()
        testOSMOpeningHours()
        testPlaceBlockExtraction()
        testPlaceLinkFilter()
        print("Rich card unit tests passed")
    }

    static func testLinkPreviewSecurity() {
        let validURLs = [
            "https://www.apple.com/shop/buy-mac/mac-studio",
            "https://developer.apple.com/documentation/mapkit",
            "https://openstreetmap.org/copyright",
        ]
        for raw in validURLs {
            let url = URL(string: raw)!
            precondition(LinkPreviewSecurity.isAllowed(url: url), "Expected allowed URL: \(raw)")
        }

        // Your own private domains come from a setting, never from the source.
        UserDefaults.standard.set(["Example-Home.net."], forKey: "richCardBlockedDomains")
        defer { UserDefaults.standard.removeObject(forKey: "richCardBlockedDomains") }
        precondition(LinkPreviewSecurity.isAllowed(url: URL(string: "https://notexample-home.net/")!),
                     "Only the domain and its subdomains are blocked")
        let blockedURLs = [
            "http://localhost:8092/chapters",
            "http://127.0.0.1:11434/api/tags",
            "https://[::1]:8443/api/v1/sessions",
            "http://192.168.0.10:8092/",
            "http://10.0.0.5/admin",
            "http://172.20.10.1/status",
            "https://100.100.100.100/dns",
            "https://mac-mini.example-tailnet.ts.net/api/v1/sessions",
            "https://fixer.example-home.net/",
            "http://printer.local/status",
            "file:///Users/test/secret.txt",
            "ftp://example.com/file",
            "https://user:pass@example.com/page",
            "https://example.com/reset?token=secret123",
            "https://s3.amazonaws.com/bucket/item?X-Amz-Signature=deadbeef",
            "https://example.com/callback?code=oauth_code_123",
        ]
        for raw in blockedURLs {
            guard let url = URL(string: raw) else { continue }
            precondition(!LinkPreviewSecurity.isAllowed(url: url), "Expected blocked URL: \(raw)")
        }
    }

    static func testLinkPreviewExtractor() {
        let markdown = """
        Order at [Shop Mac Studio](https://www.apple.com/shop/buy-mac/mac-studio).
        Internal dashboard: https://mac-mini.example-tailnet.ts.net:8445 and http://192.168.0.10:8092.
        Inline code `https://example.com/in-inline-code` and image ![Diagram](https://www.apple.com/image.png) are skipped.
        ```bash
        curl https://example.com/in-fenced-code
        ```
        Duplicate link https://www.apple.com/shop/buy-mac/mac-studio and second link https://www.openstreetmap.org/about,
        third https://swift.org/blog/, fourth https://developer.apple.com/swift/.
        """
        let extracted = LinkPreviewExtractor.extractURLs(from: markdown)
        precondition(extracted.map(\.absoluteString) == [
            "https://www.apple.com/shop/buy-mac/mac-studio",
            "https://www.openstreetmap.org/about",
            "https://swift.org/blog/",
        ], "Extracted unexpected URLs: \(extracted)")
    }

    static func testLinkPreviewHTMLParser() {
        let html = """
        <!doctype html>
        <html>
        <head>
          <title>Fallback Title</title>
          <meta property="og:title" content="Shop Mac Studio &amp; Accessories" />
          <meta property="og:site_name" content="Apple" />
          <meta property="og:image" content="/is/mac-studio-gallery-1.jpg" />
          <script>window.secret = "ignore";</script>
        </head>
        <body></body>
        </html>
        """
        let pageURL = URL(string: "https://www.apple.com/shop/buy-mac/mac-studio")!
        let parsed = LinkPreviewHTMLParser.parse(htmlData: Data(html.utf8), pageURL: pageURL)
        precondition(parsed != nil, "Expected HTML parser to succeed")
        precondition(parsed?.title == "Shop Mac Studio & Accessories", "Unexpected title: \(String(describing: parsed?.title))")
        precondition(parsed?.siteName == "Apple")
        precondition(parsed?.domain == "apple.com")
        precondition(parsed?.imageURL?.absoluteString == "https://www.apple.com/is/mac-studio-gallery-1.jpg")
    }

    static func testLinkPreviewStore() async throws {
        let appleURL = URL(string: "https://www.apple.com/shop/buy-mac/mac-studio")!
        let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
        let store = LinkPreviewStore { url in
            if url == appleURL {
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
        let disabled = await store.resolve(forText: "Order at https://www.apple.com/shop/buy-mac/mac-studio", enabled: false)
        precondition(disabled.isEmpty, "Disabled store must not resolve previews")

        let cards = await store.resolve(urls: [appleURL])
        precondition(cards.count == 1)
        let card = cards[0]
        precondition(card.title == "Shop Mac Studio")
        precondition(card.domain == "apple.com")
        precondition(card.siteName == "Apple")
        precondition(card.imageID == card.id)
        let cachedImage = await store.imageData(id: card.id)
        precondition(cachedImage == jpegBytes, "Expected cached preview image bytes")
    }

    static func testOSMOpeningHours() {
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz

        // Wednesday 14:30
        let wedAfternoon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 14, minute: 30))!
        // Wednesday 21:30
        let wedNight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 21, minute: 30))!
        // Sunday 12:00
        let sunNoon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12, minute: 0))!

        let schedule = "Mo-Fr 08:00-20:00; Sa 09:00-17:00; Su off"
        precondition(OSMOpeningHours.evaluate(schedule, at: wedAfternoon, timeZone: tz) == true)
        precondition(OSMOpeningHours.evaluate(schedule, at: wedNight, timeZone: tz) == false)
        precondition(OSMOpeningHours.evaluate(schedule, at: sunNoon, timeZone: tz) == false)
        precondition(OSMOpeningHours.evaluate("24/7", at: sunNoon, timeZone: tz) == true)
    }

    static func testPlaceBlockExtraction() {
        var reply = """
        Here are three urgent care clinics near Santa Clara:

        1. **Concentra Urgent Care** — 2737 Walsh Ave
        2. **Instant Urgent Care** — 3466 El Camino Real

        ```places
        {"query":"Urgent care near Santa Clara","near":"Santa Clara, CA","places":[
          {"name":"Concentra Urgent Care","address":"2737 Walsh Ave, Santa Clara, CA 95051","category":"Urgent care clinic","rating":4.2,"reviewCount":86},
          {"name":"Instant Urgent Care","address":"3466 El Camino Real, Santa Clara, CA 95051","category":"Urgent care clinic","rating":4.7,"reviewCount":214}
        ]}
        ```
        """
        let proposal = PlaceCardResolver.extractProposal(from: &reply)
        precondition(proposal != nil, "Expected places block to be extracted")
        precondition(proposal?.near == "Santa Clara, CA")
        precondition(proposal?.places.count == 2)
        precondition(proposal?.places[0].name == "Concentra Urgent Care")
        precondition(!reply.contains("```places"), "Places block must be stripped from visible reply text")
        precondition(reply.contains("Concentra Urgent Care"))
    }

    static func testPlaceLinkFilter() {
        func pin(_ name: String, website: String?) -> PlacePin {
            PlacePin(id: name, name: name, latitude: 37.37, longitude: -121.95, website: website)
        }
        let places = [
            pin("Harbor Urgent Care", website: "https://www.harborcare.example.com/locations/bayside/"),
            pin("Lantern Clinic", website: "https://lanternclinic.example.org/"),
            pin("Northgate Health Urgent & Primary Care Bayside - Bayside Square",
                website: "https://northgatehealth.example.com/locations/bayside"),
            pin("Corner Bakery", website: "https://www.facebook.com/cornerbakerybayside"),
        ]
        // Linked place names, the reply format a places block follows.
        let reply = """
        - **[Harbor Urgent Care](https://www.harborcare.example.com/urgent-care/bayside/)**: walk-in.
        - **[Lantern Clinic](https://lanternclinic.example.org/resources/fit-for-duty/)**: fit-for-duty exams.
        - **[Northgate Health Urgent Care](https://directory.example.net/clinics/northgate-bayside.html)**: book in the app.
        - Fill in [the leave certification form](https://www.dol.example.gov/forms/leave-cert.pdf) first.
        - Their [hours page](https://www.facebook.com/otherbusiness/hours) and [Corner Bakery](https://cornerbakery.example.com/).
        - See https://news.example.com/urgent-care-costs for typical fees, and [Urgent Care](https://guide.example.com/what-is-urgent-care).
        """
        let links = LinkPreviewExtractor.extractLinks(from: reply, limit: 64)
        precondition(links.first?.label == "Harbor Urgent Care", "Labels come with links: \(links)")
        precondition(links.count == 8, "Every link is found: \(links.map(\.url))")
        precondition(LinkPreviewExtractor.extractURLs(from: reply) == links.prefix(3).map(\.url))

        let uncovered = PlaceLinkFilter.uncovered(links, places: places).map(\.url.absoluteString)
        precondition(uncovered == [
            "https://www.dol.example.gov/forms/leave-cert.pdf",
            "https://www.facebook.com/otherbusiness/hours",
            "https://news.example.com/urgent-care-costs",
            "https://guide.example.com/what-is-urgent-care",
        ], "Only links the map doesn't cover keep a preview: \(uncovered)")
        precondition(PlaceLinkFilter.uncovered(links, places: []).count == links.count,
                     "Without a map card every link keeps its preview")

        // Matching by site: subdomains count; shared hosts need the place's own page.
        let site = URL(string: "https://harborcare.example.com/")!
        precondition(PlaceLinkFilter.sameSite(URL(string: "https://booking.harborcare.example.com/x")!, site))
        precondition(!PlaceLinkFilter.sameSite(URL(string: "https://notharborcare.example.com/")!, site))
        let page = URL(string: "https://www.facebook.com/cornerbakerybayside")!
        precondition(PlaceLinkFilter.sameSite(URL(string: "https://facebook.com/cornerbakerybayside/photos")!, page))
        precondition(!PlaceLinkFilter.sameSite(URL(string: "https://facebook.com/cornerbakerybaysideextra")!, page))

        // Matching by label.
        precondition(PlaceLinkFilter.labelNames("**Lantern Clinic**", place: "Lantern Clinic"))
        precondition(PlaceLinkFilter.labelNames("Lantern Clinic Bayside, CA", place: "Lantern Clinic"))
        precondition(PlaceLinkFilter.labelNames("Harbor", place: "Harbor Urgent Care"))
        precondition(!PlaceLinkFilter.labelNames("Urgent care", place: "Harbor Urgent Care"))
        precondition(!PlaceLinkFilter.labelNames("Bayside", place: "Northgate Health Urgent & Primary Care Bayside"))
        precondition(!PlaceLinkFilter.labelNames("map", place: "Map Room Cafe"))
        precondition(PlaceLinkFilter.labelNames("Café Olé", place: "Cafe Ole"))

        // Saved replies: cards resolved before the rule are filtered when shown, matched by
        // the link as written even when the card's URL is where a redirect ended.
        func card(_ written: String, final: String) -> LinkPreviewCard {
            LinkPreviewCard(id: LinkPreviewSecurity.cardID(for: written), url: final,
                            domain: "", title: "", siteName: nil, imageID: nil)
        }
        let saved = [
            card("https://directory.example.net/clinics/northgate-bayside.html",
                 final: "https://directory.example.net/c/12345"),
            card("https://lanternclinic.example.org/resources/fit-for-duty/",
                 final: "https://lanternclinic.example.org/resources/fit-for-duty/"),
            card("https://www.dol.example.gov/forms/leave-cert.pdf",
                 final: "https://www.dol.example.gov/forms/leave-cert.pdf"),
        ]
        let map = PlaceCardResolver.buildCard(query: "Clinics", regionName: nil, places: places)
        let shown = PlaceLinkFilter.visible(saved, placeCard: map, text: reply).map(\.url)
        precondition(shown == ["https://www.dol.example.gov/forms/leave-cert.pdf"], "Shown: \(shown)")
        precondition(PlaceLinkFilter.visible(saved, placeCard: nil, text: reply) == saved)
    }
}
