import Foundation
import XCTest
@testable import Hermes

private final class SectionRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest, Data?) throws -> (Int, Any))?
    /// The Mac refuses section changes (e.g. another device deleted the section).
    @MainActor static var refusesSectionChanges = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, object) = try handler(request, body)
                let data = try JSONSerialization.data(withJSONObject: object)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1",
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
final class CantripTabSectionsTests: XCTestCase {
    private func tab(_ id: String, section: String? = nil, streaming: Bool = false, inputs: Int = 0) -> CantripRemoteSession {
        var session = CantripRemoteSession(id: id, title: id, workdir: "/tmp", isStreaming: streaming, canResume: false,
                                           councilMode: false, queuedCount: 0, status: nil, messages: nil,
                                           supportsImageAttachments: true, queued: nil)
        session.sectionID = section
        session.pendingInputCount = inputs
        return session
    }

    func testListingDecodesSectionsAndEachTabsSection() throws {
        let json = """
        {"sessions":[{"id":"a","title":"A","workdir":"/","isStreaming":false,"canResume":false,"councilMode":false,
          "queuedCount":0,"sectionID":"s1","supportsTabSections":true}],
         "sections":[{"id":"s1","name":"Work"}],"supportsTabSections":true}
        """
        let listing = try JSONDecoder().decode(CantripSessionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(listing.sections, [CantripTabSection(id: "s1", name: "Work")])
        XCTAssertEqual(listing.supportsTabSections, true)
        XCTAssertEqual(listing.sessions.first?.sectionID, "s1")
        XCTAssertEqual(listing.sessions.first?.supportsTabSections, true)

        let legacy = try JSONDecoder().decode(CantripSessionsResponse.self, from: Data(#"{"sessions":[]}"#.utf8))
        XCTAssertNil(legacy.sections)
        XCTAssertNil(legacy.supportsTabSections)
    }

    func testGroupsFollowTheMacsOrderAndCollapsedSectionsKeepActiveTabs() throws {
        let sessions = [tab("a"), tab("b", section: "s2"), tab("c", section: "s1", streaming: true),
                        tab("d", section: "gone"), tab("e", section: "s1"), tab("f", section: "s1", inputs: 1)]
        XCTAssertNil(CantripTabGrouping.groups(sessions, sections: []), "Without sections the list stays flat")
        let sections = [CantripTabSection(id: "s1", name: "Work"), CantripTabSection(id: "s2", name: "Home")]
        let groups = try XCTUnwrap(CantripTabGrouping.groups(sessions, sections: sections))
        XCTAssertEqual(groups.map(\.name), ["Tabs", "Work", "Home"])
        XCTAssertEqual(groups.map { $0.sessions.map(\.id) }, [["a", "d"], ["c", "e", "f"], ["b"]],
                       "Tabs of a deleted section show under Tabs; order follows the Mac")
        XCTAssertNil(groups[0].section)
        XCTAssertEqual(CantripTabGrouping.visible(groups[1], collapsed: false, selectedID: nil).map(\.id), ["c", "e", "f"])
        XCTAssertEqual(CantripTabGrouping.visible(groups[1], collapsed: true, selectedID: nil).map(\.id), ["c", "f"],
                       "A collapsed section keeps working tabs and tabs waiting for an answer")
        XCTAssertEqual(CantripTabGrouping.visible(groups[1], collapsed: true, selectedID: "e").map(\.id), ["c", "e", "f"],
                       "and the open tab")
        XCTAssertEqual(CantripTabGrouping.sectionID(of: tab("x", section: "gone"), sections: sections), nil)
        XCTAssertEqual(CantripTabGrouping.sectionID(of: tab("x", section: "s2"), sections: sections), "s2")
    }

    func testCollapseIsRememberedPerMacOnThisDevice() throws {
        let suite = "cantrip-section-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CantripTabSectionCollapse(defaults: defaults)
        store.toggle("s1", scope: "mini")
        XCTAssertTrue(store.isCollapsed("s1", scope: "mini"))
        XCTAssertFalse(store.isCollapsed("s1", scope: "laptop"), "Each paired Mac has its own")
        let reopened = CantripTabSectionCollapse(defaults: defaults)
        XCTAssertTrue(reopened.isCollapsed("s1", scope: "mini"), "Collapse survives relaunch")
        reopened.toggle("s1", scope: "mini")
        XCTAssertFalse(reopened.isCollapsed("s1", scope: "mini"))
    }

    private func configuredModel(supportsSections: Bool) async throws
        -> (CantripRemoteModel, () -> [(String, String, [String: Any]?)]) {
        var sections: [[String: Any]] = [["id": "s1", "name": "Work"]]
        var tabs: [[String: Any]] = [
            ["id": "a", "title": "A", "workdir": "/", "isStreaming": false, "canResume": false, "councilMode": false,
             "queuedCount": 0, "supportsTabMetadata": true, "supportsTabSections": supportsSections],
        ]
        var log: [(String, String, [String: Any]?)] = []
        SectionRequestProtocol.handler = { request, body in
            let path = request.url?.path ?? "", method = request.httpMethod ?? "GET"
            let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            log.append((method, path, json))
            var listing: [String: Any] { supportsSections
                ? ["sessions": tabs, "sections": sections, "supportsTabSections": true] : ["sessions": tabs] }
            if method == "PATCH", path.hasPrefix("/api/v1/sections/") {
                let id = String(path.dropFirst("/api/v1/sections/".count))
                guard !SectionRequestProtocol.refusesSectionChanges,
                      let index = sections.firstIndex(where: { $0["id"] as? String == id }) else {
                    return (404, ["error": "That section no longer exists. Refresh the tabs and try again."])
                }
                if let name = json?["name"] as? String { sections[index]["name"] = name }
                if let position = json?["position"] as? Int {
                    sections.insert(sections.remove(at: index), at: min(max(position, 0), sections.count))
                }
                return (200, ["sections": sections])
            }
            switch (method, path) {
            case ("GET", "/api/v1/sessions"): return (200, listing)
            case ("GET", "/api/v1/sessions/a"): return (200, ["session": tabs[0]])
            case ("POST", "/api/v1/sections"):
                let section: [String: Any] = ["id": "s2", "name": json?["name"] ?? ""]
                sections.append(section)
                return (201, ["section": section, "sections": sections])
            case ("DELETE", let deletePath) where deletePath.hasPrefix("/api/v1/sections/"):
                let id = String(deletePath.dropFirst("/api/v1/sections/".count))
                sections.removeAll { $0["id"] as? String == id }
                for index in tabs.indices where tabs[index]["sectionID"] as? String == id { tabs[index]["sectionID"] = nil }
                return (200, ["sections": sections])
            case ("POST", "/api/v1/sessions/a/metadata"):
                tabs[0]["sectionID"] = json?["sectionID"] is NSNull ? nil : json?["sectionID"]
                return (200, ["session": tabs[0]])
            case ("POST", "/api/v1/sessions"):
                let created: [String: Any] = ["id": "n", "title": "New", "workdir": "/", "isStreaming": false,
                                              "canResume": false, "councilMode": false, "queuedCount": 0,
                                              "sectionID": json?["sectionID"] ?? NSNull()]
                tabs.append(created)
                return (201, ["session": created])
            default:
                return (404, ["error": "not found"])
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SectionRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: configuration))
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "unit-section-token",
                                               tailscaleOnly: true)
        XCTAssertTrue(configured, model.errorMessage ?? "Configuration failed")
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            SectionRequestProtocol.handler = nil
            SectionRequestProtocol.refusesSectionChanges = false
        }
        model.setAppActive(true)
        await model.refreshNow()
        return (model, { log })
    }

    func testSectionChangesReachTheMacAndRefreshTheList() async throws {
        let (model, log) = try await configuredModel(supportsSections: true)
        XCTAssertTrue(model.supportsTabSections)
        XCTAssertEqual(model.tabSections.map(\.name), ["Work"])

        let filed = await model.fileTab("a", in: "s1")
        XCTAssertTrue(filed, model.errorMessage ?? "")
        XCTAssertEqual(model.sessions.first { $0.id == "a" }?.sectionID, "s1")
        let metadata = log().last { $0.1 == "/api/v1/sessions/a/metadata" }
        XCTAssertEqual(metadata?.2?["sectionID"] as? String, "s1")

        let unfiled = await model.fileTab("a", in: nil)
        XCTAssertTrue(unfiled)
        XCTAssertTrue(log().last { $0.1 == "/api/v1/sessions/a/metadata" }?.2?["sectionID"] is NSNull,
                      "Tabs is sent as null")

        let created = await model.createSection(named: "Clients", filing: "a")
        XCTAssertTrue(created, model.errorMessage ?? "")
        XCTAssertEqual(model.tabSections.map(\.name), ["Work", "Clients"])
        XCTAssertEqual(model.sessions.first { $0.id == "a" }?.sectionID, "s2", "The tab is filed in the new section")

        let renamed = await model.renameSection("s1", to: "Office")
        XCTAssertTrue(renamed)
        XCTAssertEqual(model.tabSections.first?.name, "Office")

        let newTab = await model.createTab(inSection: "s2")
        XCTAssertEqual(newTab, "n")
        XCTAssertEqual(log().last { $0.0 == "POST" && $0.1 == "/api/v1/sessions" }?.2?["sectionID"] as? String, "s2")

        let deleted = await model.deleteSection("s1")
        XCTAssertTrue(deleted)
        XCTAssertEqual(model.tabSections.map(\.id), ["s2"])
        XCTAssertFalse(model.isMutating)
    }

    func testMovingASectionSendsItsPositionAndRevertsWhenTheMacRefuses() async throws {
        let (model, log) = try await configuredModel(supportsSections: true)
        _ = await model.createSection(named: "Clients")
        XCTAssertEqual(model.tabSections.map(\.id), ["s1", "s2"])

        // Edit Sections drags: onMove's destination counts rows before the move.
        XCTAssertEqual(CantripTabGrouping.sectionPosition(movingFrom: 1, to: 0), 0)
        XCTAssertEqual(CantripTabGrouping.sectionPosition(movingFrom: 0, to: 2), 1)
        XCTAssertEqual(CantripTabGrouping.sectionPosition(movingFrom: 1, to: 1), 1)
        let up = await model.moveSection("s2", to: CantripTabGrouping.sectionPosition(movingFrom: 1, to: 0))
        XCTAssertTrue(up, model.errorMessage ?? "")
        XCTAssertEqual(model.tabSections.map(\.id), ["s2", "s1"])
        let patch = log().last { $0.0 == "PATCH" }
        XCTAssertEqual(patch?.1, "/api/v1/sections/s2")
        XCTAssertEqual(patch?.2?["position"] as? Int, 0)
        XCTAssertNil(patch?.2?["name"], "Moving doesn't resend the name")

        let down = await model.moveSection("s2", offset: 1)
        XCTAssertTrue(down)
        XCTAssertEqual(model.tabSections.map(\.id), ["s1", "s2"])
        let past = await model.moveSection("s2", offset: 1)
        XCTAssertFalse(past, "The last section can't move further down")
        let patches = log().filter { $0.0 == "PATCH" }.count
        let same = await model.moveSection("s1", to: 0)
        XCTAssertTrue(same)
        XCTAssertEqual(log().filter { $0.0 == "PATCH" }.count, patches, "Dropping a section in place sends nothing")

        SectionRequestProtocol.refusesSectionChanges = true
        let refused = await model.moveSection("s2", to: 0)
        XCTAssertFalse(refused)
        XCTAssertEqual(model.tabSections.map(\.id), ["s1", "s2"], "A refused move puts the order back")
        XCTAssertNotNil(model.errorMessage, "A refused move says why")
        XCTAssertFalse(model.isMutating)
    }

    func testDeletingASectionWithTabsAsksFirstAndAnEmptyOneGoesAtOnce() async throws {
        let (model, log) = try await configuredModel(supportsSections: true)
        _ = await model.fileTab("a", in: "s1")
        let work = try XCTUnwrap(model.tabSections.first { $0.id == "s1" })
        model.requestDeleteSection(work)
        XCTAssertEqual(model.sectionDeletion, work, "A section with tabs asks before deleting")
        XCTAssertFalse(log().contains { $0.0 == "DELETE" }, "Nothing is deleted until confirmed")

        _ = await model.createSection(named: "Later")
        let later = try XCTUnwrap(model.tabSections.first { $0.name == "Later" })
        XCTAssertFalse(model.sessions.contains { $0.sectionID == later.id }, "New Section makes an empty section")
        model.requestDeleteSection(later)
        for _ in 0..<50 where model.tabSections.contains(later) { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(log().last { $0.0 == "DELETE" }?.1, "/api/v1/sections/\(later.id)", "An empty section deletes at once")
        XCTAssertFalse(model.tabSections.contains(later))

        model.sectionDeletion = nil
        let deleted = await model.deleteSection(work.id)
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.sessions.contains { $0.id == "a" }, "Deleting a section keeps its tabs")
        XCTAssertNil(model.sessions.first { $0.id == "a" }?.sectionID, "Its tabs go back to Tabs")
    }

    func testHoldToDragDropsMoveTabsAndSectionsWithoutHandles() {
        func movable(_ id: String, _ section: String? = nil) -> CantripRemoteSession {
            var session = tab(id, section: section)
            session.supportsTabReordering = true
            session.supportsTabSections = true
            return session
        }
        let sections = [CantripTabSection(id: "s1", name: "Work"), CantripTabSection(id: "s2", name: "Games"),
                        CantripTabSection(id: "s3", name: "Later")]
        let a = movable("a"), b = movable("b", "s1"), c = movable("c", "s1"), d = movable("d", "s2")
        let all = [a, b, c, d]
        typealias Drag = CantripTabDrag
        XCTAssertEqual(Drag.item(Drag.payload(tab: "a")), .tab("a"))
        XCTAssertEqual(Drag.item(Drag.payload(section: "s1")), .section("s1"))
        XCTAssertNil(Drag.item("plain text"))

        // On a tab: takes its place in the shown order.
        XCTAssertEqual(Drag.drop(Drag.payload(tab: "a"), onTab: d, order: all), .moveTab(id: "a", targetID: "d", after: true))
        XCTAssertEqual(Drag.drop(Drag.payload(tab: "d"), onTab: b, order: all), .moveTab(id: "d", targetID: "b", after: false))
        XCTAssertNil(Drag.drop(Drag.payload(tab: "b"), onTab: b, order: all))

        // On a header: a tab is filed there; a section takes the header's place (on Tabs: first).
        XCTAssertEqual(Drag.drop(Drag.payload(tab: "a"), onHeaderOf: "s2", sections: sections, sessions: all),
                       .fileTab(id: "a", sectionID: "s2"))
        XCTAssertEqual(Drag.drop(Drag.payload(tab: "b"), onHeaderOf: nil, sections: sections, sessions: all),
                       .fileTab(id: "b", sectionID: nil))
        XCTAssertNil(Drag.drop(Drag.payload(tab: "b"), onHeaderOf: "s1", sections: sections, sessions: all), "Already there")
        XCTAssertEqual(Drag.drop(Drag.payload(section: "s3"), onHeaderOf: "s1", sections: sections, sessions: all),
                       .moveSection(id: "s3", position: 0))
        XCTAssertEqual(Drag.drop(Drag.payload(section: "s1"), onHeaderOf: "s3", sections: sections, sessions: all),
                       .moveSection(id: "s1", position: 2))
        XCTAssertEqual(Drag.drop(Drag.payload(section: "s2"), onHeaderOf: nil, sections: sections, sessions: all),
                       .moveSection(id: "s2", position: 0))
        XCTAssertNil(Drag.drop(Drag.payload(section: "s1"), onHeaderOf: nil, sections: sections, sessions: all), "Already first")
        XCTAssertNil(Drag.drop(Drag.payload(section: "s2"), onHeaderOf: "s2", sections: sections, sessions: all))
    }

    func testOlderMacsAreToldToUpdateAndNothingIsSent() async throws {
        let (model, log) = try await configuredModel(supportsSections: false)
        XCTAssertFalse(model.supportsTabSections)
        XCTAssertTrue(model.tabSections.isEmpty)
        let filed = await model.fileTab("a", in: "s1")
        XCTAssertFalse(filed)
        XCTAssertEqual(model.errorMessage, CantripRemoteError.tabSectionsUnsupported.localizedDescription)
        XCTAssertFalse(log().contains { $0.0 != "GET" }, "No write reaches a Mac without sections")
        let state = CantripTabActionState(session: try XCTUnwrap(model.sessions.first), model: model)
        XCTAssertFalse(state.canFileInSection, "Move to Section is hidden for older Macs")
    }
}
