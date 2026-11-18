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
        XCTAssertTrue(reply.string.contains("the pruner now removes it"), "Paragraphs and the list share one view")
        XCTAssertFalse(reply.string.contains("12 min"), "The table is a grid of its own")
        XCTAssertGreaterThan(reply.frame.height, 40)

        func cell(_ text: String) throws -> NSTextView {
            try XCTUnwrap(textViews(in: host).first { $0.string == text }, "No cell \"\(text)\" in \(texts)")
        }
        func frame(_ text: String) throws -> CGRect { let view = try cell(text); return view.convert(view.bounds, to: nil) }
        XCTAssertEqual(try frame("Build").minX, try frame("Tests").minX, accuracy: 0.5, "Each column's cells line up")
        XCTAssertEqual(try frame("Tests").midY, try frame("12 min").midY, accuracy: 0.5, "Each row's cells line up")
        XCTAssertGreaterThan(try frame("12 min").minX, try frame("Tests").maxX)
        let time = try XCTUnwrap(cell("12 min").textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(time.alignment, .right, "Right-aligned columns stay right-aligned")
        XCTAssertTrue(try cell("12 min").isSelectable)
    }

    /// Sizing like `Text`: no room at the minimum, the unwrapped text as the ideal, wrapped to a
    /// width otherwise; measured without touching the view.
    func testSelectableTextSizesLikeText() {
        let text = CantripRichText.attributed("A long paragraph that wraps when it's narrow.\n\n- one\n- two",
                                              style: CantripRichText.Style(size: 13))
        var cache: [CGFloat: CGSize] = [:]
        let measure = { (width: CGFloat?) in CantripRichText.measure(text, width: width) }
        XCTAssertEqual(CantripRichText.fit(ProposedViewSize(width: 0, height: nil), cache: &cache, measure: measure), .zero)
        let ideal = CantripRichText.fit(.unspecified, cache: &cache, measure: measure)
        XCTAssertEqual(CantripRichText.fit(.infinity, cache: &cache, measure: measure), ideal)
        XCTAssertGreaterThan(ideal.width, 150)
        XCTAssertLessThan(ideal.width, 600)
        let narrow = CantripRichText.fit(ProposedViewSize(width: 120, height: nil), cache: &cache, measure: measure)
        XCTAssertEqual(narrow.width, 120)
        XCTAssertGreaterThan(narrow.height, ideal.height, "Narrow text wraps onto more lines")
    }

    /// A reply in a split view's detail column, as Gateway Mac and the Home window lay it out: the
    /// split view asks each column for its minimum width, and a reply that answered that with its
    /// full text width sent AppKit into an update-constraints loop that aborted the app at launch.
    func testReplyInSplitViewDetailLaysOutWithoutConstraintLoop() async throws {
        let (model, vm) = try await transcript()
        let view = NavigationSplitView {
            List { Text("Tabs") }
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } detail: {
            ScrollView { rows(model, vm) }
        }
        .frame(minWidth: 700, minHeight: 500)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        for width in [900.0, 760, 1200, 900] {
            window.setContentSize(CGSize(width: width, height: 600))
            try await Task.sleep(for: .milliseconds(150))
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
        let reply = try XCTUnwrap(textViews(in: host).first { $0.string.hasPrefix("The build passed") })
        XCTAssertLessThan(reply.frame.width, 1200, "The reply takes its column's width, not its text's")
        XCTAssertGreaterThan(reply.frame.width, 200)
        let minimum = host.fittingSize
        XCTAssertLessThan(minimum.width, 1000, "A reply doesn't raise the window's minimum width: \(minimum)")
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
