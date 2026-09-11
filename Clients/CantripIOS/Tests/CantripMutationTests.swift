import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class MutationRequestProtocol: URLProtocol {
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
final class CantripMutationTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-000000000001"

    private func snapshot(capabilities: Bool = true, list: Bool = false, id: String? = nil) -> Data {
        let session = """
        {"id":"\(id ?? sessionID)","title":"Test","workdir":"/tmp",
         "isStreaming":true,"canResume":true,"councilMode":false,"queuedCount":1,
         "supportsAutoDelivery":\(capabilities),"supportsImageAttachments":\(capabilities),
         "supportsTabMetadata":\(capabilities),"supportsQueueRemoval":\(capabilities),
         "supportsTabReordering":\(capabilities),"isLocked":true,
         "messages":[]}
        """
        return Data((list ? "{\"sessions\":[\(session)]}" : "{\"session\":\(session)}").utf8)
    }

    private func model() async throws -> CantripRemoteModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MutationRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: configuration))
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "unit-mutation-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured, model.errorMessage ?? "Configuration failed")
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            MutationRequestProtocol.handler = nil
        }
        return model
    }

    func testAllDeliveryModesRecoverFromCooldownBeforePostingOnce() async throws {
        for mode in CantripDeliveryMode.allCases {
            for withImages in [false, true] {
                let model = try await model()
                let response = snapshot()
                MutationRequestProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
                await model.selectSession(sessionID)
                XCTAssertNotNil(model.errorMessage)

                var methods: [String] = []
                MutationRequestProtocol.handler = { request in
                    methods.append(request.httpMethod ?? "")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-mutation-token")
                    if request.httpMethod == "POST" {
                        XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)/messages")
                        XCTAssertEqual(request.timeoutInterval, 12)
                    } else {
                        XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)")
                        XCTAssertEqual(request.timeoutInterval, 3)
                    }
                    return (200, response)
                }
                let sent = await model.send(
                    "Hello", mode: mode,
                    images: withImages ? [ChatImageAttachment(data: Data([1, 2, 3]))] : [],
                    sessionID: sessionID
                )
                XCTAssertTrue(sent, model.errorMessage ?? "Expected recovered send")
                XCTAssertNil(model.errorMessage)
                XCTAssertEqual(methods, ["GET", "POST"], "Reuse preparation rather than reading twice")
                XCTAssertEqual(model.selectedSession?.id, sessionID)
                model.clearConfiguration()
            }
        }
    }

    func testReadFailureIsNotReportedAsPossibleDeliveryAndNextSendCanRecover() async throws {
        let model = try await model()
        var methods: [String] = []
        MutationRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            throw URLError(.networkConnectionLost)
        }
        let sent = await model.send("Hello", mode: .auto, sessionID: sessionID)
        XCTAssertFalse(sent)
        XCTAssertEqual(methods, ["GET"])
        XCTAssertTrue(model.errorMessage?.contains("was not sent") == true)
        XCTAssertFalse(model.errorMessage?.contains("may have reached") == true)
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.isMutating)
        XCTAssertFalse(model.isReorderingTabs)

        let response = snapshot()
        MutationRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            return (200, response)
        }
        let retried = await model.send("Hello", mode: .auto, sessionID: sessionID)
        XCTAssertTrue(retried, model.errorMessage ?? "Explicit retry should recover immediately")
        XCTAssertEqual(methods, ["GET", "GET", "POST"])
    }

    func testNoDiscoveredOrConfiguredRouteReportsNotSentWithoutAnyRequest() async throws {
        let model = try await model()
        let configured = await model.configure(url: "", pairingToken: "unit-mutation-token")
        XCTAssertTrue(configured)
        MutationRequestProtocol.handler = { _ in
            XCTFail("No route should mean no HTTP traffic")
            throw URLError(.badURL)
        }
        let sent = await model.send("Hello", mode: .auto, sessionID: sessionID)
        XCTAssertFalse(sent)
        XCTAssertTrue(model.errorMessage?.contains("was not sent") == true)
        XCTAssertFalse(model.errorMessage?.contains("may have reached") == true)
    }

    func testPostFailuresAreUncertainAndNeverReplayed() async throws {
        for networkFailure in [false, true] {
            let model = try await model()
            let response = snapshot()
            var methods: [String] = []
            MutationRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                if request.httpMethod == "POST" {
                    if networkFailure { throw URLError(.networkConnectionLost) }
                    return (503, Data(#"{"error":"Proxy unavailable"}"#.utf8))
                }
                return (200, response)
            }
            let sent = await model.send("Hello", mode: .auto, sessionID: sessionID)
            XCTAssertFalse(sent)
            XCTAssertEqual(methods, ["GET", "POST"])
            XCTAssertTrue(model.errorMessage?.contains("may have reached Cantrip") == true)
            XCTAssertFalse(model.errorMessage?.contains("was not sent") == true)
            XCTAssertFalse(model.isConnected)
            model.clearConfiguration()
        }
    }

    func testCapabilityAndAuthenticationRejectionsDoNotWriteOrClaimUncertainDelivery() async throws {
        for status in [200, 401] {
            let model = try await model()
            let response = snapshot(capabilities: false)
            var methods: [String] = []
            MutationRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                return (status, response)
            }
            let sent = await model.send("Hello", mode: .auto, sessionID: sessionID)
            XCTAssertFalse(sent)
            XCTAssertEqual(methods, ["GET"])
            XCTAssertTrue(model.errorMessage?.contains(status == 401 ? "pairing token" : "Auto sending") == true)
            XCTAssertFalse(model.errorMessage?.contains("may have reached") == true)
            model.clearConfiguration()
        }
    }

    func testOtherMutationsAlsoRecoverAndReuseTheirCapabilityChecks() async throws {
        let operations: [(String, (CantripRemoteModel) async -> Bool)] = [
            ("POST", { await $0.createSession() }),
            ("POST", { await $0.stop(sessionID: self.sessionID) }),
            ("POST", { await $0.resume() }),
            ("POST", { await $0.newConversation() }),
            ("POST", { await $0.updateTab(self.sessionID, name: "Renamed", isLocked: true) }),
            ("DELETE", { await $0.removeQueuedPrompt("pending", sessionID: self.sessionID) })
        ]
        for (method, operation) in operations {
            let model = try await model()
            var methods: [String] = []
            MutationRequestProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
            await model.selectSession(sessionID)
            MutationRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                return (200, self.snapshot(
                    list: request.httpMethod == "GET" && request.url?.path == "/api/v1/sessions"
                ))
            }
            let succeeded = await operation(model)
            XCTAssertTrue(succeeded, model.errorMessage ?? "Expected recovered mutation")
            XCTAssertEqual(methods, ["GET", method])
            model.clearConfiguration()
        }
    }

    private func seedTabs(_ model: CantripRemoteModel, ids: [String]) async throws {
        for id in ids {
            MutationRequestProtocol.handler = { request in
                (200, self.snapshot(list: request.httpMethod == "GET", id: id))
            }
            let created = await model.createSession()
            XCTAssertTrue(created, model.errorMessage ?? "Could not create fixture tab")
        }
    }

    func testTabMoveAppliesAuthoritativeOrderWithoutChangingSelectionOrTranscript() async throws {
        let model = try await model()
        let otherID = "00000000-0000-0000-0000-000000000002"
        let addedID = "00000000-0000-0000-0000-000000000003"
        try await seedTabs(model, ids: [sessionID, otherID])
        let selected = model.selectedSession
        let revision = model.transcriptRevision
        var methods: [String] = []
        MutationRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            XCTAssertTrue(model.isReorderingTabs)
            XCTAssertEqual(model.sessions.map(\.id), [otherID, self.sessionID],
                           "The list must show the dropped order while the host responds")
            if request.httpMethod == "GET" { return (200, self.snapshot(id: otherID)) }
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(otherID)/move")
            let data: Data
            if let body = request.httpBody {
                data = body
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1024)
                var body = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: bytes.prefix(count))
                }
                data = body
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(body, ["targetID": self.sessionID, "placement": "before"])
            let sessions = try [otherID, self.sessionID, addedID].map { id -> [String: Any] in
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: self.snapshot(id: id)) as? [String: Any])
                var session = try XCTUnwrap(payload["session"] as? [String: Any])
                session.removeValue(forKey: "messages")
                return session
            }
            return (200, try JSONSerialization.data(withJSONObject: ["sessions": sessions]))
        }
        let moved = await model.moveTab(otherID, offset: -1)
        XCTAssertTrue(moved, model.errorMessage ?? "Expected reorder")
        XCTAssertEqual(methods, ["GET", "POST"])
        XCTAssertEqual(model.sessions.map(\.id), [otherID, sessionID, addedID])
        XCTAssertEqual(model.selectedSessionID, otherID)
        XCTAssertEqual(model.selectedSession, selected)
        XCTAssertEqual(model.transcriptRevision, revision)
        XCTAssertFalse(model.isMutating)
        XCTAssertFalse(model.isReorderingTabs)
    }

    func testTabMoveRejectsOldHostsAndNeverReplaysAnUncertainWrite() async throws {
        let otherID = "00000000-0000-0000-0000-000000000002"
        for failure in ["legacy", "offline", "post", "closed"] {
            let model = try await model()
            try await seedTabs(model, ids: [sessionID, otherID])
            let order = model.sessions.map(\.id)
            var methods: [String] = []
            MutationRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                if failure == "offline" || request.httpMethod == "POST" {
                    if failure == "closed" { return (404, Data(#"{"error":"session not found"}"#.utf8)) }
                    throw URLError(.networkConnectionLost)
                }
                var data = self.snapshot(id: otherID)
                if failure == "legacy" {
                    var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    var session = try XCTUnwrap(payload["session"] as? [String: Any])
                    session.removeValue(forKey: "supportsTabReordering")
                    payload["session"] = session
                    data = try JSONSerialization.data(withJSONObject: payload)
                }
                return (200, data)
            }
            let moved = await model.moveTab(otherID, offset: -1)
            XCTAssertFalse(moved)
            XCTAssertEqual(methods, failure == "legacy" || failure == "offline" ? ["GET"] : ["GET", "POST"])
            XCTAssertEqual(model.sessions.map(\.id), order, "Failed moves must not leave an optimistic order")
            XCTAssertEqual(model.selectedSessionID, otherID)
            if failure == "legacy" {
                XCTAssertTrue(model.errorMessage?.contains("reorder") == true)
            } else if failure == "offline" {
                XCTAssertTrue(model.errorMessage?.contains("was not sent") == true)
            } else if failure == "post" {
                XCTAssertTrue(model.errorMessage?.contains("may have reached") == true)
            }
            XCTAssertFalse(model.isMutating)
            XCTAssertFalse(model.isReorderingTabs)
            model.clearConfiguration()
        }
    }

    func testInvalidTabMoveDoesNotMakeRequests() async throws {
        let model = try await model()
        let otherID = "00000000-0000-0000-0000-000000000002"
        try await seedTabs(model, ids: [sessionID, otherID])
        MutationRequestProtocol.handler = { _ in
            XCTFail("Invalid or self moves must not send a request")
            throw URLError(.badURL)
        }
        let selfMove = await model.moveTab(sessionID, relativeTo: sessionID, after: false)
        XCTAssertTrue(selfMove)
        for (id, offset) in [(sessionID, -1), (otherID, 1), ("closed", 1)] {
            let moved = await model.moveTab(id, offset: offset)
            XCTAssertFalse(moved)
            XCTAssertNotNil(model.errorMessage)
        }
        let missing = await model.moveTab(sessionID, relativeTo: "closed", after: true)
        XCTAssertFalse(missing)
    }

    func testDrawerStaysOpenThroughDelayedReorderAndFailureRollback() async throws {
        for fails in [false, true] {
            let model = try await model()
            let otherID = "00000000-0000-0000-0000-000000000002"
            try await seedTabs(model, ids: [sessionID, otherID])
            let state = ReorderDrawerState()
            let controller = UIHostingController(rootView: ReorderDrawerHarness(model: model, state: state))
            controller.traitOverrides.horizontalSizeClass = .compact
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            )
            let window = UIWindow(windowScene: scene)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(300))
            state.presented = true
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(state.presented)
            let selected = model.selectedSession
            let revision = model.transcriptRevision
            MutationRequestProtocol.handler = { request in
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertTrue(model.isMutating)
                XCTAssertTrue(model.isReorderingTabs)
                XCTAssertTrue(state.presented, "Saving a reorder must not dismiss the drawer")
                XCTAssertEqual(model.sessions.map(\.id), [otherID, self.sessionID])
                if request.httpMethod == "GET" { return (200, self.snapshot(id: otherID)) }
                if fails { return (404, Data(#"{"error":"session not found"}"#.utf8)) }
                let tabs = try [otherID, self.sessionID].map { id -> Any in
                    let payload = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: self.snapshot(id: id)) as? [String: Any]
                    )
                    return try XCTUnwrap(payload["session"])
                }
                return (200, try JSONSerialization.data(withJSONObject: ["sessions": tabs]))
            }
            let moved = await model.moveTab(otherID, offset: -1)
            XCTAssertEqual(moved, !fails)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(state.presented)
            XCTAssertEqual(model.sessions.map(\.id), fails ? [sessionID, otherID] : [otherID, sessionID])
            XCTAssertEqual(model.selectedSession, selected)
            XCTAssertEqual(model.transcriptRevision, revision)
            XCTAssertEqual(state.chatAppearances, 1)
            XCTAssertFalse(model.isReorderingTabs)
            XCTAssertFalse(model.isMutating)
            model.clearConfiguration()
        }
    }
}

@MainActor
private final class ReorderDrawerState: ObservableObject {
    @Published var presented = false
    var chatAppearances = 0
}

private struct ReorderDrawerHarness: View {
    @ObservedObject var model: CantripRemoteModel
    @ObservedObject var state: ReorderDrawerState

    var body: some View {
        ChatNavigationView(
            isTabListPresented: $state.presented, hasTabs: true,
            canSelectTabs: !model.isMutating, isReorderingTabs: model.isReorderingTabs
        ) { modal, dismiss in
            CantripSessionDrawer(
                model: model, isModal: modal, onDismiss: dismiss,
                onSelect: { _ in XCTFail("Moving must not select") },
                onCreate: {}, onRename: { _ in }, onClose: { _ in }
            )
        } content: {
            Text("Existing conversation").onAppear { state.chatAppearances += 1 }
        }
    }
}
