import Foundation
import XCTest
@testable import Hermes

private final class HistoryRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { responseTask?.cancel() }
    override func startLoading() {
        responseTask = Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try await handler(request)
                try Task.checkCancellation()
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
final class CantripHistoryTests: XCTestCase {
    private let id = "00000000-0000-0000-0000-000000000001"
    private func messageID(_ value: Int) -> String {
        String(format: "00000000-0000-0000-0001-%012d", value)
    }

    private func session(revision: String = "r1", start: String = "start", values: [Int] = [3, 4],
                         older: Bool = true, list: Bool = false, title: String = "Tab",
                         legacy: Bool = false) throws -> Data {
        var session: [String: Any] = [
            "id": id, "title": title, "workdir": "/tmp", "isStreaming": false,
            "canResume": false, "councilMode": false, "queuedCount": 0,
        ]
        if !legacy {
            session["supportsPagedHistory"] = true
            session["historyRevision"] = revision
            if !list {
                session["historyStartID"] = start
                session["hasOlderMessages"] = older
            }
        }
        if !list {
            session["messages"] = values.map { value in
                ["id": messageID(value), "role": "assistant", "text": "Reply \(value)",
                 "thinking": "", "activities": []] as [String: Any]
            }
        }
        return try JSONSerialization.data(withJSONObject: list ? ["sessions": [session]] : ["session": session])
    }

    private func model() async throws -> CantripRemoteModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HistoryRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        let model = CantripRemoteModel(urlSession: client)
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "history-test-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured, model.errorMessage ?? "Configuration failed")
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            client.invalidateAndCancel()
            HistoryRequestProtocol.handler = nil
        }
        return model
    }

    private func waitForRefresh(_ model: CantripRemoteModel) async throws {
        for _ in 0..<200 {
            if model.selectedSession != nil && !model.isRefreshing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(model.errorMessage ?? model.detailError ?? "No conversation loaded")
    }

    func testBoundedQueriesConditionalRefreshAndLegacyFallback() async throws {
        let model = try await model()
        var paths: [String] = []
        HistoryRequestProtocol.handler = { request in
            paths.append(request.url!.path)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(items.contains(URLQueryItem(name: "history", value: "recent")))
            XCTAssertEqual(request.timeoutInterval, 3, "Keep fast dead-route detection")
            return (200, try self.session(list: request.url!.path == "/api/v1/sessions"))
        }
        model.setAppActive(true)
        try await waitForRefresh(model)
        XCTAssertEqual(model.pollDelay, .seconds(5))
        let initialRevision = model.transcriptRevision
        await model.refreshNow()
        XCTAssertEqual(paths.filter { $0 != "/api/v1/sessions" }.count, 1,
                       "An unchanged summary must not download the conversation again")
        XCTAssertEqual(model.transcriptRevision, initialRevision)
        HistoryRequestProtocol.handler = { request in
            if request.url!.path == "/api/v1/sessions" {
                return (200, try self.session(revision: "r2", list: true))
            }
            XCTAssertTrue(request.url!.query!.contains("revision=r1"))
            return (200, Data(#"{"unchanged":true}"#.utf8))
        }
        await model.refreshNow()
        XCTAssertEqual(model.selectedSession?.transcript.count, 2)
        XCTAssertNil(model.detailError)
        HistoryRequestProtocol.handler = { request in
            (200, try self.session(values: [1, 2, 3, 4], list: request.url!.path == "/api/v1/sessions", legacy: true))
        }
        await model.refreshNow()
        XCTAssertEqual(model.selectedSession?.transcript.count, 4)
        XCTAssertNil(model.selectedSession?.hasOlderMessages)
    }

    func testSlowDetailPublishesTabsAndKeepsConnectionAndCachedTranscript() async throws {
        let model = try await model()
        HistoryRequestProtocol.handler = { request in
            (200, try self.session(list: request.url!.path == "/api/v1/sessions"))
        }
        model.setAppActive(true)
        try await waitForRefresh(model)
        HistoryRequestProtocol.handler = { request in
            if request.url!.path == "/api/v1/sessions" {
                return (200, try self.session(revision: "r2", list: true, title: "Updated tab"))
            }
            XCTAssertEqual(model.sessions.first?.title, "Updated tab",
                           "Publish the successful list before awaiting detail")
            throw URLError(.timedOut)
        }
        await model.refreshNow()
        XCTAssertEqual(model.sessions.first?.title, "Updated tab")
        XCTAssertEqual(model.selectedSession?.transcript.count, 2)
        XCTAssertTrue(model.isConnected)
        XCTAssertNotNil(model.detailError)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.pollDelay, .milliseconds(1500))
        HistoryRequestProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        await model.refreshNow()
        XCTAssertEqual(model.connectionState, .reconnecting)
        XCTAssertEqual(model.selectedSession?.transcript.count, 2)
    }

    func testOlderHistorySurvivesRefreshWithoutDuplicatesAndResetReplacesIt() async throws {
        let model = try await model()
        HistoryRequestProtocol.handler = { request in
            (200, try self.session(list: request.url!.path == "/api/v1/sessions"))
        }
        model.setAppActive(true)
        try await waitForRefresh(model)
        HistoryRequestProtocol.handler = { request in
            XCTAssertTrue(request.url!.query!.contains("before=\(self.messageID(3))"))
            return (200, try self.session(values: [1, 2], older: false))
        }
        await model.loadOlderMessages()
        XCTAssertEqual(model.selectedSession?.transcript.map(\.text), (1...4).map { "Reply \($0)" })
        XCTAssertEqual(model.historyPrependAnchor, messageID(3))
        XCTAssertEqual(model.historyPrependRevision, 1)
        XCTAssertEqual(model.selectedSession?.hasOlderMessages, false)
        HistoryRequestProtocol.handler = { request in
            (200, try self.session(revision: "r2", values: [4, 5], list: request.url!.path == "/api/v1/sessions"))
        }
        await model.refreshNow()
        XCTAssertEqual(model.selectedSession?.transcript.map(\.text), (1...5).map { "Reply \($0)" })
        HistoryRequestProtocol.handler = { request in
            (200, try self.session(revision: "reset", start: "new", values: [6],
                                  older: false, list: request.url!.path == "/api/v1/sessions"))
        }
        await model.refreshNow()
        XCTAssertEqual(model.selectedSession?.transcript.map(\.text), ["Reply 6"])
    }

    func testOlderHistoryFailureAndServerSwitchDoNotMixTranscripts() async throws {
        let model = try await model()
        HistoryRequestProtocol.handler = { request in
            (200, try self.session(list: request.url!.path == "/api/v1/sessions"))
        }
        model.setAppActive(true)
        try await waitForRefresh(model)
        HistoryRequestProtocol.handler = { _ in
            (409, Data(#"{"error":"History changed"}"#.utf8))
        }
        await model.loadOlderMessages()
        XCTAssertEqual(model.selectedSession?.transcript.count, 2)
        XCTAssertNotNil(model.detailError)
        XCTAssertFalse(model.isLoadingHistory)
        model.setAppActive(false)
        let switched = await model.configure(url: "https://other.example", pairingToken: "other-token", tailscaleOnly: true)
        XCTAssertTrue(switched)
        XCTAssertNil(model.selectedSession)
        XCTAssertNil(model.detailError)
        HistoryRequestProtocol.handler = { _ in throw URLError(.timedOut) }
        await model.selectSession(id)
        XCTAssertNil(model.selectedSession, "Never show another server's cached conversation")
    }

    func testExplicitFullMessageDownloadDoesNotBlockLightweightRefresh() async throws {
        let model = try await model()
        var release: CheckedContinuation<Void, Never>?
        var lists = 0
        HistoryRequestProtocol.handler = { request in
            if request.url!.path.contains("/messages/") {
                XCTAssertEqual(request.timeoutInterval, 20)
                await withCheckedContinuation { release = $0 }
                return (200, try JSONSerialization.data(withJSONObject: [
                    "message": ["id": self.messageID(4), "role": "assistant",
                                "text": "Full response", "thinking": "", "activities": []]
                ]))
            }
            let list = request.url!.path == "/api/v1/sessions"
            if list { lists += 1 }
            return (200, try self.session(list: list))
        }
        model.setAppActive(true)
        try await waitForRefresh(model)
        let download = Task { try await model.fullMessage(sessionID: id, messageID: messageID(4)) }
        for _ in 0..<100 {
            if release != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(release)
        let before = lists
        await model.refreshNow()
        XCTAssertEqual(lists, before + 1)
        XCTAssertTrue(model.isConnected)
        release?.resume()
        let message = try await download.value
        XCTAssertEqual(message.text, "Full response")
    }

    func testCachedSelectionAndMissedWindowNeverInventHistoryContinuity() async throws {
        let model = try await model()
        HistoryRequestProtocol.handler = { _ in (200, try self.session()) }
        await model.selectSession(id)
        HistoryRequestProtocol.handler = { _ in throw URLError(.timedOut) }
        await model.selectSession("00000000-0000-0000-0000-000000000002")
        await model.selectSession(id)
        XCTAssertEqual(model.selectedSession?.transcript.count, 2, "A failed revisit keeps cached history")
        HistoryRequestProtocol.handler = { request in
            (200, try self.session(revision: "gap", values: [10, 11], list: request.url!.path == "/api/v1/sessions"))
        }
        model.setAppActive(true)
        for _ in 0..<200 {
            if model.selectedSession?.historyRevision == "gap", !model.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.selectedSession?.transcript.map(\.text), ["Reply 10", "Reply 11"])
        XCTAssertEqual(model.selectedSession?.hasOlderMessages, true,
                       "A missed window must be filled by paging, not concatenated across a gap")
    }

    func testUnattendedHistoryStaysBoundedUntilExplicitlyExpanded() async throws {
        let model = try await model()
        var step = 0
        HistoryRequestProtocol.handler = { request in
            (200, try self.session(revision: "r\(step)", values: Array((step * 20)..<(step * 20 + 30)),
                                  list: request.url!.path == "/api/v1/sessions"))
        }
        model.setAppActive(true)
        try await waitForRefresh(model)
        for next in 1...7 {
            step = next
            await model.refreshNow()
        }
        XCTAssertEqual(model.selectedSession?.transcript.count, 120)
        XCTAssertEqual(model.selectedSession?.transcript.first?.id, messageID(50))
        HistoryRequestProtocol.handler = { _ in
            (200, try self.session(revision: "r7", values: Array(40..<50)))
        }
        await model.loadOlderMessages()
        XCTAssertEqual(model.selectedSession?.transcript.count, 130,
                       "Only explicit older-history loading expands the rolling memory window")
    }
}
