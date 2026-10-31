import Foundation
import MapKit
import XCTest
@testable import Hermes

private final class RichCardImageRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
                ))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
}

@MainActor
final class CantripRichCardTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-000000000001"
    private let sampleImageID = String(repeating: "a", count: 64)

    override func tearDown() {
        RichCardImageRequestProtocol.handler = nil
        super.tearDown()
    }

    private func api() throws -> CantripRemoteAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RichCardImageRequestProtocol.self]
        return CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "test-pairing-token",
            urlSession: URLSession(configuration: configuration)
        )
    }

    func testRemoteMessageDecodesLinkPreviewsAndPlaceCard() throws {
        let json = """
        {
          "id": "m1",
          "role": "assistant",
          "text": "Order at https://www.apple.com/shop/buy-mac/mac-studio",
          "thinking": "",
          "activities": [],
          "linkPreviews": [
            {
              "id": "lp-1",
              "url": "https://www.apple.com/shop/buy-mac/mac-studio",
              "title": "Shop Mac Studio",
              "domain": "apple.com",
              "siteName": "Apple",
              "imageID": "\(sampleImageID)"
            }
          ],
          "placeCard": {
            "query": "Urgent care near Santa Clara",
            "regionName": "Santa Clara, CA",
            "centerLatitude": 37.3692363,
            "centerLongitude": -121.9511819,
            "latitudeDelta": 0.04,
            "longitudeDelta": 0.04,
            "places": [
              {
                "id": "concentra-sc",
                "name": "Concentra Urgent Care",
                "latitude": 37.3692363,
                "longitude": -121.9511819,
                "category": "Urgent care clinic",
                "address": "2737 Walsh Ave, Santa Clara, CA 95051",
                "phone": "+1-408-567-0400",
                "website": "https://www.concentra.com",
                "rating": 4.2,
                "reviewCount": 86,
                "isOpenNow": true,
                "hoursSummary": "Mo-Fr 08:00-17:00",
                "appleMapsURL": "https://maps.apple.com/?q=Concentra%20Urgent%20Care&ll=37.369236,-121.951182"
              }
            ]
          }
        }
        """
        let message = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.linkPreviews?.count, 1)
        XCTAssertEqual(message.linkPreviews?.first?.title, "Shop Mac Studio")
        XCTAssertEqual(message.linkPreviews?.first?.domain, "apple.com")
        XCTAssertEqual(message.linkPreviews?.first?.imageID, sampleImageID)

        let placeCard = try XCTUnwrap(message.placeCard)
        XCTAssertEqual(placeCard.query, "Urgent care near Santa Clara")
        XCTAssertEqual(placeCard.places.count, 1)
        let place = try XCTUnwrap(placeCard.places.first)
        XCTAssertEqual(place.name, "Concentra Urgent Care")
        XCTAssertEqual(place.rating, 4.2)
        XCTAssertEqual(place.reviewCount, 86)
        XCTAssertEqual(place.isOpenNow, true)
        XCTAssertEqual(place.resolvedMapsURL?.host, "maps.apple.com")
    }

    func testSafeWebURLAndImageIDValidation() throws {
        XCTAssertTrue(CantripLinkPreview.validImageID(sampleImageID))
        XCTAssertFalse(CantripLinkPreview.validImageID("../etc/passwd"))
        XCTAssertFalse(CantripLinkPreview.validImageID(String(repeating: "G", count: 64)))

        XCTAssertTrue(CantripLinkPreview.isSafeWebURL(try XCTUnwrap(URL(string: "https://www.apple.com/shop/buy-mac/mac-studio"))))
        XCTAssertFalse(CantripLinkPreview.isSafeWebURL(try XCTUnwrap(URL(string: "https://host.example-tailnet.ts.net/status"))))
        XCTAssertFalse(CantripLinkPreview.isSafeWebURL(try XCTUnwrap(URL(string: "http://printer.local"))))
        XCTAssertFalse(CantripLinkPreview.isSafeWebURL(try XCTUnwrap(URL(string: "http://localhost:8080"))))
        XCTAssertFalse(CantripLinkPreview.isSafeWebURL(try XCTUnwrap(URL(string: "file:///etc/hosts"))))
        XCTAssertFalse(CantripLinkPreview.isSafeWebURL(try XCTUnwrap(URL(string: "https://user:pass@example.com"))))
    }

    func testLinkPreviewImageFetchRequiresValidIDAndAuth() async throws {
        let client = try api()
        do {
            _ = try await client.linkPreviewImageData(id: "../../secret")
            XCTFail("Invalid image ID must be rejected before network call")
        } catch CantripRemoteError.invalidResponse {}

        let sampleBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        RichCardImageRequestProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-pairing-token")
            XCTAssertEqual(request.url?.path, "/api/v1/link-previews/image")
            let body = try JSONSerialization.data(withJSONObject: ["data": sampleBytes.base64EncodedString()])
            return (200, body)
        }
        let fetched = try await client.linkPreviewImageData(id: sampleImageID)
        XCTAssertEqual(fetched, sampleBytes)
    }

    func testPlacePinsUseTheMacsNameIconAndNotes() throws {
        let json = #"""
        [{"id":"p1","name":"Arisan Tea & Coffee House","latitude":37.35,"longitude":-122.0,"category":"Tea house",
          "listedName":"Arisan","symbol":"cup.and.saucer.fill","glyph":"☕"},
         {"id":"p2","name":"Matcha Cafe Maiko","latitude":37.32,"longitude":-121.94,"approximate":true,"symbol":"mappin"},
         {"id":"p3","name":"Old card","latitude":37.3,"longitude":-121.9,"category":"Cafe"},
         {"id":"p4","name":"Odd","latitude":37.3,"longitude":-121.9,"symbol":"not.a.cantrip.symbol","category":"Urgent care"}]
        """#
        let pins = try JSONDecoder().decode([CantripPlacePin].self, from: Data(json.utf8))
        XCTAssertEqual(pins[0].listedName, "Arisan")
        XCTAssertEqual(pins[0].pinSymbol, "cup.and.saucer.fill")
        XCTAssertEqual(pins[1].approximate, true)
        XCTAssertEqual(pins[2].pinSymbol, "cup.and.saucer.fill", "Cards from older Macs get an icon from their category")
        XCTAssertEqual(pins[3].pinSymbol, "cross.case.fill", "Only symbols Cantrip uses are drawn")
    }

    func testClosePinsMoveApartInsideTheMap() {
        let widths = ["Matsu Matcha", "Arisan Tea & Coffee House"].map { CantripPlaceMapFit.pinWidth($0) }
        let offsets = CantripPlaceMapFit.labelOffsets(points: [CGPoint(x: 300, y: 30), CGPoint(x: 240, y: 31)], widths: widths,
                                                      bounds: CGRect(x: 0, y: 0, width: 600, height: 300))
        XCTAssertEqual(offsets[0], .zero)
        XCTAssertGreaterThan(offsets[1].height, 0, "At the top edge the second pin moves down, still inside the map")
    }

    func testPlaceMapFitKeepsEveryPinRightOfTheList() throws {
        let pins = [
            CLLocationCoordinate2D(latitude: 37.3692, longitude: -121.9512),
            CLLocationCoordinate2D(latitude: 37.3535, longitude: -121.9399),
            CLLocationCoordinate2D(latitude: 37.3816, longitude: -121.9751),
        ]
        let size = CGSize(width: 680, height: 310)
        // A 244 pt list floating 12 pt from the left edge, plus room for pin labels.
        let insets = CantripPlaceMapFit.Insets(top: 40, left: 264 + 80, bottom: 34, right: 12 + 80)
        let rect = try XCTUnwrap(CantripPlaceMapFit.rect(for: pins, size: size, insets: insets))
        XCTAssertEqual(rect.size.width / rect.size.height, size.width / size.height, accuracy: 0.0001)
        let area = CGRect(x: insets.left, y: insets.top, width: size.width - insets.left - insets.right,
                          height: size.height - insets.top - insets.bottom).insetBy(dx: -0.5, dy: -0.5)
        for pin in pins {
            let point = MKMapPoint(pin)
            let screen = CGPoint(x: (point.x - rect.origin.x) / rect.size.width * size.width,
                                 y: (point.y - rect.origin.y) / rect.size.height * size.height)
            XCTAssertTrue(area.contains(screen), "\(screen) outside \(area)")
        }
        XCTAssertNil(CantripPlaceMapFit.rect(for: [], size: size, insets: insets))
    }
}

