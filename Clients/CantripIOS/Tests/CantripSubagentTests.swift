import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class SubagentRequestProtocol: URLProtocol {
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

@MainActor
final class CantripSubagentTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-000000000001"

    private func client() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubagentRequestProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testRemoteMessageDecodesFullSubagentPayload() throws {
        let message = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(#"""
        {"id":"m1","role":"assistant","text":"Done","thinking":"","activities":[],
         "subagents":[{
           "id":"call_H3v6","agentID":"92674a76-1ff7-4b4f-acc0-584c5c0b1c4a",
           "name":"Count tmp files","agentType":"explore","summary":"Count tmp files",
           "model":"gpt-5.4-mini","effort":"high","background":true,"status":"running",
           "startedAt":1790501259.092,"finishedAt":1790501261.094,
           "intent":"Searching the test suite","currentStep":"Count direct entries",
           "latestMessage":"0 entries in /tmp.","steps":3,"tokens":8972,
           "error":"boom","canCancel":true,
           "recentSteps":[{"title":"Count direct entries","toolName":"bash","state":"succeeded"}]
         }]}
        """#.utf8))

        let subagent = try XCTUnwrap(message.subagents?.first)
        XCTAssertEqual(subagent.id, "call_H3v6")
        XCTAssertEqual(subagent.agentID, "92674a76-1ff7-4b4f-acc0-584c5c0b1c4a")
        XCTAssertEqual(subagent.name, "Count tmp files")
        XCTAssertEqual(subagent.agentType, "explore")
        XCTAssertEqual(subagent.summary, "Count tmp files")
        XCTAssertEqual(subagent.model, "gpt-5.4-mini")
        XCTAssertEqual(subagent.effort, "high")
        XCTAssertTrue(subagent.background)
        XCTAssertEqual(subagent.status, .running)
        XCTAssertEqual(subagent.startedAt, 1790501259.092)
        XCTAssertEqual(subagent.finishedAt, 1790501261.094)
        XCTAssertEqual(subagent.intent, "Searching the test suite")
        XCTAssertEqual(subagent.currentStep, "Count direct entries")
        XCTAssertEqual(subagent.latestMessage, "0 entries in /tmp.")
        XCTAssertEqual(subagent.steps, 3)
        XCTAssertEqual(subagent.tokens, 8972)
        XCTAssertEqual(subagent.error, "boom")
        XCTAssertTrue(subagent.canCancel)
        XCTAssertEqual(subagent.recentSteps, [
            CantripRemoteSubagentStep(title: "Count direct entries", toolName: "bash", state: "succeeded")
        ])
    }

    func testRemoteMessageDecodesMinimalAndUnknownStatusSubagents() throws {
        let message = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(#"""
        {"id":"m1","role":"assistant","text":"","thinking":"","activities":[],
         "subagents":[
           {"id":"call_min","agentID":"agent_min"},
           {"id":"call_new","agentID":"agent_new","status":"starting-soon"}
         ]}
        """#.utf8))

        let subagents = try XCTUnwrap(message.subagents)
        XCTAssertEqual(subagents.count, 2)
        XCTAssertEqual(subagents[0].name, "")
        XCTAssertEqual(subagents[0].agentType, "")
        XCTAssertEqual(subagents[0].summary, "")
        XCTAssertNil(subagents[0].model)
        XCTAssertFalse(subagents[0].background)
        XCTAssertEqual(subagents[0].status, .working)
        XCTAssertNil(subagents[0].startedAt)
        XCTAssertEqual(subagents[0].steps, 0)
        XCTAssertEqual(subagents[0].tokens, 0)
        XCTAssertFalse(subagents[0].canCancel)
        XCTAssertEqual(subagents[0].recentSteps, [])
        XCTAssertEqual(subagents[1].status, .working)
    }

    func testRemoteMessageWithoutSubagentsKeepsOptionalNil() throws {
        let message = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(#"""
        {"id":"m2","role":"assistant","text":"Plain reply","thinking":"","activities":[]}
        """#.utf8))

        XCTAssertNil(message.subagents)
        XCTAssertEqual(message.presentedText, "Plain reply")
    }

    func testTokenAndElapsedFormatting() {
        XCTAssertEqual(CantripSubagentFormat.tokenLabel(999), "999 tokens")
        XCTAssertEqual(CantripSubagentFormat.tokenLabel(1_000), "1.0k tokens")
        XCTAssertEqual(CantripSubagentFormat.tokenLabel(8972), "9.0k tokens")
        XCTAssertEqual(CantripSubagentFormat.tokenLabel(1_260_000), "1.3M tokens")
        XCTAssertEqual(CantripSubagentFormat.tokenAccessibilityLabel(8_400), "8.4 thousand tokens")

        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(CantripSubagentFormat.elapsedLabel(startedAt: 9_958, finishedAt: nil, now: now), "42s")
        XCTAssertEqual(CantripSubagentFormat.elapsedLabel(startedAt: 9_815, finishedAt: nil, now: now), "3m 05s")
        XCTAssertEqual(CantripSubagentFormat.elapsedLabel(startedAt: 6_280, finishedAt: nil, now: now), "1h 02m")
        XCTAssertEqual(CantripSubagentFormat.elapsedLabel(startedAt: 10_010, finishedAt: nil, now: now), "0s")
        XCTAssertEqual(CantripSubagentFormat.elapsedLabel(startedAt: 9_000, finishedAt: 9_042, now: now), "42s")
    }

    func testAPIConstructsCancelSubagentEndpointRequest() async throws {
        let client = client()
        let api = CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "unit-token",
            urlSession: client
        )
        let encodedPath = "/api/v1/sessions/session%201/subagents/agent%2Fwith%20space/cancel"
        var step = 0
        SubagentRequestProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + "unit-token")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "history", value: "recent")])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath, encodedPath)
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.timeoutInterval, 12)
            step += 1
            return (200, Data(#"{"cancelled":true}"#.utf8))
        }
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            SubagentRequestProtocol.handler = nil
        }

        let cancelled = try await api.cancelSubagent(sessionID: "session 1", agentID: "agent/with space")
        XCTAssertTrue(cancelled)
        XCTAssertEqual(step, 1)
    }

    func testAPIPropagatesHostCancelErrorMessage() async throws {
        let client = client()
        let api = CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "unit-token",
            urlSession: client
        )
        SubagentRequestProtocol.handler = { _ in
            (409, Data(#"{"error":"That subagent already finished."}"#.utf8))
        }
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            SubagentRequestProtocol.handler = nil
        }

        do {
            _ = try await api.cancelSubagent(sessionID: "session", agentID: "agent")
            XCTFail("Expected cancel rejection")
        } catch CantripRemoteError.http(let status, let message) {
            XCTAssertEqual(status, 409)
            XCTAssertEqual(message, "That subagent already finished.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testModelCancelSubagentRefreshesSelectedSessionSnapshot() async throws {
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "unit-subagent-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured, model.errorMessage ?? "Configuration failed")
        var requests: [String] = []
        var sessionReads = 0
        SubagentRequestProtocol.handler = { request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            requests.append("\(request.httpMethod ?? "") \(path)")
            if request.httpMethod == "POST" {
                XCTAssertEqual(path, "/api/v1/sessions/\(self.sessionID)/subagents/agent%2Fwith%20space/cancel")
                return (200, Data(#"{"cancelled":true}"#.utf8))
            }
            XCTAssertEqual(path, "/api/v1/sessions/\(self.sessionID)")
            sessionReads += 1
            return (200, try self.sessionPayload(subagentStatus: sessionReads == 1 ? "running" : "cancelled"))
        }
        addTeardownBlock { @MainActor in
            model.clearConfiguration()
            client.invalidateAndCancel()
            SubagentRequestProtocol.handler = nil
        }

        await model.selectSession(sessionID)
        XCTAssertEqual(model.selectedSession?.transcript.first?.subagents?.first?.status, .running)
        let cancelled = try await model.cancelSubagent(sessionID: sessionID, agentID: "agent/with space")
        XCTAssertTrue(cancelled)
        XCTAssertEqual(model.selectedSession?.transcript.first?.subagents?.first?.status, .cancelled)
        XCTAssertEqual(requests, [
            "GET /api/v1/sessions/\(sessionID)",
            "POST /api/v1/sessions/\(sessionID)/subagents/agent%2Fwith%20space/cancel",
            "GET /api/v1/sessions/\(sessionID)",
        ])
    }

    func testSubagentCardScreenshotsAtPhoneWidth() async throws {
        let artifactDirectory = ProcessInfo.processInfo.environment["TEST_RUNNER_SUBAGENTS_ARTIFACT_DIR"]
        guard let artifactDirectory, !artifactDirectory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SUBAGENTS_ARTIFACT_DIR to write subagent screenshots.")
        }
        let output = URL(fileURLWithPath: artifactDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )

        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", UIUserInterfaceStyle.dark)] {
            let controller = UIHostingController(rootView:
                ScrollView {
                    CantripSubagentStack(
                        remote: CantripRemoteModel(),
                        sessionID: sessionID,
                        subagents: screenshotSubagents(),
                        finishedInitiallyExpanded: true
                    )
                    .padding()
                }
                .frame(width: 393)
                .background(Color(.systemBackground))
            )
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(250))
            controller.view.frame = window.bounds
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = output.appendingPathComponent("subagent-cards-\(name).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let attachment = XCTAttachment(image: image)
            attachment.name = "subagent-cards-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testQueuedSubagentIsLiveAndStoppable() throws {
        let messages = try JSONDecoder().decode([CantripRemoteMessage].self, from: Data(#"""
        [{"id":"m1","role":"assistant","text":"Launched the prompts agent.","thinking":"","activities":[],
          "subagents":[{"id":"q","agentID":"agent-q","name":"notif-prompts","status":"queued","background":true,"canCancel":true}]}]
        """#.utf8))
        let queued = try XCTUnwrap(messages.first?.subagents?.first)
        XCTAssertEqual(queued.status, .queued)
        XCTAssertTrue(queued.status.isLive)
        XCTAssertTrue(queued.status.isCancellableState)
        XCTAssertEqual(queued.status.displayText, "Queued")
        XCTAssertEqual(CantripPinnedSubagents.live(in: messages).map(\.id), ["q"])
    }

    func testPinnedSubagentsKeepOnlyLiveOnesAcrossReplies() throws {
        let messages = try JSONDecoder().decode([CantripRemoteMessage].self, from: Data(#"""
        [{"id":"m1","role":"assistant","text":"First","thinking":"","activities":[],
          "subagents":[{"id":"a","agentID":"a","status":"completed"},{"id":"b","agentID":"b","status":"running","background":true}]},
         {"id":"m2","role":"user","text":"Next","thinking":"","activities":[]},
         {"id":"m3","role":"assistant","text":"","thinking":"","activities":[],
          "subagents":[{"id":"c","agentID":"c","status":"idle"},{"id":"d","agentID":"d","status":"failed"},
                       {"id":"e","agentID":"e","status":"cancelled"},{"id":"f","agentID":"f","status":"starting-soon","background":true}]}]
        """#.utf8))

        XCTAssertEqual(CantripPinnedSubagents.live(in: messages).map(\.id), ["b", "c", "f"])
        XCTAssertEqual(CantripPinnedSubagents.background(in: messages).map(\.id), ["b", "f"])
        XCTAssertEqual(CantripPinnedSubagents.liveBackground(in: messages).map(\.id), ["b", "f"])
        XCTAssertEqual(CantripPinnedSubagents.liveForeground(in: messages).map(\.id), ["c"])
        XCTAssertEqual(CantripPinnedSubagents.live(in: [messages[1]]), [])
    }

    func testBackgroundTaskButtonScreenshotsAtPhoneWidth() async throws {
        let artifactDirectory = ProcessInfo.processInfo.environment["TEST_RUNNER_SUBAGENTS_ARTIFACT_DIR"]
        guard let artifactDirectory, !artifactDirectory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SUBAGENTS_ARTIFACT_DIR to write subagent screenshots.")
        }
        let output = URL(fileURLWithPath: artifactDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let background = screenshotSubagents().filter(\.background)

        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", UIUserInterfaceStyle.dark)] {
            let controller = UIHostingController(rootView:
                VStack(spacing: 0) {
                    ScrollView {
                        Text(String(repeating: "The main conversation remains available while the watcher runs. ", count: 14))
                            .padding()
                    }
                    VStack(spacing: 8) {
                        CantripBackgroundTaskButton(subagents: background) {}
                        Text("Composer")
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding()
                    .background(.bar)
                }
                .frame(width: 393)
                .background(Color(.systemBackground))
            )
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(250))
            controller.view.frame = window.bounds
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = output.appendingPathComponent("background-task-button-\(name).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testFinishedSubagentsSitWhereTheyEndedInTheReply() throws {
        let message = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(#"""
        {"id":"m1","role":"assistant","text":"Starting an explorer.\n\n```\na\n\nb\n```\n\nIt found three tests.","thinking":"","activities":[],
         "subagents":[{"id":"a","agentID":"a","status":"completed","textBlock":2},
                      {"id":"b","agentID":"b","status":"failed"},
                      {"id":"c","agentID":"c","status":"cancelled","textBlock":2}]}
        """#.utf8))
        let subagents = try XCTUnwrap(message.subagents)
        XCTAssertEqual(subagents.map(\.textBlock), [2, nil, 2])

        // Old hosts send no textBlock: those cards stay before the text.
        let placed = CantripReplyBlocks.placed(subagents)
        XCTAssertEqual(placed.map(\.block), [0, 2])
        XCTAssertEqual(placed.map { $0.subagents.map(\.id) }, [["b"], ["a", "c"]])
        XCTAssertEqual(CantripReplyBlocks.split(message.text, before: placed.map(\.block)),
                       ["", "Starting an explorer.\n\n```\na\n\nb\n```", "It found three tests."])
        XCTAssertEqual(CantripReplyBlocks.split("é👍\r\n\r\nNext", before: [1]), ["é👍", "Next"])
        XCTAssertEqual(CantripReplyBlocks.split("Only", before: [7]), ["Only", ""])
        XCTAssertEqual(CantripReplyBlocks.split("Only", before: []), ["Only"])
    }

    func testPinnedSubagentScreenshotsAtPhoneWidth() async throws {
        let artifactDirectory = ProcessInfo.processInfo.environment["TEST_RUNNER_SUBAGENTS_ARTIFACT_DIR"]
        guard let artifactDirectory, !artifactDirectory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SUBAGENTS_ARTIFACT_DIR to write subagent screenshots.")
        }
        let output = URL(fileURLWithPath: artifactDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let live = screenshotSubagents().filter(\.status.isLive)

        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", UIUserInterfaceStyle.dark)] {
            let controller = UIHostingController(rootView:
                VStack(spacing: 0) {
                    ScrollView {
                        Text(String(repeating: "A long streamed reply keeps growing below the subagent. ", count: 40))
                            .padding()
                    }
                    CantripPinnedSubagents(remote: CantripRemoteModel(), sessionID: sessionID,
                                           subagents: live, maxHeight: 300)
                    Text("Composer").frame(maxWidth: .infinity, minHeight: 52).background(.gray.opacity(0.2))
                }
                .frame(width: 393)
                .background(Color(.systemBackground))
            )
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(250))
            controller.view.frame = window.bounds
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = output.appendingPathComponent("subagent-pinned-\(name).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    private func sessionPayload(subagentStatus: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "session": [
                "id": sessionID,
                "title": "Project",
                "workdir": "/tmp",
                "isStreaming": subagentStatus == "running",
                "canResume": false,
                "councilMode": false,
                "queuedCount": 0,
                "messages": [[
                    "id": "reply",
                    "role": "assistant",
                    "text": "Existing reply",
                    "thinking": "",
                    "activities": [],
                    "subagents": [[
                        "id": "call_1",
                        "agentID": "agent/with space",
                        "name": "Count tmp files",
                        "agentType": "explore",
                        "status": subagentStatus,
                        "startedAt": 1_790_501_259,
                        "steps": 1,
                        "tokens": 900,
                        "canCancel": subagentStatus == "running",
                    ]],
                ]],
            ],
        ])
    }

    private func screenshotSubagents() -> [CantripRemoteSubagent] {
        let now = Date().timeIntervalSince1970
        return [
            CantripRemoteSubagent(
                id: "call_running",
                agentID: "agent-running",
                name: "Count tmp files",
                agentType: "explore",
                summary: "Count tmp files",
                model: "gpt-5.4-mini",
                background: false,
                status: .running,
                startedAt: now - 42,
                intent: "Counting direct entries in /tmp",
                steps: 3,
                tokens: 8_400,
                canCancel: true,
                recentSteps: [
                    CantripRemoteSubagentStep(title: "List /tmp", toolName: "bash", state: "succeeded"),
                    CantripRemoteSubagentStep(title: "Count direct entries", toolName: "bash", state: "running"),
                ]
            ),
            CantripRemoteSubagent(
                id: "call_idle",
                agentID: "agent-idle",
                name: "Wait for review",
                agentType: "task",
                summary: "Run targeted tests after review",
                model: "claude-haiku-4.5",
                background: true,
                status: .idle,
                startedAt: now - 185,
                currentStep: "Waiting for follow-up instructions",
                latestMessage: "Ready for the next command.",
                steps: 2,
                tokens: 999,
                canCancel: true,
                recentSteps: [
                    CantripRemoteSubagentStep(title: "Run unit tests", toolName: "xcodebuild", state: "succeeded"),
                ]
            ),
            CantripRemoteSubagent(
                id: "call_completed",
                agentID: "agent-completed",
                name: "",
                agentType: "general-purpose",
                summary: "Investigate remote message decoding",
                model: "gpt-5.5",
                status: .completed,
                startedAt: now - 3_720,
                finishedAt: now - 60,
                latestMessage: "Decoded payloads are compatible.",
                steps: 7,
                tokens: 124_500,
                recentSteps: [
                    CantripRemoteSubagentStep(title: "Read CantripRemote.swift", toolName: "view", state: "succeeded"),
                ]
            ),
            CantripRemoteSubagent(
                id: "call_failed",
                agentID: "agent-failed",
                name: "Check flaky renderer",
                agentType: "explore",
                summary: "Check flaky renderer",
                model: "gpt-5.4-mini",
                status: .failed,
                startedAt: now - 140,
                finishedAt: now - 20,
                latestMessage: "Renderer timed out while waiting for a window scene.",
                steps: 4,
                tokens: 1_250_000,
                error: "Timed out waiting for a render surface.",
                recentSteps: [
                    CantripRemoteSubagentStep(title: "Open preview harness", toolName: "view", state: "succeeded"),
                    CantripRemoteSubagentStep(title: "Render phone width", toolName: "xcodebuild", state: "failed"),
                ]
            ),
        ]
    }
}
