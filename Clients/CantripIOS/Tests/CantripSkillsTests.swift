import Foundation
import XCTest
@testable import Hermes

private final class SkillsRequestProtocol: URLProtocol {
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
final class CantripSkillsTests: XCTestCase {
    /// The host contract's example (invented skill names).
    static let payload = """
    {
      "library": "~/Library/Application Support/Cantrip/skills",
      "backends": ["Claude Code", "Copilot", "Codex", "Antigravity"],
      "skills": [
        {"name": "weather-lookup", "description": "Looks up the weather.", "enabled": true,
         "backends": ["Claude Code", "Copilot", "Codex", "Antigravity"], "problems": []},
        {"name": "notes-sync", "description": "", "enabled": false, "backends": [],
         "problems": ["Name clash: ~/.agents/skills/notes-sync is a folder Cantrip doesn't manage (left as is; rename one of them)"]}
      ],
      "rules": [{"folder": "~/Coding", "lines": 12, "mirror": "~/Coding/CLAUDE.md"}],
      "drift": [{"path": "~/Coding/app/CLAUDE.md", "problem": "holds the rules but there's no AGENTS.md beside it"}],
      "driftCheckedAt": "2026-11-01T13:40:00Z",
      "checking": false
    }
    """

    private func decode(_ json: String) throws -> CantripSkillsSnapshot {
        try JSONDecoder().decode(CantripSkillsSnapshot.self, from: Data(json.utf8))
    }

