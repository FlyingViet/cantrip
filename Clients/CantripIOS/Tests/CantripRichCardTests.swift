import Foundation
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
        XCTAssertFalse(CantripLinkPreview.isSafeWebURL(try XCTUnwrap(URL(string: "http://fixer.example-home.com"))))
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
}
