import Foundation
import XCTest
@testable import Hermes

private final class PrivacyGateRequestProtocol: URLProtocol {
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

/// Synthetic Privacy Gate payloads, shared with the render tests.
enum PrivacyGateFixture {
    static let taskID = UUID(uuidString: "10000000-0000-0000-0000-0000000000A1")!
    static let otherTaskID = UUID(uuidString: "10000000-0000-0000-0000-0000000000A2")!

    static let gate = """
    {
      "enabled": true, "mode": "observe", "appliesTo": ["homeChat", "homeTasks"],
      "defaultRoute": "cloud", "uncertainRoute": "redactApprove",
      "classifier": {"enabled": true, "baseURL": "", "model": "", "timeoutMs": 2500, "rotations": 3,
                     "cloudMinProbability": 0.9, "cacheMinutes": 60, "maxInputCharacters": 3000},
      "rules": [
        {"id": "secrets", "route": "local", "enabled": true, "detectors": ["secret"],
         "scope": ["request", "earlier", "memory", "context"]},
        {"id": "private-sources", "route": "local", "enabled": true, "sources": ["personal", "mail", "messages"],
         "scope": ["request"]},
        {"id": "personal-details", "route": "redactApprove", "enabled": true,
         "detectors": ["ssn", "card", "phone"], "privateTerms": true},
        {"id": "code", "route": "cloud", "enabled": false, "repoWorkdir": true}
      ],
      "chat": "auto",
      "tasks": {"10000000-0000-0000-0000-0000000000A1": "local"},
      "cloudRuns": {"excludeMCP": ["personal", "forms"], "denyReads": ["~/Cantrip Memory"]},
      "offline": {"chat": "ask", "tasks": "hold"},
      "approvalTimeoutMinutes": {"chat": 10, "tasks": 240},
      "stickyTurns": 3,
      "futureSetting": {"kept": [1, 2.5, "three"]}
    }
    """

    static func policy(gate: String? = Self.gate, classifier: String? = """
        {"address": "http://127.0.0.1:8000/v1", "model": "example-classifier-4b", "from": "privateLocal",
         "log": "~/Library/Logs/Cantrip/privacy-decisions.jsonl"}
        """) -> String {
        """
        {
          "policy": {
            "revision": 7, "enabled": true,
            "rules": [{"id": "no-force-push", "effect": "deny", "reason": "Keep shared history.", "enabled": true,
                       "source": "user", "commands": ["git push --force"]}],
            "privateTerms": ["Project Lantern"]\(gate.map { ",\n\"privacyGate\": \($0)" } ?? "")
          },
          "summaries": {"no-force-push": "Blocks: git push --force"},
          "file": "~/Library/Application Support/Cantrip/policy.json",
          "loadError": null,
          "namedCommands": ["cantrip-restart"]\(classifier.map { ",\n\"privacyClassifier\": \($0)" } ?? "")
        }
        """
    }

    static func snapshot(_ json: String = policy()) throws -> CantripPolicySnapshot {
        try JSONDecoder().decode(CantripPolicySnapshot.self, from: Data(json.utf8))
    }

    static func tasks() throws -> [CantripHomeTask] {
        func task(_ id: UUID, _ title: String) throws -> CantripHomeTask {
            try JSONDecoder().decode(CantripHomeTask.self, from: Data("""
            {"id":"\(id.uuidString)","title":"\(title)","prompt":"Summarize it.",
            "schedule":{"kind":"weekdays","summary":"Weekdays at 8:00 AM","timeZone":"America/Los_Angeles",
            "hour":8,"minute":0,"weekdays":[2,3,4,5,6]},
            "enabled":true,"createdAt":0,"updatedAt":0,"nextRunAt":null,
            "lastRunAt":null,"state":"scheduled","activeRunID":null,"runs":[]}
            """.utf8))
        }
        return [try task(taskID, "Morning briefing"), try task(otherTaskID, "Weekly receipts")]
    }

