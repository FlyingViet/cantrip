import Foundation
import XCTest
@testable import Hermes

private final class ImageRequestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

final class CantripImageTransportTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-000000000001"

    override func tearDown() {
        ImageRequestProtocol.handler = nil
        super.tearDown()
    }

    private func api() throws -> CantripRemoteAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRequestProtocol.self]
        return CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "test-pairing-token",
            urlSession: URLSession(configuration: configuration)
        )
    }

    private func snapshot(support: Bool?) throws -> Data {
        var session: [String: Any] = [
            "id": sessionID, "title": "Test", "workdir": "/tmp",
            "isStreaming": false, "canResume": false, "councilMode": false,
            "queuedCount": 0,
        ]
        if let support { session["supportsImageAttachments"] = support }
        return try JSONSerialization.data(withJSONObject: ["session": session])
    }

    func testLegacyHostIsNeverSentAnImageMutation() async throws {
        for support: Bool? in [nil, false] {
            let response = try snapshot(support: support)
            var requests = 0
            ImageRequestProtocol.handler = { request in
                requests += 1
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, response)
            }
            do {
                _ = try await api().send(
                    "Look at this", mode: .queue, sessionID: sessionID,
                    images: [ChatImageAttachment(data: Data([1, 2, 3]))]
                )
                XCTFail("Unsupported hosts must reject image sends")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("updated Cantrip host"))
            }
            XCTAssertEqual(requests, 1, "Never POST text without its images")
        }
    }

    func testImageSendPreflightsThenPostsOnceWithAuthentication() async throws {
        let response = try snapshot(support: true)
        var methods: [String] = []
        ImageRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-pairing-token")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)/messages")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                return (202, response)
            }
            return (200, response)
        }
        let result = try await api().send(
            "", mode: .interrupt, sessionID: sessionID,
            images: [ChatImageAttachment(data: Data([1, 2, 3]))]
        )
        XCTAssertEqual(methods, ["GET", "POST"])
        XCTAssertEqual(result.id, sessionID)
    }

    func testFailedImageMutationIsNotReplayed() async throws {
        let response = try snapshot(support: true)
        var mutations = 0
        ImageRequestProtocol.handler = { request in
            if request.httpMethod == "POST" {
                mutations += 1
                return (400, Data(#"{"error":"Invalid image"}"#.utf8))
            }
            return (200, response)
        }
        do {
            _ = try await api().send(
                "Look", mode: .inject, sessionID: sessionID,
                images: [ChatImageAttachment(data: Data([1, 2, 3]))]
            )
            XCTFail("The server error must surface")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Invalid image"))
        }
        XCTAssertEqual(mutations, 1)
    }

    func testTextOnlyStillWorksWithLegacyHostsWithoutPreflight() async throws {
        let response = try snapshot(support: nil)
        var requests = 0
        ImageRequestProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "POST")
            return (202, response)
        }
        _ = try await api().send("Hello", mode: .queue, sessionID: sessionID)
        XCTAssertEqual(requests, 1)
    }
}
