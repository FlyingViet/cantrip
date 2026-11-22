import Foundation
import XCTest
@testable import Hermes

/// A Mac stub that tags the tab list and answers 304 when the request carries its current tag.
private final class RevalidationRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) -> (status: Int, body: Data, etag: String?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            guard let handler = Self.handler, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let answer = handler(request)
            var headers = ["Content-Type": "application/json"]
            if let etag = answer.etag { headers["ETag"] = etag }
            let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// The Mac's poll of a Cantrip host (Gateway Mac, and Cantrip.app's Home window, which builds its
/// model the same way): the tab list goes out with the tag of the copy it holds, a 304 keeps that
/// copy, and a changed list replaces it. A Cantrip v1.1.18 Home window, which predates this,
/// downloaded the full list every 15 s.
@MainActor
final class MacRevalidationTests: XCTestCase {
    private let tabID = "70000000-0000-0000-0000-000000000001"

    private func listing(_ title: String) -> Data {
        Data(#"{"sessions":[{"id":"\#(tabID)","title":"\#(title)","workdir":"/tmp","isStreaming":false,"canResume":false,"councilMode":false,"queuedCount":0,"supportsAutoDelivery":true,"supportsPagedHistory":true,"historyRevision":"r1"}]}"#.utf8)
    }

    private func tag(_ data: Data) -> String { "W/\"\(data.hashValue)\"" }

    func testTabListPollsSendIfNoneMatchAndKeepTheListOn304() async throws {
        var body = listing("Garden")
        var sent: [String?] = []
        var notModified = 0
        RevalidationRequestProtocol.handler = { [unowned self] request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.path ?? ""
            switch path {
            case "/api/v1/sessions":
                let header = request.value(forHTTPHeaderField: "If-None-Match")
                sent.append(header)
                if header == tag(body) {
                    notModified += 1
                    return (304, Data(), tag(body))
                }
                return (200, body, tag(body))
            case "/api/v1/sessions/\(tabID)":
                return (200, Data(#"{"unchanged":true}"#.utf8), nil)
            default:
                return (404, Data(#"{"error":"not found"}"#.utf8), nil)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RevalidationRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        // As Gateway Mac and the Home window plug-in build it: no saved copy on disk.
        let model = CantripRemoteModel(urlSession: client)
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            client.invalidateAndCancel()
            RevalidationRequestProtocol.handler = nil
        }
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "revalidation-token",
                                               tailscaleOnly: true)
        XCTAssertTrue(configured, model.errorMessage ?? "configure failed")
        model.setAppActive(true)

        func until(_ seconds: Double = 12, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertTrue(condition(), "timed out: sent \(sent)")
        }

        try await until { notModified >= 1 }
        XCTAssertNil(sent.first ?? nil, "the first read has no copy to revalidate")
        XCTAssertEqual(sent.last, tag(listing("Garden")), "the next poll sends the tag it holds")
        XCTAssertEqual(model.sessions.map(\.title), ["Garden"], "a 304 keeps the list")
        XCTAssertNil(model.errorMessage)

        body = listing("Garden (renamed)")
        try await until { model.sessions.map(\.title) == ["Garden (renamed)"] }
        let afterChange = sent.count
        try await until { sent.count > afterChange && notModified >= 2 }
        XCTAssertEqual(sent.last, tag(listing("Garden (renamed)")), "the changed list's tag replaces the old one")
        XCTAssertEqual(model.sessions.map(\.title), ["Garden (renamed)"])
    }
}
