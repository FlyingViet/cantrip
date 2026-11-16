import AppKit
import SwiftUI
import XCTest
@testable import Hermes

/// Progress notes folded above the answer, and a selection across the answer's paragraphs, as
/// Gateway Mac and the Home window draw them.
@MainActor
final class WorkNotesMacRenderTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-0000000000f4"
    private let notes = "Checking the build log first.\n\nFound the failing step; reading the test output."
    private let answer = """
    The build passed after one fix.

    - **Cause:** a stale cache in `DerivedData`.
    - **Fix:** the pruner now removes it.

    | Step | Time |
    |---|---:|
    | Build | 4 min |
    | Tests | 12 min |
    """

    private func transcript(streaming: Bool = false) async throws -> (CantripRemoteModel, ChatViewModel) {
        let model = try StartFreshFixture.model(for: self)
        let reply: [String: Any] = [
            "id": "r1", "role": "assistant", "thinking": "", "activities": [],
            "text": streaming ? notes : notes + "\n\n" + answer,
            "work": ["noteBlocks": 2, "notes": 2, "steps": streaming ? 3 : 5, "hasAnswer": !streaming],
        ]
        var session: [String: Any] = [
            "id": sessionID, "title": "Studio Builds", "workdir": "/tmp", "isStreaming": streaming,
            "canResume": false, "councilMode": false, "queuedCount": 0,
            "messages": [["id": "p1", "role": "user", "text": "Why did the build fail?", "thinking": "", "activities": []], reply],
        ]
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

    private func rows(_ model: CantripRemoteModel, _ vm: ChatViewModel, expanded: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(vm.turns) { turn in
                TurnView(turn: turn, remote: model, cantripSessionID: model.selectedSessionID,
                         remoteMessage: vm.remoteMessage(for: turn.id))
            }
        }
        .padding(20)
        .frame(width: 560, alignment: .topLeading)
        .environment(\.cantripWorkNotesExpanded, expanded)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews(in:))
    }

    private func hosted(_ view: some View, _ appearance: NSAppearance.Name) async throws -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    func testAnswerIsOneSelectableTextAndNotesFold() async throws {
        let (model, vm) = try await transcript()
        let (window, host) = try await hosted(rows(model, vm), .aqua)
        defer { window.close() }
        let texts = textViews(in: host).map(\.string)
        XCTAssertFalse(texts.contains { $0.contains("Checking the build log") }, "Notes stay folded: \(texts)")
        let reply = try XCTUnwrap(textViews(in: host).first { $0.string.hasPrefix("The build passed") }, "\(texts)")
        XCTAssertTrue(reply.isSelectable && !reply.isEditable)
        XCTAssertTrue(reply.string.contains("Tests\t12 min"), "Paragraphs, list and table share one view")
        XCTAssertGreaterThan(reply.frame.height, 80)
    }

    /// Renders for review. Set TEST_RUNNER_WORK_NOTES_ARTIFACT_DIR (pass TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testWorkNotesMacScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_WORK_NOTES_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_WORK_NOTES_ARTIFACT_DIR to render the fold on the Mac.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (done, doneVM) = try await transcript()
        let (running, runningVM) = try await transcript(streaming: true)
        func capture(_ view: some View, _ name: String, _ appearance: NSAppearance.Name, select: Bool = false) async throws {
            let (window, host) = try await hosted(view, appearance)
            defer { window.close() }
            if select, let reply = textViews(in: host).first(where: { $0.string.hasPrefix("The build") }) {
                window.makeFirstResponder(reply)
                reply.setSelectedRange(NSRange(location: 0, length: (reply.string as NSString).range(of: "pruner").location))
                try await Task.sleep(for: .milliseconds(200))
            }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(name).png"))
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await capture(rows(done, doneVM), "homewindow-folded-\(name)", appearance)
            try await capture(rows(done, doneVM, expanded: true), "homewindow-expanded-\(name)", appearance)
            try await capture(rows(running, runningVM), "homewindow-working-\(name)", appearance)
        }
        try await capture(rows(done, doneVM), "homewindow-selection-light", .aqua, select: true)
    }
}
