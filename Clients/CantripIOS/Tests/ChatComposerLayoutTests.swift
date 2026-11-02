import SwiftUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
final class ChatComposerLayoutTests: XCTestCase {
    private func session(streaming: Bool) throws -> CantripRemoteSession {
        try JSONDecoder().decode(CantripRemoteSession.self, from: Data("""
        {"id":"tab","title":"Project","workdir":"/tmp","isStreaming":\(streaming),
        "canResume":false,"councilMode":false,"isLocked":true,"queuedCount":2,
        "messages":[]}
        """.utf8))
    }

    func testComposerKeepsAttachmentsLeftAndStopBesideSendWithoutOverlap() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        for width: CGFloat in [320, 393, 768] {
            for size: DynamicTypeSize in [.large, .accessibility5] {
                for state in ["idle", "working", "stopping", "disconnected", "importing"] {
                    var attachFrame = CGRect.zero
                    var messageFrame = CGRect.zero
                    var stopFrame = CGRect.zero
                    var sendFrame = CGRect.zero
                    var composerFrame = CGRect.zero
                    let stop = CantripStopButton(
                        session: try session(streaming: state != "idle"),
                        isConnected: state != "disconnected",
                        isMutating: state == "stopping", isStopping: state == "stopping",
                        iconOnly: true, onStop: { _ in }
                    )
                    let composer = ChatComposer {
                        ImageAttachmentPicker(
                            attachments: .constant([]),
                            importID: .constant(state == "importing" ? UUID() : nil),
                            imageSupport: true, disabled: false
                        )
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            attachFrame = $0
                        }
                    } message: {
                        TextField("Message Cantrip", text: .constant("Next message"), axis: .vertical)
                            .textFieldStyle(.plain).lineLimit(1...5)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                messageFrame = $0
                            }
                    } trailing: {
                        stop
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                stopFrame = $0
                            }
                        Button {} label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                                .frame(width: 44, height: 44)
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            sendFrame = $0
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        composerFrame = $0
                    }
                    let content = VStack {
                        Spacer()
                        composer.padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    .environment(\.dynamicTypeSize, size)
                    let controller = UIHostingController(rootView: content)
                    // These fixture widths describe usable content, not the display plus its system rail.
                    controller.safeAreaRegions = []
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                    window.rootViewController = controller
                    window.makeKeyAndVisible()
                    defer { window.isHidden = true }
                    controller.view.layoutIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    XCTAssertEqual(composerFrame.width, width - 32, accuracy: 1)
                    XCTAssertEqual(attachFrame.width, 44, accuracy: 1)
                    XCTAssertEqual(attachFrame.height, 44, accuracy: 1)
                    XCTAssertEqual(sendFrame.width, 44, accuracy: 1)
                    XCTAssertEqual(sendFrame.height, 44, accuracy: 1)
                    XCTAssertGreaterThanOrEqual(messageFrame.width, 120)
                    XCTAssertLessThanOrEqual(attachFrame.maxX, messageFrame.minX)
                    XCTAssertLessThanOrEqual(messageFrame.maxX, sendFrame.minX)
                    XCTAssertTrue(composerFrame.contains(attachFrame))
                    XCTAssertTrue(composerFrame.contains(sendFrame))
                    if state != "idle" {
                        XCTAssertEqual(stopFrame.size, CGSize(width: 44, height: 44))
                        XCTAssertLessThanOrEqual(messageFrame.maxX, stopFrame.minX)
                        XCTAssertLessThanOrEqual(stopFrame.maxX, sendFrame.minX)
                        XCTAssertTrue(composerFrame.contains(stopFrame))
                        XCTAssertEqual(stop.isEnabled, state == "working" || state == "importing")
                    } else {
                        XCTAssertFalse(stop.isVisible)
                    }
                    if width == 320 && (state == "working" || state == "stopping") {
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        let attachment = XCTAttachment(image: image)
                        attachment.name = "composer-\(state)-\(size)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                }
            }
        }
    }

    func testImagePreviewsRemainAboveTheComposerAtNarrowAndLargeTextSizes() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let attachments = (0..<4).map { _ in ChatImageAttachment(data: data) }
        for size: DynamicTypeSize in [.large, .accessibility5] {
            let previews = ImageAttachmentPreviews(
                attachments: .constant(attachments), remote: CantripRemoteModel(),
                disabled: false, isImporting: false
            )
            .environment(\.dynamicTypeSize, size)
            let controller = UIHostingController(rootView: previews)
            controller.safeAreaRegions = []
            let measured = controller.sizeThatFits(in: CGSize(width: 288, height: 1000))
            XCTAssertLessThanOrEqual(measured.width, 288)
            XCTAssertGreaterThanOrEqual(measured.height, 80)
            XCTAssertLessThan(measured.height, 150)
        }
    }

    private func question(choices: Bool = true) -> CantripInputRequest {
        CantripInputRequest(
            id: UUID(), kind: "question", source: "Copilot", title: "Copilot needs your answer",
            detail: choices ? "The demo key did not unlock. What happened on your device?" : "What should we call it?",
            choices: choices ? [
                "The secure sheet appeared, and I entered cantrip-demo-123",
                "The secure sheet appeared, but I canceled or entered something different",
                "No secure sheet appeared"
            ] : [],
            allowsFreeform: true, url: nil, code: nil,
            expiresAt: Date().addingTimeInterval(600).timeIntervalSince1970
        )
    }

    func testQuestionExtendsComposerAndKeepsReplyVisibleAtKeyboardAndAccessibleSizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for width: CGFloat in [320, 393, 768] {
            for height: CGFloat in [700, 300] {
                for size: DynamicTypeSize in [.large, .accessibility5] {
                    let maximum = min(320, height * 0.45)
                    let request = question()
                    var composerFrame = CGRect.zero
                    var questionFrame = CGRect.zero
                    var messageFrame = CGRect.zero
                    let view = VStack(spacing: 0) {
                        ScrollView {
                            Text("Your reply reached me. Now let's try a password prompt using a throwaway SSH key.")
                                .frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                        ChatComposer {
                            Image(systemName: "plus.circle").font(.system(size: 24)).frame(width: 44, height: 44)
                        } message: {
                            TextField("Your reply", text: .constant("Reply"), axis: .vertical)
                                .textFieldStyle(.plain).lineLimit(1...5)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                    messageFrame = $0
                                }
                        } trailing: {
                            Image(systemName: "stop.fill").font(.system(size: 14)).frame(width: 44, height: 44)
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).frame(width: 44, height: 44)
                        } accessory: {
                            CantripQuestionPanel(request: request, maxHeight: maximum) { _ in }
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                    questionFrame = $0
                                }
                            Divider().padding(.horizontal, 12)
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            composerFrame = $0
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    .environment(\.dynamicTypeSize, size)
                    .preferredColorScheme(.dark)
                    let controller = UIHostingController(rootView: view)
                    controller.safeAreaRegions = []
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: width, height: height)
                    window.rootViewController = controller
                    window.makeKeyAndVisible()
                    defer { window.isHidden = true; window.rootViewController = nil }
                    try await Task.sleep(for: .milliseconds(150))
                    controller.view.layoutIfNeeded()
                    XCTAssertEqual(composerFrame.width, width - 32, accuracy: 1)
                    XCTAssertGreaterThan(questionFrame.height, 44)
                    XCTAssertLessThanOrEqual(questionFrame.height, maximum + 1)
                    XCTAssertTrue(composerFrame.insetBy(dx: -1, dy: -1).contains(questionFrame))
                    XCTAssertTrue(composerFrame.insetBy(dx: -1, dy: -1).contains(messageFrame))
                    XCTAssertLessThanOrEqual(questionFrame.maxY, messageFrame.minY)
                    XCTAssertLessThanOrEqual(composerFrame.maxY, height)
                    XCTAssertGreaterThanOrEqual(composerFrame.minY, 0)
                    let views = descendants(controller.view)
                    XCTAssertEqual(views.filter { $0 is UITextField || ($0 as? UITextView)?.isEditable == true }.count, 1)
                    for field in views.compactMap({ $0 as? UITextView }) where field.isEditable {
                        XCTAssertGreaterThanOrEqual(field.bounds.height, field.font?.lineHeight ?? 0)
                    }
                    for scroll in views.compactMap({ $0 as? UIScrollView }) where scroll.bounds.width > 0 {
                        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                    }
                    if size.isAccessibilitySize {
                        let questionScroll = try XCTUnwrap(views.compactMap { $0 as? UIScrollView }.first {
                            !($0 is UITextView)
                                && abs($0.convert($0.bounds, to: window).minY - questionFrame.minY) < 1
                        })
                        XCTAssertGreaterThan(questionScroll.contentSize.height, questionScroll.bounds.height)
                        questionScroll.setContentOffset(
                            CGPoint(x: 0, y: questionScroll.contentSize.height - questionScroll.bounds.height),
                            animated: false
                        )
                        try await Task.sleep(for: .milliseconds(50))
                        XCTAssertGreaterThan(questionScroll.contentOffset.y, 0,
                                             "Long choices must remain reachable above the pinned reply field")
                    }
                    let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    })
                    attachment.name = "question-composer-\(Int(width))x\(Int(height))-\(size)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    func testShortQuestionDoesNotReserveTheMaximumHeight() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var panelHeight: CGFloat = 0
        let view = VStack {
            Spacer()
            CantripQuestionPanel(request: question(choices: false), maxHeight: 300) { _ in }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        }
        let controller = UIHostingController(rootView: view)
        controller.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 361, height: 600)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(200))
        controller.view.layoutIfNeeded()
        XCTAssertGreaterThan(panelHeight, 44)
        XCTAssertLessThan(panelHeight, 150)
    }

    func testAddingSwitchingAndResolvingQuestionPreservesTheMessageFieldAndDraft() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = QuestionComposerState()
        let controller = UIHostingController(rootView: QuestionComposerHarness(state: state))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(150))
        let original = try XCTUnwrap(descendants(controller.view).first {
            $0 is UITextField || ($0 as? UITextView)?.isEditable == true
        })
        for request in [question(), question(choices: false), nil] {
            state.question = request
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            let current = try XCTUnwrap(descendants(controller.view).first {
                $0 is UITextField || ($0 as? UITextView)?.isEditable == true
            })
            XCTAssertTrue(original === current, "The reply must extend the existing composer, not replace its field")
            XCTAssertEqual(state.draft, "Keep my draft")
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor
private final class QuestionComposerState: ObservableObject {
    @Published var question: CantripInputRequest?
    @Published var draft = "Keep my draft"
}

private struct QuestionComposerHarness: View {
    @ObservedObject var state: QuestionComposerState

    var body: some View {
        VStack {
            Spacer()
            ChatComposer {
                Image(systemName: "plus.circle").frame(width: 44, height: 44)
            } message: {
                TextField("Your reply", text: $state.draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } trailing: {
                Image(systemName: "arrow.up.circle.fill").frame(width: 44, height: 44)
            } accessory: {
                if let question = state.question {
                    CantripQuestionPanel(request: question) { _ in }
                    Divider()
                }
            }
        }
    }
}
