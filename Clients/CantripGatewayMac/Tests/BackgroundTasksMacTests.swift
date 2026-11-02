import AppKit
import SwiftUI
import XCTest
@testable import Hermes

/// A tab's running background tasks above its composer, as iOS shows them.
@MainActor
final class BackgroundTasksMacTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-0000000000b7"

    private func subagent(_ id: String, _ name: String, status: String, background: Bool,
                          startedAgo: TimeInterval = 200) -> [String: Any] {
        let now = Date().timeIntervalSince1970
        var agent: [String: Any] = [
            "id": id, "agentID": "agent-\(id)", "name": name, "agentType": "task",
            "summary": name, "background": background, "status": status,
            "startedAt": now - startedAgo, "canCancel": true, "steps": 2,
            "currentStep": "Waiting for the workflow run",
        ]
        if status == "completed" { agent["finishedAt"] = now - 20 }
        return agent
    }

    private func tab(subagents: [[String: Any]], isHome: Bool = false) async throws
        -> (CantripRemoteModel, ChatViewModel) {
        let model = try StartFreshFixture.model(for: self)
        var session: [String: Any] = [
            "id": sessionID, "title": "CantripGatewayMac", "workdir": "/tmp", "isStreaming": false,
            "canResume": false, "councilMode": false, "queuedCount": 0,
            "messages": [
                ["id": "p1", "role": "user", "text": "Build the Windows installer",
                 "thinking": "", "activities": []],
                ["id": "r1", "role": "assistant", "text": "CI is building it; a watcher is following the run.",
                 "thinking": "", "activities": [], "subagents": subagents],
            ],
        ]
        if isHome { session["isCantripHome"] = true }
        let detail = try JSONSerialization.data(withJSONObject: ["session": session])
        session.removeValue(forKey: "messages")
        let list = try JSONSerialization.data(withJSONObject: ["sessions": [session]])
        StartFreshRequestProtocol.handler = { request in
            (200, request.url?.path == "/api/v1/sessions" ? list : detail)
        }
        await model.selectSession(sessionID)
        XCTAssertEqual(model.selectedSession?.id, sessionID, model.errorMessage ?? "Tab not selected")
        return (model, try StartFreshFixture.chat(model, for: self))
    }

    func testTabListsOnlyItsLiveBackgroundTasks() async throws {
        let (model, _) = try await tab(subagents: [
            subagent("w", "watch-windows-ci", status: "running", background: true),
            subagent("q", "watch-upload", status: "queued", background: true),
            subagent("f", "explore-repo", status: "running", background: false),
            subagent("d", "watch-old-build", status: "completed", background: true),
        ])
        let tasks = MacHomeChatView.liveBackgroundTasks(
            in: model.selectedSession, selectedID: model.selectedSessionID, isTab: true
        )
        XCTAssertEqual(tasks.map(\.id), ["w", "q"])
        XCTAssertTrue(MacHomeChatView.liveBackgroundTasks(
            in: model.selectedSession, selectedID: model.selectedSessionID, isTab: false
        ).isEmpty, "Home's chat keeps background work behind its Background button")
        XCTAssertTrue(MacHomeChatView.liveBackgroundTasks(
            in: model.selectedSession, selectedID: "another-tab", isTab: true
        ).isEmpty, "A tab still loading must not show the previous tab's tasks")
    }

    func testFinishedBackgroundTasksHideThePill() async throws {
        let (model, _) = try await tab(subagents: [
            subagent("d", "watch-old-build", status: "completed", background: true),
        ])
        XCTAssertTrue(MacHomeChatView.liveBackgroundTasks(
            in: model.selectedSession, selectedID: model.selectedSessionID, isTab: true
        ).isEmpty)
    }

    func testHomeSessionNeverShowsThePill() async throws {
        let (model, _) = try await tab(subagents: [
            subagent("w", "watch-windows-ci", status: "running", background: true),
        ], isHome: true)
        XCTAssertTrue(MacHomeChatView.liveBackgroundTasks(
            in: model.selectedSession, selectedID: model.selectedSessionID, isTab: true
        ).isEmpty)
    }

    /// Renders for review. Set TEST_RUNNER_BACKGROUND_TASKS_ARTIFACT_DIR (pass
    /// TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testBackgroundTasksMacScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_BACKGROUND_TASKS_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_BACKGROUND_TASKS_ARTIFACT_DIR to render background tasks on the Mac.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (model, vm) = try await tab(subagents: [
            subagent("w", "watch-windows-ci", status: "running", background: true),
            subagent("q", "watch-upload", status: "queued", background: true, startedAgo: 40),
            subagent("d", "watch-old-build", status: "completed", background: true, startedAgo: 900),
        ])
        let navigation = MacHomeNavigation()
        let chat = MacHomeChatView(remote: model, vm: vm, voice: VoiceController(),
                                   navigation: navigation, slashCommands: model.slashCommands, isTab: true)
            .frame(width: 900, height: 560)
        let sheet = CantripBackgroundTasksView(remote: model, sessionID: sessionID)
            .frame(width: 620, height: 560)
        try await capture(chat, "mac-tab-background-pill", output)
        try await capture(sheet, "mac-tab-background-sheet", output)
    }

    private func capture(_ view: some View, _ name: String, _ output: URL) async throws {
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        window.setContentSize(host.fittingSize)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
