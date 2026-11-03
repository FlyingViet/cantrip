import Foundation
import XCTest
@testable import Hermes

private final class BackendsRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) throws -> (Int, Data))?
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { responseTask?.cancel() }
    override func startLoading() {
        responseTask = Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                    statusCode: status, httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
}

@MainActor
final class CantripBackendsTests: XCTestCase {
    /// The host's payload, as Cantrip encodes it (invented accounts).
    static let payload = """
    {"checkInterval": 1800, "revision": 7, "backends": [
      {"id": "copilot", "name": "Copilot CLI", "state": "ready", "summary": "Signed in",
       "path": "/opt/homebrew/bin/copilot", "version": "1.0.105", "signedIn": true, "account": "octocat",
       "authMethod": "GitHub account", "plan": "Pro",
       "quota": [{"name": "Premium allowance", "usedPercent": 12.4, "resetsAt": "2026-12-01T00:00:00Z"}],
       "lastSuccessAt": "2026-11-01T20:00:00Z", "checkedAt": "2026-11-01T20:15:00Z", "checking": false, "unavailable": false,
       "signIn": {"mode": "deviceCode", "command": "copilot login --device-code",
                  "hint": "Sign in shows a link and a code here. Open the link on any device and enter the code."}},
      {"id": "claude", "name": "Claude Code", "state": "signedOut",
       "summary": "Skipped by routing: your backups run until you sign in.",
       "path": "/usr/local/bin/claude", "version": "2.1.312", "signedIn": false, "quota": [],
       "lastAuthError": {"message": "Failed to authenticate. OAuth session expired.", "at": "2026-11-01T19:58:00Z"},
       "checkedAt": "2026-11-01T20:15:00Z", "checking": false, "unavailable": true, "problem": "Claude Code isn't signed in.",
       "signIn": {"mode": "terminal", "command": "claude auth login",
                  "hint": "Claude Code signs in through a page that returns to the Mac, so Sign in opens Terminal on the Mac to finish there."}},
      {"id": "antigravity", "name": "Antigravity", "state": "notInstalled", "summary": "Not installed on the Mac",
       "quota": [], "checking": false, "unavailable": false,
       "signIn": {"mode": "terminal", "command": "agy", "hint": "Antigravity signs in only in its own interactive mode."}},
      {"id": "codex", "name": "Codex", "state": "unknown", "summary": "Codex didn't answer within 45 s.",
       "path": "/usr/local/bin/codex", "quota": [{"name": "Weekly limit", "usedPercent": 100, "resetsAt": "2026-11-03T08:00:00.250Z"}],
       "checking": true, "unavailable": false, "problem": "Codex didn't answer within 45 s.",
       "signIn": {"mode": "deviceCode", "command": "codex login --device-auth", "hint": "Sign in shows a link and a code here.",
                  "url": "https://auth.example.com/device", "code": "WXYZ-98765", "startedAt": "2026-11-01T20:16:00Z",
                  "message": "Open the link on any device and enter the code."}}
    ]}
    """

    private func decode() throws -> CantripBackendsSnapshot {
        try JSONDecoder().decode(CantripBackendsSnapshot.self, from: Data(Self.payload.utf8))
    }

