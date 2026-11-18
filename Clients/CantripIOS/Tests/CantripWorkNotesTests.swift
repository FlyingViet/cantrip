import SwiftUI
import UIKit
import XCTest
@testable import Hermes

/// Progress notes fold above a reply's answer, and reply text selects across paragraphs.
@MainActor
final class CantripWorkNotesTests: XCTestCase {
    private let sessionID = "00000000-0000-0000-0000-0000000000a7"

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

    // MARK: - Fold

    func testWorkFoldSplitsNotesFromTheAnswer() throws {
        let message = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(#"""
        {"id":"m1","role":"assistant","text":"x","thinking":"","activities":[],
         "work":{"noteBlocks":2,"notes":2,"steps":5,"hasAnswer":true}}
        """#.utf8))
        let work = try XCTUnwrap(message.work)
        XCTAssertEqual(work, CantripRemoteWork(noteBlocks: 2, notes: 2, steps: 5, hasAnswer: true))

        let text = notes + "\n\n" + answer
        let fold = try XCTUnwrap(CantripWorkFold.make(text: text, work: work, streaming: false))
        XCTAssertEqual(fold.notes, notes)
        XCTAssertEqual(fold.answer, answer)
        XCTAssertEqual(fold.summary, "2 notes · 5 steps")
        XCTAssertEqual(fold.latestNote, "Found the failing step; reading the test output.")
        XCTAssertFalse(fold.working)

        let agent = CantripRemoteSubagent(id: "a", agentID: "a", status: .completed)
        let split = fold.place([(block: 1, subagents: [agent]), (block: 4, subagents: [agent])])
        XCTAssertEqual(split.notes.map(\.block), [1], "A card placed within the notes stays with them")
        XCTAssertEqual(split.answer.map(\.block), [2], "Answer cards count blocks from the answer")

        let streaming = CantripRemoteWork(noteBlocks: 2, notes: 2, steps: 3, hasAnswer: false)
        XCTAssertEqual(CantripWorkFold.make(text: notes, work: streaming, streaming: true)?.working, true,
                       "While running, the notes fold behind Working")
        XCTAssertNil(CantripWorkFold.make(text: notes, work: streaming, streaming: false),
                     "A finished run with no answer after its notes shows them in full")
        XCTAssertNil(CantripWorkFold.make(text: text, work: nil, streaming: false), "Older Macs send no split")
    }

    // MARK: - Rendering

    private func transcript(_ messages: [[String: Any]], streaming: Bool = false) async throws
        -> (CantripRemoteModel, ChatViewModel) {
        let model = try StartFreshFixture.model(for: self)
        var session: [String: Any] = [
            "id": sessionID, "title": "Studio Builds", "workdir": "/tmp", "isStreaming": streaming,
            "canResume": false, "councilMode": false, "queuedCount": 0, "messages": messages,
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

    private func messages(work: Bool, streaming: Bool = false) -> [[String: Any]] {
        var reply: [String: Any] = [
            "id": "r1", "role": "assistant", "thinking": "", "activities": [],
            "text": streaming ? notes : notes + "\n\n" + answer,
        ]
        if work {
            reply["work"] = ["noteBlocks": 2, "notes": 2, "steps": streaming ? 3 : 5, "hasAnswer": !streaming]
        }
        return [["id": "p1", "role": "user", "text": "Why did the build fail?", "thinking": "", "activities": []], reply]
    }

    private func hosted(_ view: some View, width: CGFloat = 393, height: CGFloat = 760,
                        style: UIUserInterfaceStyle = .light) async throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIHostingController(rootView: view)
        controller.overrideUserInterfaceStyle = style
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutIfNeeded()
        return window
    }

    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews(in:))
    }

    func testAnswerIsOneSelectableTextAndNotesFold() async throws {
        let (model, vm) = try await transcript(messages(work: true))
        let window = try await hosted(WorkNotesTranscript(remote: model, vm: vm))
        defer { window.isHidden = true }
        let views = textViews(in: window)
        let texts = views.map { $0.attributedText.string }
        XCTAssertFalse(texts.contains { $0.contains("Checking the build log") }, "Notes stay folded: \(texts)")
        let reply = try XCTUnwrap(views.first { $0.attributedText.string.hasPrefix("The build passed") }, "\(texts)")
        XCTAssertTrue(reply.isSelectable && !reply.isEditable)
        XCTAssertTrue(reply.attributedText.string.contains("the pruner now removes it"), "Paragraphs and the list share one view")
        XCTAssertFalse(reply.attributedText.string.contains("12 min"), "The table is a grid of its own")
        XCTAssertGreaterThan(reply.bounds.height, 60)
        let tests = try XCTUnwrap(views.first { $0.attributedText.string == "Tests" }, "\(texts)")
        let time = try XCTUnwrap(views.first { $0.attributedText.string == "12 min" }, "\(texts)")
        XCTAssertTrue(tests.isSelectable && time.isSelectable)
        XCTAssertEqual(tests.convert(tests.bounds, to: window).midY, time.convert(time.bounds, to: window).midY, accuracy: 0.5,
                       "A row's cells line up")

        // A selection across paragraphs and list items copies as plain lines.
        reply.selectedRange = NSRange(location: 0, length: (reply.attributedText.string as NSString).range(of: "pruner").location)
        reply.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string,
                       "The build passed after one fix.\n•\tCause: a stale cache in DerivedData.\n•\tFix: the ")
    }

    /// Renders replies for review. Set TEST_RUNNER_WORK_NOTES_ARTIFACT_DIR (pass
    /// TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testWorkNotesScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_WORK_NOTES_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_WORK_NOTES_ARTIFACT_DIR to render the replies.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func capture(_ view: some View, _ name: String, style: UIUserInterfaceStyle, width: CGFloat = 393,
                     height: CGFloat = 760, size: DynamicTypeSize = .large,
                     select: ((UITextView) -> Void)? = nil) async throws {
            let window = try await hosted(view.dynamicTypeSize(size), width: width, height: height, style: style)
            defer { window.isHidden = true }
            if let select, let reply = textViews(in: window).first(where: { $0.attributedText.string.hasPrefix("The build") }) {
                reply.becomeFirstResponder()
                select(reply)
                try await Task.sleep(for: .milliseconds(300))
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let data = try XCTUnwrap(image.pngData())
            try data.write(to: output.appendingPathComponent("ios-\(name).png"))
        }
        let (folded, foldedVM) = try await transcript(messages(work: true))
        let (expanded, expandedVM) = try await transcript(messages(work: true))
        let (running, runningVM) = try await transcript(messages(work: true, streaming: true), streaming: true)
        let (older, olderVM) = try await transcript(messages(work: false))
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            try await capture(WorkNotesTranscript(remote: folded, vm: foldedVM), "folded-\(name)", style: style)
            try await capture(WorkNotesTranscript(remote: expanded, vm: expandedVM, expanded: true), "expanded-\(name)", style: style)
            try await capture(WorkNotesTranscript(remote: running, vm: runningVM), "working-\(name)", style: style)
        }
        try await capture(WorkNotesTranscript(remote: older, vm: olderVM), "no-split-light", style: .light)
        try await capture(WorkNotesTranscript(remote: folded, vm: foldedVM), "selection-light", style: .light) { reply in
            reply.selectedRange = NSRange(location: 0, length: (reply.attributedText.string as NSString).range(of: "pruner").location)
        }
        try await capture(WorkNotesTranscript(remote: folded, vm: foldedVM), "folded-ax-dark", style: .dark,
                          width: 320, height: 1300, size: .accessibility3)
    }
}

private struct WorkNotesTranscript: View {
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject var vm: ChatViewModel
    var expanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(vm.turns) { turn in
                    TurnView(turn: turn, remote: remote, cantripSessionID: remote.selectedSessionID,
                             remoteMessage: vm.remoteMessage(for: turn.id))
                }
            }
            .padding()
        }
        .environment(\.cantripWorkNotesExpanded, expanded)
        .background(Color(.systemBackground))
    }
}
