import Foundation
import XCTest
@testable import Hermes

private final class SectionRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest, Data?) throws -> (Int, Any))?

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
            switch (method, path) {
            case ("GET", "/api/v1/sessions"): return (200, listing)
            case ("GET", "/api/v1/sessions/a"): return (200, ["session": tabs[0]])
            case ("POST", "/api/v1/sections"):
                let section: [String: Any] = ["id": "s2", "name": json?["name"] ?? ""]
                sections.append(section)
                return (201, ["section": section, "sections": sections])
            case ("PATCH", "/api/v1/sections/s1"):
                if let name = json?["name"] as? String { sections[0]["name"] = name }
                return (200, ["sections": sections])
            case ("DELETE", "/api/v1/sections/s1"):
                sections.removeFirst()
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
