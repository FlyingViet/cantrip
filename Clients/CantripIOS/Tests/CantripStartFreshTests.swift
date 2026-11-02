import Foundation
import SwiftUI
import XCTest
@testable import Hermes

final class StartFreshRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try await handler(request)
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
}

/// A model and environment paired with a fake Mac through in-memory saved servers and a
/// throwaway defaults suite, so tests never touch the Keychain or the app's saved servers.
@MainActor
enum StartFreshFixture {
    static func model(for test: XCTestCase) throws -> CantripRemoteModel {
        let (servers, defaults, suite) = try profiles(.cantrip)
        try servers.select(try servers.add(ServerDraft(
            name: "Test Mac", url: "https://cantrip.example", credential: "start-fresh-test-token",
            tailscaleOnly: true
        )))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StartFreshRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: configuration), servers: servers)
        test.addTeardownBlock { @MainActor in
            model.setAppActive(false)
            StartFreshRequestProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
        XCTAssertTrue(model.isConfigured, model.errorMessage ?? "The fixture Mac is not paired")
        return model
    }

    /// The chat as an open tab shows it, mapped from the model's selected session.
    static func chat(_ model: CantripRemoteModel, for test: XCTestCase) throws -> ChatViewModel {
        let (servers, defaults, suite) = try profiles(.hermes)
        test.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let env = HermesEnv(servers: servers, defaults: defaults)
        env.select(.cantrip)
        let vm = ChatViewModel(env: env, remote: model, voice: VoiceController())
        vm.syncRemoteTranscript()
        return vm
    }

    private static func profiles(_ kind: ServerKind) throws -> (ServerProfiles, UserDefaults, String) {
        var credentials: [String: String] = [:]
        let store = ServerCredentialStore(
            read: { credentials[$0] }, write: { credentials[$0] = $1 }, remove: { credentials.removeValue(forKey: $0) }
        )
        let suite = "start-fresh-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (ServerProfiles(kind: kind, defaults: defaults, credentials: store), defaults, suite)
    }
}

