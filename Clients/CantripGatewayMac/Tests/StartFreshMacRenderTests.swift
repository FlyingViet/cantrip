import AppKit
import SwiftUI
import XCTest
@testable import Hermes

/// Start Fresh's divider and repeated-error actions as the Mac's transcript shows them.
@MainActor
final class StartFreshMacRenderTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-0000000000f3"
    private let failure = "Execution failed: 400 The requested model is not supported"

    private func message(_ id: String, _ role: String, _ text: String) -> [String: Any] {
        ["id": id, "role": role, "text": text, "thinking": "", "activities": []]
    }

    private func transcript(_ messages: [[String: Any]], repeatedError: String? = nil) async throws
        -> (CantripRemoteModel, ChatViewModel) {
        let model = try StartFreshFixture.model(for: self)
        var session: [String: Any] = [
            "id": sessionID, "title": "Plexa", "workdir": "/tmp", "isStreaming": false,
            "canResume": false, "councilMode": false, "queuedCount": 0,
            "supportsStartFresh": true, "supportsModelSettings": true, "messages": messages,
        ]
        if let repeatedError { session["repeatedErrorMessageID"] = repeatedError }
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

    private func rows(_ model: CantripRemoteModel, _ vm: ChatViewModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(vm.turns) { turn in
                TurnView(turn: turn, remote: model, cantripSessionID: model.selectedSessionID,
                         remoteMessage: vm.remoteMessage(for: turn.id))
            }
        }
        .padding(20)
        .frame(width: 640, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Renders for review. Set TEST_RUNNER_START_FRESH_ARTIFACT_DIR (pass
    /// TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testStartFreshMacScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_START_FRESH_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_START_FRESH_ARTIFACT_DIR to render Start Fresh on the Mac.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (dividerModel, dividerVM) = try await transcript([
            message("p1", "user", "Ship the beta build"),
            message("r1", "assistant", "Shipped build 1.4 (210) to TestFlight."),
            message("f1", "freshStart", CantripStartFresh.defaultCaption),
            message("p2", "user", "Draft the release notes"),
            message("r2", "assistant", "Here are the release notes for 1.4: faster sync and a new widget."),
        ])
        let (errorModel, errorVM) = try await transcript([
            message("p1", "user", "What's the admin password for the router?"),
            message("r1", "assistant", "I can't help find or reveal passwords."),
            message("p2", "user", "Ship the beta build"),
            message("e1", "error", failure),
            message("p3", "user", "Try again"),
            message("e2", "error", failure),
        ], repeatedError: "e2")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await capture(rows(dividerModel, dividerVM), "mac-divider-\(name)", appearance, output)
            try await capture(rows(errorModel, errorVM), "mac-error-actions-\(name)", appearance, output)
        }
    }

    private func capture(_ view: some View, _ name: String, _ appearance: NSAppearance.Name,
                         _ output: URL) async throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        defer { window.close() }
        window.setContentSize(host.fittingSize)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
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