    private func api() throws -> CantripRemoteAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackendsRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            BackendsRequestProtocol.handler = nil
        }
        return CantripRemoteAPI(transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
                                token: "backends-test-token", urlSession: client)
    }

    func testDecodesTheHostPayload() throws {
        let snapshot = try decode()
        XCTAssertEqual(snapshot.backends.map(\.id), ["copilot", "claude", "antigravity", "codex"])
        XCTAssertEqual(snapshot.checkInterval, 1800)
        let claude = snapshot.backends[1]
        XCTAssertEqual(claude.state, "signedOut")
        XCTAssertEqual(claude.unavailable, true)
        XCTAssertEqual(claude.lastAuthError?.message, "Failed to authenticate. OAuth session expired.")
        XCTAssertEqual(snapshot.backends[3].signIn.code, "WXYZ-98765")
        XCTAssertTrue(snapshot.backends[3].isSigningIn)
        let bare = try JSONDecoder().decode(CantripBackendsSnapshot.self, from: Data("""
        {"backends": [{"id": "codex", "name": "Codex", "state": "unknown", "summary": "Not checked yet",
                       "signIn": {"mode": "deviceCode", "command": "codex login --device-auth", "hint": ""}}]}
        """.utf8))
        XCTAssertNil(bare.backends[0].quota)
        XCTAssertFalse(bare.backends[0].isChecking)
    }

    func testRowText() throws {
        let snapshot = try decode()
        let (copilot, claude, agy, codex) = (snapshot.backends[0], snapshot.backends[1], snapshot.backends[2], snapshot.backends[3])
        XCTAssertEqual(CantripBackendText.stateLabel(copilot), "Ready")
        XCTAssertEqual(CantripBackendText.stateLabel(claude), "Signed out")
        XCTAssertEqual(CantripBackendText.stateLabel(agy), "Not installed")
        XCTAssertEqual(CantripBackendText.stateLabel(codex), "Checking…")
        XCTAssertEqual(CantripBackendText.brief(copilot), "octocat · Pro · Premium allowance 12% used")
        XCTAssertEqual(CantripBackendText.brief(claude), claude.summary)
        XCTAssertFalse(CantripBackendText.offersSignIn(copilot))
        XCTAssertTrue(CantripBackendText.offersSignIn(claude))
        XCTAssertFalse(CantripBackendText.offersSignIn(agy), "nothing to sign in to before it's installed")
        XCTAssertTrue(CantripBackendText.offersSignIn(codex), "a check that couldn't tell still offers a sign-in")
        XCTAssertEqual(CantripBackendText.signInNote(claude), claude.signIn.hint, "Terminal-only sign-ins say so")
        XCTAssertNil(CantripBackendText.signInNote(copilot))

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T20:20:00Z"))
        let lines = CantripBackendText.lines(claude, now: now)
        XCTAssertEqual(lines.first?.text, claude.summary)
        XCTAssertTrue(lines.contains { $0.text == "Installed: /usr/local/bin/claude · 2.1.312" })
        XCTAssertTrue(lines.contains { $0.warning && $0.text.hasPrefix("Last sign-in error: Failed to authenticate. OAuth session expired.") })
        XCTAssertTrue(lines.last?.text.hasPrefix("Checked ") == true)
        let codexLines = CantripBackendText.lines(codex, now: now).map(\.text)
        XCTAssertTrue(codexLines.contains { $0.hasPrefix("Weekly limit: 100% used · resets ") }, "\(codexLines)")
        XCTAssertEqual(codexLines.last, "Checking now…")
        XCTAssertTrue(CantripBackendText.lines(agy, now: now).map(\.text).contains("Install Antigravity on the Mac to use it."))
    }

    func testAPIReadsAndReportsOlderMacs() async throws {
        var seen: [(String, String, [String: Any]?)] = []
        BackendsRequestProtocol.handler = { request in
            var body: [String: Any]?
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                stream.close()
                body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } else if let data = request.httpBody {
                body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            seen.append((request.httpMethod ?? "", request.url?.path ?? "", body))
            return (200, Data(Self.payload.utf8))
        }
        let api = try api()
        let snapshot = try await api.backends()
        XCTAssertEqual(snapshot.backends.count, 4)
        XCTAssertEqual(seen.last?.0, "GET")
        XCTAssertEqual(seen.last?.1, "/api/v1/backends")

        BackendsRequestProtocol.handler = { _ in (404, Data(#"{"error":"not found"}"#.utf8)) }
        do {
            _ = try await api.backends()
            XCTFail("an older Mac has no backends endpoint")
        } catch {
            XCTAssertEqual(error.localizedDescription, CantripBackendText.unsupported)
        }
    }
}

/// Settings' "GitHub on your Mac" row reads the Mac's gh sign-in from GET /api/v1/backends.
final class CantripGitHubAuthTests: XCTestCase {
    private func snapshot(github: Any?) throws -> CantripBackendsSnapshot {
        var json: [String: Any] = ["backends": [Any](), "checkInterval": 1800]
        if let github { json["github"] = github }
        return try JSONDecoder().decode(CantripBackendsSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testDecodesTheMacsSignInAndOlderMacsLeaveItOut() throws {
        let github = try XCTUnwrap(snapshot(github: [
            "state": "signedIn", "host": "github.com", "login": "octo-qa", "scopes": ["repo", "workflow"],
            "accounts": [["login": "octo-qa", "active": true, "valid": true, "scopes": ["repo", "workflow"]],
                         ["login": "work-qa", "active": false, "valid": true, "scopes": ["repo"]]],
            "checkedAt": "2026-11-02T23:50:00Z", "checking": false,
        ]).github)
        XCTAssertEqual(github.login, "octo-qa")
        XCTAssertEqual(github.accounts?.count, 2)
        XCTAssertNil(try snapshot(github: nil).github, "a Mac from before it reports nothing")
    }

    func testSignedInShowsWhoWithAQuieterSignInAgain() {
        let shown = CantripGitHubPresentation.make(.init(state: "signedIn", login: "octo-qa"), loaded: true)
        XCTAssertEqual(shown.detail, "Signed in as octo-qa")
        XCTAssertEqual(shown.button, "Sign In Again…")
        XCTAssertFalse(shown.prominent)
        XCTAssertFalse(shown.warning)
        let two = CantripGitHubPresentation.make(.init(state: "signedIn", login: "octo-qa", accounts: [
            .init(login: "octo-qa", active: true), .init(login: "work-qa", active: false),
        ]), loaded: true)
        XCTAssertEqual(two.detail, "Signed in as octo-qa (1 more account)")
    }

    func testSignedOutAndExpiredOfferSignIn() {
        let out = CantripGitHubPresentation.make(.init(state: "signedOut"), loaded: true)
        XCTAssertEqual(out.button, "Sign In…")
        XCTAssertTrue(out.prominent && out.warning)
        XCTAssertTrue(out.detail.hasPrefix("Not signed in"))
        let expired = CantripGitHubPresentation.make(.init(state: "needsSignIn", login: "octo-qa"), loaded: true)
        XCTAssertEqual(expired.button, "Sign In…")
        XCTAssertTrue(expired.detail.contains("octo-qa's GitHub sign-in"))
        let missing = CantripGitHubPresentation.make(.init(state: "notInstalled"), loaded: true)
        XCTAssertFalse(missing.buttonEnabled, "no gh, no sign-in")
    }

    func testOlderMacsAndUnknownAnswersNeverSaySignedOut() {
        for shown in [CantripGitHubPresentation.make(nil, loaded: true),
                      CantripGitHubPresentation.make(.init(state: "unknown"), loaded: true),
                      CantripGitHubPresentation.make(.init(state: "somethingNew"), loaded: true),
                      CantripGitHubPresentation.make(nil, loaded: false)] {
            XCTAssertFalse(shown.warning, shown.detail)
            XCTAssertFalse(shown.prominent, shown.detail)
            XCTAssertFalse(shown.detail.localizedCaseInsensitiveContains("not signed in"), shown.detail)
        }
        XCTAssertTrue(CantripGitHubPresentation.make(nil, loaded: true).detail.contains("Update Cantrip on your Mac"))
    }

    func testASignInStartedHereWaitsForTheMacsNextCheck() {
        let started = ISO8601DateFormatter().date(from: "2026-11-02T23:50:00Z")!
        XCTAssertFalse(SettingsGitHubSection.isWaiting(startedAt: nil, checkedAt: "2026-11-02T23:00:00Z"))
        XCTAssertTrue(SettingsGitHubSection.isWaiting(startedAt: started, checkedAt: "2026-11-02T23:49:00Z"))
        XCTAssertTrue(SettingsGitHubSection.isWaiting(startedAt: started, checkedAt: nil))
        XCTAssertFalse(SettingsGitHubSection.isWaiting(startedAt: started, checkedAt: "2026-11-02T23:51:30Z"))
    }
}
