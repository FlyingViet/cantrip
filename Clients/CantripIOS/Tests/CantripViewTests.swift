import Foundation
import SwiftUI
import XCTest
@testable import Hermes

private final class ViewRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest, Data) async throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.body(of: request)
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try await handler(request, body)
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

    /// URLProtocol receives a request's body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Views (docs/views.md): the blocks a view's card adds, decoded leniently and drawn by tab, the
/// confirmation every button asks for, and the API the screens use.
@MainActor
final class CantripViewTests: XCTestCase {
    private struct Sent: Equatable {
        let method: String
        let path: String
        let body: String
    }

    private let summaryJSON = #"""
    {"id":"6A1F","name":"Homelab","subtitle":null,"icon":"server.rack","pinned":true,"private":true,
     "sources":["tool","tasks"],"createdAt":"2026-11-17T18:00:00Z","updatedAt":"2026-11-17T18:05:00.250Z",
     "refreshedAt":"2026-11-17T18:30:00Z","refreshing":false,"problems":["homelab_status timed out"]}
    """#

    private let viewCard = #"""
    {"version":1,"id":"view-6A1F","type":"view","source":{"kind":"view","name":"Homelab","updatedAt":"2026-11-17T18:30:00Z"},
     "fallbackText":"Homelab","blocks":[
      {"type":"header","title":"Homelab","symbol":"server.rack"},
      {"type":"section","title":"Services","subtitle":"From homelab_status","symbol":"server.rack"},
      {"type":"tabs","tabs":[{"title":"Up","count":1},{"title":"All","symbol":"list.bullet","count":"two"},{"title":"Charts","count":2}]},
      {"type":"table","title":"Running","columns":[{"title":"Service"},{"title":"Status","align":"trailing"},{"title":"7"},{"title":"8"},{"title":"9"},{"title":"10"},{"title":"11"}],
       "tableRows":[{"id":"r1","cells":[{"text":"Plex"},{"text":"Up","tone":"positive","symbol":"checkmark.circle.fill"},{"text":3},{"text":"c"},{"text":"d"},{"text":"e"},{"text":"f"}],
                     "accessibilityLabel":"Plex, Up"},
                    {"cells":"broken"},
                    "not a row"]},
      {"type":"chart","kind":"line","title":"Requests","min":0,"max":70,"items":[]},
      {"type":"chart","kind":"pie","items":[{"label":"Up","high":3,"highText":"3"},{"label":"Down","high":1,"highText":"1","tone":"negative"},{"label":"None","high":0}]},
      {"type":"actions","buttons":[{"id":"a1","kind":"refresh","label":"Refresh","style":"prominent","confirmTitle":"Refresh Homelab?","confirmMessage":"Cantrip reads this view's sources again."},
                                   {"id":"a2","kind":"launchMissiles","label":"Launch"},
                                   {"kind":"open","label":"No ID"},
                                   {"id":"a3","kind":"ask","label":"Ask Home","confirmTitle":"Ask Home?"}]}]}
    """#

    private var detailJSON: String { #"{"view":\#(summaryJSON),"card":\#(viewCard),"refreshAfter":30}"# }

    private func card(_ json: String) throws -> CantripCard {
        try JSONDecoder().decode(CantripCard.self, from: Data(json.utf8))
    }

    private func block(_ json: String) throws -> CantripCard.Block {
        try JSONDecoder().decode(CantripCard.Block.self, from: Data(json.utf8))
    }

    private func titled(_ title: String, type: String = "stat") -> CantripCard.Block {
        var block = CantripCard.Block(type: type)
        block.title = title
        block.label = title
        block.value = "1"
        return block
    }

    private func tabs(_ counts: [Int]) -> CantripCard.Block {
        var block = CantripCard.Block(type: "tabs")
        block.tabs = counts.enumerated().map { CantripCard.Tab(title: "Tab \($0.offset)", count: $0.element) }
        return block
    }

    private func shown(_ sections: [CantripCardPanel.Section]) -> [String] {
        sections.map { section in
            switch section {
            case .block(let block): block.title ?? block.type
            case .map(let map, _): map.type
            case .tabs: "tabs"
            }
        }
    }

    // MARK: Decoding

    func testDecodesTheNewBlocksLeniently() throws {
        let detail = try JSONDecoder().decode(CantripHomeViewDetail.self, from: Data(detailJSON.utf8))
        let blocks = detail.card.blocks
        XCTAssertEqual(blocks.map(\.type), ["header", "section", "tabs", "table", "chart", "chart", "actions"])

        XCTAssertEqual(blocks[1].subtitle, "From homelab_status")
        XCTAssertEqual(blocks[2].tabs?.map(\.title), ["Up", "All", "Charts"])
        XCTAssertEqual(blocks[2].tabs?.map(\.count), [1, 0, 2], "a count that isn't a number reads as an empty tab")
        XCTAssertEqual(blocks[2].tabs?[1].symbol, "list.bullet")

        let table = blocks[3]
        XCTAssertEqual(table.title, "Running")
        XCTAssertEqual(table.columns?.count, 6, "at most six columns")
        XCTAssertEqual(table.columns?[1].align, "trailing")
        XCTAssertEqual(table.tableRows?.count, 2, "a row that isn't an object drops alone")
        let row = try XCTUnwrap(table.tableRows?.first)
        XCTAssertEqual(row.cells.count, 6, "at most six cells")
        XCTAssertEqual(row.cells.map(\.text), ["Plex", "Up", nil, "c", "d", "e"],
                       "a malformed cell stays an empty cell so the rest keep their columns")
        XCTAssertEqual(row.cells[1].tone, "positive")
        XCTAssertEqual(row.accessibilityLabel, "Plex, Up")
        XCTAssertEqual(table.tableRows?.last?.cells, [], "malformed cells read as none")

        XCTAssertEqual(blocks[4].kind, "line")
        XCTAssertEqual(blocks[4].title, "Requests")
        XCTAssertEqual(blocks[5].kind, "pie")
        XCTAssertEqual(CantripCardPieChart.slices(blocks[5]).map(\.label), ["Up", "Down"], "a zero slice has no share")
        XCTAssertEqual(CantripCardPieChart.slices(blocks[5]).map(\.percent), [75, 25].map { (Double($0) / 100).formatted(.percent.precision(.fractionLength(0))) })
        XCTAssertEqual(CantripCardPieChart.slices(blocks[5]).map(\.tone), [nil, "negative"])

        XCTAssertEqual(blocks[6].buttons?.count, 4)
        XCTAssertEqual(blocks[6].buttons?.first?.confirmTitle, "Refresh Homelab?")
        XCTAssertEqual(CantripCard.ActionButton.shown(blocks[6].buttons).compactMap(\.id), ["a1", "a3"],
                       "kinds this app doesn't know, and buttons without an ID, are hidden")

        let restored = try JSONDecoder().decode(CantripCard.self, from: JSONEncoder().encode(detail.card))
        XCTAssertEqual(restored, detail.card, "a saved card keeps its new blocks")
    }

    func testCapsBlocksTableRowsAndChartItems() throws {
        let stats = (0..<60).map { #"{"type":"stat","label":"S\#($0)","value":"\#($0)"}"# }.joined(separator: ",")
        XCTAssertEqual(try card(#"{"id":"c","blocks":[\#(stats)]}"#).blocks.count, 48, "a view's card draws up to 48 blocks")

        let rows = (0..<70).map { #"{"cells":[{"text":"\#($0)"}]}"# }.joined(separator: ",")
        XCTAssertEqual(try block(#"{"type":"table","tableRows":[\#(rows)]}"#).tableRows?.count, 50)

        let items = (0..<70).map { #"{"label":"\#($0)","high":\#($0)}"# }.joined(separator: ",")
        XCTAssertEqual(try block(#"{"type":"chart","kind":"line","items":[\#(items)]}"#).items?.count, 60)
        XCTAssertEqual(try block(#"{"type":"list","items":[\#(items)]}"#).items?.count, 24, "other blocks keep their cap")

        let line = try block(#"{"type":"chart","kind":"line","items":[\#(items)]}"#)
        XCTAssertEqual(CantripCardLineChart.labeledPositions(count: 60), [0, 29, 59], "first, middle and last labels")
        XCTAssertEqual(CantripCardLineChart.labeledPositions(count: 1), [0])
        XCTAssertEqual(CantripCardLineChart.scale(line, points: CantripCardLineChart.points(line)), 0...59)
        XCTAssertTrue(CantripCardPanel.draws(line))
        XCTAssertFalse(CantripCardPanel.draws(try block(#"{"type":"chart","kind":"line","items":[{"label":"x"}]}"#)),
                       "a line without values draws nothing")
        XCTAssertFalse(CantripCardPanel.draws(try block(#"{"type":"chart","kind":"pie","items":[{"label":"x","high":0}]}"#)))
    }

    func testTableColumnsFillTheCardOrScroll() {
        XCTAssertEqual(CantripCardTable.columnWidths(natural: [60, 20], available: 176), [120, 40],
                       "a narrow table grows in proportion to fill the card")
        XCTAssertEqual(CantripCardTable.columnWidths(natural: [400, 300, 100], available: 300), [260, 260, 100],
                       "a wide one keeps its columns (long text wraps at the cap) and scrolls")
    }

    // MARK: Tabs

    func testTabsShowOnlyTheChosenTabsBlocks() {
        let blocks = [titled("Header", type: "header"), tabs([2, 1, 9]),
                      titled("A1"), titled("A2"), titled("B1"), titled("C1"), titled("C2")]
        XCTAssertEqual(shown(CantripCardPanel.sections(blocks)), ["Header", "tabs", "A1", "A2"], "the first tab at first")
        XCTAssertEqual(shown(CantripCardPanel.sections(blocks, selectedTab: { _ in 1 })), ["Header", "tabs", "B1"])
        XCTAssertEqual(shown(CantripCardPanel.sections(blocks, selectedTab: { _ in 2 })), ["Header", "tabs", "C1", "C2"],
                       "a count past the end takes only the blocks there are")
        XCTAssertEqual(shown(CantripCardPanel.sections(blocks, selectedTab: { _ in 7 })), ["Header", "tabs", "C1", "C2"],
                       "a choice past the last tab shows the last")
        XCTAssertEqual(CantripCardPanel.entries(blocks, selectedTab: { _ in 1 }).map(\.index), [0, 1, 4],
                       "each section keeps its block's place, which keys its state")

        let after = [tabs([1, 1]), titled("A"), titled("B"), titled("After")]
        XCTAssertEqual(shown(CantripCardPanel.sections(after, selectedTab: { _ in 1 })), ["tabs", "B", "After"],
                       "blocks after the tabs' groups always show")
        XCTAssertEqual(CantripCardPanel.tabGroups(after[0], after: 0, end: 4), [1..<2, 2..<3])

        let single = [tabs([1]), titled("Only"), titled("Next")]
        XCTAssertEqual(shown(CantripCardPanel.sections(single)), ["Only", "Next"], "one tab needs no control")

        var empty = CantripCard.Block(type: "tabs")
        empty.tabs = []
        XCTAssertEqual(shown(CantripCardPanel.sections([empty, titled("Shown")])), ["Shown"])

        let nested = [tabs([3, 1]), tabs([1, 1]), titled("Inner A"), titled("Inner B"), titled("Outer B")]
        XCTAssertEqual(shown(CantripCardPanel.sections(nested, selectedTab: { $0 == 1 ? 1 : 0 })), ["tabs", "tabs", "Inner B"],
                       "a tab's own tabs choose within its blocks")
        XCTAssertEqual(shown(CantripCardPanel.sections(nested, selectedTab: { _ in 1 })), ["tabs", "Outer B"])

        XCTAssertEqual(shown(CantripCardPanel.sections([tabs([0, 2]), titled("X"), titled("Y")])), ["tabs"],
                       "an empty tab shows nothing under the control")
    }

    func testTabSelectionIsKeptPerCardAndBlock() {
        let selections = CantripCardTabSelections.shared
        let key = "view-test-\(UUID().uuidString):2"
        XCTAssertEqual(selections.selection(key), 0)
        selections.select(2, for: key)
        XCTAssertEqual(selections.selection(key), 2)
        XCTAssertEqual(selections.selection(key + "0"), 0, "another block keeps its own tab")
    }

    // MARK: Actions

    func testActionsDrawOnlyOnAViewsScreen() throws {
        let actions = try block(#"{"type":"actions","buttons":[{"id":"a1","kind":"runTask","label":"Run"}]}"#)
        XCTAssertFalse(CantripCardPanel.draws(actions), "chat cards never draw a view's buttons")
        XCTAssertTrue(CantripCardPanel.draws(actions, allowsActions: true))
        let unknown = try block(#"{"type":"actions","buttons":[{"id":"a1","kind":"deleteEverything","label":"Go"}]}"#)
        XCTAssertFalse(CantripCardPanel.draws(unknown, allowsActions: true), "a row of only unknown kinds draws nothing")
        XCTAssertEqual(CantripCardPanel.sections([actions, titled("Stat")]).count, 1)
    }

    func testButtonsAskBeforeAnythingIsSent() async throws {
        var sent: [Sent] = []
        ViewRequestProtocol.handler = { request, body in
            sent.append(Sent(method: request.httpMethod ?? "", path: request.url?.path ?? "", body: String(decoding: body, as: UTF8.self)))
            return (200, Data(#"{"result":"started","message":"Daily check is running."}"#.utf8))
        }
        addTeardownBlock { @MainActor in ViewRequestProtocol.handler = nil }
        let api = try self.api()
        let detail = try JSONDecoder().decode(CantripHomeViewDetail.self, from: Data(detailJSON.utf8))
        let button = try XCTUnwrap(CantripCard.ActionButton.shown(detail.card.blocks.last?.buttons).first)
        var results: [CantripHomeViewActionResult] = []
        let perform: (CantripCard.ActionButton) async throws -> Void = { button in
            results.append(try await api.runHomeViewAction(viewID: detail.view.id, actionID: try XCTUnwrap(button.id)))
        }

        var flow = CantripCardActionFlow()
        flow.choose(button)
        XCTAssertEqual(flow.pending, button, "a tap shows the confirmation")
        XCTAssertTrue(sent.isEmpty, "a tap alone sends nothing")
        flow.cancel()
        XCTAssertNil(flow.pending)
        XCTAssertNil(flow.confirm(), "after Cancel there is nothing to confirm")
        XCTAssertTrue(sent.isEmpty, "Cancel never sends")

        flow.choose(button)
        let chosen = try XCTUnwrap(flow.confirm(button))
        XCTAssertNil(flow.pending, "the question closes")
        try await perform(chosen)
        XCTAssertEqual(sent, [Sent(method: "POST", path: "/api/v1/home/views/6A1F/actions/a1", body: #"{"confirmed":true}"#)])
        XCTAssertEqual(results.first?.result, "started")
        XCTAssertEqual(results.first?.message, "Daily check is running.")
    }

    func testActionResults() throws {
        func result(_ json: String) throws -> CantripHomeViewActionResult {
            try JSONDecoder().decode(CantripHomeViewActionResult.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try result(#"{"result":"open","url":"https://status.example.com/"}"#).webURL?.host, "status.example.com")
        XCTAssertNil(try result(#"{"result":"open","url":"javascript:alert(1)"}"#).webURL, "only web pages open")
        XCTAssertNil(try result(#"{"result":"open","url":"http://nas.local/"}"#).webURL, "no local addresses")
        let record = try result(#"{"result":"record","taskID":"8F2D7A90-0C7F-4F0B-9D6B-3F0E1A2B3C4D","recordID":"1B9C2D3E-4F50-6172-8394-A5B6C7D8E9F0"}"#)
        XCTAssertEqual(record.record?.taskID.uuidString, "8F2D7A90-0C7F-4F0B-9D6B-3F0E1A2B3C4D")
        XCTAssertNil(try result(#"{"result":"record","taskID":"nope","recordID":"x"}"#).record)
        let refreshed = try result(#"{"result":"refreshed","view":\#(summaryJSON),"card":\#(viewCard)}"#)
        XCTAssertEqual(refreshed.view?.name, "Homelab")
        XCTAssertEqual(refreshed.card?.blocks.count, 7)
        XCTAssertEqual(try result(#"{"result":"sent","message":"Asked Home."}"#).message, "Asked Home.")
    }

    // MARK: Views the Mac resolved

    /// `GET /api/v1/home/views/<id>` and the list, as this branch's Mac resolver answers them for
    /// synthetic data (made-up services and trackers).
    private let resolvedHomelab = #"""
    {"card":{"accessibilityLabel":"Homelab","blocks":[{"subtitle":"Service health","symbol":"server.rack","title":"Homelab",
    "type":"header"},{"accessibilityLabel":"Services up, 2","label":"Services up","symbol":"checkmark.seal","type":"stat",
    "value":"2"},{"symbol":"square.stack.3d.up","title":"Services","type":"section"},{"accessibilityLabel":"Table",
    "columns":[{"align":"leading","title":"Service"},{"align":"leading","title":"Status"},{"align":"leading","title":"Version"}],
    "tableRows":[{"accessibilityLabel":"Grafana, Status Up, Version 11.2.0","cells":[{"text":"Grafana"},{"text":"Up",
    "tone":"positive"},{"text":"11.2.0"}],"id":"row-0"},{"accessibilityLabel":"NAS, Status Up, Version —","cells":[{"text":"NAS"},
    {"text":"Up","tone":"positive"},{"text":"—"}],"id":"row-1"},{"accessibilityLabel":"Router, Status Down, Version 4.1.3",
    "cells":[{"text":"Router"},{"text":"Down","tone":"negative"},{"text":"4.1.3"}],"id":"row-2"}],"type":"table"},
    {"rows":[{"key":"NAS documents","value":"1,234"}],"type":"keyValue"},{"buttons":[{"confirmMessage":"Cantrip reads this view's sources again.",
    "confirmTitle":"Refresh Homelab?","id":"a1","kind":"refresh","label":"Refresh","style":"prominent","symbol":"arrow.clockwise"}],
    "type":"actions"}],"fallbackText":"Homelab — Service health\nServices up 2\nSERVICES\nService | Status | Version\nGrafana | Up | 11.2.0\nNAS | Up | —\nRouter | Down | 4.1.3\nNAS documents: 1,234",
    "id":"view-5966EDC3-9A59-47EA-AFAB-314F477B38BC","source":{"kind":"view","name":"Homelab","updatedAt":"2026-11-18T03:32:50Z"},
    "type":"view","version":1},"refreshAfter":30,"view":{"createdAt":"2026-11-18T03:32:50Z","icon":"server.rack","id":"5966EDC3-9A59-47EA-AFAB-314F477B38BC",
    "name":"Homelab","pinned":true,"private":true,"problems":[],"refreshedAt":"2026-11-18T03:32:50Z","refreshing":false,
    "sources":["tool"],"subtitle":"Service health","updatedAt":"2026-11-18T03:32:50Z"}}
    """#

    private let resolvedDashboard = #"""
    {"card":{"accessibilityLabel":"This week","blocks":[{"subtitle":"Across the trackers","symbol":"rectangle.3.group",
    "title":"This week","type":"header"},{"accessibilityLabel":"Overview, Interviews, Bills","tabs":[{"count":3,"symbol":"square.grid.2x2",
    "title":"Overview"},{"count":2,"symbol":"person.2","title":"Interviews"},{"count":1,"symbol":"creditcard","title":"Bills"}],
    "type":"tabs"},{"accessibilityLabel":"Active interview loops, 6","label":"Active interview loops","symbol":"person.2",
    "type":"stat","value":"6"},{"rows":[{"key":"Follow-ups waiting on me","value":"3"},{"key":"Bills due soon","value":"6"},
    {"key":"Active subscriptions","value":"13"}],"type":"keyValue"},{"accessibilityLabel":"Trackers","columns":[{"align":"leading",
    "title":"Tracker"},{"align":"trailing","title":"Records"},{"align":"leading","title":"Last run"}],"tableRows":[{"accessibilityLabel":"Interview tracker, Records 22, Last run Succeeded",
    "cells":[{"text":"Interview tracker"},{"text":"22"},{"text":"Succeeded","tone":"positive"}],"id":"row-0"},{"accessibilityLabel":"Follow-up tracker, Records 5, Last run Succeeded",
    "cells":[{"text":"Follow-up tracker"},{"text":"5"},{"text":"Succeeded","tone":"positive"}],"id":"row-1"},{"accessibilityLabel":"Trip tracker, Records 2, Last run Succeeded",
    "cells":[{"text":"Trip tracker"},{"text":"2"},{"text":"Succeeded","tone":"positive"}],"id":"row-2"},{"accessibilityLabel":"Bills tracker, Records 19, Last run Succeeded",
    "cells":[{"text":"Bills tracker"},{"text":"19"},{"text":"Succeeded","tone":"positive"}],"id":"row-3"}],"title":"Trackers",
    "type":"table"},{"accessibilityLabel":"By stage","items":[{"accessibilityLabel":"Applied, 9, 41 percent","high":9,
    "highText":"9","label":"Applied","low":0},{"accessibilityLabel":"Recruiter screen complete, 2, 9 percent","high":2,
    "highText":"2","label":"Recruiter screen complete","low":0},{"accessibilityLabel":"Interviewing, 3, 14 percent",
    "high":3,"highText":"3","label":"Interviewing","low":0},{"accessibilityLabel":"Final round, 1, 5 percent","high":1,
    "highText":"1","label":"Final round","low":0},{"accessibilityLabel":"Offer, 1, 5 percent","high":1,"highText":"1",
    "label":"Offer","low":0,"tone":"positive"},{"accessibilityLabel":"Rejected, 6, 27 percent","high":6,"highText":"6",
    "label":"Rejected","low":0,"tone":"negative"}],"kind":"pie","max":9,"min":0,"title":"By stage","type":"chart"},
    {"accessibilityLabel":"Applications per day","items":[{"accessibilityLabel":"Mon, Oct 5, 3","high":3,"highText":"3",
    "label":"Mon, Oct 5","low":0},{"accessibilityLabel":"Thu, Oct 8, 3","high":3,"highText":"3","label":"Thu, Oct 8",
    "low":0},{"accessibilityLabel":"Mon, Oct 12, 3","high":3,"highText":"3","label":"Mon, Oct 12","low":0},{"accessibilityLabel":"Thu, Oct 15, 3",
    "high":3,"highText":"3","label":"Thu, Oct 15","low":0},{"accessibilityLabel":"Mon, Oct 19, 3","high":3,"highText":"3",
    "label":"Mon, Oct 19","low":0},{"accessibilityLabel":"Thu, Oct 22, 3","high":3,"highText":"3","label":"Thu, Oct 22",
    "low":0},{"accessibilityLabel":"Mon, Oct 26, 2","high":2,"highText":"2","label":"Mon, Oct 26","low":0},{"accessibilityLabel":"Thu, Oct 29, 2",
    "high":2,"highText":"2","label":"Thu, Oct 29","low":0}],"kind":"line","max":3,"min":0,"title":"Applications per day",
    "type":"chart"},{"accessibilityLabel":"By category","items":[{"accessibilityLabel":"Software, 6","high":6,"highText":"6",
    "label":"Software","low":0},{"accessibilityLabel":"Subscription, 5","high":5,"highText":"5","label":"Subscription",
    "low":0},{"accessibilityLabel":"Utility, 3","high":3,"highText":"3","label":"Utility","low":0},{"accessibilityLabel":"Insurance, 2",
    "high":2,"highText":"2","label":"Insurance","low":0},{"accessibilityLabel":"Membership, 2","high":2,"highText":"2",
    "label":"Membership","low":0},{"accessibilityLabel":"Other, 1","high":1,"highText":"1","label":"Other","low":0}],
    "kind":"bar","max":6,"min":0,"title":"By category","type":"chart"},{"buttons":[{"confirmMessage":"Cantrip starts the task's run in the background.",
    "confirmTitle":"Run Interview tracker now?","id":"a1","kind":"runTask","label":"Run interview tracker","symbol":"play.fill"},
    {"confirmMessage":"Summarize this week across my trackers: what changed and what needs me next.","confirmTitle":"Ask Home?",
    "id":"a2","kind":"ask","label":"Summarize my week","symbol":"sparkles"}],"type":"actions"}],"fallbackText":"This week — Across the trackers\nActive interview loops 6\nFollow-ups waiting on me: 3\nBills due soon: 6\nActive subscriptions: 13\nTrackers\nTracker | Records | Last run\nInterview tracker | 22 | Succeeded\nFollow-up tracker | 5 | Succeeded\nTrip tracker | 2 | Succeeded\nBills tracker | 19 | Succeeded\nBy stage\nApplied 9\nRecruiter screen complete 2\nInterviewing 3\nFinal round 1\nOffer 1\nRejected 6\nApplications per day\nMon, Oct 5 3\nThu, Oct 8 3\nMon, Oct 12 3\nThu, Oct 15 3\nMon, Oct 19 3\nThu, Oct 22 3\nMon, Oct 26 2\nThu, Oct 29 2\nBy category\nSoftware 6\nSubscription 5\nUtility 3\nInsurance 2\nMembership 2\nOther 1",
    "id":"view-C6E99EA8-8A0A-4E94-B83C-732E76A12CF6","source":{"kind":"view","name":"This week","updatedAt":"2026-11-18T03:32:50Z"},
    "type":"view","version":1},"refreshAfter":30,"view":{"createdAt":"2026-11-18T03:32:50Z","icon":"rectangle.3.group",
    "id":"C6E99EA8-8A0A-4E94-B83C-732E76A12CF6","name":"This week","pinned":true,"private":false,"problems":[],"refreshing":false,
    "sources":["records","tasks"],"subtitle":"Across the trackers","updatedAt":"2026-11-18T03:32:50Z"}}
    """#

    private let resolvedList = #"""
    {"revision":"840BD0F5-6366-4FF6-AD6F-CFCFB8D5A73E","supportsViewActions":true,"views":[{"createdAt":"2026-11-18T03:32:50Z",
    "icon":"server.rack","id":"5966EDC3-9A59-47EA-AFAB-314F477B38BC","name":"Homelab","pinned":true,"private":true,
    "problems":[],"refreshedAt":"2026-11-18T03:32:50Z","refreshing":false,"sources":["tool"],"subtitle":"Service health",
    "updatedAt":"2026-11-18T03:32:50Z"},{"createdAt":"2026-11-18T03:32:50Z","icon":"rectangle.3.group","id":"C6E99EA8-8A0A-4E94-B83C-732E76A12CF6",
    "name":"This week","pinned":true,"private":false,"problems":[],"refreshing":false,"sources":["records","tasks"],
    "subtitle":"Across the trackers","updatedAt":"2026-11-18T03:32:50Z"}]}
    """#

    func testDrawsViewsTheMacResolved() throws {
        let homelab = try JSONDecoder().decode(CantripHomeViewDetail.self, from: Data(resolvedHomelab.utf8))
        XCTAssertEqual(homelab.view.name, "Homelab")
        XCTAssertTrue(homelab.view.isPrivate)
        XCTAssertEqual(homelab.card.id, "view-\(homelab.view.id)")
        XCTAssertEqual(homelab.refreshAfter, 30)
        XCTAssertEqual(homelab.card.blocks.map(\.type), ["header", "stat", "section", "table", "keyValue", "actions"])
        let table = try XCTUnwrap(homelab.card.blocks.first { $0.type == "table" })
        XCTAssertEqual(table.columns?.compactMap(\.title), ["Service", "Status", "Version"])
        XCTAssertEqual(table.tableRows?.map { $0.cells.first?.text }, ["Grafana", "NAS", "Router"])
        XCTAssertEqual(table.tableRows?.map { $0.cells[1].tone }, ["positive", "positive", "negative"])
        XCTAssertEqual(table.tableRows?.last?.accessibilityLabel, "Router, Status Down, Version 4.1.3")
        let actions = try XCTUnwrap(homelab.card.blocks.last)
        XCTAssertEqual(CantripCard.ActionButton.shown(actions.buttons).first?.confirmTitle, "Refresh Homelab?")
        XCTAssertEqual(CantripCardPanel.sections(homelab.card.blocks).count, 5, "in chat the Refresh button isn't drawn")
        XCTAssertEqual(CantripCardPanel.sections(homelab.card.blocks, allowsActions: true).count, 6)

        let dashboard = try JSONDecoder().decode(CantripHomeViewDetail.self, from: Data(resolvedDashboard.utf8))
        let blocks = dashboard.card.blocks
        XCTAssertEqual(blocks.map(\.type), ["header", "tabs", "stat", "keyValue", "table", "chart", "chart", "chart", "actions"])
        XCTAssertEqual(blocks[1].tabs?.compactMap(\.title), ["Overview", "Interviews", "Bills"])
        func shown(_ tab: Int) -> [Int] {
            CantripCardPanel.entries(blocks, selectedTab: { _ in tab }, allowsActions: true).map(\.index)
        }
        XCTAssertEqual(shown(0), [0, 1, 2, 3, 4, 8], "Overview: its stat, numbers and table; the buttons after the tabs")
        XCTAssertEqual(shown(1), [0, 1, 5, 6, 8], "Interviews: the pie and the line")
        XCTAssertEqual(shown(2), [0, 1, 7, 8], "Bills: the bars")
        XCTAssertEqual(CantripCardPieChart.slices(blocks[5]).map(\.label),
                       ["Applied", "Recruiter screen complete", "Interviewing", "Final round", "Offer", "Rejected"])
        XCTAssertEqual(CantripCardPieChart.slices(blocks[5]).map(\.tone), [nil, nil, nil, nil, "positive", "negative"])
        XCTAssertEqual(CantripCardLineChart.points(blocks[6]).count, 8)
        XCTAssertEqual(CantripCardLineChart.scale(blocks[6], points: CantripCardLineChart.points(blocks[6])), 0...3)
        XCTAssertEqual(blocks[4].columns?.map(\.align), ["leading", "trailing", "leading"])
        XCTAssertEqual(CantripCard.ActionButton.shown(blocks[8].buttons).compactMap(\.kind), ["runTask", "ask"])

        let list = try JSONDecoder().decode(ResolvedList.self, from: Data(resolvedList.utf8))
        XCTAssertEqual(list.views.compactMap(\.value).map(\.name), ["Homelab", "This week"])
        XCTAssertEqual(list.views.compactMap(\.value).map(\.pinned), [true, true])
        XCTAssertNil(list.views.compactMap(\.value).last?.refreshedAt, "records and tasks are read live: no tool time")
    }

    private struct ResolvedList: Decodable {
        let views: [CantripLossy<CantripHomeViewSummary>]
    }

    // MARK: API

    private func api() throws -> CantripRemoteAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ViewRequestProtocol.self]
        return CantripRemoteAPI(transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
                                token: "test-pairing-token", urlSession: URLSession(configuration: configuration))
    }

    func testViewRequestsAndAnswers() async throws {
        var sent: [Sent] = []
        var queries: [String] = []
        ViewRequestProtocol.handler = { [summaryJSON, detailJSON] request, body in
            let path = request.url?.path ?? ""
            sent.append(Sent(method: request.httpMethod ?? "", path: path, body: String(decoding: body, as: UTF8.self)))
            queries.append(request.url?.query ?? "")
            switch (request.httpMethod, path) {
            case ("GET", "/api/v1/home/views"):
                if request.url?.query?.contains("revision=r1") == true { return (200, Data(#"{"unchanged":true,"revision":"r1"}"#.utf8)) }
                return (200, Data(#"{"views":[\#(summaryJSON),{"name":"No ID"},{"id":"B2","name":"Week","pinned":false,"private":false,"sources":["records"],"createdAt":0,"updatedAt":0,"refreshing":true,"problems":[]}],"revision":"r1","supportsViewActions":true}"#.utf8))
            case ("POST", "/api/v1/home/views/6A1F/pin"):
                return (200, Data(summaryJSON.utf8))
            case ("DELETE", "/api/v1/home/views/6A1F"):
                return (200, Data(#"{"deleted":true}"#.utf8))
            default:
                return (200, Data(detailJSON.utf8))
            }
        }
        addTeardownBlock { @MainActor in ViewRequestProtocol.handler = nil }
        let api = try self.api()

        let fetched = try await api.homeViews(ifChangedFrom: nil)
        let listed = try XCTUnwrap(fetched)
        XCTAssertEqual(listed.views.map(\.id), ["6A1F", "B2"], "a view without an ID drops alone")
        XCTAssertEqual(listed.revision, "r1")
        XCTAssertTrue(listed.supportsActions)
        let summary = listed.views[0]
        XCTAssertTrue(summary.pinned)
        XCTAssertTrue(summary.isPrivate)
        XCTAssertEqual(summary.sources, ["tool", "tasks"])
        XCTAssertEqual(summary.problems, ["homelab_status timed out"])
        XCTAssertEqual(summary.updatedAt, Date(timeIntervalSince1970: 1_794_938_700.25), "ISO dates, with or without fractions")
        XCTAssertEqual(summary.refreshedAt, ISO8601DateFormatter().date(from: "2026-11-17T18:30:00Z"))
        XCTAssertEqual(summary.symbol, "server.rack")
        XCTAssertEqual(summary.spokenLabel.hasPrefix("Homelab, Pinned, Private, Updated "), true)
        XCTAssertEqual(listed.views[1].updatedAt, Date(timeIntervalSinceReferenceDate: 0), "Swift's default date encoding")
        XCTAssertTrue(listed.views[1].refreshing)
        let unchanged = try await api.homeViews(ifChangedFrom: "r1")
        XCTAssertNil(unchanged, "an unchanged list keeps the one shown")

        let detail = try await api.homeView(id: "6A1F")
        XCTAssertEqual(detail.view.name, "Homelab")
        XCTAssertEqual(detail.card.id, "view-6A1F")
        XCTAssertEqual(detail.refreshAfter, 30)
        _ = try await api.refreshHomeView(id: "6A1F")
        let pinned = try await api.pinHomeView(id: "6A1F", pinned: false)
        XCTAssertEqual(pinned.id, "6A1F", "the pin answers the bare summary")
        try await api.deleteHomeView(id: "6A1F")

        XCTAssertEqual(sent, [
            Sent(method: "GET", path: "/api/v1/home/views", body: ""),
            Sent(method: "GET", path: "/api/v1/home/views", body: ""),
            Sent(method: "GET", path: "/api/v1/home/views/6A1F", body: ""),
            Sent(method: "POST", path: "/api/v1/home/views/6A1F/refresh", body: ""),
            Sent(method: "POST", path: "/api/v1/home/views/6A1F/pin", body: #"{"pinned":false}"#),
            Sent(method: "DELETE", path: "/api/v1/home/views/6A1F", body: ""),
        ])
        XCTAssertTrue(queries[1].contains("revision=r1"))
        XCTAssertThrowsError(try CantripRemoteAPI.homeViewPath(""), "an empty ID is never sent")
        XCTAssertEqual(try CantripRemoteAPI.homeViewPath("a/b", "actions", "a 1"), "/api/v1/home/views/a%2Fb/actions/a%201")
        XCTAssertTrue(CantripRemoteAPI.isSlowWrite(method: "POST", path: "/api/v1/home/views/6A1F/refresh"),
                      "a refresh waits on the Mac's tools")
        XCTAssertTrue(CantripRemoteAPI.isSlowWrite(method: "POST", path: "/api/v1/home/views/6A1F/actions/a1"))
        XCTAssertFalse(CantripRemoteAPI.isSlowWrite(method: "POST", path: "/api/v1/home/views/6A1F/pin"))
    }

    func testDetailDecoding() throws {
        let noCardID = #"{"view":\#(summaryJSON),"card":{"blocks":[{"type":"header","title":"Homelab"}]},"refreshAfter":1}"#
        let detail = try JSONDecoder().decode(CantripHomeViewDetail.self, from: Data(noCardID.utf8))
        XCTAssertEqual(detail.card.id, "view-6A1F", "a card without an ID keeps the view's, so its tabs survive a refetch")
        XCTAssertEqual(detail.refreshAfter, 5, "never fetched more often than every 5 seconds")
        let wrapped = try JSONDecoder().decode(CantripHomeViewDetail.self, from: Data(#"{"view":\#(summaryJSON),"card":\#(viewCard)}"#.utf8))
        XCTAssertEqual(wrapped.refreshAfter, 30)
        XCTAssertThrowsError(try JSONDecoder().decode(CantripHomeViewDetail.self, from: Data(#"{"card":\#(viewCard)}"#.utf8)))
    }

    func testTasksSnapshotSaysWhetherTheMacHasViews() async throws {
        var supports = true
        ViewRequestProtocol.handler = { _, _ in
            let flag = supports ? #","supportsViews":true"# : ""
            return (200, Data(#"{"tasks":[],"revision":"t1","error":null,"supportsReordering":true\#(flag)}"#.utf8))
        }
        addTeardownBlock { @MainActor in ViewRequestProtocol.handler = nil }
        let api = try self.api()
        let current = try await api.homeTasks()
        XCTAssertTrue(current.supportsViews)
        supports = false
        let older = try await api.homeTasks()
        XCTAssertFalse(older.supportsViews, "an older Mac shows no Views")
    }

    /// A change goes to the Mac once, after the views list confirmed the route and that the view
    /// is still there; a view that's gone gets nothing sent.
    func testViewChangesConfirmTheViewBeforeSendingOnce() async throws {
        var sent: [Sent] = []
        ViewRequestProtocol.handler = { [summaryJSON] request, body in
            let path = request.url?.path ?? ""
            sent.append(Sent(method: request.httpMethod ?? "", path: path, body: String(decoding: body, as: UTF8.self)))
            switch path {
            case "/api/v1/home/views":
                return (200, Data(#"{"views":[\#(summaryJSON)],"revision":"r1","supportsViewActions":true}"#.utf8))
            case "/api/v1/home/views/6A1F/actions/a1":
                return (200, Data(#"{"result":"started","message":"Queued."}"#.utf8))
            default:
                return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ViewRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: configuration))
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "unit-views-token", tailscaleOnly: true)
        XCTAssertTrue(configured, model.errorMessage ?? "Configuration failed")
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            ViewRequestProtocol.handler = nil
        }

        func viewRequests() -> [Sent] { sent.filter { $0.path.hasPrefix("/api/v1/home/views") } }
        sent = []
        let result = try await model.runHomeViewAction(viewID: "6A1F", actionID: "a1")
        XCTAssertEqual(result.message, "Queued.")
        XCTAssertEqual(viewRequests().map(\.method), ["GET", "POST"], "the list first, then the one write")
        XCTAssertEqual(viewRequests().last?.body, #"{"confirmed":true}"#)

        sent = []
        do {
            _ = try await model.runHomeViewAction(viewID: "GONE", actionID: "a1")
            XCTFail("a view that's gone isn't changed")
        } catch CantripRemoteError.rejected(let message) {
            XCTAssertEqual(message, "This view is no longer on the Mac.")
        }
        XCTAssertEqual(viewRequests().map(\.method), ["GET"], "nothing is posted for a view that's gone")
    }
}
