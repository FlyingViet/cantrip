import Foundation
import XCTest
@testable import Hermes

/// A Mac stub that answers with entity tags and records what each request carried.
private final class SavedCopyRequestProtocol: URLProtocol {
    struct Answer {
        var status: Int
        var body: Data
        var etag: String? = nil
    }

    @MainActor static var handler: ((URLRequest) async throws -> Answer)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            do {
                let answer = try await XCTUnwrap(Self.handler)(request)
                var headers = ["Content-Type": "application/json"]
                if let etag = answer.etag { headers["ETag"] = etag }
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: answer.status,
                    httpVersion: "HTTP/1.1", headerFields: headers
                ))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: answer.body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
}

@MainActor
final class CantripSavedCopyTests: XCTestCase {
    private let homeID = CantripHomeIdentity.sessionID
    private let tabID = "30000000-0000-0000-0000-000000000001"

    private func session(_ id: String, title: String, home: Bool, reply: String?, revision: String = "r1") -> String {
        let messages = reply.map { #"[{"id":"40000000-0000-0000-0000-000000000001","role":"assistant","text":"\#($0)","thinking":"","activities":[]}]"# } ?? "[]"
        return """
        {"id":"\(id)","title":"\(title)","workdir":"/tmp","isStreaming":false,"canResume":false,
        "councilMode":false,"queuedCount":0,"supportsAutoDelivery":true,"isCantripHome":\(home),
        "supportsPagedHistory":true,"historyRevision":"\(revision)","messages":\(messages)}
        """
    }

    private var listing: Data {
        Data(#"{"sessions":[\#(session(tabID, title: "Garden", home: false, reply: nil))],"home":\#(session(homeID, title: "Cantrip Home", home: true, reply: nil))}"#.utf8)
    }

    private var homeDetail: Data {
        Data(#"{"session":\#(session(homeID, title: "Cantrip Home", home: true, reply: "Saved reply from the Mac"))}"#.utf8)
    }

    private var tasks: Data {
        Data("""
        {"tasks":[{"id":"10000000-0000-0000-0000-000000000001","title":"Track SFO flights",
        "prompt":"Check prices.","schedule":{"kind":"weekdays","summary":"Weekdays at 8 AM",
        "timeZone":"America/Los_Angeles","startAt":null,"intervalMinutes":null,"weekdays":[2,3,4,5,6],
        "hour":8,"minute":0},"enabled":true,"createdAt":0,"updatedAt":0,"nextRunAt":null,
        "lastRunAt":null,"state":"idle","activeRunID":null,"runs":[]}],"revision":"task-revision"}
        """.utf8)
    }

    private var artifacts: Data { Data(#"{"artifacts":[],"revision":"artifact-revision"}"#.utf8) }

    private func path(_ request: URLRequest) -> String {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    }

    private func body(for path: String) -> Data? {
        switch path {
        case "/api/v1/sessions": listing
        case "/api/v1/home": homeDetail
        case "/api/v1/home/tasks": tasks
        case "/api/v1/home/artifacts": artifacts
        // The poll's check of Home's history revision.
        case "/api/v1/sessions/\(homeID)": Data(#"{"unchanged":true}"#.utf8)
        default: nil
        }
    }

    private func tag(_ data: Data) -> String { "W/\"\(data.count)-\(data.hashValue)\"" }

    private func makeModel(_ store: CantripSavedCopy) async throws -> (CantripRemoteModel, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SavedCopyRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        let model = CantripRemoteModel(urlSession: client, savedCopy: store)
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "saved-copy-token",
                                               tailscaleOnly: true)
        XCTAssertTrue(configured, model.errorMessage ?? "configure failed")
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            client.invalidateAndCancel()
        }
        return (model, client)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("saved-copy-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The first launch keeps the Mac's answers; a cold launch draws them before any request returns,
    /// marked as a saved copy, then sends their tags back and clears the mark when the Mac answers 304.
    func testColdLaunchDrawsSavedCopyFirstAndRevalidatesIt() async throws {
        let folder = try directory()
        SavedCopyRequestProtocol.handler = { [unowned self] request in
            let data = try XCTUnwrap(self.body(for: self.path(request)), self.path(request))
            return .init(status: 200, body: data, etag: self.tag(data))
        }
        defer { SavedCopyRequestProtocol.handler = nil }

        let first = CantripSavedCopy(directory: folder)
        let (warm, _) = try await makeModel(first)
        XCTAssertTrue(warm.savedCopyParts.isEmpty, "nothing saved yet")
        warm.setAppActive(true)
        await warm.selectHome()
        try await until { !warm.sessions.isEmpty && !warm.homeTasks.isEmpty }
        XCTAssertEqual(warm.selectedSession?.transcript.last?.text, "Saved reply from the Mac")
        XCTAssertEqual(warm.homeTasks.map(\.title), ["Track SFO flights"])
        warm.setAppActive(false)
        first.flush()
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(kept.count, 1, "one folder for the pairing")
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(kept[0]).path))
        XCTAssertTrue(files.isSuperset(of: ["sessions.plist", "home.plist", "tasks.plist", "artifacts.plist"]), "\(files)")
        XCTAssertFalse(kept[0].contains("saved-copy-token"), "the folder never names the token")

        // Cold launch: requests wait until the test lets them through.
        var requests: [URLRequest] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
        var released = false
        SavedCopyRequestProtocol.handler = { [unowned self] request in
            requests.append(request)
            if !released { await withCheckedContinuation { waiting.append($0) } }
            let data = try XCTUnwrap(self.body(for: self.path(request)))
            if request.value(forHTTPHeaderField: "If-None-Match") == self.tag(data) {
                return .init(status: 304, body: Data(), etag: self.tag(data))
            }
            return .init(status: 200, body: data, etag: self.tag(data))
        }
        let (cold, _) = try await makeModel(CantripSavedCopy(directory: folder))
        XCTAssertEqual(cold.sessions.map(\.title), ["Garden"], "the tab list is drawn from the saved copy")
        XCTAssertEqual(cold.homeTasks.map(\.title), ["Track SFO flights"], "Tasks are drawn from the saved copy")
        XCTAssertEqual(cold.savedCopyParts, ["sessions", "home", "tasks", "artifacts"])
        XCTAssertNotNil(cold.showHome())
        XCTAssertEqual(cold.selectedSession?.transcript.last?.text, "Saved reply from the Mac",
                       "Home's chat shows before the Mac answers")
        XCTAssertTrue(cold.showsSavedCopy, "and is marked as a saved copy")
        XCTAssertTrue(cold.homeTasksShowSavedCopy)
        XCTAssertTrue(CantripLaunchSplash.isReady(lane: .home, remote: cold), "the splash doesn't wait for the Mac")

        let loading = Task { await cold.refreshHomeData() }
        try await until { waiting.count == 2 }
        XCTAssertTrue(cold.homeTasksShowSavedCopy, "still marked while the Mac hasn't answered")
        released = true
        waiting.forEach { $0.resume() }
        await loading.value
        XCTAssertFalse(cold.homeTasksShowSavedCopy, "Tasks confirmed")
        cold.setAppActive(true)
        try await until { cold.savedCopyParts.isEmpty }
        XCTAssertTrue(cold.savedCopyParts.isEmpty, "every part confirmed: \(cold.savedCopyParts)")
        XCTAssertFalse(cold.showsSavedCopy)
        XCTAssertEqual(cold.homeTasks.map(\.title), ["Track SFO flights"], "a 304 keeps the saved answer")
        // Later polls of Tasks name the revision they hold instead (`unchanged` replies).
        let tagged = requests.filter {
            ["/api/v1/sessions", "/api/v1/home/tasks"].contains(path($0)) && $0.url?.query?.contains("revision=") != true
        }
        XCTAssertFalse(tagged.isEmpty)
        for request in tagged {
            XCTAssertNotNil(request.value(forHTTPHeaderField: "If-None-Match"), "\(path(request)) sends its tag")
        }
    }

    /// A 304 reuses the kept answer (no body to decode); a changed answer replaces it and its tag.
    func testNotModifiedReusesKeptAnswerAndChangeReplacesIt() async throws {
        var current = listing
        var sent: [String?] = []
        SavedCopyRequestProtocol.handler = { [unowned self] request in
            sent.append(request.value(forHTTPHeaderField: "If-None-Match"))
            if request.value(forHTTPHeaderField: "If-None-Match") == self.tag(current) {
                return .init(status: 304, body: Data(), etag: self.tag(current))
            }
            return .init(status: 200, body: current, etag: self.tag(current))
        }
        defer { SavedCopyRequestProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SavedCopyRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        let store = CantripSavedCopy(directory: nil)
        store.open(pairing: "0a")
        let api = CantripRemoteAPI(transport: .remote(URL(string: "https://cantrip.example")!), token: "t",
                                   urlSession: client, savedCopy: (store, "0a"))

        let full = try await api.sessionListing()
        XCTAssertEqual(full.sessions.map(\.title), ["Garden"])
        XCTAssertEqual(store.entry("sessions"), .init(body: listing, etag: tag(listing)))
        let unchanged = try await api.sessionListing()
        XCTAssertEqual(unchanged.sessions.map(\.title), ["Garden"], "304: the kept list")
        current = Data(#"{"sessions":[\#(session(tabID, title: "Garden plans", home: false, reply: nil))]}"#.utf8)
        let changed = try await api.sessionListing()
        XCTAssertEqual(changed.sessions.map(\.title), ["Garden plans"], "a change comes in full")
        XCTAssertEqual(store.entry("sessions")?.etag, tag(current))
        XCTAssertEqual(sent, [nil, tag(listing), tag(listing)])

        // Without a saved copy nothing is sent or kept (older callers, other routes).
        let plain = CantripRemoteAPI(transport: .remote(URL(string: "https://cantrip.example")!), token: "t",
                                     urlSession: client)
        _ = try await plain.sessionListing()
        XCTAssertNil(sent.last!)
    }

    /// Home's lists are asked for while its chat is still loading, and the personal mascot (about
    /// 1.3 MB on a real Mac) only once Home's reads have answered, so it doesn't share a slow link with them.
    func testHomeListsLoadAlongsideItsChatAndTheMascotWaits() async throws {
        let mascotRevision = String(repeating: "ab", count: 32)
        let listed = Data(#"{"sessions":[],"home":\#(session(homeID, title: "Cantrip Home", home: true, reply: nil)),"privateMascotRevision":"\#(mascotRevision)"}"#.utf8)
        var order: [String] = []
        var held: [CheckedContinuation<Void, Never>] = []
        var releaseHome = false
        SavedCopyRequestProtocol.handler = { [unowned self] request in
            let path = self.path(request)
            order.append("start " + path)
            if path == "/api/v1/home", !releaseHome { await withCheckedContinuation { held.append($0) } }
            defer { order.append("end " + path) }
            if path == "/api/v1/mascot" { return .init(status: 404, body: Data(#"{"error":"none"}"#.utf8)) }
            let data = path == "/api/v1/sessions" ? listed : try XCTUnwrap(self.body(for: path), path)
            return .init(status: 200, body: data)
        }
        defer { SavedCopyRequestProtocol.handler = nil }
        let (model, _) = try await makeModel(CantripSavedCopy(directory: nil))
        let load = try XCTUnwrap(model.showHome())
        let loading = Task { await model.loadHome(load) }
        try await until { !held.isEmpty && order.contains("end /api/v1/home/tasks") }
        XCTAssertTrue(order.contains("end /api/v1/home/tasks"), "Tasks answered while Home's chat still loads: \(order)")
        model.setAppActive(true)
        try await until { order.contains("end /api/v1/sessions") }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(order.contains("start /api/v1/mascot"), "the mascot waits for Home's chat: \(order)")
        releaseHome = true
        held.forEach { $0.resume() }
        await loading.value
        try await until { order.contains("start /api/v1/mascot") }
        let mascot = try XCTUnwrap(order.firstIndex(of: "start /api/v1/mascot"), "\(order)")
        XCTAssertLessThan(try XCTUnwrap(order.lastIndex(of: "end /api/v1/home")), mascot)
    }

    /// Unpairing forgets the copy on the device; another pairing never reads it.
    func testUnpairingDiscardsTheSavedCopy() async throws {
        let folder = try directory()
        let store = CantripSavedCopy(directory: folder)
        let key = CantripSavedCopy.pairingKey(url: "https://cantrip.example/", directAddress: nil, token: "t1")
        store.open(pairing: key)
        store.keep("sessions", body: listing, etag: "W/\"1\"", pairing: key)
        store.keep("tab-x", body: homeDetail, etag: nil, pairing: "other")
        store.flush()
        XCTAssertNil(store.entry("tab-x"), "an answer for a pairing that's no longer open is dropped")
        let other = CantripSavedCopy(directory: folder)
        XCTAssertTrue(other.open(pairing: CantripSavedCopy.pairingKey(
            url: "https://cantrip.example/", directAddress: nil, token: "t2")).isEmpty)
        XCTAssertEqual(CantripSavedCopy(directory: folder).open(pairing: key)["sessions"]?.body, listing)
        store.discard(pairing: key)
        store.flush()
        XCTAssertTrue(CantripSavedCopy(directory: folder).open(pairing: key).isEmpty)
    }
}
