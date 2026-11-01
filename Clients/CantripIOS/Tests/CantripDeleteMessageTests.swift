import Foundation
import XCTest
@testable import Hermes

/// Delete Message: decoding, the checked single POST, which rows have the menu (prompts and errors,
/// never replies), and that every cached page (older ones too) drops messages the Mac lists as deleted.
@MainActor
final class CantripDeleteMessageTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-0000000000d1"
    private let busy = "Wait for this tab to finish before deleting a message."

    private func id(_ value: Int) -> String { String(format: "00000000-0000-0000-0002-%012d", value) }

    private func message(_ value: Int, _ role: String? = nil, _ text: String? = nil) -> [String: Any] {
        ["id": id(value), "role": role ?? (value % 2 == 1 ? "user" : "assistant"),
         "text": text ?? "Fixture message \(value)", "thinking": "", "activities": []]
    }

    /// One page of the tab, paged as the app requests it: `values` are message numbers (odd ones
    /// prompts, even ones replies).
    private func snapshot(
        values: [Int] = [5, 6, 7, 8], older: Bool = true, revision: String = "r1",
        supported: Bool? = true, streaming: Bool = false, deleted: [Int]? = nil,
        messages: [[String: Any]]? = nil, list: Bool = false
    ) throws -> Data {
        var session: [String: Any] = [
            "id": sessionID, "title": "Fixture Tab", "workdir": "/tmp/fixture", "isStreaming": streaming,
            "canResume": false, "councilMode": false, "queuedCount": 0,
            "supportsPagedHistory": true, "historyRevision": revision,
        ]
        if let supported { session["supportsDeleteMessage"] = supported }
        if let deleted { session["deletedMessageIDs"] = deleted.map(id) }
        if !list {
            session["historyStartID"] = "fixture-start"
            session["hasOlderMessages"] = older
            session["messages"] = messages ?? values.map { message($0) }
        }
        return try JSONSerialization.data(withJSONObject: list ? ["sessions": [session]] : ["session": session])
    }

    private func isList(_ request: URLRequest) -> Bool {
        request.httpMethod == "GET" && request.url?.path == "/api/v1/sessions"
    }

    private func isOlderPage(_ request: URLRequest) -> Bool {
        request.url?.query?.contains("before=") == true
    }

    private func api() throws -> CantripRemoteAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StartFreshRequestProtocol.self]
        addTeardownBlock { @MainActor in StartFreshRequestProtocol.handler = nil }
        return CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "delete-message-test-token",
            urlSession: URLSession(configuration: configuration)
        )
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The tab open with its recent page (5–8) and, when `loadsOlder`, the older page (1–4) too.
    private func selectedModel(loadsOlder: Bool = true, supported: Bool? = true,
                               streaming: Bool = false) async throws -> CantripRemoteModel {
        let model = try StartFreshFixture.model(for: self)
        StartFreshRequestProtocol.handler = { request in
            if self.isOlderPage(request) {
                XCTAssertTrue(request.url?.query?.contains("before=\(self.id(5))") == true)
                return (200, try self.snapshot(values: [1, 2, 3, 4], older: false, supported: supported,
                                               streaming: streaming))
            }
            return (200, try self.snapshot(supported: supported, streaming: streaming, list: self.isList(request)))
        }
        await model.selectSession(sessionID)
        XCTAssertEqual(model.selectedSession?.id, sessionID, model.errorMessage ?? "Tab not selected")
        if loadsOlder {
            await model.loadOlderMessages()
            XCTAssertEqual(model.selectedSession?.transcript.map(\.id), (1...8).map(id), "Both pages are loaded")
        }
        return model
    }

    /// Polls as the app does while it's open, until `done` (a missed poll is retried).
    private func poll(_ model: CantripRemoteModel, until done: () -> Bool,
                      _ message: @autoclosure () -> String) async throws {
        model.setAppActive(true)
        for _ in 0..<300 where !done() {
            await model.refreshNow()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(done(), message())
    }

    // MARK: Decoding

    private struct SessionResponse: Decodable { let session: CantripRemoteSession }

    func testSnapshotDecodesDeleteFieldsAndOlderMacsLeaveThemNil() throws {
        let current = try JSONDecoder().decode(SessionResponse.self, from: snapshot(deleted: [1, 2])).session
        XCTAssertEqual(current.supportsDeleteMessage, true)
        XCTAssertEqual(current.deletedMessageIDs, [id(1), id(2)])

        let none = try JSONDecoder().decode(SessionResponse.self, from: snapshot(deleted: [])).session
        XCTAssertEqual(none.deletedMessageIDs, [])

        let older = try JSONDecoder().decode(SessionResponse.self, from: snapshot(supported: nil)).session
        XCTAssertNil(older.supportsDeleteMessage)
        XCTAssertNil(older.deletedMessageIDs)
    }

    // MARK: API

    func testDeleteChecksTheTabThenPostsTheMessageIDOnce() async throws {
        var methods: [String] = []
        StartFreshRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)/delete-message")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasSuffix("delete-message-test-token") == true)
                XCTAssertTrue(request.url?.query?.contains("recentExchanges=") == true, "Paged clients get the paged form")
                XCTAssertEqual(try self.body(request) as? [String: String], ["messageID": self.id(7)])
                return (200, try self.snapshot(values: [5, 6], revision: "r2", deleted: [7, 8]))
            }
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)")
            return (200, try self.snapshot())
        }
        let session = try await api().deleteMessage(messageID: id(7), sessionID: sessionID)
        XCTAssertEqual(methods, ["GET", "POST"], "One check of the tab, then a single write")
        XCTAssertEqual(session.transcript.map(\.id), [id(5), id(6)])
        XCTAssertEqual(session.deletedMessageIDs, [id(7), id(8)])
    }

    func testOlderMacsAndBusyTabsAreRefusedWithoutAWrite() async throws {
        let cases: [(supported: Bool?, streaming: Bool, reason: String)] = [
            (nil, false, CantripDeleteMessage.unsupported),
            (false, false, CantripDeleteMessage.unsupported),
            (true, true, busy),
        ]
        for item in cases {
            var methods: [String] = []
            StartFreshRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                return (200, try self.snapshot(supported: item.supported, streaming: item.streaming))
            }
            do {
                _ = try await api().deleteMessage(messageID: id(7), sessionID: sessionID)
                XCTFail("A tab that can't delete messages must not receive the write")
            } catch CantripRemoteError.http(let status, let message) {
                XCTAssertEqual(status, 409)
                XCTAssertEqual(message, item.reason)
            }
            XCTAssertEqual(methods, ["GET"])
        }
    }

    func testTheMacsRefusalSurfacesItsReason() async throws {
        let refusals: [(Int, String)] = [
            (404, "That message is no longer in this conversation."),
            (409, busy),
            (400, "Send a messageID."),
        ]
        for (status, reason) in refusals {
            StartFreshRequestProtocol.handler = { request in
                if request.httpMethod == "POST" {
                    return (status, try JSONSerialization.data(withJSONObject: ["error": reason]))
                }
                return (200, try self.snapshot())
            }
            do {
                _ = try await api().deleteMessage(messageID: id(7), sessionID: sessionID)
                XCTFail("A refusal must not look like a deleted message")
            } catch CantripRemoteError.http(let code, let message) {
                XCTAssertEqual(code, status)
                XCTAssertEqual(message, reason)
            }
        }
    }

    // MARK: Model

    func testDeletingAnOlderExchangeDropsItFromTheLoadedOlderPage() async throws {
        let model = try await selectedModel()
        StartFreshRequestProtocol.handler = { request in
            if request.httpMethod == "POST" {
                XCTAssertTrue(model.isMutating, "Delete disables actions while the request is in flight")
                XCTAssertEqual(try self.body(request) as? [String: String], ["messageID": self.id(1)])
                // The recent page doesn't reach the deleted exchange; only the cached older page holds it.
                return (200, try self.snapshot(revision: "r2", deleted: [1, 2]))
            }
            return (200, try self.snapshot(list: self.isList(request)))
        }
        let deleted = await model.deleteMessage(id(1), sessionID: sessionID)
        XCTAssertTrue(deleted, model.errorMessage ?? "Expected the message to be deleted")
        XCTAssertEqual(model.selectedSession?.transcript.map(\.id), [3, 4, 5, 6, 7, 8].map(id),
                       "The prompt and its reply leave the older page right away")
        XCTAssertEqual(model.selectedSession?.hasOlderMessages, false, "The older page stays loaded")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isMutating)

        let vm = try StartFreshFixture.chat(model, for: self)
        XCTAssertEqual(vm.turns.map(\.text), [3, 4, 5, 6, 7, 8].map { "Fixture message \($0)" })
    }

    func testAMessageDeletedOnAnotherDeviceLeavesEveryCachedPage() async throws {
        let model = try await selectedModel()
        // Another device deleted 3–4, which only the older page held here; the poll sees a new revision.
        StartFreshRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertFalse(self.isOlderPage(request), "Polling never refetches the older page")
            return (200, try self.snapshot(revision: "r3", deleted: [4, 3], list: self.isList(request)))
        }
        try await poll(model, until: { model.selectedSession?.historyRevision == "r3" }, "The poll sees r3")
        XCTAssertEqual(model.selectedSession?.transcript.map(\.id), [1, 2, 5, 6, 7, 8].map(id))

        // Then 7–8, in the recent page: the next page starts later and still merges with the older one.
        StartFreshRequestProtocol.handler = { request in
            (200, try self.snapshot(values: [5, 6], revision: "r4", deleted: [8, 7, 4, 3],
                                    list: self.isList(request)))
        }
        try await poll(model, until: { model.selectedSession?.historyRevision == "r4" }, "The poll sees r4")
        XCTAssertEqual(model.selectedSession?.transcript.map(\.id), [1, 2, 5, 6].map(id))
        let vm = try StartFreshFixture.chat(model, for: self)
        XCTAssertEqual(vm.turns.count, 4, "The chat drops the deleted rows too")
    }

    func testARefusedDeleteKeepsTheTranscriptAndShowsTheReason() async throws {
        let model = try await selectedModel(loadsOlder: false)
        StartFreshRequestProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return (409, try JSONSerialization.data(withJSONObject: ["error": self.busy]))
            }
            return (200, try self.snapshot(list: self.isList(request)))
        }
        let deleted = await model.deleteMessage(id(7), sessionID: sessionID)
        XCTAssertFalse(deleted)
        XCTAssertEqual(model.selectedSession?.transcript.map(\.id), [5, 6, 7, 8].map(id))
        XCTAssertTrue(model.errorMessage?.contains(busy) == true, model.errorMessage ?? "No error shown")
        XCTAssertFalse(model.isMutating)
    }

    // MARK: Rows

    func testOnlyPromptsAndErrorsHaveTheMenuAndOfferDeleteWhileTheTabIsIdle() async throws {
        let messages: [[String: Any]] = [
            message(1, "user", "Fixture prompt"),
            message(2, "assistant", "Fixture reply"),
            message(3, "freshStart", CantripStartFresh.defaultCaption),
            message(4, "user", "Fixture prompt"),
            message(5, "error", "Fixture failure"),
            message(6, "handoff", "Fixture handoff result").merging(
                ["handoffResult": ["tabID": sessionID, "tabTitle": "Fixture Tab", "state": "completed",
                                   "summary": "Done"]]) { $1 },
            message(7, "assistant", "Fixture child card").merging(
                ["childResult": ["id": "00000000-0000-0000-0000-0000000000d2", "title": "Fixture Child",
                                 "state": "running", "summary": "", "actions": []]]) { $1 },
        ]
        let model = try StartFreshFixture.model(for: self)
        var supported: Bool? = true
        var streaming = false
        var revision = "r1"
        StartFreshRequestProtocol.handler = { request in
            (200, try self.snapshot(revision: revision, supported: supported, streaming: streaming,
                                    messages: messages, list: self.isList(request)))
        }
        await model.selectSession(sessionID)
        let session = try XCTUnwrap(model.selectedSession)
        XCTAssertEqual(session.transcript.map(CantripDeleteMessage.hasMenu),
                       [true, false, false, true, true, false, false])
        XCTAssertEqual(session.transcript.map { CantripDeleteMessage.offers($0, in: session) },
                       [true, false, false, true, true, false, false])

        // The rows on screen, as TurnView maps them.
        let vm = try StartFreshFixture.chat(model, for: self)
        func rows() -> [TurnView] {
            vm.turns.map { turn in
                TurnView(turn: turn, remote: model, cantripSessionID: model.selectedSessionID,
                         remoteMessage: vm.remoteMessage(for: turn.id))
            }
        }
        func targets() -> [String?] { rows().map { $0.deleteMessageTarget?.messageID } }
        XCTAssertEqual(rows().map { $0.messageMenu().attached }, [true, false, false, true, true, false, false],
                       "Replies get no menu, so their text keeps native selection")
        XCTAssertEqual(targets().compactMap { $0 }, [id(1), id(4), id(5)])
        let local = TurnView(turn: ChatTurn(role: .user, text: "Not sent"), remote: model,
                             cantripSessionID: model.selectedSessionID)
        XCTAssertFalse(local.messageMenu().attached, "A local row without a Mac message gets no menu")
        XCTAssertNil(local.deleteMessageTarget)

        streaming = true
        revision = "r2"
        try await poll(model, until: { model.selectedSession?.isStreaming == true }, "The tab works")
        vm.syncRemoteTranscript()
        XCTAssertEqual(targets().compactMap { $0 }, [], "Hidden while the tab works")
        XCTAssertEqual(rows().map { $0.messageMenu().attached }, [true, false, false, true, true, false, false],
                       "Rows keep the same views while the tab works; the menu is just empty")

        streaming = false
        supported = nil
        revision = "r3"
        try await poll(model, until: { model.selectedSession?.historyRevision == "r3" }, "The older Mac's tab loads")
        vm.syncRemoteTranscript()
        XCTAssertNil(model.selectedSession?.supportsDeleteMessage)
        XCTAssertEqual(targets().compactMap { $0 }, [], "Hidden on Macs without supportsDeleteMessage")
    }

    /// The prompt and error menu's Copy reads like the row.
    func testCopyReadsLikeTheRow() throws {
        let tab = "00000000-0000-0000-0000-0000000000d3"
        let messages = try JSONDecoder().decode(SessionResponse.self, from: snapshot(messages: [
            message(1, "user", "Ask @[Fixture Garden](cantrip-tab:\(tab)) about **seeds**"),
            message(2, "error", "Fixture **failure**"),
        ])).session.transcript
        XCTAssertEqual(messages.map(CantripDeleteMessage.copyText), [
            "Ask @Fixture Garden about **seeds**",
            "Fixture **failure**",
        ])
    }

    func testDropDeletedLeavesOtherMessagesInOrder() throws {
        var session = try JSONDecoder().decode(
            SessionResponse.self, from: snapshot(values: [1, 2, 3, 4], deleted: [2, 3, 99])
        ).session
        CantripDeleteMessage.dropDeleted(from: &session)
        XCTAssertEqual(session.transcript.map(\.id), [id(1), id(4)])

        var untouched = try JSONDecoder().decode(SessionResponse.self, from: snapshot(values: [1, 2])).session
        CantripDeleteMessage.dropDeleted(from: &untouched)
        XCTAssertEqual(untouched.transcript.map(\.id), [id(1), id(2)])
    }
}
