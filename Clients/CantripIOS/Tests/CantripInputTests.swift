import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class InputRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Task { @MainActor in
            do {
                let (status, data) = try XCTUnwrap(Self.handler)(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status,
                                                           httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
}

@MainActor
final class CantripInputTests: XCTestCase {
    private let sessionID = UUID().uuidString
    private let id = UUID()

    private func data(kind: String = "secret", expires: Double = Date().addingTimeInterval(600).timeIntervalSince1970) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["requests": [[
            "id": id.uuidString, "kind": kind, "title": "Input needed", "source": "/usr/bin/ssh on Mac",
            "detail": "Credential request for user@fixture", "choices": ["A", "B"],
            "allowsFreeform": kind == "question", "expiresAt": expires
        ]]])
    }

    private func model() async throws -> CantripRemoteModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InputRequestProtocol.self]
        let client = URLSession(configuration: config)
        let model = CantripRemoteModel(urlSession: client, authorizeSensitiveAction: { _ in })
        let configured = await model.configure(url: "https://input.example", pairingToken: "input-fixture", tailscaleOnly: true)
        XCTAssertTrue(configured, model.errorMessage ?? "")
        addTeardownBlock { @MainActor in
            model.setAppActive(false); model.clearConfiguration()
            client.invalidateAndCancel(); InputRequestProtocol.handler = nil
        }
        return model
    }

    func testResponsePreflightsOriginalChallengeAndNeverUsesChat() async throws {
        let model = try await model()
        var paths: [String] = []
        InputRequestProtocol.handler = { request in
            paths.append(request.url!.path)
            if request.httpMethod == "GET" { return (200, try self.data()) }
            XCTAssertEqual(request.httpMethod, "POST")
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = stream.read(&bytes, maxLength: bytes.count)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: String])
            XCTAssertEqual(body, ["decision": "submit", "text": "synthetic-secret"])
            return (200, Data(#"{"accepted":true}"#.utf8))
        }
        let sent = await model.respondToInput(sessionID: sessionID, id: id,
            answer: .init(decision: "submit", text: "synthetic-secret"), identity: model.usageIdentity)
        XCTAssertTrue(sent)
        XCTAssertEqual(paths, ["/api/v1/sessions/\(sessionID)/input", "/api/v1/sessions/\(sessionID)/input/\(id)"])
        XCTAssertTrue(model.selectedSession?.transcript.isEmpty ?? true)
    }

    func testExpiredMissingAndDifferentMacRejectWithoutPost() async throws {
        let model = try await model()
        for response in [try data(expires: 1), Data(#"{"requests":[]}"#.utf8)] {
            var methods: [String] = []
            InputRequestProtocol.handler = { request in methods.append(request.httpMethod!); return (200, response) }
            let sent = await model.respondToInput(sessionID: sessionID, id: id,
                answer: .init(decision: "approve"), identity: model.usageIdentity)
            XCTAssertFalse(sent)
            XCTAssertEqual(methods, ["GET"])
        }
        InputRequestProtocol.handler = { _ in XCTFail("No stale-Mac write"); return (200, try self.data()) }
        let sent = await model.respondToInput(sessionID: sessionID, id: id,
            answer: .init(decision: "approve"), identity: UUID())
        XCTAssertFalse(sent)
    }

    func testUncertainAnswerIsNotReplayed() async throws {
        let model = try await model()
        var methods: [String] = []
        InputRequestProtocol.handler = { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, try self.data())
        }
        let sent = await model.respondToInput(sessionID: sessionID, id: id,
            answer: .init(decision: "submit", text: "synthetic-secret"), identity: model.usageIdentity)
        XCTAssertFalse(sent)
        XCTAssertEqual(methods, ["GET", "POST"])
        XCTAssertFalse(model.errorMessage?.contains("synthetic-secret") == true)
    }

    func testInputNotificationRetainsNavigationIdentity() throws {
        let server = UUID(), event = UUID()
        let target = try XCTUnwrap(CantripNotificationTarget(userInfo: [
            "cantrip": ["kind": "input", "eventID": event.uuidString, "sessionID": sessionID,
                        "serverID": server.uuidString, "fingerprint": "paired"]
        ]))
        XCTAssertEqual(target.kind, "input")
        XCTAssertEqual(target.eventID, event)
        XCTAssertEqual(target.serverID, server)
        XCTAssertEqual(target.sessionID.uuidString, sessionID)
    }

    func testSecureInputFormAtNarrowAndAccessibleWidths() async throws {
        let model = try await model()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let session = CantripRemoteSession(id: sessionID, title: "Work", workdir: "/tmp", isStreaming: true,
            canResume: false, councilMode: false, queuedCount: 0, status: "Waiting for input",
            messages: nil, supportsImageAttachments: nil, queued: nil, supportsInputRequests: true, pendingInputCount: 1)
        XCTAssertTrue(CantripSessionPicker.statusSummary(for: session).contains("Needs input"))
        InputRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, try self.data())
        }
        for width: CGFloat in [320, 768] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                let view = CantripInputRequestsView(model: model, session: session).environment(\.dynamicTypeSize, size)
                let controller = UIHostingController(rootView: view)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                window.rootViewController = controller; window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil }
                try await Task.sleep(for: .milliseconds(350))
                controller.view.layoutIfNeeded()
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                for _ in 0..<12 {
                    if descendants(controller.view).compactMap({ $0 as? UITextField }).contains(where: { $0.isSecureTextEntry }) { break }
                    if let scroll = descendants(controller.view).compactMap({ $0 as? UIScrollView }).first {
                        let bottom = max(0, scroll.contentSize.height - scroll.bounds.height)
                        scroll.setContentOffset(CGPoint(x: 0, y: min(bottom, scroll.contentOffset.y + scroll.bounds.height / 2)), animated: false)
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    controller.view.layoutIfNeeded()
                }
                let all = descendants(controller.view)
                XCTAssertTrue(all.compactMap { $0 as? UITextField }.contains { $0.isSecureTextEntry },
                              "Secure input must remain reachable by scrolling at \(width) / \(size)")
                for scroll in all.compactMap({ $0 as? UIScrollView }) where scroll.bounds.width > 0 {
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = "Input \(Int(width)) \(size)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
}
