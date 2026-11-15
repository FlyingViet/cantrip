import SwiftUI
import XCTest
@testable import Hermes

private final class MuseRequestProtocol: URLProtocol {
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

/// Home's Muse request card: decoding, and Send / Edit / Cancel as the Mac expects them, with
/// Face ID before every Send.
@MainActor
final class CantripMuseRequestTests: XCTestCase {
    private let homeID = "7EAE0CE5-8C8B-4652-9FD0-214867A90E5D"
    private let requestID = "5B0C7E2F-4A86-4E7F-9A1B-3F6B2A108C4D"
    private let text = "Bass Compass, last 30 days: 1,240 active users. Write a 30-day growth plan."

    private func cardJSON(state: String = "waiting", actions: String = #"["send","edit","cancel"]"#,
                          sendLabel: String = "Send") -> String {
        #"{"id":"\#(requestID)","title":"Growth plan","text":"\#(text)","chat":"Cantrip · Growth plan","state":"\#(state)","# +
        #""statusLine":"\#(state == "held" ? "The Privacy Gate found mail content. Nothing has been sent. Edit it, or send it anyway." : "Nothing is sent until you tap Send.")","expiresAt":\#(Int(Date().timeIntervalSince1970) + 86_000),"actions":\#(actions),"sendLabel":"\#(sendLabel)"}"#
    }

    func testDecodesTheCardAndOlderMacsStillDecode() throws {
        let message = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data("""
        {"id":"m1","role":"handoff","text":"fallback","thinking":"","author":"Muse","activities":[],
         "museRequest":\(cardJSON())}
        """.utf8))
        let card = try XCTUnwrap(message.museRequest)
        XCTAssertEqual(card.text, text)
        XCTAssertTrue(card.isOpen && !card.isHeld && message.isHandoffResult)
        XCTAssertEqual(card.sendLabel, "Send")
        let held = try JSONDecoder().decode(CantripRemoteMuseRequest.self,
                                            from: Data(cardJSON(state: "held", sendLabel: "Send anyway").utf8))
        XCTAssertTrue(held.isHeld)
        XCTAssertEqual(held.sendLabel, "Send anyway")
        let closed = try JSONDecoder().decode(CantripRemoteMuseRequest.self,
                                              from: Data(cardJSON(state: "somethingNew", actions: "[]").utf8))
        XCTAssertEqual(closed.state, .other)
        XCTAssertFalse(closed.isOpen)
        let old = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data("""
        {"id":"m2","role":"handoff","text":"plain","thinking":"","author":"Muse","activities":[]}
        """.utf8))
        XCTAssertNil(old.museRequest)
    }

    func testSendAsksFaceIDThenPostsTheExactTextAndCancelPostsNothingElse() async throws {
        var authorizations: [String] = []
        var refuse = false
        var posted: [(path: String, body: [String: Any])] = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MuseRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        let model = CantripRemoteModel(urlSession: client, authorizeSensitiveAction: { reason in
            authorizations.append(reason)
            if refuse { throw CancellationError() }
        })
        MuseRequestProtocol.handler = { [homeID, requestID] request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            if request.httpMethod == "POST", path.hasPrefix("/api/v1/muse/requests/") {
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream {
                    stream.open()
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: 4096); if n <= 0 { break }; data.append(buffer, count: n) }
                    stream.close()
                    body = data
                }
                posted.append((path, (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:]))
                let state = path.hasSuffix("/cancel") ? "cancelled" : "sending"
                return (200, Data(#"{"card":{"id":"\#(requestID)","title":"Growth plan","text":"x","state":"\#(state)","actions":[]}}"#.utf8))
            }
            if path == "/api/v1/sessions/\(homeID)" || path == "/api/v1/home" {
                return (200, Data("""
                {"session":{"id":"\(homeID)","title":"Cantrip Home","workdir":"/tmp","isStreaming":false,"canResume":false,
                "councilMode":false,"queuedCount":0,"status":null,"messages":[],"queued":[],"isCantripHome":true}}
                """.utf8))
            }
            return (200, Data(#"{"sessions":[]}"#.utf8))
        }
        addTeardownBlock { @MainActor in
            model.clearConfiguration()
            client.invalidateAndCancel()
            MuseRequestProtocol.handler = nil
        }
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "muse-token", tailscaleOnly: true)
        XCTAssertTrue(configured)

        let sent = await model.actOnMuseRequest(requestID, action: .send(text: text, override: false))
        XCTAssertEqual(sent?.state, .sending)
        XCTAssertEqual(authorizations, ["Send this request to your Muse."])
        XCTAssertEqual(posted.last?.path, "/api/v1/muse/requests/\(requestID)/send")
        XCTAssertEqual(posted.last?.body["text"] as? String, text)
        XCTAssertNil(posted.last?.body["override"])

        _ = await model.actOnMuseRequest(requestID, action: .send(text: text, override: true))
        XCTAssertEqual(posted.last?.body["override"] as? Bool, true)
        XCTAssertTrue(authorizations.last?.contains("held it") == true)

        // No Face ID, no send: nothing is posted.
        refuse = true
        let count = posted.count
        let refused = await model.actOnMuseRequest(requestID, action: .send(text: text, override: false))
        XCTAssertNil(refused)
        XCTAssertEqual(posted.count, count)
        XCTAssertTrue(model.errorMessage?.contains("Nothing was sent") == true)

        // Edit and Cancel don't need Face ID.
        let before = authorizations.count
        _ = await model.actOnMuseRequest(requestID, action: .edit("Shorter plan, please."))
        XCTAssertEqual(posted.last?.path, "/api/v1/muse/requests/\(requestID)/edit")
        XCTAssertEqual(posted.last?.body["text"] as? String, "Shorter plan, please.")
        let cancelled = await model.actOnMuseRequest(requestID, action: .cancel)
        XCTAssertEqual(cancelled?.state, .cancelled)
        XCTAssertEqual(posted.last?.path, "/api/v1/muse/requests/\(requestID)/cancel")
        XCTAssertTrue(posted.last?.body.isEmpty == true)
        XCTAssertEqual(authorizations.count, before)
    }

    /// Renders the card (open and held) for review. Set TEST_RUNNER_MUSE_REQUEST_ARTIFACT_DIR.
    func testCardScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["MUSE_REQUEST_ARTIFACT_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_MUSE_REQUEST_ARTIFACT_DIR to render the card.")
        }
        let model = CantripRemoteModel()
        for (name, json) in [("open", cardJSON()), ("held", cardJSON(state: "held", sendLabel: "Send anyway"))] {
            let card = try JSONDecoder().decode(CantripRemoteMuseRequest.self, from: Data(json.utf8))
            let view = CantripMuseRequestCard(card: card, remote: model).padding().frame(width: 390)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: directory).appendingPathComponent("muse-request-\(name).png"))
        }
    }
}
