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

    private func model(authorize: @escaping (String) async throws -> Void = { _ in }) async throws -> CantripRemoteModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InputRequestProtocol.self]
        let client = URLSession(configuration: config)
        let model = CantripRemoteModel(urlSession: client, authorizeSensitiveAction: authorize)
        let configured = await model.configure(url: "https://input.example", pairingToken: "input-fixture", tailscaleOnly: true)
        XCTAssertTrue(configured, model.errorMessage ?? "")
        addTeardownBlock { @MainActor in
            model.setAppActive(false); model.clearConfiguration()
            client.invalidateAndCancel(); InputRequestProtocol.handler = nil
        }
        return model
    }

    private func sessionData(pending: Bool = true, chatReplies: Bool = true) throws -> Data {
        let input = try JSONSerialization.jsonObject(with: data(kind: "question")) as! [String: Any]
        var session: [String: Any] = [
            "id": sessionID, "title": "Work", "workdir": "/tmp", "isStreaming": true,
            "canResume": false, "councilMode": false, "queuedCount": 0, "messages": [],
            "supportsInputRequests": true, "supportsImageAttachments": true, "supportsAutoDelivery": true,
            "pendingInputCount": pending ? 1 : 0, "supportsChatInputReplies": chatReplies
        ]
        if chatReplies { session["pendingInputs"] = pending ? input["requests"] : [] }
        return try JSONSerialization.data(withJSONObject: ["session": session])
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testChatReplyPinsQuestionAndPreservesImageWithoutBiometrics() async throws {
        let model = try await model { _ in XCTFail("Ordinary chat questions do not need Face ID") }
        var paths: [String] = []
        let image = ChatImageAttachment(data: Data("fixture-image".utf8))
        InputRequestProtocol.handler = { request in
            paths.append(request.url!.path)
            if request.httpMethod == "GET" { return (200, try self.sessionData()) }
            let body = try self.body(request)
            XCTAssertEqual(body["inputRequestID"] as? String, self.id.uuidString)
            XCTAssertEqual(body["text"] as? String, "Here is the error")
            let images = try XCTUnwrap(body["images"] as? [[String: String]])
            XCTAssertEqual(images.first?["data"], image.data.base64EncodedString())
            return (202, try self.sessionData(pending: false))
        }
        await model.selectSession(sessionID)
        paths = []
        let sent = await model.send("Here is the error", mode: .auto, images: [image])
        XCTAssertTrue(sent, model.errorMessage ?? "")
        XCTAssertEqual(paths, ["/api/v1/sessions/\(sessionID)", "/api/v1/sessions/\(sessionID)/messages"])
        XCTAssertNil(model.chatInputRequest)
        XCTAssertEqual(model.selectedSession?.queuedCount, 0)
    }

    func testResolvedQuestionDoesNotRetargetOrQueueReply() async throws {
        let model = try await model { _ in XCTFail("No biometric prompt for a question") }
        InputRequestProtocol.handler = { _ in (200, try self.sessionData()) }
        await model.selectSession(sessionID)
        var requests = 0
        InputRequestProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "GET", "Never POST a stale reply as a new task")
            return (200, try self.sessionData(pending: false))
        }
        let sent = await model.send("stale reply", mode: .auto)
        XCTAssertFalse(sent)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.errorMessage?.contains("already answered") == true)
    }

    func testLegacyHostQuestionUsesInputAPIAndRejectsAttachments() async throws {
        let model = try await model { _ in XCTFail("No biometric prompt for a question") }
        InputRequestProtocol.handler = { _ in (200, try self.sessionData(chatReplies: false)) }
        await model.selectSession(sessionID)
        let requests = try JSONDecoder().decode([String: [CantripInputRequest]].self, from: data(kind: "question"))["requests"]!
        model.inputContext = .init(identity: model.usageIdentity, sessionID: sessionID, requests: requests)
        InputRequestProtocol.handler = { _ in XCTFail("Old host cannot safely receive attached question replies"); return (200, Data()) }
        let attached = await model.send("screenshot", mode: .auto, images: [.init(data: Data([1]))])
        XCTAssertFalse(attached)
        var paths: [String] = []
        InputRequestProtocol.handler = { request in
            paths.append(request.url!.path)
            if request.httpMethod == "GET" { return (200, try self.data(kind: "question")) }
            XCTAssertEqual(try self.body(request)["text"] as? String, "answer in chat")
            return (200, Data(#"{"accepted":true}"#.utf8))
        }
        let sent = await model.send("answer in chat", mode: .auto)
        XCTAssertTrue(sent, model.errorMessage ?? "")
        XCTAssertEqual(paths, ["/api/v1/sessions/\(sessionID)/input", "/api/v1/sessions/\(sessionID)/input/\(id)"])
    }

    func testQuestionOnlyRouteCannotSubmitPassword() async throws {
        let model = try await model { _ in XCTFail("Question route must reject a secret rather than authorize it") }
        InputRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, try self.data(kind: "secret"))
        }
        let sent = await model.respondToInput(sessionID: sessionID, id: id,
            answer: .init(decision: "submit", text: "not-a-chat-answer"), identity: model.usageIdentity, questionOnly: true)
        XCTAssertFalse(sent)
    }

    func testQuestionsStayOutOfSecureModalAndComposerContextHasNoSeparateAnswerField() async throws {
        let model = try await model { _ in XCTFail("Rendering questions must not authenticate") }
        InputRequestProtocol.handler = { request in
            if request.url?.path.hasSuffix("/input") == true { return (200, try self.data(kind: "question")) }
            return (200, try self.sessionData())
        }
        await model.selectSession(sessionID)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let session = try XCTUnwrap(model.selectedSession)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        for modal in [false, true] {
            let view = modal ? AnyView(CantripInputRequestsView(model: model, session: session))
                : AnyView(CantripInputComposer(model: model))
            let controller = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(350))
            controller.view.layoutIfNeeded()
            XCTAssertFalse(descendants(controller.view).contains { $0 is UITextField || ($0 as? UITextView)?.isEditable == true },
                           "Ordinary replies use the normal chat composer, not another answer form")
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = modal ? "Secure modal excludes question" : "Composer question context"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertNil(model.inputRequestsSession)
    }

    func testComposerPollsLegacyQuestionsWithoutMountingTranscript() async throws {
        let model = try await model { _ in XCTFail("Question polling must not authenticate") }
        InputRequestProtocol.handler = { request in
            if request.url?.path.hasSuffix("/input") == true { return (200, try self.data(kind: "question")) }
            return (200, try self.sessionData(chatReplies: false))
        }
        await model.selectSession(sessionID)
        XCTAssertNil(model.chatInputRequest)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIHostingController(rootView: CantripInputComposer(model: model))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<20 where model.chatInputRequest == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.chatInputRequest?.id, id)
        XCTAssertEqual(model.inputContext?.sessionID, sessionID)
        XCTAssertNil(model.inputRequestsSession)
    }

    func testComposerReplyStateRespectsExplicitDeliveryAndChoiceOnlyQuestions() throws {
        let question = try XCTUnwrap(
            JSONDecoder().decode([String: [CantripInputRequest]].self, from: data(kind: "question"))["requests"]?.first
        )
        let choiceOnly = CantripInputRequest(
            id: UUID(), kind: "question", source: "Copilot", title: "Choose",
            detail: "Choose one", choices: ["A", "B"], allowsFreeform: false,
            url: nil, code: nil, expiresAt: question.expiresAt
        )
        XCTAssertEqual(CantripInputComposer.placeholder(for: question, mode: .auto), "Your reply…")
        XCTAssertEqual(CantripInputComposer.placeholder(for: choiceOnly, mode: .auto), "Choose an answer above…")
        XCTAssertFalse(CantripInputComposer.acceptsText(for: choiceOnly, mode: .auto))
        for mode in CantripDeliveryMode.allCases where mode != .auto {
            XCTAssertEqual(CantripInputComposer.placeholder(for: question, mode: mode), "Message Cantrip…")
            XCTAssertTrue(CantripInputComposer.acceptsText(for: choiceOnly, mode: mode))
        }
        XCTAssertTrue(CantripInputComposer.acceptsText(for: nil, mode: .auto))
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
