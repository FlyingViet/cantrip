import CoreLocation
import Foundation
import XCTest
@testable import Hermes

private final class LocationRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest, Data?) async throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        let captured = body
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try await handler(request, captured)
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
final class CantripLocationSharingTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-000000000001"
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!

    private func fix(age: TimeInterval = 120) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 37.389_42, longitude: -122.081_87),
                   altitude: 0, horizontalAccuracy: 35, verticalAccuracy: -1,
                   timestamp: Date(timeIntervalSinceNow: -age))
    }

    func testCoarseFixIsRoundedBeforeItLeavesTheDevice() {
        let coarse = CantripClientLocation.make(fix(), label: "Mountain View, CA, United States", precise: false,
                                                device: "iPhone", timeZone: pacific)
        XCTAssertEqual(coarse.latitude, 37.39)
        XCTAssertEqual(coarse.longitude, -122.08)
        XCTAssertEqual(coarse.accuracy, 1_000, "a coarse fix never claims better than about 1 km")
        XCTAssertEqual(coarse.age, 120, accuracy: 1)
        XCTAssertEqual(coarse.timeZone, "America/Los_Angeles")
        XCTAssertFalse(coarse.precise)
        let precise = CantripClientLocation.make(fix(), label: nil, precise: true, device: "Mac", timeZone: pacific)
        XCTAssertEqual(precise.latitude, 37.389_42)
        XCTAssertEqual(precise.longitude, -122.081_87)
        XCTAssertEqual(precise.accuracy, 35)
        XCTAssertTrue(precise.precise)
    }

    func testMessageBodyCarriesTheLocationOnlyWhenShared() throws {
        let location = CantripClientLocation.make(fix(), label: "Mountain View, CA", precise: false,
                                                  device: "iPhone", timeZone: pacific)
        let shared = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            CantripMessageBody(text: "Weather?", mode: .auto, images: [], location: location)
        )) as? [String: Any]
        let sent = try XCTUnwrap(shared?["location"] as? [String: Any])
        XCTAssertEqual(Set(sent.keys), ["latitude", "longitude", "label", "accuracy", "precise", "timeZone", "age", "device"])
        XCTAssertEqual(sent["label"] as? String, "Mountain View, CA")
        let off = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            CantripMessageBody(text: "Weather?", mode: .auto, images: [])
        )) as? [String: Any]
        XCTAssertNil(off?["location"], "no location key while sharing is off")
    }

    func testSendAttachesThisDevicesLocationToTheMessage() async throws {
        let original = CantripLocationSharing.provider
        let location = CantripClientLocation.make(fix(), label: "Mountain View, CA", precise: false,
                                                  device: "iPhone", timeZone: pacific)
        var shared: CantripClientLocation? = location
        CantripLocationSharing.provider = { shared }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocationRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: configuration))
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "unit-location-token",
                                               tailscaleOnly: true)
        XCTAssertTrue(configured)
        addTeardownBlock { @MainActor in
            CantripLocationSharing.provider = original
            model.setAppActive(false)
            model.clearConfiguration()
            LocationRequestProtocol.handler = nil
        }
        let snapshot = Data("""
        {"session":{"id":"\(sessionID)","title":"Home","workdir":"/tmp","isStreaming":false,"canResume":false,
         "councilMode":false,"queuedCount":0,"supportsAutoDelivery":true,"supportsClientLocation":true,"messages":[]}}
        """.utf8)
        var bodies: [[String: Any]] = []
        LocationRequestProtocol.handler = { request, body in
            if request.httpMethod == "POST", let body,
               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                bodies.append(object)
            }
            return (200, snapshot)
        }
        let first = await model.send("What's the weather today?", mode: .auto, sessionID: sessionID)
        XCTAssertTrue(first, model.errorMessage ?? "send failed")
        struct Envelope: Decodable { let session: CantripRemoteSession }
        XCTAssertEqual(try JSONDecoder().decode(Envelope.self, from: snapshot).session.supportsClientLocation, true)
        let sent = try XCTUnwrap(bodies.last?["location"] as? [String: Any])
        XCTAssertEqual(sent["label"] as? String, "Mountain View, CA")
        XCTAssertEqual(sent["latitude"] as? Double, 37.39)
        XCTAssertEqual(sent["device"] as? String, "iPhone")

        shared = nil
        let second = await model.send("And tomorrow?", mode: .auto, sessionID: sessionID)
        XCTAssertTrue(second)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNil(bodies.last?["location"], "sharing off sends no location; the Mac's stands in")
    }

    func testSettingsPageListsLocationAndDescribesEachState() {
        XCTAssertTrue(SettingsPage.available.contains(.location))
        XCTAssertEqual(SettingsPage.location.title, "Location")
        XCTAssertEqual(SettingsLocationPage.status(.found("Mountain View, CA")), "Mountain View, CA")
        XCTAssertEqual(SettingsLocationPage.status(.denied), "Location access is off for this app")
        XCTAssertEqual(SettingsLocationPage.status(.off), "Off")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: CantripLocationSharing.enabledKey), "off by default")
    }
}
