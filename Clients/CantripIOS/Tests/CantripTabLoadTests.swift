import Foundation
import XCTest
@testable import Hermes

/// A Mac stub whose tab reads can be dropped or held, to check that a tab whose load failed or is slow
/// reads as loading (never "No tab open") and recovers on its own.
private final class TabLoadRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { responseTask?.cancel() }

    override func startLoading() {
        responseTask = Task { @MainActor in
            do {
                let (status, data) = try await XCTUnwrap(Self.handler)(request)
                try Task.checkCancellation()
                let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status,
                                                             httpVersion: "HTTP/1.1",
                                                             headerFields: ["Content-Type": "application/json"]))
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
final class CantripTabLoadTests: XCTestCase {
    private let tabID = "60000000-0000-0000-0000-000000000001"
    /// Listed first, so polling opens it; the tests then open `tabID`.
    private let otherID = "60000000-0000-0000-0000-000000000009"

    private func session(messages: Bool, id: String? = nil, title: String = "Garden") -> String {
        let body = messages ? #","historyStartID":"start","hasOlderMessages":false,"messages":[{"id":"61000000-0000-0000-0000-000000000001","role":"assistant","text":"Loaded reply","thinking":"","activities":[]}]"# : ""
        return #"{"id":"\#(id ?? tabID)","title":"\#(title)","workdir":"/tmp","isStreaming":false,"canResume":false,"councilMode":false,"queuedCount":0,"supportsAutoDelivery":true,"supportsPagedHistory":true,"historyRevision":"r1"\#(body)}"#
    }

    private var listing: Data {
        Data(#"{"sessions":[\#(session(messages: false, id: otherID, title: "Other")),\#(session(messages: false))]}"#.utf8)
    }

    /// Answers the tab list and the first tab; nil for anything else.
    private func common(_ request: URLRequest) -> (Int, Data)? {
        switch path(request) {
        case "/api/v1/sessions": return (200, listing)
        case "/api/v1/sessions/\(otherID)":
            return (200, Data(#"{"session":\#(session(messages: true, id: otherID, title: "Other"))}"#.utf8))
        default: return nil
        }
    }

    private func path(_ request: URLRequest) -> String {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    }

    private func model() async throws -> CantripRemoteModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TabLoadRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        let model = CantripRemoteModel(urlSession: client)
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "tab-load-token",
                                               tailscaleOnly: true)
        XCTAssertTrue(configured, model.errorMessage ?? "configure failed")
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            client.invalidateAndCancel()
            TabLoadRequestProtocol.handler = nil
        }
        return model
    }

    private func until(_ seconds: Double = 6, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// The first read of the tab is dropped (the link timed out): the tab says why, with Retry, and the
    /// next poll loads it without the user doing anything.
    func testDroppedTabLoadRecoversOnItsOwn() async throws {
        var tabReads = 0
        TabLoadRequestProtocol.handler = { [unowned self] request in
            if let answer = self.common(request) { return answer }
            switch self.path(request) {
            case "/api/v1/sessions/\(self.tabID)":
                tabReads += 1
                if tabReads == 1 { throw URLError(.timedOut) }
                return (200, Data(#"{"session":\#(self.session(messages: true))}"#.utf8))
            default: return (404, Data(#"{"error":"not here"}"#.utf8))
            }
        }
        let model = try await model()
        model.setAppActive(true)
        try await until { model.selectedSession?.id == self.otherID }
        await model.selectSession(tabID)
        XCTAssertNil(model.selectedSession, "the first read was dropped")
        XCTAssertEqual(model.loadingTab?.title, "Garden", "the tab reads as loading by name, not as no tab")
        XCTAssertNotNil(model.detailError, "and says why")

        try await until { model.selectedSession?.transcript.last?.text == "Loaded reply" }
        XCTAssertEqual(model.selectedSession?.transcript.last?.text, "Loaded reply", "the poll loaded it")
        XCTAssertNil(model.loadingTab)
        XCTAssertNil(model.detailError)
        XCTAssertEqual(tabReads, 2)
    }

    /// A slow read (the conversation arrives seconds later) shows the tab loading the whole time, and
    /// polls in between don't start the same read again.
    func testSlowTabLoadShowsLoadingUntilItArrives() async throws {
        var tabReads = 0
        var release: CheckedContinuation<Void, Never>?
        TabLoadRequestProtocol.handler = { [unowned self] request in
            if let answer = self.common(request) { return answer }
            switch self.path(request) {
            case "/api/v1/sessions/\(self.tabID)":
                tabReads += 1
                if tabReads == 1 { await withCheckedContinuation { release = $0 } }
                return (200, Data(#"{"session":\#(self.session(messages: true))}"#.utf8))
            default: return (404, Data(#"{"error":"not here"}"#.utf8))
            }
        }
        let model = try await model()
        model.setAppActive(true)
        try await until { model.selectedSession?.id == self.otherID }
        let loading = Task { await model.selectSession(tabID) }
        try await until { release != nil }
        await model.refreshNow()
        await model.refreshNow()
        XCTAssertEqual(model.loadingTab?.title, "Garden", "still loading, by name")
        XCTAssertNil(model.detailError)
        XCTAssertEqual(tabReads, 1, "polls don't start the read again while it's on its way")
        release?.resume()
        await loading.value
        XCTAssertEqual(model.selectedSession?.transcript.last?.text, "Loaded reply")
        XCTAssertNil(model.loadingTab)
    }

    /// Tab reads ask for step summaries; a step the Mac sent without its details loads once when opened
    /// and is reused after that.
    func testSummarizedStepLoadsItsDetailsOnceWhenOpened() async throws {
        var queries: [String] = []
        var stepReads = 0
        let messageID = "61000000-0000-0000-0000-000000000002"
        TabLoadRequestProtocol.handler = { [unowned self] request in
            queries.append(request.url?.query ?? "")
            switch self.path(request) {
            case "/api/v1/sessions": return (200, Data(#"{"sessions":[\#(self.session(messages: false))]}"#.utf8))
            case "/api/v1/sessions/\(self.tabID)":
                let detail = self.session(messages: false).dropLast() + #","historyStartID":"start","messages":[{"id":"\#(messageID)","role":"assistant","text":"Done","thinking":"","activities":[{"id":"toolu_1","title":"Run checks","toolName":"bash","state":"succeeded","detailBytes":48000}]}]}"#
                return (200, Data(#"{"session":\#(detail)}"#.utf8))
            case "/api/v1/sessions/\(self.tabID)/messages/\(messageID)/steps/toolu_1":
                stepReads += 1
                return (200, Data(#"{"step":{"id":"toolu_1","title":"Run checks","toolName":"bash","state":"succeeded","input":"make check","output":"all passed"}}"#.utf8))
            default: return (404, Data(#"{"error":"not here"}"#.utf8))
            }
        }
        let model = try await model()
        await model.selectSession(tabID)
        let step = try XCTUnwrap(model.selectedSession?.transcript.last?.activities.first)
        XCTAssertEqual(step.detailBytes, 48_000)
        XCTAssertNil(step.output)
        XCTAssertTrue(queries.last?.contains("steps=summary") == true, "tab reads ask for summaries: \(queries)")

        let ref = CantripRemoteStepRef(sessionID: tabID, messageID: messageID, stepID: "toolu_1", bytes: 48_000)
        let loaded = try await model.stepDetails(ref)
        XCTAssertEqual(loaded.output, "all passed")
        XCTAssertEqual(loaded.input, "make check")
        _ = try await model.stepDetails(ref)
        XCTAssertEqual(stepReads, 1, "reopening a step reuses what was loaded")
    }
}
