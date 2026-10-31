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

        let blockedURLs = [
            "http://localhost:8092/chapters",
            "http://127.0.0.1:11434/api/tags",
            "https://[::1]:8443/api/v1/sessions",
            "http://192.168.0.94:8092/",
            "http://10.0.0.5/admin",
            "http://172.20.10.1/status",
            "https://100.100.100.100/dns",
            "https://mac-mini.example-tailnet.ts.net/api/v1/sessions",
            "https://fixer.example-home.com/",
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
        Internal dashboard: https://mac-mini.example-tailnet.ts.net:8445 and http://192.168.0.94:8092.
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
}
