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
                         legacy: Bool = false, fullContent: Bool = false) throws -> Data {
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
                ["id": messageID(value), "role": "assistant",
                 "text": fullContent ? String(repeating: "Reply \(value)\n", count: 4000) : "Reply \(value)",
                 "thinking": fullContent ? String(repeating: "Reasoning\n", count: 1000) : "",
                 "activities": fullContent ? (0..<60).map {
                     ["id": "tool-\($0)", "title": "Step \($0)", "toolName": "bash",
                      "state": "succeeded", "input": "Input \($0)", "output": "Output \($0)"]
                 } : []] as [String: Any]
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

    func testPagedQueriesConditionalRefreshAndLegacyFallback() async throws {
        let model = try await model()
        var paths: [String] = []
        HistoryRequestProtocol.handler = { request in
            paths.append(request.url!.path)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(items.contains(URLQueryItem(name: "history", value: "recent")))
            XCTAssertEqual(request.timeoutInterval, request.url!.path == "/api/v1/sessions" ? 3 : 20,
                           "Only conversation reads receive a larger download budget")
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

    func testFullContentLoadsByDefaultAndOlderPagesRequireExplicitRequest() async throws {
        let model = try await model()
        var olderReads = 0
        HistoryRequestProtocol.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertFalse(request.url!.path.contains("/messages/"), "No per-message detail request is needed")
            let older = items.contains { $0.name == "before" }
            if older {
                olderReads += 1
                XCTAssertEqual(items.first { $0.name == "before" }?.value, self.messageID(3))
            }
            return (200, try self.session(values: older ? [1, 2] : [3, 4], older: !older,
                                          list: request.url!.path == "/api/v1/sessions", fullContent: true))
        }
        model.setAppActive(true)
        try await waitForRefresh(model)
        await model.refreshNow()
        XCTAssertEqual(olderReads, 0)
        let recent = try XCTUnwrap(model.selectedSession?.transcript.last)
        XCTAssertEqual(recent.text, String(repeating: "Reply 4\n", count: 4000))
        XCTAssertEqual(recent.thinking, String(repeating: "Reasoning\n", count: 1000))
        XCTAssertEqual(recent.activities.count, 60)
        XCTAssertEqual(recent.activities.first?.input, "Input 0")
        XCTAssertEqual(recent.activities.last?.output, "Output 59")
        XCTAssertNotEqual(recent.isPreview, true)
        let env = HermesEnv()
        env.select(.cantrip)
        let vm = ChatViewModel(env: env, remote: model, voice: VoiceController())
        vm.syncRemoteTranscript()
        XCTAssertEqual(vm.turns.last?.text, recent.text)
        XCTAssertEqual(vm.turns.last?.thinking, recent.thinking)
        XCTAssertEqual(vm.turns.last?.tools.first?.arguments, "Step 0\nInput 0")
        XCTAssertEqual(vm.turns.last?.tools.last?.output, "Output 59")
        await model.loadOlderMessages()
        XCTAssertEqual(olderReads, 1)
        let oldest = try XCTUnwrap(model.selectedSession?.transcript.first)
        XCTAssertEqual(oldest.text, String(repeating: "Reply 1\n", count: 4000))
        XCTAssertEqual(oldest.thinking, recent.thinking)
        XCTAssertEqual(oldest.activities, recent.activities)
        XCTAssertEqual(model.selectedSession?.transcript.count, 4)
        await model.refreshNow()
        XCTAssertEqual(olderReads, 1, "Refresh never prefetches more old history")
    }

    func testSlowRecentPageKeepsPollingAndDoesNotBlockMutations() async throws {
        let model = try await model()
        let started = expectation(description: "Conversation download started")
        let polled = expectation(description: "Tabs refreshed during conversation download")
        var release: CheckedContinuation<Void, Never>?
        var lists = 0
        var details = 0
        HistoryRequestProtocol.handler = { request in
            let list = request.url!.path == "/api/v1/sessions" && request.httpMethod == "GET"
            if list {
                lists += 1
                if lists == 2 { polled.fulfill() }
            } else if request.httpMethod == "GET" {
                details += 1
                started.fulfill()
                await withCheckedContinuation { release = $0 }
            }
            return (200, try self.session(list: list))
        }
        model.setAppActive(true)
        await fulfillment(of: [started, polled], timeout: 7)
        XCTAssertEqual(details, 1, "Polling must not duplicate an in-flight conversation download")
        XCTAssertTrue(model.isConnected)
        let created = expectation(description: "Mutation finished before history")
        let mutation = Task {
            let success = await model.createSession()
            XCTAssertTrue(success)
            created.fulfill()
        }
        await fulfillment(of: [created], timeout: 1)
        release?.resume()
        await mutation.value
        await model.refreshNow()
    }

    func testOlderPageDownloadDoesNotBlockTabRefresh() async throws {
        let model = try await model()
        var release: CheckedContinuation<Void, Never>?
        HistoryRequestProtocol.handler = { request in
            if request.url!.query!.contains("before=") {
                await withCheckedContinuation { release = $0 }
                return (200, try self.session(values: [1, 2], older: false))
            }
            return (200, try self.session(list: request.url!.path == "/api/v1/sessions"))
        }
        model.setAppActive(true)
        try await waitForRefresh(model)
        let download = Task { await model.loadOlderMessages() }
        for _ in 0..<100 {
            if release != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(release)
        let refreshed = expectation(description: "Lightweight refresh finishes while older page is loading")
        let refresh = Task { await model.refreshNow(); refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 1)
        release?.resume()
        await download.value
        await refresh.value
        XCTAssertEqual(model.selectedSession?.transcript.count, 4)
    }

    func testPollingDoesNotDuplicateAnExplicitTabLoad() async throws {
        let model = try await model()
        var release: CheckedContinuation<Void, Never>?
        var details = 0
        HistoryRequestProtocol.handler = { request in
            let list = request.url!.path == "/api/v1/sessions"
            if !list {
                details += 1
                await withCheckedContinuation { release = $0 }
            }
            return (200, try self.session(list: list))
        }
        let selection = Task { await model.selectSession(id) }
        for _ in 0..<100 {
            if release != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(release)
        model.setAppActive(true)
        await model.refreshNow()
        XCTAssertEqual(details, 1)
        release?.resume()
        await selection.value
        XCTAssertEqual(model.selectedSession?.transcript.count, 2)
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
