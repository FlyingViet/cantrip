import Foundation
import MapKit

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
        testPlaceMapFit()
        testPlaceMatching()
        try await testMatchaPlacesResolve()
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

    static func testPlaceMapFit() {
        let pins = [
            CLLocationCoordinate2D(latitude: 37.3692, longitude: -121.9512),
            CLLocationCoordinate2D(latitude: 37.3535, longitude: -121.9399),
            CLLocationCoordinate2D(latitude: 37.3816, longitude: -121.9751),
        ]
        let size = CGSize(width: 680, height: 310)
        // A 248 pt list floating 12 pt from the left edge, plus room for pin labels.
        let insets = PlaceMapFit.Insets(top: 40, left: 268 + 80, bottom: 34, right: 12 + 80)
        guard let rect = PlaceMapFit.rect(for: pins, size: size, insets: insets) else {
            preconditionFailure("Expected a fitted rect")
        }
        precondition(abs(rect.size.width / rect.size.height - size.width / size.height) < 0.0001,
                     "The rect keeps the view's aspect ratio, so MapKit shows it exactly")
        func screen(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            let point = MKMapPoint(coordinate)
            return CGPoint(x: (point.x - rect.origin.x) / rect.size.width * size.width,
                           y: (point.y - rect.origin.y) / rect.size.height * size.height)
        }
        let area = CGRect(x: insets.left, y: insets.top, width: size.width - insets.left - insets.right,
                          height: size.height - insets.top - insets.bottom)
        for pin in pins {
            let p = screen(pin)
            precondition(area.insetBy(dx: -0.5, dy: -0.5).contains(p), "Pin \(p) must sit in \(area)")
        }
        // The pins span the free area in at least one direction: fitted, not just shrunk.
        let xs = pins.map { screen($0).x }, ys = pins.map { screen($0).y }
        precondition(abs((xs.max()! - xs.min()!) - area.width) < 1 || abs((ys.max()! - ys.min()!) - area.height) < 1)

        // One place: centred in the free area at the minimum width, never a world-scale zoom.
        let single = PlaceMapFit.rect(for: [pins[0]], size: size, insets: insets, minimumMeters: 2_000)!
        let meters = single.size.width / size.width * area.width / MKMapPointsPerMeterAtLatitude(pins[0].latitude)
        precondition(abs(meters - 2_000) < 1, "Single pin spans \(meters) m")
        precondition(PlaceMapFit.rect(for: [], size: size, insets: insets) == nil)
    }

    static func testPlaceMatching() {
        precondition(PlaceMatcher.namesMatch("Cere Tea", "Ceré Tea"), "Accents don't matter")
        precondition(PlaceMatcher.namesMatch("Arisan Tea & Coffee House", "Arisan"), "A listing under the short name matches")
        precondition(!PlaceMatcher.namesMatch("Matcha Cafe Maiko", "2855 Stevens Creek Blvd"), "An address isn't the place")
        precondition(!PlaceMatcher.namesMatch("Matcha Cafe Maiko", "Westfield Valley Fair"), "Nor is the mall it's in")
        precondition(!PlaceMatcher.namesMatch("Tea House", "Story Tea"), "One shared common word isn't a match")
        precondition(PlaceMatcher.hints(query: "Arisan Tea & Coffee House El Camino Real Sunnyvale CA", name: "Arisan Tea & Coffee House")
                     == ["el", "camino", "real", "sunnyvale"], "Hints are the query's where-words, without the state")

        // The address result that came first loses to the café a later search found.
        let address = PlaceCandidate(name: "2855 Stevens Creek Blvd", latitude: 37.3249, longitude: -121.9452,
                                     poiCategory: nil, address: "2855 Stevens Creek Blvd, Santa Clara")
        let cafe = PlaceCandidate(name: "Matcha Cafe Maiko", latitude: 37.3261, longitude: -121.9456,
                                  poiCategory: "MKPOICategoryRestaurant", address: "2855 Stevens Creek Blvd, Unit 9254, Santa Clara")
        let choice = PlaceMatcher.choose([address, cafe], name: "Matcha Cafe Maiko",
                                         query: "Matcha Cafe Maiko Westfield Valley Fair 2855 Stevens Creek Blvd Santa Clara CA")
        precondition(choice?.candidate == cafe && choice?.branchMatched == true)
        precondition(PlaceMatcher.choose([address], name: "Matcha Cafe Maiko", query: nil) == nil, "No named listing, no match")

        // Icons come from the reply's category first, then the listing's; the cross is only for care.
        precondition(PlaceSymbol.symbol(category: "Matcha cafe", poi: "MKPOICategoryRestaurant") == "cup.and.saucer.fill")
        precondition(PlaceSymbol.symbol(category: "Tea house", poi: nil) == "cup.and.saucer.fill")
        precondition(PlaceSymbol.symbol(category: nil, poi: "MKPOICategoryRestaurant") == "fork.knife")
        precondition(PlaceSymbol.symbol(category: "Urgent care clinic", poi: nil) == "cross.case.fill")
        precondition(PlaceSymbol.symbol(category: "Steakhouse", poi: nil) == "mappin", "\"tea\" inside a word doesn't count")
        precondition(PlaceSymbol.symbol(category: nil, poi: nil) == "mappin" && PlaceSymbol.glyph(for: "mappin") == "📍")
        // Saved cards from before icons get one from their category.
        precondition(PlacePin(id: "a", name: "A", latitude: 1, longitude: 1, category: "Cafe").pinSymbol == "cup.and.saucer.fill")

        let pin = PlacePin(id: "m", name: "Matcha Cafe Maiko", latitude: 37.3, longitude: -121.9)
        precondition(PlaceLinkFilter.covers(url: URL(string: "https://phoenix.aws.mapquest.com/us/california/matcha-cafe-maiko-492809960")!,
                                            label: nil, places: [pin]), "A listing page whose path spells the name is covered")
        precondition(!PlaceLinkFilter.covers(url: URL(string: "https://news.example.com/best-matcha-in-the-bay")!, label: nil, places: [pin]))
    }

    /// The reply that showed "2855 Stevens Creek Blvd", a San Jose branch and medical crosses,
    /// replayed from recorded MapKit and OpenStreetMap results.
    static func testMatchaPlacesResolve() async throws {
        struct Fixture: Decodable {
            var search: [String: [PlaceCandidate]]
            var osm: [String: [PlaceCandidate]]
            var regions: [String: [Double]]
        }
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("matcha-places.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        @Sendable func region(_ name: String?) -> MKCoordinateRegion? {
            guard let name, let r = fixture.regions[name], r.count == 4 else { return nil }
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: r[0], longitude: r[1]),
                                      span: MKCoordinateSpan(latitudeDelta: r[2], longitudeDelta: r[3]))
        }
        let sources = PlaceCardResolver.Sources(region: { region($0) }, search: { query, _ in fixture.search[query] ?? [] },
                                                searchOSM: { query, _ in fixture.osm[query] ?? [] }, details: { _, _ in nil })
        var reply = """
        For the best matcha itself, go to [Matsu Matcha](https://matsumatcha.example.com/), or try \
        [Matcha Cafe Maiko](https://phoenix.aws.mapquest.com/us/california/matcha-cafe-maiko-492809960).

        ```places
        {"near":"Santa Clara, CA","query":"Matcha cafes near Santa Clara","places":[{"name":"Matsu Matcha","query":"Matsu Matcha 3030 El Camino Real Santa Clara CA","category":"Matcha cafe"},{"name":"Matcha Cafe Maiko","query":"Matcha Cafe Maiko Westfield Valley Fair 2855 Stevens Creek Blvd Santa Clara CA","category":"Matcha cafe"},{"name":"Arisan Tea & Coffee House","query":"Arisan Tea & Coffee House El Camino Real Sunnyvale CA","category":"Tea house"},{"name":"Cere Tea","query":"Cere Tea Cupertino CA","category":"Tea house"},{"name":"Izumi Matcha","query":"Izumi Matcha Cupertino CA","category":"Matcha cafe"}]}
        ```
        """
        let proposal = try XCTUnwrapLike(PlaceCardResolver.extractProposal(from: &reply))
        let card = try XCTUnwrapLike(await PlaceCardResolver(sources: sources).resolve(proposal))
        let pins = card.places
        precondition(pins.map(\.name) == ["Matsu Matcha", "Matcha Cafe Maiko", "Arisan Tea & Coffee House", "Cere Tea", "Izumi Matcha"],
                     "Every pin is under the reply's name: \(pins.map(\.name))")
        precondition(pins.allSatisfy { $0.isApproximate == nil && $0.pinSymbol == "cup.and.saucer.fill" },
                     "All five matched, with cafe icons: \(pins.map { ($0.isApproximate, $0.pinSymbol) })")
        precondition(pins[1].address?.hasPrefix("2855 Stevens Creek Blvd, Unit 9254") == true && pins[1].listedName == nil,
                     "Maiko is the café at Valley Fair, not the mall's address")
        precondition(pins[2].address == "1082 East El Camino Real, Sunnyvale" && pins[2].listedName == "Arisan",
                     "Arisan is the Sunnyvale branch the query named, from OpenStreetMap: \(pins[2])")
        precondition(pins[3].address?.contains("Saratoga") == true, "Ceré Tea: the branch nearest Cupertino, not Milpitas")
        precondition(pins.map(\.category) == ["Matcha cafe", "Matcha cafe", "Tea house", "Tea house", "Matcha cafe"],
                     "The reply's categories show")

        // No link card repeats a mapped place, whatever listing it resolved to.
        let previews = [
            LinkPreviewCard(id: LinkPreviewSecurity.cardID(for: "https://matsumatcha.example.com/"), url: "https://matsumatcha.example.com/",
                            domain: "matsumatcha.example.com", title: "Matsu Matcha"),
            LinkPreviewCard(id: LinkPreviewSecurity.cardID(for: "https://phoenix.aws.mapquest.com/us/california/matcha-cafe-maiko-492809960"),
                            url: "https://phoenix.aws.mapquest.com/us/california/matcha-cafe-maiko-492809960",
                            domain: "phoenix.aws.mapquest.com", title: "Matcha Cafe Maiko"),
        ]
        precondition(PlaceLinkFilter.visible(previews, placeCard: card, text: reply).isEmpty, "No link cards under the map")

        // A place no listing names still gets a pin, under its own name, marked approximate.
        let lone = PlaceBlockProposal(query: nil, near: "Santa Clara, CA", places: [
            .init(name: "Matcha Cafe Maiko", query: "Matcha Cafe Maiko Westfield Valley Fair 2855 Stevens Creek Blvd Santa Clara CA", category: nil),
        ])
        let addressOnly = PlaceCardResolver.Sources(region: { region($0) }, search: { query, _ in
            query.contains("Westfield") ? (fixture.search[query] ?? []) : []
        }, searchOSM: { _, _ in [] }, details: { _, _ in nil })
        let approximate = try XCTUnwrapLike(await PlaceCardResolver(sources: addressOnly).resolve(lone)).places
        precondition(approximate.count == 1 && approximate[0].name == "Matcha Cafe Maiko" && approximate[0].isApproximate == true
                     && approximate[0].listedName == nil && approximate[0].pinSymbol == "mappin",
                     "Never renamed to an address: \(approximate)")
        precondition((approximate[0].snapshot["approximate"] as? Bool) == true && approximate[0].snapshot["glyph"] as? String == "📍")
    }

    struct Missing: Error {}
    static func XCTUnwrapLike<T>(_ value: T?) throws -> T {
        guard let value else { throw Missing() }
        return value
    }
}
