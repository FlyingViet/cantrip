import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class StopRequestProtocol: URLProtocol {
    @MainActor static var handler: ((StopRequestProtocol) throws -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            do {
                try XCTUnwrap(Self.handler)(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    func respond(_ data: Data, status: Int = 200) throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        ))
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class CantripStopTests: XCTestCase {
    private let firstID = "00000000-0000-0000-0000-000000000001"
    private let secondID = "00000000-0000-0000-0000-000000000002"

    private func snapshot(id: String, streaming: Bool, locked: Bool = true) -> Data {
        let queued = streaming ? #"[{"id":"pending","text":"Next prompt"}]"# : "[]"
        return Data("""
        {"session":{"id":"\(id)","title":"Project","workdir":"/tmp",
        "isStreaming":\(streaming),"canResume":false,"councilMode":false,
        "isLocked":\(locked),"queuedCount":\(streaming ? 1 : 0),"queued":\(queued),
        "messages":[{"id":"reply","role":"assistant","text":"Existing reply",
        "thinking":"","activities":[]}]}}
        """.utf8)
    }

    private func session(streaming: Bool) throws -> CantripRemoteSession {
        struct Response: Decodable { let session: CantripRemoteSession }
        return try JSONDecoder().decode(
            Response.self, from: snapshot(id: firstID, streaming: streaming)
        ).session
    }

    private func model() async throws -> CantripRemoteModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StopRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: configuration))
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "unit-stop-token", tailscaleOnly: true
        )
        return try XCTUnwrap(configured ? model : nil, model.errorMessage ?? "Configuration failed")
    }

    private func button(
        session: CantripRemoteSession?, connected: Bool = true,
        mutating: Bool = false, stopping: Bool = false
    ) -> CantripStopButton {
        CantripStopButton(
            session: session, isConnected: connected, isMutating: mutating,
            isStopping: stopping, onStop: { _ in }
        )
    }

    func testVisibilityAndAvailabilityFollowRemoteWorkNotLocalSendingOrTabLock() throws {
        let busy = try session(streaming: true)
        let idle = try session(streaming: false)
        XCTAssertTrue(button(session: busy).isVisible)
        XCTAssertTrue(button(session: busy).isEnabled, "Locks must not block Stop")
        XCTAssertNil(busy.supportsTabMetadata, "Stop works on legacy hosts too")
        XCTAssertFalse(button(session: idle).isVisible)
        XCTAssertFalse(button(session: nil).isVisible)
        XCTAssertFalse(button(session: nil).isEnabled)
        XCTAssertFalse(button(session: idle).isEnabled)
        XCTAssertTrue(button(session: busy, connected: false).isVisible)
        XCTAssertFalse(button(session: busy, connected: false).isEnabled)
        XCTAssertFalse(button(session: busy, mutating: true).isEnabled)
        XCTAssertTrue(button(session: idle, mutating: true, stopping: true).isVisible)
        XCTAssertFalse(button(session: busy, stopping: true).isEnabled)
    }

    func testCompactButtonPreservesTapTargetAtLargeTextSizes() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        for stopping in [false, true] {
            for size: DynamicTypeSize in [.large, .accessibility3, .accessibility5] {
                let control = button(session: try session(streaming: true), stopping: stopping)
                    .environment(\.dynamicTypeSize, size)
                let controller = UIHostingController(rootView: control)
                controller.safeAreaRegions = []
                let window = UIWindow(windowScene: scene)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                controller.view.layoutIfNeeded()
                let measured = controller.sizeThatFits(in: CGSize(width: 180, height: 500))
                XCTAssertGreaterThanOrEqual(measured.width, 44)
                XCTAssertLessThanOrEqual(measured.width, 128)
                XCTAssertEqual(measured.height, 44, accuracy: 0.5)
                if size == .large || size == .accessibility5 {
                    window.frame = CGRect(origin: .zero, size: measured)
                    controller.view.frame = window.bounds
                    controller.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                        controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "compact-stop-\(stopping ? "pending" : "ready")-\(size)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testStopPostsOnceAndWaitsForAuthoritativeLockedSessionSnapshot() async throws {
        let model = try await model()
        defer {
            model.clearConfiguration()
            StopRequestProtocol.handler = nil
        }
        let before = snapshot(id: firstID, streaming: true)
        let after = snapshot(id: firstID, streaming: false)
        let requested = expectation(description: "Cancel reached the host")
        var pending: StopRequestProtocol?
        var mutations = 0
        StopRequestProtocol.handler = { transport in
            if transport.request.httpMethod == "POST" {
                mutations += 1
                XCTAssertEqual(transport.request.url?.path, "/api/v1/sessions/\(self.firstID)/cancel")
                XCTAssertEqual(
                    transport.request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer unit-stop-token"
                )
                XCTAssertNil(transport.request.httpBody)
                pending = transport
                requested.fulfill()
            } else {
                try transport.respond(before)
            }
        }
        await model.selectSession(firstID)
        let stopping = Task { await model.stop(sessionID: firstID) }
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertTrue(model.isMutating)
        XCTAssertEqual(model.stoppingSessionID, firstID)
        XCTAssertEqual(model.selectedSession?.isStreaming, true)
        XCTAssertEqual(model.selectedSession?.queuedCount, 1, "Do not optimistically clear the queue")
        let duplicate = await model.stop(sessionID: firstID)
        XCTAssertFalse(duplicate)
        XCTAssertNotNil(model.errorMessage)
        try XCTUnwrap(pending).respond(after)
        let stopped = await stopping.value
        XCTAssertTrue(stopped)
        XCTAssertEqual(mutations, 1)
        XCTAssertFalse(model.isMutating)
        XCTAssertNil(model.stoppingSessionID)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.selectedSession?.isStreaming, false)
        XCTAssertEqual(model.selectedSession?.isLocked, true)
        XCTAssertEqual(model.selectedSession?.queuedCount, 0)
        XCTAssertEqual(model.selectedSession?.transcript.first?.text, "Existing reply")
    }

    func testStopTargetsTappedTabWhenSelectionChangesBeforeTaskRuns() async throws {
        let model = try await model()
        defer {
            model.clearConfiguration()
            StopRequestProtocol.handler = nil
        }
        var cancelledIDs: [String] = []
        StopRequestProtocol.handler = { transport in
            let path = try XCTUnwrap(transport.request.url).path
            let id = path.contains(self.secondID) ? self.secondID : self.firstID
            let stopping = transport.request.httpMethod == "POST"
            if stopping {
                XCTAssertTrue(path.hasSuffix("/cancel"))
                cancelledIDs.append(id)
            }
            try transport.respond(self.snapshot(id: id, streaming: !stopping))
        }
        let env = HermesEnv()
        let originalLane = env.executionLane
        env.select(.cantrip)
        defer { env.select(originalLane) }
        let vm = ChatViewModel(env: env, remote: model, voice: VoiceController())
        let stopped = expectation(description: "Tapped tab finished stopping")
        var started = false
        let observation = model.$stoppingSessionID.sink { id in
            if id != nil {
                started = true
            } else if started {
                stopped.fulfill()
            }
        }
        defer { observation.cancel() }
        // Let initialization sync the empty model, then load the remote tab without
        // updating the view model's mirror (a poll can render before its onChange).
        await Task.yield()
        await model.selectSession(firstID)
        XCTAssertFalse(vm.remoteIsStreaming)
        vm.stop()
        await model.selectSession(secondID)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(cancelledIDs, [firstID])
        XCTAssertEqual(model.selectedSessionID, secondID)
        XCTAssertEqual(model.selectedSession?.isStreaming, true)
        XCTAssertEqual(model.selectedSession?.queuedCount, 1)
    }

    func testSharedChatRendersWorkingAndPausedComposersWithoutMutations() async throws {
        let model = try await model()
        let env = HermesEnv()
        let originalLane = env.executionLane
        let originalPause = UserDefaults.standard.object(forKey: "hermes.paused")
        env.select(.cantrip)
        defer {
            env.select(originalLane)
            if let originalPause {
                UserDefaults.standard.set(originalPause, forKey: "hermes.paused")
            } else {
                UserDefaults.standard.removeObject(forKey: "hermes.paused")
            }
            model.clearConfiguration()
            StopRequestProtocol.handler = nil
        }
        StopRequestProtocol.handler = { transport in
            XCTAssertEqual(transport.request.httpMethod, "GET")
            if transport.request.url?.path == "/api/v1/copilot/usage" {
                try transport.respond(Data(#"{"isRefreshing":false}"#.utf8))
            } else {
                try transport.respond(self.snapshot(id: self.firstID, streaming: true))
            }
        }
        await model.selectSession(firstID)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        for paused in [false, true] {
            UserDefaults.standard.set(paused, forKey: "hermes.paused")
            let controller = UIHostingController(rootView: ChatView(env: env, remote: model))
            let window = UIWindow(windowScene: scene)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = paused ? "shared-chat-paused" : "shared-chat-working"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(image.size.height, 700)
            XCTAssertEqual(model.selectedSessionID, firstID)
            XCTAssertEqual(model.selectedSession?.isStreaming, true)
            XCTAssertEqual(model.selectedSession?.queuedCount, 1)
            XCTAssertFalse(model.isMutating)
            XCTAssertEqual(env.executionLane, .cantrip)
        }
    }

    func testFailedStopSurfacesErrorWithoutReplayOrClearingWork() async throws {
        for networkFailure in [false, true] {
            let model = try await model()
            defer {
                model.clearConfiguration()
                StopRequestProtocol.handler = nil
            }
            var mutations = 0
            StopRequestProtocol.handler = { transport in
                if transport.request.httpMethod == "POST" {
                    mutations += 1
                    if networkFailure { throw URLError(.networkConnectionLost) }
                    try transport.respond(Data(#"{"error":"Stop rejected by host"}"#.utf8), status: 500)
                } else {
                    try transport.respond(self.snapshot(id: self.firstID, streaming: true))
                }
            }
            await model.selectSession(firstID)
            let stopped = await model.stop(sessionID: firstID)
            XCTAssertFalse(stopped)
            XCTAssertEqual(mutations, 1)
            XCTAssertEqual(model.selectedSession?.isStreaming, true)
            XCTAssertEqual(model.selectedSession?.queuedCount, 1)
            XCTAssertNil(model.stoppingSessionID)
            XCTAssertFalse(model.isMutating)
            if networkFailure {
                XCTAssertTrue(model.errorMessage?.contains("may have reached Cantrip") == true)
                XCTAssertFalse(model.isConnected)
            } else {
                XCTAssertEqual(model.errorMessage, "Cantrip returned HTTP 500: Stop rejected by host")
            }
        }
    }
}