    static func message(privacy: String?) -> String {
        """
        {"id": "p1", "role": "user", "text": "What's on my calendar tomorrow?", "thinking": "",
         "activities": []\(privacy.map { ", \"privacy\": \($0)" } ?? "")}
        """
    }
}

/// The Privacy Gate's wire format: message badges, the policy section, and the POST bodies.
@MainActor
final class CantripPrivacyGateTests: XCTestCase {
    private func json(_ object: Any) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func original() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PrivacyGateFixture.gate.utf8)) as? [String: Any])
    }

    // MARK: Messages

    func testUserMessageDecodesWithAndWithoutPrivacy() throws {
        let decoder = JSONDecoder()
        let badged = try decoder.decode(CantripRemoteMessage.self, from: Data(PrivacyGateFixture.message(privacy: """
            {"route": "local", "mode": "observe", "applied": false, "label": "Would run locally · secrets",
             "detail": "A secret in the request. Rules 1 ms, 3 ms in all. Observing: this run was sent as usual."}
            """).utf8))
        let privacy = try XCTUnwrap(badged.privacy)
        XCTAssertEqual(privacy.kind, .local)
        XCTAssertEqual(privacy.label, "Would run locally · secrets")
        XCTAssertFalse(privacy.applied)
        XCTAssertFalse(privacy.isEnforced)
        XCTAssertTrue(privacy.isVisible)
        XCTAssertEqual(privacy.accessibilityLabel, "Privacy: Would run locally · secrets")
        XCTAssertTrue(privacy.detail.hasPrefix("A secret in the request."))

        let plain = try decoder.decode(CantripRemoteMessage.self, from: Data(PrivacyGateFixture.message(privacy: nil).utf8))
        XCTAssertNil(plain.privacy, "Macs from before the gate send no privacy")
        XCTAssertEqual(plain.text, badged.text)

        // A field this app can't read never costs the message.
        let odd = try decoder.decode(CantripRemoteMessage.self, from: Data(PrivacyGateFixture.message(privacy: #""soon""#).utf8))
        XCTAssertEqual(odd.privacy?.isVisible, false)
        let partial = try decoder.decode(CantripRemoteMessage.self, from: Data(PrivacyGateFixture.message(
            privacy: #"{"route": "teleport", "label": "Somewhere new", "applied": "yes"}"#).utf8))
        XCTAssertEqual(partial.privacy?.label, "Somewhere new")
        XCTAssertEqual(partial.privacy?.symbol, "shield", "An unknown route keeps a neutral symbol")
        XCTAssertEqual(partial.privacy?.applied, false)
        XCTAssertEqual(partial.privacy?.mode, "observe")
    }

    func testBadgeSymbolsAndEmphasis() {
        let symbols = CantripPrivacyRoute.allCases.map { CantripPrivacyBadge(route: $0.rawValue, label: "x").symbol }
        XCTAssertEqual(symbols, ["house.fill", "cloud", "eye.slash", "wifi.slash"])
        for route in CantripPrivacyRoute.allCases {
            XCTAssertEqual(CantripPrivacyBadge(route: route.rawValue, mode: "observe", label: "x").emphasis, .quiet,
                           "Observe mode stays quiet for \(route)")
        }
        XCTAssertEqual(CantripPrivacyBadge(route: "local", mode: "enforce", applied: true, label: "Ran locally").emphasis, .local)
        XCTAssertEqual(CantripPrivacyBadge(route: "cloud", mode: "enforce", applied: true, label: "Cloud").emphasis, .enforced)
        XCTAssertEqual(CantripPrivacyBadge(route: "redactApprove", mode: "enforce", label: "Asked first").emphasis, .enforced)
        XCTAssertFalse(CantripPrivacyBadge(route: "local", label: "  ").isVisible)
    }

    // MARK: Policy

    /// A rule that only hands requests to the classifier says so instead of showing its fallback route.
    func testARuleThatAsksTheClassifier() throws {
        let value = try JSONDecoder().decode(MCPAppJSONValue.self, from: Data(#"""
            {"id": "personal-hints", "route": "redactApprove", "detectors": ["name", "email"], "privateTerms": true,
             "scope": ["request"], "askClassifier": true}
            """#.utf8))
        let rule = try XCTUnwrap(CantripPrivacyGate.Rule(value))
        XCTAssertTrue(rule.askClassifier)
        XCTAssertEqual(rule.routeTitle, "Classifier decides")
        XCTAssertEqual(rule.matches, "people's names, email addresses · private terms")
    }

    func testPolicyDecodesThePrivacyGate() throws {
        let snapshot = try PrivacyGateFixture.snapshot()
        let gate = try XCTUnwrap(snapshot.policy.privacyGate)
        XCTAssertTrue(gate.enabled)
        XCTAssertEqual(gate.mode, .observe)
        XCTAssertEqual(gate.chat, .auto)
        XCTAssertEqual(gate.route(forTask: PrivacyGateFixture.taskID), .local)
        XCTAssertEqual(gate.route(forTask: PrivacyGateFixture.otherTaskID), .auto)
        XCTAssertEqual(gate.rules.map(\.id), ["secrets", "private-sources", "personal-details", "code"])
        XCTAssertEqual(gate.rules.map(\.enabled), [true, true, true, false])
        XCTAssertEqual(gate.rules[0].routeTitle, "Local")
        XCTAssertEqual(gate.rules[0].matches, "secrets")
        XCTAssertEqual(gate.rules[1].matches, "private sources: personal, mail, messages")
        XCTAssertEqual(gate.rules[2].routeTitle, "Ask first")
        XCTAssertEqual(gate.rules[2].matches, "Social Security numbers, card numbers, phone numbers · private terms")
        XCTAssertEqual(gate.rules[3].matches, "work in a code repository")

        let classifier = try XCTUnwrap(snapshot.privacyClassifier)
        XCTAssertEqual(classifier.from, "privateLocal")
        XCTAssertEqual(classifier.headline, "Same server as Private Local")
        XCTAssertEqual(classifier.subtitle, "http://127.0.0.1:8000/v1 · Model: example-classifier-4b")
        // The rest of the policy still reads as before.
        XCTAssertEqual(snapshot.policy.revision, 7)
        XCTAssertEqual(snapshot.policy.rules.map(\.id), ["no-force-push"])
    }

    func testOlderMacsPolicyHasNoPrivacyGate() throws {
        let snapshot = try PrivacyGateFixture.snapshot(PrivacyGateFixture.policy(gate: nil, classifier: nil))
        XCTAssertNil(snapshot.policy.privacyGate, "Settings hides the section")
        XCTAssertNil(snapshot.privacyClassifier)
        XCTAssertEqual(snapshot.policy.rules.count, 1)
        // A section this app can't read hides the gate without failing the page.
        let garbled = try PrivacyGateFixture.snapshot(PrivacyGateFixture.policy(gate: #""on""#))
        XCTAssertNil(garbled.policy.privacyGate)
        XCTAssertEqual(garbled.policy.revision, 7)
    }

    func testClassifierStatusAndTestResultText() throws {
        let own = CantripPrivacyClassifierStatus(address: "https://classifier.example/v1", model: "example-4b", from: "own")
        XCTAssertEqual(own.headline, "https://classifier.example/v1")
        XCTAssertEqual(own.subtitle, "Model: example-4b")
        let none = CantripPrivacyClassifierStatus(from: "none", problem: "No classifier model is set.")
        XCTAssertFalse(none.isConfigured)
        XCTAssertEqual(none.headline, "No classifier model is set.")
        XCTAssertNil(none.subtitle)

        let result = try JSONDecoder().decode(CantripPrivacyTestResult.self, from: Data("""
            {"ok": true, "address": "http://127.0.0.1:8000/v1", "model": "example-4b", "latencyMs": 412,
             "route": "cloud", "probabilities": {"local": 0.02, "cloud": 0.9712, "redactApprove": 0.0088}}
            """.utf8))
        XCTAssertEqual(result.summary, "Cloud in 412 ms · 97% cloud")
        let failed = try JSONDecoder().decode(CantripPrivacyTestResult.self, from: Data("""
            {"ok": false, "error": "The classifier didn't answer within 2500 ms."}
            """.utf8))
        XCTAssertEqual(failed.summary, "The classifier didn't answer within 2500 ms.")
    }

    // MARK: POST bodies

    func testPrivacyGateChangeSendsTheWholeSectionWithOneFieldChanged() throws {
        let gate = try XCTUnwrap(try PrivacyGateFixture.snapshot().policy.privacyGate)
        let original = try original()

        let enforce = try json(gate.setting("mode", to: .string("enforce")).change)
        XCTAssertEqual(Array(enforce.keys), ["privacyGate"])
        var section = try XCTUnwrap(enforce["privacyGate"] as? [String: Any])
        XCTAssertEqual(section["mode"] as? String, "enforce")
        section["mode"] = "observe"
        XCTAssertEqual(section as NSDictionary, original as NSDictionary, "Every other field goes back as read")

        let off = try json(gate.setting("enabled", to: .bool(false)).change)
        XCTAssertEqual((off["privacyGate"] as? [String: Any])?["enabled"] as? Bool, false)

        let rule = try json(gate.settingRule("code", enabled: true).change)
        var ruleSection = try XCTUnwrap(rule["privacyGate"] as? [String: Any])
        var rules = try XCTUnwrap(ruleSection["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.map { $0["enabled"] as? Bool }, [true, true, true, true])
        rules[3]["enabled"] = false
        ruleSection["rules"] = rules
        XCTAssertEqual(ruleSection as NSDictionary, original as NSDictionary, "Only that rule's switch changes")

        // What the Mac decodes: integers stay integers, nothing is dropped.
        struct Classifier: Decodable { let timeoutMs: Int; let rotations: Int; let cloudMinProbability: Double }
        struct Section: Decodable {
            let classifier: Classifier
            let approvalTimeoutMinutes: [String: Int]
            let stickyTurns: Int
        }
        let body = try JSONSerialization.data(withJSONObject: try XCTUnwrap(enforce["privacyGate"]))
        let decoded = try JSONDecoder().decode(Section.self, from: body)
        XCTAssertEqual(decoded.classifier.timeoutMs, 2500)
        XCTAssertEqual(decoded.classifier.rotations, 3)
        XCTAssertEqual(decoded.classifier.cloudMinProbability, 0.9)
        XCTAssertEqual(decoded.approvalTimeoutMinutes, ["chat": 10, "tasks": 240])
        XCTAssertEqual(decoded.stickyTurns, 3)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertNotNil(text.range(of: #""stickyTurns":3[,}]"#, options: .regularExpression), "Sent as an integer: \(text)")
        XCTAssertNotNil(text.range(of: #""timeoutMs":2500[,}]"#, options: .regularExpression))
    }

    func testPrivacyRouteBodies() throws {
        let chat = try json(CantripPrivacyGate.routeChange(task: nil, route: .local))
        let chatRoute = try XCTUnwrap(chat["privacyRoute"] as? [String: Any])
        XCTAssertTrue(chatRoute["task"] is NSNull, "Home chat's route names no task")
        XCTAssertEqual(chatRoute["route"] as? String, "local")

        let task = try json(CantripPrivacyGate.routeChange(task: PrivacyGateFixture.taskID, route: .cloudWithPrivateTools))
        XCTAssertEqual(task["privacyRoute"] as? [String: String],
                       ["task": "10000000-0000-0000-0000-0000000000A1", "route": "cloudWithPrivateTools"])
        let auto = try json(CantripPrivacyGate.routeChange(task: PrivacyGateFixture.taskID, route: .auto))
        XCTAssertEqual((auto["privacyRoute"] as? [String: Any])?["route"] as? String, "auto")
        XCTAssertEqual(CantripPrivacyRouteChoice.allCases.map(\.label), [
            "Decide each time", "Always local", "Always cloud, without private tools", "Always cloud, with private tools",
        ])
    }

    func testPolicySaveNeverSendsABrokenPrivacyGate() throws {
        let snapshot = try PrivacyGateFixture.snapshot()
        let body = try json(try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(["policy": snapshot.policy]))))
        let policy = try XCTUnwrap(body["policy"] as? [String: Any])
        XCTAssertEqual(policy["privacyGate"] as? NSDictionary, try original() as NSDictionary,
                       "The section goes back exactly as read")
        XCTAssertEqual(policy["privateTerms"] as? [String], ["Project Lantern"], "Nothing this app doesn't show is lost")
        XCTAssertEqual((policy["rules"] as? [[String: Any]])?.first?["commands"] as? [String], ["git push --force"])

        // An edited section goes back whole.
        var edited = snapshot.policy
        edited.privacyGate = edited.privacyGate?.setting("mode", to: .string("enforce"))
        let editedPolicy = try json(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edited))))
        var gate = try XCTUnwrap(editedPolicy["privacyGate"] as? [String: Any])
        XCTAssertEqual(gate["mode"] as? String, "enforce")
        gate["mode"] = "observe"
        XCTAssertEqual(gate as NSDictionary, try original() as NSDictionary)

        // A section this app couldn't read is left out, so the Mac keeps its own.
        let garbled = try PrivacyGateFixture.snapshot(PrivacyGateFixture.policy(gate: #""on""#))
        let garbledPolicy = try json(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(garbled.policy))))
        XCTAssertNil(garbledPolicy["privacyGate"])
        XCTAssertEqual(garbledPolicy["privateTerms"] as? [String], ["Project Lantern"])
        // Older Macs: nothing to send.
        let older = try PrivacyGateFixture.snapshot(PrivacyGateFixture.policy(gate: nil))
        XCTAssertNil(try json(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(older.policy))))["privacyGate"])
    }

    // MARK: Through the model

    private func configuredModel() async throws -> CantripRemoteModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyGateRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        let model = CantripRemoteModel(urlSession: client)
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "privacy-gate-test",
                                               tailscaleOnly: true)
        XCTAssertTrue(configured)
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            client.invalidateAndCancel()
            PrivacyGateRequestProtocol.handler = nil
        }
        return model
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

    func testModelPostsPrivacyChangesOnceWithTheRevision() async throws {
        let model = try await configuredModel()
        let gate = try XCTUnwrap(try PrivacyGateFixture.snapshot().policy.privacyGate)
        var posts: [[String: Any]] = []
        PrivacyGateRequestProtocol.handler = { request in
            guard request.url?.path == "/api/v1/policy" else { return (200, Data(#"{"sessions":[]}"#.utf8)) }
            if request.httpMethod == "POST" { posts.append(try self.body(request)) }
            return (200, Data(PrivacyGateFixture.policy().utf8))
        }
        var change = gate.setting("mode", to: .string("enforce")).change
        change["revision"] = 7
        let saved = await model.updateAgentPolicy(change)
        XCTAssertNotNil(saved, model.errorMessage ?? "")
        var route = CantripPrivacyGate.routeChange(task: nil, route: .cloud)
        route["revision"] = 7
        _ = await model.updateAgentPolicy(route)

        XCTAssertEqual(posts.count, 2, "Each change is sent once")
        XCTAssertEqual(posts[0]["revision"] as? Int, 7)
        XCTAssertEqual((posts[0]["privacyGate"] as? [String: Any])?["mode"] as? String, "enforce")
        XCTAssertEqual(((posts[0]["privacyGate"] as? [String: Any])?["rules"] as? [Any])?.count, 4)
        XCTAssertEqual(posts[1]["revision"] as? Int, 7)
        let sentRoute = try XCTUnwrap(posts[1]["privacyRoute"] as? [String: Any])
        XCTAssertTrue(sentRoute["task"] is NSNull)
        XCTAssertEqual(sentRoute["route"] as? String, "cloud")
    }

    func testModelTestsTheClassifier() async throws {
        let model = try await configuredModel()
        var tests = 0
        PrivacyGateRequestProtocol.handler = { request in
            guard request.url?.path == "/api/v1/policy/privacy-test" else { return (200, Data(#"{"sessions":[]}"#.utf8)) }
            XCTAssertEqual(request.httpMethod, "POST")
            tests += 1
            return (200, Data("""
                {"ok": true, "address": "http://127.0.0.1:8000/v1", "model": "example-4b", "latencyMs": 380,
                 "route": "cloud", "probabilities": {"local": 0.01, "cloud": 0.98, "redactApprove": 0.01}}
                """.utf8))
        }
        let result = await model.testPrivacyClassifier()
        XCTAssertEqual(tests, 1)
        XCTAssertEqual(result?.summary, "Cloud in 380 ms · 98% cloud")
    }

    func testSettingsReadsHomeTasksWhenHomeHasntLoadedThem() async throws {
        let model = try await configuredModel()
        let tasks = try PrivacyGateFixture.tasks()
        PrivacyGateRequestProtocol.handler = { request in
            guard request.url?.path == "/api/v1/home/tasks" else { return (200, Data(#"{"sessions":[]}"#.utf8)) }
            return (200, Data("""
                {"tasks": [
                  {"id":"\(tasks[0].id.uuidString)","title":"Morning briefing","prompt":"Summarize it.",
                   "schedule":{"kind":"once","summary":"No schedule","timeZone":"America/Los_Angeles"},
                   "enabled":true,"createdAt":0,"updatedAt":0,"nextRunAt":null,
                   "lastRunAt":null,"state":"scheduled","activeRunID":null,"runs":[]}
                ], "revision": "r1"}
                """.utf8))
        }
        let read = try await model.homeTasksForSettings()
        XCTAssertEqual(read.map(\.id), [tasks[0].id])
        XCTAssertEqual(read.map(\.title), ["Morning briefing"])
    }
}