    private func client() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SkillsRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            SkillsRequestProtocol.handler = nil
        }
        return client
    }

    private func api() throws -> CantripRemoteAPI {
        CantripRemoteAPI(transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
                         token: "skills-test-token", urlSession: client())
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDecodesTheHostPayload() throws {
        let snapshot = try decode(Self.payload)
        XCTAssertEqual(snapshot.library, "~/Library/Application Support/Cantrip/skills")
        XCTAssertEqual(snapshot.backends, ["Claude Code", "Copilot", "Codex", "Antigravity"])
        XCTAssertEqual(snapshot.skills.map(\.name), ["weather-lookup", "notes-sync"])
        XCTAssertEqual(snapshot.skills[0].description, "Looks up the weather.")
        XCTAssertTrue(snapshot.skills[0].enabled)
        XCTAssertFalse(snapshot.skills[1].enabled)
        XCTAssertEqual(snapshot.skills[1].problems.count, 1)
        XCTAssertEqual(snapshot.rules, [CantripSkillsRule(folder: "~/Coding", lines: 12, mirror: "~/Coding/CLAUDE.md")])
        XCTAssertEqual(snapshot.drift.map(\.path), ["~/Coding/app/CLAUDE.md"])
        XCTAssertEqual(snapshot.driftCheckedDate, Date(timeIntervalSince1970: 1_793_540_400))
        XCTAssertFalse(snapshot.checking)
        XCTAssertNil(snapshot.messages)
    }

    func testMissingOptionalFieldsDecode() throws {
        let snapshot = try decode("""
        {"library": "~/skills", "backends": [], "checking": true, "driftCheckedAt": null,
         "skills": [{"name": "weather-lookup", "enabled": true}],
         "rules": [{"folder": "~/Coding", "lines": 1}], "drift": [], "messages": ["Linked ~/.agents/skills/weather-lookup"]}
        """)
        XCTAssertNil(snapshot.driftCheckedAt)
        XCTAssertNil(snapshot.driftCheckedDate)
        XCTAssertNil(snapshot.rules[0].mirror)
        XCTAssertEqual(snapshot.skills[0].description, "")
        XCTAssertEqual(snapshot.skills[0].backends, [])
        XCTAssertEqual(snapshot.skills[0].problems, [])
        XCTAssertEqual(snapshot.messages, ["Linked ~/.agents/skills/weather-lookup"])

        let bare = try decode(#"{"skills": []}"#)
        XCTAssertEqual(bare.rules, [])
        XCTAssertEqual(bare.drift, [])
        XCTAssertFalse(bare.checking)
        XCTAssertThrowsError(try decode(#"{"rules": []}"#), "A payload without skills isn't the skills screen")
        XCTAssertEqual(CantripSkills.date("2026-11-01T13:40:00.250Z")?.timeIntervalSince1970, 1_793_540_400.25)
    }

    func testRowText() throws {
        let snapshot = try decode(Self.payload)
        let (on, off) = (snapshot.skills[0], snapshot.skills[1])
        XCTAssertEqual(CantripSkills.seenBy(on), "Seen by: Claude Code, Copilot, Codex, Antigravity")
        XCTAssertEqual(CantripSkills.seenBy(off), "No backend sees it")
        XCTAssertEqual(CantripSkills.toggleLabel(on), "weather-lookup, on for every backend")
        XCTAssertEqual(CantripSkills.toggleLabel(off), "notes-sync, off for every backend")
        XCTAssertEqual(CantripSkills.ruleText(snapshot.rules[0]), "~/Coding — 12 lines (mirrored to ~/Coding/CLAUDE.md)")
        XCTAssertEqual(CantripSkills.ruleText(CantripSkillsRule(folder: "~/Notes", lines: 1, mirror: nil)), "~/Notes — 1 line")
        XCTAssertEqual(CantripSkills.relinkSummary([]), "Relinked. Everything was already linked.")
        XCTAssertEqual(CantripSkills.relinkSummary(["Linked ~/.agents/skills/notes-sync"]),
                       "Relinked: Linked ~/.agents/skills/notes-sync")
    }

    func testDriftStatusAndPolling() throws {
        let english = Locale(identifier: "en_US")
        var snapshot = try decode(Self.payload)
        let checked = try XCTUnwrap(snapshot.driftCheckedDate)
        XCTAssertEqual(CantripSkills.driftStatus(snapshot, now: checked.addingTimeInterval(20), locale: english),
                       "Last checked just now")
        XCTAssertEqual(CantripSkills.driftStatus(snapshot, now: checked.addingTimeInterval(300), locale: english),
                       "Last checked 5 minutes ago")
        XCTAssertFalse(CantripSkills.isDriftClear(snapshot), "There's a finding")
        XCTAssertEqual(CantripSkills.driftSummary(snapshot), "1 drift finding")
        snapshot.drift = []
        XCTAssertTrue(CantripSkills.isDriftClear(snapshot))
        XCTAssertEqual(CantripSkills.driftSummary(snapshot), "No drift found")
        snapshot.checking = true
        XCTAssertEqual(CantripSkills.driftStatus(snapshot), "Checking…")
        XCTAssertFalse(CantripSkills.isDriftClear(snapshot), "Not while checking")
        snapshot.checking = false
        snapshot.driftCheckedAt = nil
        XCTAssertEqual(CantripSkills.driftStatus(snapshot), "Not checked yet")
        XCTAssertFalse(CantripSkills.isDriftClear(snapshot), "Never checked isn't clear")
        XCTAssertEqual(CantripSkills.pollInterval(checking: true), .seconds(2))
        XCTAssertEqual(CantripSkills.pollInterval(checking: false), .seconds(10))
    }

    func testReadsAndOlderHostsSayUpdate() async throws {
        let api = try api()
        SkillsRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/skills")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer skills-test-token")
            return (200, Data(Self.payload.utf8))
        }
        let snapshot = try await api.skills()
        XCTAssertEqual(snapshot.skills.count, 2)

        SkillsRequestProtocol.handler = { _ in (404, Data(#"{"error":"not found"}"#.utf8)) }
        do {
            _ = try await api.skills()
            XCTFail("An older Mac has no skills endpoint")
        } catch CantripRemoteError.skillsUnsupported {}
        XCTAssertEqual(CantripRemoteError.skillsUnsupported.localizedDescription,
                       "This Mac's Cantrip doesn't share skills yet. Update Cantrip on the Mac.")
    }

    func testActionsPostTheirBodiesAndRefusalsKeepTheMacsWords() async throws {
        let api = try api()
        var posts: [[String: Any]] = []
        SkillsRequestProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/skills")
            posts.append(try self.body(request))
            return (200, Data(Self.payload.utf8))
        }
        _ = try await api.skillsAction(.setEnabled(name: "weather-lookup", enabled: false))
        _ = try await api.skillsAction(.sync)
        _ = try await api.skillsAction(.check)
        XCTAssertEqual(posts.count, 3)
        XCTAssertEqual(posts[0]["action"] as? String, "setEnabled")
        XCTAssertEqual(posts[0]["name"] as? String, "weather-lookup")
        XCTAssertEqual(posts[0]["enabled"] as? Bool, false)
        XCTAssertEqual(posts[1] as? [String: String], ["action": "sync"])
        XCTAssertEqual(posts[2] as? [String: String], ["action": "check"])

        SkillsRequestProtocol.handler = { _ in (400, Data(#"{"error":"No skill named weather-lookup."}"#.utf8)) }
        do {
            _ = try await api.skillsAction(.setEnabled(name: "weather-lookup", enabled: true))
            XCTFail("A refusal must surface")
        } catch CantripRemoteError.rejected(let message) {
            XCTAssertEqual(message, "No skill named weather-lookup.")
        }
    }

    func testModelShowsARefusalWithoutDisconnecting() async throws {
        let model = CantripRemoteModel(urlSession: client())
        let configured = await model.configure(url: "https://cantrip.example",
                                              pairingToken: "skills-test", tailscaleOnly: true)
        XCTAssertTrue(configured)
        addTeardownBlock { @MainActor in model.setAppActive(false); model.clearConfiguration() }
        var attempts = 0
        SkillsRequestProtocol.handler = { request in
            guard request.url?.path == "/api/v1/skills" else { return (200, Data(#"{"sessions":[]}"#.utf8)) }
            attempts += 1
            return (400, Data(#"{"error":"No skill named weather-lookup."}"#.utf8))
        }
        let result = await model.skillsAction(.setEnabled(name: "weather-lookup", enabled: true))
        XCTAssertNil(result)
        XCTAssertEqual(attempts, 1, "A refusal is never retried")
        XCTAssertEqual(model.errorMessage, "No skill named weather-lookup.")
        XCTAssertFalse(model.isMutating)
    }
}