/// Start Fresh: decoding, the single unreplayed POST, and how the divider and repeated errors map.
@MainActor
final class CantripStartFreshTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-0000000000f1"
    private let busy = "Wait for this tab to finish its current work, then start fresh."

    private func message(_ id: String, _ role: String, _ text: String = "") -> [String: Any] {
        ["id": id, "role": role, "text": text, "thinking": "", "activities": []]
    }

    private func snapshot(
        support: Bool? = true, streaming: Bool = false, queued: Int = 0, home: Bool = false,
        repeatedError: String? = nil, messages: [[String: Any]]? = nil, list: Bool = false
    ) throws -> Data {
        var session: [String: Any] = [
            "id": sessionID, "title": "Plexa", "workdir": "/Users/me/Coding/Plexa",
            "isStreaming": streaming, "canResume": false, "councilMode": false,
            "queuedCount": queued, "supportsModelSettings": true, "supportsTabMetadata": true,
            "isLocked": true, "customTitle": "Plexa",
            "messages": messages ?? [
                message("prompt-1", "user", "What's the admin password?"),
                message("error-1", "error", "Execution failed: 400 The requested model is not supported"),
                message("prompt-2", "user", "Ship the build"),
                message("error-2", "error", "Execution failed: 400 The requested model is not supported"),
            ],
        ]
        if let support { session["supportsStartFresh"] = support }
        if home { session["isCantripHome"] = true }
        if let repeatedError { session["repeatedErrorMessageID"] = repeatedError }
        return try JSONSerialization.data(withJSONObject: list ? ["sessions": [session]] : ["session": session])
    }

    private var freshMessages: [[String: Any]] {
        [
            message("prompt-1", "user", "What's the admin password?"),
            message("error-1", "error", "Execution failed: 400 The requested model is not supported"),
            message("prompt-2", "user", "Ship the build"),
            message("error-2", "error", "Execution failed: 400 The requested model is not supported"),
            message("fresh-1", "freshStart", CantripStartFresh.defaultCaption),
        ]
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


    private func selectedModel(support: Bool? = true, repeatedError: String? = "error-2",
                               messages: [[String: Any]]? = nil,
                               streaming: Bool = false) async throws -> CantripRemoteModel {
        let model = try StartFreshFixture.model(for: self)
        StartFreshRequestProtocol.handler = { request in
            (200, try self.snapshot(support: support, streaming: streaming, repeatedError: repeatedError,
                                    messages: messages, list: self.isList(request)))
        }
        await model.selectSession(sessionID)
        XCTAssertEqual(model.selectedSession?.id, sessionID, model.errorMessage ?? "Tab not selected")
        return model
    }

    // MARK: Decoding

    private struct SessionResponse: Decodable { let session: CantripRemoteSession }

    func testSnapshotDecodesStartFreshFieldsAndOlderMacsLeaveThemNil() throws {
        let decoder = JSONDecoder()
        let current = try decoder.decode(SessionResponse.self, from: try snapshot(repeatedError: "error-2"))
        XCTAssertEqual(current.session.supportsStartFresh, true)
        XCTAssertEqual(current.session.repeatedErrorMessageID, "error-2")

        let home = try decoder.decode(SessionResponse.self, from: try snapshot(support: false, home: true))
        XCTAssertEqual(home.session.supportsStartFresh, false)
        XCTAssertNil(home.session.repeatedErrorMessageID, "Only a repeating error is marked")

        let legacy = try decoder.decode(SessionResponse.self, from: try snapshot(support: nil))
        XCTAssertNil(legacy.session.supportsStartFresh, "Older Macs never claim Start Fresh")
        XCTAssertNil(legacy.session.repeatedErrorMessageID)
        XCTAssertEqual(legacy.session.transcript.count, 4)
    }

    func testFreshStartMessageDecodesAsANoticeNotAReply() throws {
        let data = try JSONSerialization.data(withJSONObject: message("fresh-1", "freshStart", CantripStartFresh.defaultCaption))
        let divider = try JSONDecoder().decode(CantripRemoteMessage.self, from: data)
        XCTAssertEqual(divider.role, "freshStart")
        XCTAssertTrue(divider.isFreshStart)
        XCTAssertFalse(divider.isHandoffResult)
        XCTAssertEqual(divider.presentedText, CantripStartFresh.defaultCaption)
        XCTAssertTrue(divider.activities.isEmpty)
        XCTAssertFalse(try JSONDecoder().decode(
            CantripRemoteMessage.self, from: JSONSerialization.data(withJSONObject: message("r", "assistant", "Hi"))
        ).isFreshStart)
    }

    // MARK: API

    func testStartFreshChecksSupportThenPostsOnceWithoutABody() async throws {
        var methods: [String] = []
        StartFreshRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)/start-fresh")
                XCTAssertNil(request.httpBody, "Start Fresh takes no request body")
                XCTAssertNil(request.httpBodyStream)
                XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
                let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertTrue(items.contains(URLQueryItem(name: "recentExchanges", value: "3")),
                              "The reply uses the same paged session shape as other tab actions")
                return (200, try self.snapshot(messages: self.freshMessages))
            }
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(self.sessionID)")
            return (200, try self.snapshot(repeatedError: "error-2"))
        }
        let session = try await api().startFresh(sessionID: sessionID)
        XCTAssertEqual(methods, ["GET", "POST"], "One capability read, then a single write")
        XCTAssertEqual(session.transcript.last?.isFreshStart, true)
        XCTAssertEqual(session.transcript.count, 5, "Earlier messages stay visible")
        XCTAssertEqual(session.title, "Plexa")
        XCTAssertEqual(session.isLocked, true)
        XCTAssertNil(session.repeatedErrorMessageID)
    }

    func testOlderMacsAndCantripHomeAreRefusedWithoutAWrite() async throws {
        for support: Bool? in [nil, false] {
            var methods: [String] = []
            StartFreshRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                return (200, try self.snapshot(support: support, home: support == false))
            }
            do {
                _ = try await api().startFresh(sessionID: sessionID)
                XCTFail("A host without Start Fresh must not receive the write")
            } catch CantripRemoteError.startFreshUnsupported {
                XCTAssertNil(support)
            } catch CantripRemoteError.http(let status, _) {
                XCTAssertEqual(support, false)
                XCTAssertEqual(status, 409)
            }
            XCTAssertEqual(methods, ["GET"])
        }
        XCTAssertTrue(CantripRemoteError.startFreshUnsupported.localizedDescription.contains("Update and reopen Cantrip"))
    }

    func testBusyTabConflictSurfacesTheMacsReason() async throws {
        var methods: [String] = []
        StartFreshRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                return (409, try JSONSerialization.data(withJSONObject: ["error": self.busy]))
            }
            return (200, try self.snapshot())
        }
        do {
            _ = try await api().startFresh(sessionID: sessionID)
            XCTFail("A conflict must not look like a fresh start")
        } catch CantripRemoteError.http(let status, let message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, busy)
        }
        XCTAssertEqual(methods, ["GET", "POST"])
    }

    func testLostResponseIsNotReplayed() async throws {
        var methods: [String] = []
        StartFreshRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, try self.snapshot())
        }
        do {
            _ = try await api().startFresh(sessionID: sessionID)
            XCTFail("An unconfirmed fresh start must not look successful")
        } catch CantripRemoteError.transport {}
        XCTAssertEqual(methods, ["GET", "POST"])
    }

    // MARK: Model

    func testModelAppliesTheReturnedSessionAndKeepsTheTab() async throws {
        let model = try await selectedModel()
        var methods: [String] = []
        StartFreshRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                XCTAssertTrue(model.isMutating, "Tab actions disable while the request is in flight")
                return (200, try self.snapshot(messages: self.freshMessages))
            }
            return (200, try self.snapshot(repeatedError: "error-2", list: self.isList(request)))
        }
        let started = await model.startFresh(sessionID: sessionID)
        XCTAssertTrue(started, model.errorMessage ?? "Expected a fresh start")
        XCTAssertEqual(methods, ["GET", "POST"])
        XCTAssertEqual(model.selectedSession?.transcript.last?.isFreshStart, true)
        XCTAssertEqual(model.selectedSession?.transcript.count, 5)
        XCTAssertNil(model.selectedSession?.repeatedErrorMessageID)
        XCTAssertEqual(model.selectedSessionID, sessionID)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isMutating)
    }

    func testModelExplainsConflictsAndOlderMacsWithoutChangingTheTranscript() async throws {
        for legacy in [false, true] {
            let model = try await selectedModel(support: legacy ? nil : true)
            var methods: [String] = []
            StartFreshRequestProtocol.handler = { request in
                methods.append(request.httpMethod ?? "")
                if request.httpMethod == "POST" {
                    return (409, try JSONSerialization.data(withJSONObject: ["error": self.busy]))
                }
                return (200, try self.snapshot(support: legacy ? nil : true, repeatedError: "error-2",
                                               list: self.isList(request)))
            }
            let started = await model.startFresh(sessionID: sessionID)
            XCTAssertFalse(started)
            XCTAssertEqual(methods, legacy ? ["GET"] : ["GET", "POST"], "Older Macs never receive the write")
            let message = try XCTUnwrap(model.errorMessage)
            XCTAssertTrue(message.contains(legacy ? "Update and reopen Cantrip" : busy), message)
            XCTAssertFalse(message.contains("may have reached"), message)
            XCTAssertEqual(model.selectedSession?.transcript.count, 4)
            XCTAssertFalse(model.isMutating)
        }
    }

    // MARK: Menu state

    func testTabActionsOfferStartFreshOnlyWhereTheMacDoes() throws {
        let model = try StartFreshFixture.model(for: self)
        func tab(_ support: Bool?, home: Bool = false, streaming: Bool = false, queued: Int = 0) -> CantripRemoteSession {
            var session = CantripRemoteSession(
                id: sessionID, title: "Plexa", workdir: "/tmp", isStreaming: streaming, canResume: false,
                councilMode: false, queuedCount: queued, status: nil, messages: nil,
                supportsImageAttachments: true, queued: nil
            )
            session.supportsStartFresh = support
            session.isCantripHome = home
            return session
        }
        XCTAssertEqual(CantripTabActionState(session: tab(true), model: model).supportsStartFresh, true)
        XCTAssertNil(CantripTabActionState(session: tab(nil), model: model).supportsStartFresh,
                     "Older Macs show the update notice")
        XCTAssertEqual(CantripTabActionState(session: tab(nil, home: true), model: model).supportsStartFresh, false,
                       "Cantrip Home never offers Start Fresh, even from an older Mac")
        XCTAssertNotEqual(CantripTabActionState(session: tab(true), model: model),
                          CantripTabActionState(session: tab(nil), model: model))
        XCTAssertFalse(CantripStartFresh.isBusy(tab(true)))
        XCTAssertTrue(CantripStartFresh.isBusy(tab(true, streaming: true)))
        XCTAssertTrue(CantripStartFresh.isBusy(tab(true, queued: 1)))
        XCTAssertTrue(CantripTabActionState(session: tab(true, queued: 1), model: model).isBusy)
    }

    // MARK: Transcript mapping

    private func viewModel(_ model: CantripRemoteModel) throws -> ChatViewModel {
        try StartFreshFixture.chat(model, for: self)
    }

    func testFreshStartMapsToADividerThatIsNeverTheStreamingReply() async throws {
        let afterError = try await selectedModel(repeatedError: nil, messages: [
            message("prompt-1", "user", "Ship the build"),
            message("error-1", "error", "Execution failed"),
            message("fresh-1", "freshStart"),
        ], streaming: true)
        let vm = try viewModel(afterError)
        XCTAssertEqual(vm.turns.map(\.role), [.user, .assistant, .freshStart])
        XCTAssertFalse(vm.turns.contains(where: \.streaming), "The divider is never the reply being streamed")
        let divider = try XCTUnwrap(vm.turns.last)
        XCTAssertNil(divider.error)
        XCTAssertNil(divider.thinking)
        XCTAssertTrue(divider.tools.isEmpty)
        XCTAssertEqual(CantripFreshStartDivider(text: divider.text).caption, CantripStartFresh.defaultCaption,
                       "An empty caption falls back to the standard text")
        XCTAssertNotEqual(vm.turns.last(where: { $0.role == .assistant })?.id, divider.id,
                          "Voice mode's latest reply skips the divider")

        let afterReply = try await selectedModel(repeatedError: nil, messages: [
            message("prompt-1", "user", "Ship the build"),
            message("reply-1", "assistant", "Shipped."),
            message("fresh-1", "freshStart", CantripStartFresh.defaultCaption),
        ], streaming: true)
        let replyVM = try viewModel(afterReply)
        XCTAssertEqual(replyVM.turns.map(\.streaming), [false, true, false],
                       "The last real reply stays the streaming target")
        XCTAssertEqual(replyVM.turns.last?.text, CantripStartFresh.defaultCaption)
        XCTAssertEqual(CantripMascotActivity.current(status: nil, transcript: afterReply.selectedSession?.transcript ?? []),
                       .thinking, "Pip never reads the divider as reply text being written")
    }

    func testOnlyTheMatchingRepeatedErrorOffersRecovery() async throws {
        let model = try await selectedModel(repeatedError: "error-2")
        let vm = try viewModel(model)
        XCTAssertEqual(vm.turns.map { $0.isRepeatedError == true }, [false, false, false, true])
        XCTAssertNotNil(vm.turns.last?.error)

        let stale = try await selectedModel(repeatedError: "prompt-2")
        XCTAssertFalse(try viewModel(stale).turns.contains { $0.isRepeatedError == true },
                       "Only an error row offers Start Fresh and Change Model")

        let older = try await selectedModel(support: nil, repeatedError: nil)
        XCTAssertFalse(try viewModel(older).turns.contains { $0.isRepeatedError == true })
    }
}
