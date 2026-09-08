import SwiftUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
final class ChatImagePreviewTests: XCTestCase {
    private func imageData() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 600), format: format)
            .image { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
                UIColor.systemYellow.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 300, height: 600))
            }.jpegData(compressionQuality: 0.8))
    }

    func testRemotePresentationRetainsOriginalPromptAndSupportsOldHosts() throws {
        let id = UUID().uuidString + "/image-1.jpg"
        let original = "Look\n\n(Attached image: /Mac/path.jpg - view this image file; it is part of my request.)"
        var fields: [String: Any] = [
            "id": "message", "role": "user", "text": original, "thinking": "", "activities": [],
        ]
        func decode() throws -> CantripRemoteMessage {
            try JSONDecoder().decode(CantripRemoteMessage.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        let legacy = try decode()
        XCTAssertEqual(legacy.presentedText, original)
        XCTAssertNil(legacy.images)
        fields["displayText"] = "Look"
        fields["images"] = [["id": id]]
        let message = try decode()
        XCTAssertEqual(message.text, original, "The provider prompt is not rewritten")
        XCTAssertEqual(message.presentedText, "Look")
        XCTAssertEqual(message.images?.first?.inSession("session").sessionID, "session")
        XCTAssertEqual(message.images?.first?.id, id)
        let queue = try JSONDecoder().decode(CantripRemoteQueuedPrompt.self,
            from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(queue.presentedText, "Look")
        XCTAssertEqual(queue.images, message.images)
    }

    func testExistingSavedTurnsDecodeWithoutImagesAndNewReferencesRoundTrip() throws {
        let old = try JSONDecoder().decode(ChatTurn.self, from: JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "role": "user", "text": "hello",
            "tools": [], "actions": [], "streaming": false,
        ]))
        XCTAssertNil(old.images)
        let source = ChatMessageImage(ChatImageAttachment(data: try imageData()))
        let turn = ChatTurn(role: .user, images: [source])
        XCTAssertFalse(turn.isEmpty)
        let restored = try JSONDecoder().decode(ChatTurn.self, from: JSONEncoder().encode(turn))
        XCTAssertEqual(restored.images, [source])
    }

    func testPreviewDecodeIsBoundedWhileFullImageKeepsUploadedPixels() throws {
        let data = try imageData()
        let thumbnail = try ChatImageDecoder.decode(data, maximumDimension: 320)
        let full = try ChatImageDecoder.decode(data, maximumDimension: 2048)
        XCTAssertEqual(thumbnail.size, CGSize(width: 320, height: 160))
        XCTAssertEqual(full.size, CGSize(width: 1200, height: 600))
        XCTAssertThrowsError(try ChatImageDecoder.decode(Data("bad image".utf8), maximumDimension: 320))
    }

    func testFullImageFitsWithoutCroppingAndSupportsZoomPanAndRotation() throws {
        let image = try ChatImageDecoder.decode(imageData(), maximumDimension: 2048)
        let view = ChatImageScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        view.setImage(image)
        view.layoutIfNeeded()
        XCTAssertEqual(view.minimumZoomScale, 320 / 1200, accuracy: 0.001)
        XCTAssertEqual(view.zoomScale, view.minimumZoomScale, accuracy: 0.001)
        XCTAssertEqual(view.contentSize.width, 320, accuracy: 1)
        XCTAssertEqual(view.contentSize.height, 160, accuracy: 1)
        let picture = try XCTUnwrap(view.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertEqual(picture.center.y, 300, accuracy: 1)
        view.setZoomScale(view.maximumZoomScale, animated: false)
        view.layoutIfNeeded()
        XCTAssertGreaterThan(view.contentSize.width, view.bounds.width)
        view.contentOffset = CGPoint(x: 90, y: 0)
        view.layoutIfNeeded()
        XCTAssertEqual(view.contentOffset.x, 90, accuracy: 1, "Layout must not reset a user's pan")
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 320)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 0.5, accuracy: 0.001)
        XCTAssertEqual(view.contentSize.height, 300, accuracy: 1)
    }

    func testFullScreenViewerLoadsTheUploadedImage() async throws {
        let source = ChatMessageImage(ChatImageAttachment(data: try imageData()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIHostingController(rootView: ChatImageViewer(
            source: source, remote: CantripRemoteModel(), index: 0
        ))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        func findImage(in view: UIView) -> ChatImageScrollView? {
            if let image = view as? ChatImageScrollView { return image }
            return view.subviews.lazy.compactMap { findImage(in: $0) }.first
        }
        let image = try XCTUnwrap(findImage(in: controller.view))
        XCTAssertGreaterThan(image.bounds.height, 400)
        XCTAssertEqual(image.zoomScale, image.minimumZoomScale, accuracy: 0.001)
        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        let screenshot = renderer.image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Full uploaded image"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFourThumbnailsFitNarrowAndAccessibilityLayouts() async throws {
        let data = try imageData()
        let images = (0..<4).map { _ in ChatMessageImage(ChatImageAttachment(data: data)) }
        let remote = CantripRemoteModel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for width: CGFloat in [240, 320, 768] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let root = ChatImageGallery(images: images, remote: remote)
                    .padding(14)
                    .environment(\.dynamicTypeSize, size)
                let controller = UIHostingController(rootView: root)
                let window = UIWindow(windowScene: scene)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 350)
                try await Task.sleep(for: .milliseconds(250))
                controller.view.layoutIfNeeded()
                let fit = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                XCTAssertLessThanOrEqual(fit.width, width)
                XCTAssertLessThan(fit.height, 300)
                let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
                let image = renderer.image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Image thumbnails \(Int(width)) \(size)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
