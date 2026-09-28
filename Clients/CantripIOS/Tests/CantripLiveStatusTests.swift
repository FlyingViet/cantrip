import XCTest
@testable import Hermes

private final class LiveStatusRequestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status,
                                                          httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@MainActor
final class CantripLiveStatusTests: XCTestCase {
    private let hostJSON = #"""
    {"version":1,"generatedAt":1790577000.5,"hostName":"Mac mini","running":1,"needsInput":1,"total":9,
     "tabs":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Deploy it","state":"input","startedAt":1790576700,
              "finishedAt":null,"detail":"Approve the upload","queued":0,"subagents":0},
             {"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Audit notifications","state":"running",
              "startedAt":1790575740,"finishedAt":null,"detail":"Running tests","queued":2,"subagents":1},
             {"id":"8F9619FF-8B86-D011-B42D-00C04FC964FF","title":"","state":"done","startedAt":null,
              "finishedAt":1790576280,"detail":null,"queued":0,"subagents":0},
             {"id":"9F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Future","state":"paused-by-newer-host"},
             {"id":"AF9619FF-8B86-D011-B42D-00C04FC964FF","title":"E","state":"failed","finishedAt":1790570000},
             {"id":"BF9619FF-8B86-D011-B42D-00C04FC964FF","title":"F","state":"stopped","finishedAt":1790560000}]}
    """#

    func testDecodesHostSnapshotAndToleratesNewStates() throws {
        let snapshot = try CantripLiveStatusFetcher.decode(Data(hostJSON.utf8))
        XCTAssertEqual(snapshot.hostName, "Mac mini")
        XCTAssertEqual(snapshot.tabs.map(\.status), [.input, .running, .done, .running, .failed, .stopped])
        XCTAssertEqual(snapshot.tabs[1].startDate, Date(timeIntervalSince1970: 1_790_575_740))
        XCTAssertEqual(snapshot.tabs[1].queued, 2)
        XCTAssertEqual(snapshot.tabs[2].displayTitle, "Untitled tab")
        XCTAssertEqual(snapshot.tabs[3].queued, 0, "missing counts default to zero")
        XCTAssertEqual(snapshot.summary, "1 needs input · 1 running")
        XCTAssertTrue(snapshot.isActive)
    }

    func testLiveActivityStateCarriesAtMostFiveTabs() throws {
        let snapshot = try CantripLiveStatusFetcher.decode(Data(hostJSON.utf8))
        let state = CantripTabsAttributes.ContentState(snapshot)
        XCTAssertEqual(state.tabs.count, 5)
        XCTAssertEqual(state.updatedAt, snapshot.generatedAt)
        XCTAssertEqual(state.oldestRunningStart, Date(timeIntervalSince1970: 1_790_575_740))
        // The Mac's pushed content-state decodes with the same keys.
        let pushed = #"{"tabs":[{"id":"x","title":"T","state":"running","startedAt":1}],"running":1,"needsInput":0,"total":3,"updatedAt":2}"#
        let decoded = try JSONDecoder().decode(CantripTabsAttributes.ContentState.self, from: Data(pushed.utf8))
        XCTAssertEqual(decoded.tabs.first?.status, .running)
        XCTAssertEqual(decoded.summary, "1 running")
    }

    func testSummaries() {
        XCTAssertEqual(CantripLiveFormat.summary(running: 0, needsInput: 0, total: 0), "No tabs")
        XCTAssertEqual(CantripLiveFormat.summary(running: 0, needsInput: 0, total: 1), "All 1 tab idle")
        XCTAssertEqual(CantripLiveFormat.summary(running: 3, needsInput: 2, total: 8), "2 need input · 3 running")
    }

    func testDeepLinksRoundTrip() throws {
        let server = UUID().uuidString
        let tab = UUID().uuidString
        XCTAssertEqual(CantripDeepLink.parse(CantripDeepLink.tab(tab, serverID: server)), .tab(id: tab, serverID: server))
        XCTAssertEqual(CantripDeepLink.parse(CantripDeepLink.tabs(serverID: nil)), .tabs(serverID: nil))
        XCTAssertEqual(CantripDeepLink.parse(try XCTUnwrap(URL(string: "cantripagent://tab/not-a-uuid"))), .tabs(serverID: nil))
        XCTAssertNil(CantripDeepLink.parse(try XCTUnwrap(URL(string: "https://example.com/tab/\(tab)"))))
    }

    func testEndpointsKeepTheBasePath() {
        XCTAssertEqual(CantripLiveStatusFetcher.endpoint("https://mac.tail.ts.net")?.absoluteString,
                       "https://mac.tail.ts.net/api/v1/live-status")
        XCTAssertEqual(CantripLiveStatusFetcher.endpoint("https://mac.tail.ts.net/cantrip/",
                                                         path: "/api/v1/live-status/subscription")?.absoluteString,
                       "https://mac.tail.ts.net/cantrip/api/v1/live-status/subscription")
        XCTAssertNil(CantripLiveStatusFetcher.endpoint(nil))
        XCTAssertNil(CantripLiveStatusFetcher.endpoint("ftp://mac"))
    }

    func testWidgetFetchesWithThePairingToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveStatusRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        let config = CantripLiveStatusConfig(serverID: UUID().uuidString, token: "pair-token",
                                             baseURL: "https://mac.tail.ts.net", installationID: UUID().uuidString,
                                             environment: "development")
        var seen: URLRequest?
        LiveStatusRequestProtocol.handler = { request in
            seen = request
            return (200, Data(self.hostJSON.utf8))
        }
        let snapshot = try await CantripLiveStatusFetcher.fetch(config, session: session)
        XCTAssertEqual(snapshot.tabs.count, 6)
        XCTAssertEqual(seen?.url?.path, "/api/v1/live-status")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer pair-token")

        LiveStatusRequestProtocol.handler = { _ in (404, Data()) }
        do {
            _ = try await CantripLiveStatusFetcher.fetch(config, session: session)
            XCTFail("an old host should be reported")
        } catch let error as CantripLiveStatusFetchError {
            XCTAssertEqual(error, .hostTooOld)
        }

        var body: [String: Any]?
        LiveStatusRequestProtocol.handler = { request in
            body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody ?? request.bodyData)) as? [String: Any]
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/live-status/subscription")
            return (200, Data(#"{"configured":true,"message":"ok"}"#.utf8))
        }
        try await CantripLiveStatusFetcher.subscribe(config, fields: ["widgetToken": "ab12"], session: session)
        XCTAssertEqual(body?["widgetToken"] as? String, "ab12")
        XCTAssertEqual(body?["serverID"] as? String, config.serverID)
        XCTAssertEqual(body?["environment"] as? String, "development")

        let noRoute = CantripLiveStatusConfig(serverID: "s", token: "t", baseURL: nil, installationID: "i", environment: "development")
        do {
            _ = try await CantripLiveStatusFetcher.fetch(noRoute, session: session)
            XCTFail("local-network-only pairings are refreshed by the app")
        } catch let error as CantripLiveStatusFetchError {
            XCTAssertEqual(error, .noRoute)
        }
    }

    func testSubscriptionFieldsFollowTheToggle() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "live-status-\(UUID().uuidString)"))
        let controller = CantripLiveStatusController(defaults: defaults)
        controller.pairingChanged(serverID: nil, token: nil, baseURL: nil, tailscaleOnly: false, installationID: UUID())
        XCTAssertNil(controller.subscriptionFields(activitiesAllowed: true), "no pairing, nothing to register")

        let server = UUID()
        let installation = UUID()
        controller.pairingChanged(serverID: server, token: "t", baseURL: URL(string: "https://mac.tail.ts.net"),
                                  tailscaleOnly: false, installationID: installation)
        var fields = try XCTUnwrap(controller.subscriptionFields(activitiesAllowed: true))
        XCTAssertEqual(fields["serverID"] as? String, server.uuidString)
        XCTAssertEqual(fields["installationID"] as? String, installation.uuidString)
        XCTAssertEqual(fields["liveActivities"] as? Bool, true)
        XCTAssertEqual(fields["startToken"] as? String, "")

        fields = try XCTUnwrap(controller.subscriptionFields(activitiesAllowed: false))
        XCTAssertEqual(fields["liveActivities"] as? Bool, false, "iOS Live Activities setting off")

        controller.liveActivitiesEnabled = false
        fields = try XCTUnwrap(controller.subscriptionFields(activitiesAllowed: true))
        XCTAssertEqual(fields["liveActivities"] as? Bool, false)
        XCTAssertEqual(fields["activityToken"] as? String, "")
        XCTAssertEqual(defaults.object(forKey: CantripLiveStatusController.enabledKey) as? Bool, false)
        controller.pairingChanged(serverID: nil, token: nil, baseURL: nil, tailscaleOnly: false, installationID: installation)
    }

    func testSameContentIgnoresReadTime() throws {
        var snapshot = try CantripLiveStatusFetcher.decode(Data(hostJSON.utf8))
        let earlier = snapshot
        snapshot.generatedAt += 30
        XCTAssertTrue(CantripLiveStatusController.sameContent(earlier, snapshot))
        snapshot.running = 0
        XCTAssertFalse(CantripLiveStatusController.sameContent(earlier, snapshot))
        XCTAssertFalse(CantripLiveStatusController.sameContent(nil, snapshot))
    }
}

private extension URLRequest {
    /// URLProtocol receives uploads as a stream.
    var bodyData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
