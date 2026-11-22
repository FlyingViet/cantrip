import Foundation
import XCTest
@testable import Hermes

private final class HomeCardRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            guard let handler = Self.handler, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: handler(request).0, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "application/json"]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: handler(request).1)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// Cards on Home: a run's cards on its result, a workspace's cards built from its records, and
/// a record's weather and map cards, decoded leniently from the Mac.
@MainActor
final class CantripHomeCardTests: XCTestCase {
    private let taskID = "8F2D7A90-0C7F-4F0B-9D6B-3F0E1A2B3C4D"
    private let recordID = "1B9C2D3E-4F50-6172-8394-A5B6C7D8E9F0"

    override func tearDown() {
        HomeCardRequestProtocol.handler = nil
        super.tearDown()
    }

    private func api() throws -> CantripRemoteAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeCardRequestProtocol.self]
        return CantripRemoteAPI(transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
                                token: "test-pairing-token", urlSession: URLSession(configuration: configuration))
    }

    private let weatherCard = #"""
    {"version":1,"id":"weather-seattle","type":"weather","accessibilityLabel":"Weather for Seattle, WA",
     "source":{"kind":"resolver","name":"Open-Meteo","attribution":"Weather data by Open-Meteo.com","url":"https://open-meteo.com/","updatedAt":"2026-11-02T05:57:33Z"},
     "blocks":[{"type":"header","title":"Seattle, WA","stat":{"value":"40°","symbol":"moon.stars.fill"}}]}
    """#

    private var tasksJSON: String {
        """
        {"revision":"r1","error":null,"supportsReordering":true,"supportsRecordCards":true,
         "workspaceCards":{"\(taskID)":[{"version":1,"id":"records-1","type":"records","blocks":[{"type":"header","title":"Due in the next 7 days"},{"type":"list","items":[{"title":"Internet","trailing":"$80.00","badges":[{"text":"Today","tone":"warning"}]}]}]}]},
         "tasks":[{"id":"\(taskID)","title":"Bills","prompt":"Track bills.",
           "schedule":{"kind":"once","summary":"No schedule","timeZone":"America/Los_Angeles","startAt":null,"intervalMinutes":null,"weekdays":null,"hour":null,"minute":null},
           "hasSchedule":true,"enabled":true,"createdAt":0,"updatedAt":0,"nextRunAt":null,"lastRunAt":0,"state":"succeeded","activeRunID":null,
           "workspace":{"recordLabel":"Bill","recordLabelPlural":"Bills","icon":"creditcard",
             "fields":[{"key":"name","label":"Name","kind":"text","required":true,"options":null}],
             "list":{"titleField":"name","subtitleFields":[],"badgeField":null,"dateField":null},
             "detailSections":[],"records":[{"id":"\(recordID)","values":{"name":"Internet"},"createdAt":0,"updatedAt":0}],
             "cards":[{"kind":"list","title":"Due"},{"kind":"weather","placeField":"city"},{"kind":"hologram"}]},
           "runs":[{"id":"5E6F7A8B-9C0D-4E1F-8A2B-3C4D5E6F7A8B","startedAt":0,"finishedAt":0,"status":"succeeded",
             "summary":"Two bills due.","cards":[\(weatherCard),{"blocks":"broken"}]}]}]}
        """
    }

    func testTasksCarryRunCardsAndWorkspaceCards() async throws {
        HomeCardRequestProtocol.handler = { [tasksJSON] _ in (200, Data(tasksJSON.utf8)) }
        let snapshot = try await api().homeTasks()
        let task = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(task.workspaceCards?.first?.blocks.first?.title, "Due in the next 7 days",
                       "the workspace's cards are attached to their task")
        XCTAssertEqual(task.workspaceCards?.first?.blocks.last?.items?.first?.trailing, "$80.00")
        XCTAssertEqual(task.workspace?.cards?.map(\.kind), ["list", "weather", "hologram"])
        XCTAssertTrue(task.workspace?.hasRecordCards == true, "a weather spec means the record detail asks for cards")
        let run = try XCTUnwrap(task.runs.first)
        XCTAssertEqual(run.summary, "Two bills due.")
        XCTAssertEqual(run.cards?.count, 2, "a malformed card never fails the task")
        XCTAssertEqual(run.cards?.first?.header?.title, "Seattle, WA")
        XCTAssertEqual(run.cards?.first?.source?.attribution, "Weather data by Open-Meteo.com")
        XCTAssertTrue(run.cards?.last?.blocks.isEmpty == true)
        XCTAssertTrue(CantripCardPanel.sections(run.cards?.last?.blocks ?? []).isEmpty, "it shows its fallback instead")
    }

    func testBackgroundRunsCarryCards() throws {
        let snapshot = try JSONDecoder().decode(CantripHomeBackgroundSnapshot.self, from: Data("""
        {"sessionID":"log","revision":"r","queued":[],"runs":[
          {"id":"5E6F7A8B-9C0D-4E1F-8A2B-3C4D5E6F7A8B","kind":"task","label":"Personal operations briefing","startedAt":0,"finishedAt":0,
           "status":"succeeded","summary":"Clear and cool.","cards":[\(weatherCard)]},
          {"id":"6E6F7A8B-9C0D-4E1F-8A2B-3C4D5E6F7A8B","kind":"task","label":"Older Mac","startedAt":0,"status":"running","summary":""}]}
        """.utf8))
        XCTAssertEqual(snapshot.runs.first?.cards?.first?.type, "weather")
        XCTAssertNil(snapshot.runs.last?.cards, "older Macs send no cards")
    }

    func testRecordCardsAreFetchedForOneRecord() async throws {
        var requested: String?
        HomeCardRequestProtocol.handler = { [weatherCard] request in
            requested = request.url?.path
            return (200, Data(#"{"cards":[\#(weatherCard)],"refreshAfter":300}"#.utf8))
        }
        let answer = try await api().homeRecordCards(taskID: try XCTUnwrap(UUID(uuidString: taskID)),
                                                     recordID: try XCTUnwrap(UUID(uuidString: recordID)))
        XCTAssertEqual(requested, "/api/v1/home/tasks/\(taskID)/records/\(recordID)/cards")
        XCTAssertEqual(answer.cards.map(\.type), ["weather"])
        XCTAssertEqual(answer.refreshAfter, 300)
    }

    // MARK: Live run cards

    private let runID = "5E6F7A8B-9C0D-4E1F-8A2B-3C4D5E6F7A8B"

    /// The query of each request for `path`, in order.
    private func queries(_ urls: [String], _ path: String) -> [[String: String]] {
        urls.compactMap { URLComponents(string: $0) }.filter { $0.path == path }.map { components in
            Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        }
    }

    private func liveCard(_ title: String, updatedAt: String) -> String {
        #"{"version":1,"id":"weather-seattle","type":"weather","live":true,"source":{"kind":"resolver","updatedAt":"\#(updatedAt)"},"blocks":[{"type":"header","title":"\#(title)"}]}"#
    }

    /// A tasks list whose latest run finished at `finishedAt` (seconds since 2001) with a live
    /// forecast fetched at `updatedAt`, and a card that isn't live.
    private func liveTasksJSON(finishedAt: TimeInterval, updatedAt: String) -> String {
        """
        {"revision":"list-1","error":null,"supportsReordering":true,
         "tasks":[{"id":"\(taskID)","title":"Briefing","prompt":"Brief me.",
           "schedule":{"kind":"once","summary":"No schedule","timeZone":"America/Los_Angeles","startAt":null,"intervalMinutes":null,"weekdays":null,"hour":null,"minute":null},
           "hasSchedule":true,"enabled":true,"createdAt":0,"updatedAt":0,"nextRunAt":null,"lastRunAt":0,"state":"succeeded","activeRunID":null,
           "runs":[{"id":"\(runID)","startedAt":0,"finishedAt":\(finishedAt),"status":"succeeded","summary":"Clear.",
             "cards":[\(liveCard("Seattle, WA", updatedAt: updatedAt)),
               {"version":1,"id":"run-card-1","type":"custom","source":{"kind":"tool","updatedAt":"2001-01-01T00:00:00Z"},"blocks":[{"type":"header","title":"Meetings"}]}]}]}]}
        """
    }

    private func liveCardsJSON(_ title: String, updatedAt: String, revision: String = "list-1.live-1") -> String {
        #"{"revision":"\#(revision)","staleAfter":900,"liveWindow":86400,"cards":[{"taskID":"\#(taskID)","runID":"\#(runID)","card":\#(liveCard(title, updatedAt: updatedAt))}]}"#
    }

    /// The tasks list asks for live cards separately, so a rebuilt forecast doesn't resend it; a live
    /// card shows its current version from `/api/v1/home/live-cards` and says "Updating…" whenever
    /// it's past `staleAfter` (or not fetched yet), never passing an old forecast off as current.
    func testLiveRunCardsComeSeparatelyAndNeverPassAsCurrent() async throws {
        var requested: [String] = []
        // The run finished at 00:00 and its forecast was fetched at 00:40; it's now 01:00.
        let now = Date(timeIntervalSinceReferenceDate: 3_600)
        HomeCardRequestProtocol.handler = { [self] request in
            let url = request.url?.absoluteString ?? ""
            if !requested.contains(url) { requested.append(url) }
            switch request.url?.path {
            case "/api/v1/home/tasks":
                return (200, Data(liveTasksJSON(finishedAt: 0, updatedAt: "2001-01-01T00:40:00Z").utf8))
            case "/api/v1/home/live-cards" where request.url?.query?.contains("revision=list-1.live-1") == true:
                return (200, Data(#"{"unchanged":true,"revision":"list-1.live-1"}"#.utf8))
            case "/api/v1/home/live-cards":
                return (200, Data(liveCardsJSON("Rebuilt", updatedAt: "2001-01-01T00:59:00Z").utf8))
            default: return (404, Data())
            }
        }
        let api = try api()
        let snapshot = try await api.homeTasks()
        XCTAssertEqual(queries(requested, "/api/v1/home/tasks").first?["liveCards"], "separate", "\(requested)")
        let task = try XCTUnwrap(snapshot.tasks.first)
        let run = try XCTUnwrap(task.runs.first)
        XCTAssertEqual(run.cards?.map(\.live), [true, nil])

        let unfetched = CantripHomeLiveCards.shown(run, live: nil, now: now)
        XCTAssertEqual(unfetched.updating, ["weather-seattle"], "a 20-minute-old forecast isn't shown as current")
        XCTAssertEqual(unfetched.cards.first?.header?.title, "Seattle, WA")
        XCTAssertTrue(CantripHomeLiveCards.needed(snapshot.tasks, live: nil, now: now))

        let fetched = try await api.homeLiveCards(ifChangedFrom: nil)
        let live = try XCTUnwrap(fetched)
        XCTAssertEqual(queries(requested, "/api/v1/home/live-cards").map { $0["revision"] }, [nil])
        XCTAssertEqual(live.staleAfter, 900)
        let current = CantripHomeLiveCards.shown(run, live: live, now: now)
        XCTAssertEqual(current.cards.map { $0.header?.title }, ["Rebuilt", "Meetings"])
        XCTAssertEqual(current.cards.first?.id, "weather-seattle")
        XCTAssertTrue(current.updating.isEmpty, "the rebuilt forecast is current; the other card is never live")

        let later = CantripHomeLiveCards.shown(run, live: live, now: now.addingTimeInterval(16 * 60))
        XCTAssertEqual(later.updating, ["weather-seattle"], "it reads as updating again once past staleAfter")
        let dayLater = CantripHomeLiveCards.shown(run, live: live, now: Date(timeIntervalSinceReferenceDate: 25 * 3_600))
        XCTAssertTrue(dayLater.updating.isEmpty, "a day-old run keeps the forecast it has")
        XCTAssertFalse(CantripHomeLiveCards.needed(snapshot.tasks, live: live,
                                                   now: Date(timeIntervalSinceReferenceDate: 25 * 3_600)))

        let unchanged = try await api.homeLiveCards(ifChangedFrom: live.revision)
        XCTAssertNil(unchanged)
        XCTAssertEqual(queries(requested, "/api/v1/home/live-cards").map { $0["revision"] }, [nil, "list-1.live-1"])

        XCTAssertEqual(CantripCardStyle.updatedText(nil, updating: true), "Updating…")
        XCTAssertTrue(CantripCardStyle.updatedText("2001-01-01T00:40:00Z", updating: true)?.hasSuffix(" · Updating…") == true)
        XCTAssertEqual(CantripCardStyle.updatedText("2001-01-01T00:40:00Z")?.contains("Updating"), false)
    }

    /// Home's poll reads the live cards alongside the tasks list when a latest run has one, then
    /// sends their revision; the list itself keeps its own revision.
    func testHomePollReadsLiveCardsWithTheList() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeCardRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        let model = CantripRemoteModel(urlSession: client)
        var requested: [String] = []
        let finished = Date().addingTimeInterval(-3_600).timeIntervalSinceReferenceDate
        let fetched = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20 * 60))
        let rebuilt = ISO8601DateFormatter().string(from: Date())
        HomeCardRequestProtocol.handler = { [self] request in
            let url = request.url?.absoluteString ?? ""
            if !requested.contains(url) { requested.append(url) }
            let query = request.url?.query ?? ""
            switch request.url?.path {
            case "/api/v1/home":
                return (200, Data(#"{"session":{"id":"7EAE0CE5-8C8B-4652-9FD0-214867A90E5D","title":"Cantrip Home","workdir":"/tmp","isStreaming":false,"canResume":false,"councilMode":false,"queuedCount":0,"status":null,"messages":[],"supportsImageAttachments":true,"queued":[],"supportsAutoDelivery":true,"isLocked":true,"isCantripHome":true,"supportsModelSettings":true,"supportsPagedHistory":true}}"#.utf8))
            case "/api/v1/home/tasks" where query.contains("revision=list-1"):
                return (200, Data(#"{"unchanged":true,"revision":"list-1"}"#.utf8))
            case "/api/v1/home/tasks":
                return (200, Data(liveTasksJSON(finishedAt: finished, updatedAt: fetched).utf8))
            case "/api/v1/home/live-cards" where query.contains("revision=list-1.live-1"):
                return (200, Data(#"{"unchanged":true,"revision":"list-1.live-1"}"#.utf8))
            case "/api/v1/home/live-cards":
                return (200, Data(liveCardsJSON("Rebuilt", updatedAt: rebuilt).utf8))
            case "/api/v1/home/artifacts": return (200, Data(#"{"artifacts":[],"revision":"a"}"#.utf8))
            default: return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            model.clearConfiguration()
            client.invalidateAndCancel()
        }
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "live-cards-token",
                                               tailscaleOnly: true)
        XCTAssertTrue(configured)
        await model.selectHome()
        let deadline = Date().addingTimeInterval(5)
        while model.homeLiveCards == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let live = try XCTUnwrap(model.homeLiveCards, "\(requested)")
        XCTAssertEqual(live.revision, "list-1.live-1")
        let run = try XCTUnwrap(model.homeTasks.first?.runs.first)
        XCTAssertEqual(CantripHomeLiveCards.shown(run, live: live).cards.first?.header?.title, "Rebuilt")
        XCTAssertEqual(queries(requested, "/api/v1/home/tasks").first?["liveCards"], "separate", "\(requested)")

        await model.refreshHomeData()
        let polled = queries(requested, "/api/v1/home/tasks").last
        XCTAssertEqual(polled?["liveCards"], "separate", "\(requested)")
        XCTAssertEqual(polled?["revision"], "list-1", "the list keeps its own revision")
        XCTAssertEqual(queries(requested, "/api/v1/home/live-cards").last?["revision"], "list-1.live-1", "\(requested)")
        XCTAssertEqual(model.homeLiveCards, live)
    }
}
