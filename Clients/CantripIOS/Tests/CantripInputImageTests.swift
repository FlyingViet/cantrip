import SwiftUI
import UIKit
import XCTest
@testable import Hermes

/// "Copilot needs your answer" questions with Mac images: the composer panel, Background
/// cards and the answered transcript copy all show them.
@MainActor
final class CantripInputImageTests: XCTestCase {
    private let sessionID = UUID().uuidString
    private let requestID = UUID()
    private let labels = ["Light — before", "Light — after", "Dark — before", "Dark — after"]

    private func imageID(_ index: Int) -> String {
        let letters: [Character] = ["a", "b", "c", "d"]
        return "previews/\(requestID.uuidString)/\(String(repeating: letters[index], count: 64)).jpg"
    }

    private var detail: String {
        "The calendar audit is complete.\n\n" + labels.enumerated().map { index, label in
            "**\(label)**\n![Calendar \(label.lowercased())](cantrip-preview://image/\(imageID(index)))"
        }.joined(separator: "\n\n") + "\n\nShould I ship both OTA updates?"
    }

    private func requestJSON(displayText: Bool = true) throws -> Data {
        var object: [String: Any] = [
            "id": requestID.uuidString, "kind": "question", "source": "Copilot",
            "title": "Copilot needs your answer", "detail": "raw paths",
            "choices": ["Ship OTA to 1.1.7 and 1.1.6 (Recommended)", "Hold"], "allowsFreeform": true,
            "expiresAt": Date().addingTimeInterval(600).timeIntervalSince1970,
        ]
        if displayText {
            object["displayText"] = detail
            object["images"] = labels.indices.map { ["id": imageID($0), "altText": "Calendar \(labels[$0].lowercased())"] }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func screenshot(_ index: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let colors: [UIColor] = [.systemBackground, .systemTeal, .black, .systemIndigo]
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 590, height: 1280), format: format)
            .image { context in
                colors[index].setFill()
                context.fill(CGRect(x: 0, y: 0, width: 590, height: 1280))
                UIColor.systemOrange.setFill()
                for row in 0..<6 { context.fill(CGRect(x: 40, y: 220 + row * 160, width: 510, height: 96)) }
            }.jpegData(compressionQuality: 0.8))
    }

    private func pairedModel(requested: @escaping (String) -> Void) async throws -> CantripRemoteModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRequestProtocol.self]
        let remote = CantripRemoteModel(urlSession: URLSession(configuration: configuration))
        let images = try labels.indices.map { (imageID($0), try screenshot($0)) }
        ImageRequestProtocol.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            if let match = images.first(where: { path.contains($0.0) }) {
                requested(path)
                return (200, try JSONSerialization.data(withJSONObject: ["data": match.1.base64EncodedString()]))
            }
            return (200, Data(#"{"sessions":[]}"#.utf8))
        }
        let configured = await remote.configure(url: "https://cantrip.example", pairingToken: "input-image-fixture")
        XCTAssertTrue(configured, remote.errorMessage ?? "")
        return remote
    }

    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String,
                                 until ready: () -> Bool) async throws -> UIHostingController<V> {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = UIHostingController(rootView: view)
        controller.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<30 where !ready() { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(400))
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return controller
    }

    func testStandaloneImageLinesBecomeBlocksOutsideCode() {
        let text = "**Before**\n![A](cantrip-preview://image/a)\n![B](/Users/me/b.png)\nAfter\r\n"
            + "  ![C](https://example.com/c.png)\r\nTail with ![inline](x) image\n```\n**Code**\n![D](d)\n```"
        XCTAssertEqual(ChatMarkdownImages.separatingBlocks(text),
                       "**Before**\n\n![A](cantrip-preview://image/a)\n![B](/Users/me/b.png)\n\nAfter\r\n\n"
                       + "  ![C](https://example.com/c.png)\r\n\nTail with ![inline](x) image\n```\n**Code**\n![D](d)\n```")
        let separated = ChatMarkdownImages.separatingBlocks(text)
        XCTAssertEqual(ChatMarkdownImages.separatingBlocks(separated), separated, "already separated text is stable")
        XCTAssertEqual(ChatMarkdownImages.separatingBlocks("No images here"), "No images here")
    }

    func testQuestionDecodesPreviewsAndSplitsThemIntoARow() throws {
        let request = try JSONDecoder().decode(CantripInputRequest.self, from: requestJSON())
        let parts = request.presentation(sessionID: sessionID)
        XCTAssertEqual(parts.previews.map(\.id), labels.indices.map(imageID))
        XCTAssertEqual(parts.previews.map(\.image.sessionID), Array(repeating: sessionID, count: 4))
        XCTAssertEqual(parts.previews.map(\.caption), labels, "the bold label above each image captions it")
        XCTAssertEqual(parts.previews.first?.image.altText, "Calendar light — before")
        XCTAssertEqual(parts.text, "The calendar audit is complete.\n\n\n\n\n\n"
                       + "Should I ship both OTA updates?")
        XCTAssertFalse(parts.text.contains("cantrip-preview"))

        let images = [ChatMessageImage(id: imageID(0), sessionID: sessionID, altText: "Header shot")]
        let mixed = ChatMarkdownImages.extractingPreviews(
            "## Screens\nIntro line\n![Header shot](cantrip-preview://image/\(imageID(0)))\n"
                + "**Not a label** because text follows\n![Other](cantrip-preview://image/\(imageID(1)))",
            images: images
        )
        XCTAssertEqual(mixed.previews, [ChatPreviewTile(image: images[0], caption: "Header shot")],
                       "only a label directly above an image captions it; unknown previews stay in the text")
        XCTAssertEqual(mixed.text, "## Screens\nIntro line\n**Not a label** because text follows\n"
                       + "![Other](cantrip-preview://image/\(imageID(1)))")

        let legacy = try JSONDecoder().decode(CantripInputRequest.self, from: requestJSON(displayText: false))
        let plain = legacy.presentation(sessionID: sessionID)
        XCTAssertEqual(plain.text, "raw paths", "older Macs keep the original text")
        XCTAssertTrue(plain.previews.isEmpty && plain.images.isEmpty)
    }

    func testQuestionPanelShowsThumbnailRowAndOpensPreviewsThroughPairing() async throws {
        var requested: [String] = []
        let remote = try await pairedModel { requested.append($0) }
        defer { remote.clearConfiguration(); ImageRequestProtocol.handler = nil }
        let request = try JSONDecoder().decode(CantripInputRequest.self, from: requestJSON())
        // The second layout reuses the paired image cache, so only the first one fetches.
        for (width, size) in [(CGFloat(390), DynamicTypeSize.large), (320, .accessibility3)] {
            let panel = CantripQuestionPanel(request: request, maxHeight: 320, sessionID: sessionID,
                                             remote: remote) { _ in }
                .environment(\.dynamicTypeSize, size)
                .background(Color(.systemBackground))
            let controller = try await render(panel, width: width, height: 420,
                                              name: "Question panel \(Int(width)) \(size)") {
                Set(requested).count >= 3
            }
            let fit = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(fit.height, 321, "The panel stays within its height and scrolls")
            XCTAssertTrue(requested.allSatisfy { $0.hasPrefix("/api/v1/sessions/\(sessionID)/previews/") && $0.hasSuffix("/thumbnail") },
                          "\(requested)")
            XCTAssertGreaterThanOrEqual(Set(requested).count, 3, "Visible thumbnails load: \(requested)")
            XCTAssertLessThanOrEqual(Set(requested).count, 4)
        }
    }

    func testBackgroundCardShowsQuestionImagesInPlace() async throws {
        var requested: [String] = []
        let remote = try await pairedModel { requested.append($0) }
        defer { remote.clearConfiguration(); ImageRequestProtocol.handler = nil }
        let request = try JSONDecoder().decode(CantripInputRequest.self, from: requestJSON())
        let card = ScrollView {
            CantripInputCard(request: request, busy: false, sessionID: sessionID, remote: remote) { _ in }
                .padding(16)
        }
        .background(Color(.systemBackground))
        _ = try await render(card, width: 390, height: 844, name: "Background question card 390") {
            Set(requested).count >= 3
        }
        XCTAssertGreaterThanOrEqual(Set(requested).count, 3, "\(requested)")

        let approval = CantripInputRequest(
            id: UUID(), kind: "approval", source: "Copilot", title: "Allow shell?", detail: "rm **/*.tmp",
            choices: [], allowsFreeform: false, url: nil, code: nil,
            expiresAt: Date().addingTimeInterval(600).timeIntervalSince1970
        )
        let parts = approval.presentation(sessionID: sessionID)
        XCTAssertEqual(parts.text, "rm **/*.tmp")
        XCTAssertTrue(parts.previews.isEmpty)
    }

    /// the user's answered question: each image sits right under a bold label with no blank line.
    func testAnsweredQuestionImagesUnderLabelsRenderInTranscript() async throws {
        var requested: [String] = []
        let remote = try await pairedModel { requested.append($0) }
        defer { remote.clearConfiguration(); ImageRequestProtocol.handler = nil }
        let images = labels.indices.map {
            ChatMessageImage(id: imageID($0), sessionID: sessionID, altText: "Calendar \(labels[$0].lowercased())")
        }
        let text = "Copilot needs your answer\n\n" + detail
        let reply = ScrollView {
            ChatAssistantText(text: text, images: images, remote: remote).padding(16)
        }
        .background(Color(.systemBackground))
        let controller = try await render(reply, width: 390, height: 844, name: "Answered question transcript 390") {
            Set(requested).count >= 2
        }
        controller.view.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(Set(requested).count, 2,
                                    "Images directly under text load as block previews: \(requested)")
    }
}
