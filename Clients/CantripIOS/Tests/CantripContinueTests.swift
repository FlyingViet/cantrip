import Foundation
import XCTest
@testable import Hermes

/// Continue on a failed run's error row: decoding, the checked single POST, and which rows offer it.
@MainActor
final class CantripContinueTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-0000000000c1"

    private func message(_ id: String, _ role: String, _ text: String = "") -> [String: Any] {
        ["id": id, "role": role, "text": text, "thinking": "", "activities": []]
    }

    private func snapshot(
        supported: Bool = true, continuable: [String]? = ["error-2"], canResume: Bool = true,
        streaming: Bool = false, messages: [[String: Any]]? = nil, list: Bool = false
    ) throws -> Data {
        var session: [String: Any] = [
            "id": sessionID, "title": "Plexa", "workdir": "/Users/me/Coding/Plexa",
            "isStreaming": streaming, "canResume": canResume, "councilMode": false, "queuedCount": 1,
            "messages": messages ?? [
                message("prompt-1", "user", "Fix the scrubber"),
                message("error-1", "error", "TypeError: fetch failed"),
                message("prompt-2", "user", "Ship the build"),
                message("error-2", "error", "No response for 10 minutes — request cancelled."),
            ],
        ]
        if supported {
            session["supportsContinueFromMessage"] = true
            session["continuableMessageIDs"] = continuable ?? []
        }
        return try JSONSerialization.data(withJSONObject: list ? ["sessions": [session]] : ["session": session])
    }

    private func isList(_ request: URLRequest) -> Bool {
        request.httpMethod == "GET" && request.url?.path == "/api/v1/sessions"
    }

    private func api() throws -> CantripRemoteAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StartFreshRequestProtocol.self]
        addTeardownBlock { @MainActor in StartFreshRequestProtocol.handler = nil }
        return CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "start-fresh-test-token",
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

    private func selectedModel(continuable: [String]? = ["error-2"], canResume: Bool = true,
                               supported: Bool = true) async throws -> CantripRemoteModel {
        let model = try StartFreshFixture.model(for: self)
        StartFreshRequestProtocol.handler = { request in
            (200, try self.snapshot(supported: supported, continuable: continuable, canResume: canResume,
                                    list: self.isList(request)))
        }
        await model.selectSession(sessionID)
        XCTAssertEqual(model.selectedSession?.id, sessionID, model.errorMessage ?? "Tab not selected")
        return model
    }

    // MARK: Decoding

    private struct SessionResponse: Decodable { let session: CantripRemoteSession }

    func testSnapshotDecodesContinueFieldsAndOlderMacsLeaveThemNil() throws {
        let current = try JSONDecoder().decode(SessionResponse.self, from: snapshot()).session
        XCTAssertEqual(current.supportsContinueFromMessage, true)
        XCTAssertEqual(current.continuableMessageIDs, ["error-2"])
        XCTAssertFalse(CantripContinue.showsTabResume(current), "The row offers Continue, so no tab-wide Resume")

        let older = try JSONDecoder().decode(SessionResponse.self, from: snapshot(supported: false)).session
        XCTAssertNil(older.supportsContinueFromMessage)
        XCTAssertNil(older.continuableMessageIDs)
        XCTAssertTrue(CantripContinue.showsTabResume(older), "Older Macs keep the tab's Resume")
    }

    // MARK: API

    func testContinueChecksTheRowThenPostsItsMessageIDOnce() async throws {
        var methods: [String] = []
        StartFreshRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)/resume")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertEqual(try self.body(request) as? [String: String], ["messageID": "error-2"])
                return (202, try self.snapshot(continuable: [], streaming: true))
            }
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)")
            return (200, try self.snapshot())
        }
        let session = try await api().continueFailedRun(messageID: "error-2", sessionID: sessionID)
        XCTAssertEqual(methods, ["GET", "POST"], "One check of the row, then a single write")
        XCTAssertTrue(session.isStreaming)
        XCTAssertEqual(session.continuableMessageIDs, [])
    }

    func testStaleRowsAndOlderMacsAreRefusedWithoutAWrite() async throws {
        let cases: [(supported: Bool, streaming: Bool, row: String, reason: String)] = [
            (true, false, "error-1", CantripContinue.gone),
            (true, true, "error-2", CantripContinue.busy),
            (false, false, "error-2", CantripContinue.unsupported),
        ]
        for item in cases {
            var methods: [String] = []
            StartFreshRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                return (200, try self.snapshot(supported: item.supported,
                                               continuable: item.streaming ? [] : ["error-2"],
                                               streaming: item.streaming))
            }
            do {
                _ = try await api().continueFailedRun(messageID: item.row, sessionID: sessionID)
                XCTFail("A row that no longer offers Continue must not receive the write")
            } catch CantripRemoteError.http(let status, let message) {
                XCTAssertEqual(status, 409)
                XCTAssertEqual(message, item.reason)
            }
            XCTAssertEqual(methods, ["GET"])
        }
    }

    func testTheMacsRefusalSurfacesItsReason() async throws {
        let offline = "The Mac is offline. Tap Continue once the network is back."
        StartFreshRequestProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return (409, try JSONSerialization.data(withJSONObject: ["error": offline]))
            }
            return (200, try self.snapshot())
        }
        do {
            _ = try await api().continueFailedRun(messageID: "error-2", sessionID: sessionID)
            XCTFail("A refusal must not look like a continued run")
        } catch CantripRemoteError.http(let status, let message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, offline)
        }
    }

    // MARK: Model

    func testModelAppliesTheReturnedSession() async throws {
        let model = try await selectedModel()
        StartFreshRequestProtocol.handler = { request in
            if request.httpMethod == "POST" {
                XCTAssertTrue(model.isMutating, "Continue disables while the request is in flight")
                return (202, try self.snapshot(continuable: [], canResume: false, streaming: true))
            }
            return (200, try self.snapshot(list: self.isList(request)))
        }
        let continued = await model.continueFailedRun(messageID: "error-2", sessionID: sessionID)
        XCTAssertTrue(continued, model.errorMessage ?? "Expected the run to continue")
        XCTAssertEqual(model.selectedSession?.isStreaming, true)
        XCTAssertEqual(model.selectedSession?.continuableMessageIDs, [])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isMutating)
    }

    // MARK: Transcript mapping

    func testOnlyListedErrorRowsOfferContinue() async throws {
        let model = try await selectedModel(continuable: ["error-1", "prompt-2"])
        let vm = try StartFreshFixture.chat(model, for: self)
        XCTAssertEqual(vm.turns.map { $0.isContinuable == true }, [false, true, false, false],
                       "Only error rows the Mac lists offer Continue")

        let none = try await selectedModel(continuable: [], canResume: false)
        XCTAssertFalse(try StartFreshFixture.chat(none, for: self).turns.contains { $0.isContinuable == true })

        let older = try await selectedModel(supported: false)
        XCTAssertFalse(try StartFreshFixture.chat(older, for: self).turns.contains { $0.isContinuable == true })
        XCTAssertTrue(older.selectedSession.map(CantripContinue.showsTabResume) == true)
    }
}
