import Foundation
import XCTest
@testable import Hermes

private final class ChildTabRequestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

/// Child tabs from Cantrip's Remote API (docs/remote-control.md "Child tabs"): the shapes below
/// are what the Mac sends (`ChildTab.snapshot`, `QueuePlan.snapshot`, the session listing).
final class CantripChildTabsTests: XCTestCase {
    private let parentID = "11111111-1111-1111-1111-111111111111"
    private let childID = "22222222-2222-2222-2222-222222222222"
    private let queuedID = "33333333-3333-3333-3333-333333333333"

    override func tearDown() {
        ChildTabRequestProtocol.handler = nil
        super.tearDown()
    }

    private func api() throws -> CantripRemoteAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChildTabRequestProtocol.self]
        return CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "test-pairing-token",
            urlSession: URLSession(configuration: configuration)
        )
    }

    private func parentJSON(supportsChildTabs: Bool? = true, reason: String? = nil) -> [String: Any] {
        var session: [String: Any] = [
            "id": parentID, "title": "Cantrip", "workdir": "/Users/me/Coding/Cantrip", "isStreaming": true,
            "canResume": false, "councilMode": false, "queuedCount": 1, "supportsQueuePlans": true,
            "queued": [[
                "id": queuedID, "text": "Change one-time tasks to delete themselves",
                "displayText": "Change one-time tasks to delete themselves", "images": [],
                "plan": ["kind": "fork", "reason": "Independent: can run in a child tab",
                         "title": "Once-task auto-remove", "repo": "Cantrip"],
            ]],
            "messages": [[
                "id": "card-1", "role": "assistant", "text": "Child tab “Per-task models”: Merge conflict · 1 of 3 files.",
                "thinking": "", "activities": [],
                "childResult": [
                    "id": childID, "parentID": parentID, "title": "Per-task models",
                    "prompt": "Let each Cantrip Home scheduled task set its own Copilot model\nthen run five tasks on Sonnet.",
                    "parentTitle": "Cantrip", "state": "conflict", "statusLine": "Merge conflict · 1 of 3 files",
                    "summary": "Each Home task can now set its own model.", "replies": ["Starting on per-task models."],
                    "files": [["path": "Sources/Cantrip/CantripHome.swift", "added": 48, "removed": 6]],
                    "added": 48, "removed": 6, "conflictFiles": ["Sources/Cantrip/CantripHome.swift"],
                    "conflictExcerpt": "  func complete(\nmain    removeOnce()\nchild   applyModel()", "cleanFileCount": 2,
                    "actions": ["resolve", "keepParent", "keepChild", "leave", "open"],
                    "branch": "cantrip/child/per-task-models-2222", "baseBranch": "main", "repoName": "Cantrip",
                    "createdAt": 1_790_000_000.0, "updatedAt": 1_790_000_100.0,
                ] as [String: Any],
            ] as [String: Any]],
        ]
        if let supportsChildTabs { session["supportsChildTabs"] = supportsChildTabs }
        if let reason { session["childTabsUnavailableReason"] = reason }
        return session
    }

    private func childJSON() -> [String: Any] {
        [
            "id": childID, "title": "Per-task models", "workdir": "/Users/me/.cache/Cantrip/worktrees/2222",
            "isStreaming": true, "canResume": false, "councilMode": false, "queuedCount": 0,
            "supportsTabReordering": false, "supportsTabSections": false, "supportsChildTabs": false,
            "childTabsUnavailableReason": "A child tab can't start its own child tabs.",
            "parentID": parentID, "sectionID": "harness",
            "child": ["state": "working", "title": "Per-task models", "parentTitle": "Cantrip", "statusLine": "Working",
                      "branch": "cantrip/child/per-task-models-2222", "baseBranch": "main", "repoName": "Cantrip"],
        ]
    }

    private func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    func testListingDecodesChildTabsPlansAndCards() throws {
        let listing = try JSONDecoder().decode(
            CantripSessionsResponse.self, from: data(["sessions": [parentJSON(), childJSON()]])
        )
        let parent = listing.sessions[0], child = listing.sessions[1]
        XCTAssertFalse(parent.isChildTab)
        XCTAssertEqual(parent.supportsChildTabs, true)
        XCTAssertEqual(parent.supportsQueuePlans, true)
        let plan = try XCTUnwrap(parent.queued?.first?.plan)
        XCTAssertEqual(plan, CantripRemoteQueuePlan(kind: .fork, reason: "Independent: can run in a child tab",
                                                    title: "Once-task auto-remove", repo: "Cantrip"))

        XCTAssertTrue(child.isChildTab)
        XCTAssertEqual(child.parentID, parentID)
        XCTAssertEqual(child.child?.state, .working)
        XCTAssertEqual(child.child?.parentTitle, "Cantrip")
        XCTAssertEqual(child.child?.branch, "cantrip/child/per-task-models-2222")
        XCTAssertEqual(child.supportsTabReordering, false, "A child stays under its parent")
        XCTAssertEqual(child.childTabsUnavailableReason, "A child tab can't start its own child tabs.")

        let card = try XCTUnwrap(parent.transcript.first?.childResult)
        XCTAssertEqual(parent.transcript.first?.role, "assistant", "Older clients read the card as a reply")
        XCTAssertFalse(parent.transcript.first?.isHandoffResult ?? true)
        XCTAssertEqual(card.id, childID)
        XCTAssertEqual(card.state, .conflict)
        XCTAssertEqual(card.files, [.init(path: "Sources/Cantrip/CantripHome.swift", added: 48, removed: 6)])
        XCTAssertEqual(card.conflictFiles, ["Sources/Cantrip/CantripHome.swift"])
        XCTAssertEqual(card.cleanFileCount, 2)
        XCTAssertEqual(card.baseBranch, "main")
        XCTAssertEqual(card.actions, ["resolve", "keepParent", "keepChild", "leave", "open"])
    }

    func testNewerStatesAndMissingFieldsStillDecode() throws {
        var parent = parentJSON()
        parent["queued"] = [["id": queuedID, "text": "Ship it", "plan": ["kind": "split", "reason": "Splits in two"]]]
        parent["messages"] = [[
            "id": "card-1", "role": "assistant", "text": "Child tab", "thinking": "", "activities": [],
            "childResult": ["id": childID, "state": "rebasing", "files": [["path": "a.swift"]]],
        ] as [String: Any]]
        var child = childJSON()
        child["child"] = ["state": "paused"]
        let listing = try JSONDecoder().decode(CantripSessionsResponse.self, from: data(["sessions": [parent, child]]))
        XCTAssertEqual(listing.sessions[0].queued?.first?.plan?.kind, .other)
        XCTAssertEqual(listing.sessions[0].queued?.first?.plan?.reason, "Splits in two")
        let card = try XCTUnwrap(listing.sessions[0].transcript.first?.childResult)
        XCTAssertEqual(card.state, .other)
        XCTAssertEqual(card.title, "")
        XCTAssertEqual(card.files, [.init(path: "a.swift", added: 0, removed: 0)])
        XCTAssertEqual(card.actions, [])
        XCTAssertEqual(listing.sessions[1].child?.state, .other)
        XCTAssertEqual(listing.sessions[1].child?.parentTitle, "")
    }

    func testOlderHostsHaveNoChildTabFields() throws {
        let session = try JSONDecoder().decode(CantripRemoteSession.self, from: Data(#"""
        {"id":"a","title":"Chat","workdir":"/tmp","isStreaming":false,"canResume":false,"councilMode":false,
         "queuedCount":1,"queued":[{"id":"q","text":"Next"}],
         "messages":[{"id":"m","role":"assistant","text":"Hi","thinking":"","activities":[]}]}
        """#.utf8))
        XCTAssertNil(session.supportsChildTabs)
        XCTAssertNil(session.parentID)
        XCTAssertNil(session.child)
        XCTAssertFalse(session.isChildTab)
        XCTAssertNil(session.queued?.first?.plan)
        XCTAssertNil(session.transcript.first?.childResult)
    }

    func testForkPostsAnEmptyBodyAndReturnsTheParentAndChild() async throws {
        let before = try data(["session": parentJSON()])
        var after = parentJSON()
        after["queued"] = []
        after["queuedCount"] = 0
        let forked = try data(["session": after, "childID": childID])
        var requests: [String] = []
        ChildTabRequestProtocol.handler = { request in
            requests.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                return (200, forked)
            }
            return (200, before)
        }
        let api = try api()
        try await api.prepareChildTabs(sessionID: parentID)
        let result = try await api.forkQueuedPrompt(id: queuedID, sessionID: parentID)
        XCTAssertEqual(requests, [
            "GET /api/v1/sessions/\(parentID)",
            "POST /api/v1/sessions/\(parentID)/queue/\(queuedID)/fork",
        ])
        XCTAssertEqual(result.childID, childID)
        XCTAssertEqual(result.session.queuedCount, 0)
    }

    func testOlderHostsAreNotAskedToFork() async throws {
        for support: Bool? in [nil, false] {
            let response = try data(["session": parentJSON(supportsChildTabs: support)])
            var methods: [String] = []
            ChildTabRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                return (200, response)
            }
            do {
                try await api().prepareChildTabs(sessionID: parentID)
                XCTFail("An older host must show the update message")
            } catch CantripRemoteError.childTabsUnsupported {}
            XCTAssertEqual(methods, ["GET"])
        }
    }

    func testForkRefusalsShowTheMacsReason() async throws {
        let reason = "This tab already has 2 child tabs running. Wait for one to finish."
        ChildTabRequestProtocol.handler = { _ in (409, try self.data(["error": reason])) }
        do {
            _ = try await api().forkQueuedPrompt(id: queuedID, sessionID: parentID)
            XCTFail("A refused fork must not look like a new child tab")
        } catch CantripRemoteError.http(let status, let message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, reason)
        }
    }

    func testCardActionsPostToTheParentsChildRoute() async throws {
        let response = try data(["session": parentJSON()])
        var paths: [String] = []
        ChildTabRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            paths.append(request.url?.path ?? "")
            return (200, response)
        }
        for action in ["keepParent", "open"] {
            let parent = try await api().childAction(action, childID: childID, parentID: parentID)
            XCTAssertEqual(parent.id, parentID)
        }
        XCTAssertEqual(paths, [
            "/api/v1/sessions/\(parentID)/children/\(childID)/keepParent",
            "/api/v1/sessions/\(parentID)/children/\(childID)/open",
        ])
    }

    func testCardOffersOnlyTheMacsActions() {
        var child = CantripRemoteChildResult(id: childID, title: "Per-task models", state: .conflict,
                                             branch: "cantrip/child/x", baseBranch: "main",
                                             actions: ["resolve", "keepParent", "keepChild", "leave", "open"])
        XCTAssertEqual(CantripChildTabText.conflictOptions(child).map(\.title), [
            "Keep both, then run the tests (Recommended)", "Keep main's version",
            "Keep the child's version", "Leave it unmerged; I'll look",
        ])
        XCTAssertTrue(CantripChildTabText.extraActions(child).isEmpty, "A conflict asks its own question")

        child = CantripRemoteChildResult(id: childID, title: "x", state: .unmerged, branch: "cantrip/child/x",
                                         actions: ["retry", "discard", "open"])
        XCTAssertEqual(CantripChildTabText.extraActions(child).map(\.action), ["retry", "discard"])
        XCTAssertEqual(CantripChildTabText.conflictOptions(child).count, 0)

        child = CantripRemoteChildResult(id: childID, title: "x", state: .failed, actions: ["open", "discard"])
        XCTAssertTrue(CantripChildTabText.extraActions(child).isEmpty, "Nothing to discard without a branch")

        child = CantripRemoteChildResult(id: childID, title: "x", state: .working, actions: ["open", "discard"])
        XCTAssertTrue(CantripChildTabText.extraActions(child).isEmpty, "Discard waits until it stops working")
        XCTAssertEqual(CantripChildTabText.summary(child), "Working on it in its own tab.")

        child = CantripRemoteChildResult(id: childID, title: "x", state: .needsInput, branch: "cantrip/child/x",
                                         actions: ["open", "requeue", "discard"])
        XCTAssertEqual(CantripChildTabText.extraActions(child).map(\.title), ["Run in this tab instead"],
                       "A running child can go back to its parent's queue")
        child = CantripRemoteChildResult(id: childID, title: "x", state: .requeued, actions: ["open"])
        XCTAssertTrue(CantripChildTabText.extraActions(child).isEmpty)
        XCTAssertEqual(CantripChildTabText.statusIcon(.requeued).symbol, "arrow.uturn.backward")
    }

    func testConflictAndBannerWording() {
        let child = CantripRemoteChildResult(
            id: childID, title: "x", state: .conflict,
            conflictFiles: ["a.swift", "b.swift", "c.swift", "d.swift", "e.swift"], cleanFileCount: 1
        )
        XCTAssertEqual(CantripChildTabText.conflictLead(child),
                       "1 file merged cleanly, but both branches changed the same lines in a.swift, b.swift, c.swift, d.swift and 1 more.")
        let only = CantripRemoteChildResult(id: childID, title: "x", state: .conflict, conflictFiles: ["a.swift"])
        XCTAssertEqual(CantripChildTabText.conflictLead(only), "Both branches changed the same lines in a.swift.")
        XCTAssertEqual(CantripChildTabText.firstLine("First line\nSecond"), "First line")
        XCTAssertEqual(
            CantripChildTabText.banner(CantripRemoteChildTab(state: .working, title: "x", parentTitle: "Cantrip",
                                                             statusLine: "Working", branch: "cantrip/child/x",
                                                             baseBranch: "main")),
            "Child tab of Cantrip · cantrip/child/x → main · Working"
        )
        XCTAssertEqual(
            CantripChildTabText.banner(CantripRemoteChildTab(state: .noChanges, title: "x", parentTitle: "Notes",
                                                             statusLine: "Done · no repository to merge")),
            "Child tab of Notes · Done · no repository to merge"
        )
    }

    func testTabListsReadChildTabsWithTheirParent() throws {
        let child = try JSONDecoder().decode(CantripRemoteSession.self, from: data(childJSON()))
        XCTAssertEqual(CantripSessionPicker.accessibilityTitle(for: child),
                       "Per-task models, Working, child tab of Cantrip")
        let parent = try JSONDecoder().decode(CantripRemoteSession.self, from: data(parentJSON()))
        XCTAssertEqual(CantripSessionPicker.accessibilityTitle(for: parent), "Cantrip, Working")
    }
}
