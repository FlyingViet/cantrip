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
}
