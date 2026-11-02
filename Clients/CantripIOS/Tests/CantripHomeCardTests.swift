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
}
