import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class ArtifactThumbnailRequestProtocol: URLProtocol {
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
final class CantripArtifactThumbnailTests: XCTestCase {
    private let homeID = "7EAE0CE5-8C8B-4652-9FD0-214867A90E5D"

    private func jpeg(_ colors: [UIColor], width: CGFloat = 600, height: CGFloat = 400) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .image { context in
                for (index, color) in colors.enumerated() {
                    color.setFill()
                    let band = height / CGFloat(colors.count)
                    context.fill(CGRect(x: 0, y: CGFloat(index) * band, width: width, height: band))
                }
                UIColor.white.withAlphaComponent(0.85).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: width * 0.62, y: height * 0.12, width: 70, height: 70))
            }.jpegData(compressionQuality: 0.8))
    }

    private func payload(_ data: Data, duration: Double? = nil) throws -> Data {
        var object: [String: Any] = ["data": data.base64EncodedString(), "width": 600, "height": 400]
        if let duration { object["durationSeconds"] = duration }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func artifact(_ id: Int, title: String, path: String, kind: String, mime: String,
                          size: Int = 2048) -> CantripHomeArtifact {
        CantripHomeArtifact(
            id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", id))!, title: title,
            relativePath: path, kind: kind, mimeType: mime, size: size, createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    private func temporaryStore(limit: Int = 3) -> CantripArtifactThumbnailStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-thumbnails-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CantripArtifactThumbnailStore(directory: directory, concurrentFetches: limit)
    }

    func testThumbnailAPIDecodesPayloadAndTreats404AsNoThumbnail() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtifactThumbnailRequestProtocol.self]
        let api = CantripRemoteAPI(transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
                                   token: "token", urlSession: URLSession(configuration: configuration))
        let image = try jpeg([.systemBlue])
        let video = UUID(), document = UUID(), broken = UUID()
        var paths: [String] = []
        ArtifactThumbnailRequestProtocol.handler = { request in
            let path = request.url!.path
            paths.append(path)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"), "Thumbnails need pairing")
            if path.contains(video.uuidString) { return (200, try self.payload(image, duration: 12.4)) }
            if path.contains(broken.uuidString) { return (200, Data(#"{"data":"","width":0,"height":0}"#.utf8)) }
            return (404, Data(#"{"error":"This artifact has no thumbnail."}"#.utf8))
        }
        defer { ArtifactThumbnailRequestProtocol.handler = nil }
        let poster = try await api.homeArtifactThumbnail(id: video)
        XCTAssertEqual(poster?.data, image)
        XCTAssertEqual(poster?.durationSeconds, 12.4)
        XCTAssertEqual(paths, ["/api/v1/home/artifacts/\(video.uuidString)/thumbnail"])
        let none = try await api.homeArtifactThumbnail(id: document)
        XCTAssertNil(none, "Documents and older Macs answer 404: show the type icon")
        do {
            _ = try await api.homeArtifactThumbnail(id: broken)
            XCTFail("An empty thumbnail is invalid")
        } catch CantripRemoteError.invalidResponse {}
    }

    func testThumbnailsComeFromMemoryThenDiskAndAreFetchedOncePerRevision() async throws {
        let store = temporaryStore()
        let photo = artifact(1, title: "Header", path: "header.png", kind: "image", mime: "image/png")
        let data = try jpeg([.systemTeal, .systemIndigo])
        var fetches = 0
        let fetch: @MainActor () async throws -> CantripHomeArtifactThumbnailPayload? = {
            fetches += 1
            try await Task.sleep(for: .milliseconds(50))
            return CantripHomeArtifactThumbnailPayload(data: data, width: 600, height: 400, durationSeconds: nil)
        }
        async let first = store.thumbnail(for: photo, fetch: fetch)
        async let second = store.thumbnail(for: photo, fetch: fetch)
        let (a, b) = await (first, second)
        XCTAssertNotNil(a)
        XCTAssertIdentical(a?.image, b?.image, "Concurrent cells share one request")
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(store.fetchCount, 1)
        XCTAssertNotNil(store.cached(photo), "Scrolling back shows the thumbnail immediately")
        _ = await store.thumbnail(for: photo, fetch: fetch)
        XCTAssertEqual(fetches, 1)

        var diskFile: URL?
        for _ in 0..<50 {
            diskFile = try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).first
            if diskFile != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(diskFile, "Thumbnails persist across launches")
        let relaunched = CantripArtifactThumbnailStore(directory: store.directory)
        XCTAssertNil(relaunched.cached(photo))
        let fromDisk = await relaunched.thumbnail(for: photo, fetch: fetch)
        XCTAssertNotNil(fromDisk)
        XCTAssertEqual(relaunched.fetchCount, 0, "A relaunch reads the disk cache instead of the Mac")

        let replaced = CantripHomeArtifact(id: photo.id, title: photo.title, relativePath: photo.relativePath,
                                           kind: photo.kind, mimeType: photo.mimeType, size: photo.size + 1,
                                           createdAt: photo.createdAt.addingTimeInterval(60))
        XCTAssertNotEqual(CantripArtifactThumbnailStore.key(replaced), CantripArtifactThumbnailStore.key(photo))
        _ = await relaunched.thumbnail(for: replaced, fetch: fetch)
        XCTAssertEqual(relaunched.fetchCount, 1, "A replaced file gets a new thumbnail")
        for _ in 0..<50 where ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path))?.count ?? 0) < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }

        relaunched.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path), "Unpairing deletes cached thumbnails")
        XCTAssertNil(relaunched.cached(replaced))
    }

    func testFailuresShowThePlaceholderUntilRefresh() async throws {
        let store = temporaryStore()
        let missing = artifact(2, title: "Old export", path: "old.png", kind: "image", mime: "image/png")
        let offline = artifact(3, title: "Clip", path: "clip.mov", kind: "video", mime: "video/quicktime")
        let undecodable = artifact(4, title: "Bad", path: "bad.png", kind: "image", mime: "image/png")
        var calls = 0
        let none = await store.thumbnail(for: missing) { calls += 1; return nil }
        XCTAssertNil(none)
        XCTAssertTrue(store.isUnavailable(missing))
        _ = await store.thumbnail(for: missing) { calls += 1; return nil }
        XCTAssertEqual(calls, 1, "A missing thumbnail is not retried while scrolling")
        _ = await store.thumbnail(for: offline) { calls += 1; throw CantripRemoteError.transport("offline") }
        XCTAssertTrue(store.isUnavailable(offline))
        _ = await store.thumbnail(for: undecodable) {
            calls += 1
            return CantripHomeArtifactThumbnailPayload(data: Data("nope".utf8), width: 1, height: 1, durationSeconds: nil)
        }
        XCTAssertTrue(store.isUnavailable(undecodable), "Undecodable data shows the placeholder")
        store.resetFailures()
        let data = try jpeg([.systemPink])
        let recovered = await store.thumbnail(for: offline) {
            calls += 1
            return CantripHomeArtifactThumbnailPayload(data: data, width: 600, height: 400, durationSeconds: 3)
        }
        XCTAssertEqual(recovered?.durationSeconds, 3, "Pull to refresh retries")
    }

    func testOnlyThreeThumbnailsDownloadAtOnce() async throws {
        let store = temporaryStore(limit: 3)
        let data = try jpeg([.systemGreen])
        var active = 0, peak = 0
        let items = (10..<18).map { artifact($0, title: "Shot \($0)", path: "shot-\($0).png", kind: "image", mime: "image/png") }
        await withTaskGroup(of: Void.self) { group in
            for item in items {
                group.addTask { @MainActor in
                    _ = await store.thumbnail(for: item) {
                        active += 1
                        peak = max(peak, active)
                        try await Task.sleep(for: .milliseconds(40))
                        active -= 1
                        return CantripHomeArtifactThumbnailPayload(data: data, width: 600, height: 400, durationSeconds: nil)
                    }
                }
            }
        }
        XCTAssertEqual(peak, 3)
        XCTAssertTrue(items.allSatisfy { store.cached($0) != nil })
    }

    func testDocumentsAndAudioKeepIconsAndDurationsReadLikePhotos() async {
        let store = temporaryStore()
        var calls = 0
        for item in [artifact(5, title: "Report", path: "report.pdf", kind: "document", mime: "application/pdf"),
                     artifact(6, title: "Memo", path: "memo.m4a", kind: "audio", mime: "audio/mp4")] {
            let result = await store.thumbnail(for: item) { calls += 1; return nil }
            XCTAssertNil(result)
        }
        XCTAssertEqual(calls, 0, "Documents and audio never request thumbnails")
        XCTAssertEqual(CantripArtifactThumbnailView.icon(artifact(5, title: "", path: "r.pdf", kind: "document",
                                                                   mime: "application/pdf")), "doc.richtext.fill")
        XCTAssertEqual(CantripArtifactThumbnailView.icon(artifact(6, title: "", path: "m.m4a", kind: "audio",
                                                                   mime: "audio/mp4")), "waveform")
        XCTAssertEqual(CantripArtifactThumbnailView.duration(0.4), "0:01")
        XCTAssertEqual(CantripArtifactThumbnailView.duration(12.4), "0:12")
        XCTAssertEqual(CantripArtifactThumbnailView.duration(754), "12:34")
        XCTAssertEqual(CantripArtifactThumbnailView.duration(3723), "1:02:03")
        let clip = artifact(7, title: "Set walk-in", path: "walkin.mov", kind: "video", mime: "video/quicktime")
        XCTAssertEqual(CantripArtifactCardLabel.accessibilityText(clip, duration: 12.4),
                       "Set walk-in, Video, 12 seconds, 2 KB")
        XCTAssertEqual(CantripArtifactCardLabel.accessibilityText(clip, duration: nil), "Set walk-in, Video, 2 KB")
    }

    func testArtifactsGridShowsThumbnailsBadgesAndPlaceholders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtifactThumbnailRequestProtocol.self]
        let model = CantripRemoteModel(urlSession: URLSession(configuration: configuration))
        let photo = try jpeg([.systemIndigo, .systemPurple, .systemPink, .systemOrange])
        let poster = try jpeg([.black, .systemRed, .systemYellow])
        var thumbnailPaths: [String] = []
        ArtifactThumbnailRequestProtocol.handler = { request in
            let path = request.url!.path
            switch path {
            case "/api/v1/home": return (200, self.homeSession())
            case "/api/v1/home/tasks": return (200, Data(#"{"tasks":[],"revision":"t1"}"#.utf8))
            case "/api/v1/home/artifacts": return (200, self.artifactsPayload())
            case let value where value.hasSuffix("/thumbnail"):
                thumbnailPaths.append(value)
                if value.contains("-000000000001/") { return (200, try self.payload(photo)) }
                if value.contains("-000000000002/") { return (200, try self.payload(poster, duration: 12.4)) }
                return (404, Data(#"{"error":"no thumbnail"}"#.utf8))
            default: return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            model.clearConfiguration()
            ArtifactThumbnailRequestProtocol.handler = nil
        }
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "artifact-token",
                                               tailscaleOnly: true)
        XCTAssertTrue(configured)
        await model.selectHome()
        XCTAssertEqual(model.homeArtifacts.count, 5)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let cases: [(String, UIUserInterfaceStyle, CGFloat, DynamicTypeSize)] = [
            ("light", .light, 393, .large), ("dark", .dark, 393, .large), ("accessibility", .dark, 320, .accessibility2)
        ]
        for (name, style, width, typeSize) in cases {
            let controller = UIHostingController(rootView:
                NavigationStack { CantripHomeArtifactsView(remote: model, openChat: { _ in }) }
                    .environment(\.dynamicTypeSize, typeSize)
                    .frame(width: width)
            )
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 852)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            for _ in 0..<40 {
                if model.homeArtifacts.prefix(2).allSatisfy({ model.artifactThumbnails.cached($0) != nil }) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["CANTRIP_RENDER_DIR"] {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try XCTUnwrap(image.pngData()).write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("artifacts-grid-\(name).png"))
            }
        }
        let artifacts = model.homeArtifacts
        XCTAssertNotNil(model.artifactThumbnails.cached(artifacts[0]), "Images get a thumbnail")
        XCTAssertEqual(model.artifactThumbnails.cached(artifacts[1])?.durationSeconds, 12.4, "Videos get a poster and duration")
        XCTAssertTrue(model.artifactThumbnails.isUnavailable(artifacts[4]), "A failed thumbnail shows the placeholder")
        XCTAssertEqual(Set(thumbnailPaths.map { String($0.dropFirst("/api/v1/home/artifacts/".count).prefix(36)) }),
                       Set([artifacts[0], artifacts[1], artifacts[4]].map(\.id.uuidString)),
                       "Documents and audio never request thumbnails, and each artifact is requested once")
        XCTAssertEqual(thumbnailPaths.count, 3)
    }

    private func homeSession() -> Data {
        Data("""
        {"session":{"id":"\(homeID)","title":"Cantrip Home","workdir":"/tmp",
        "isStreaming":false,"canResume":false,"councilMode":false,"queuedCount":0,
        "status":null,"messages":[],"supportsImageAttachments":true,"queued":[],
        "supportsAutoDelivery":true,"isLocked":true,"isCantripHome":true,
        "supportsModelSettings":true,"supportsPagedHistory":true}}
        """.utf8)
    }

    private func artifactsPayload() -> Data {
        func item(_ id: Int, _ title: String, _ path: String, _ kind: String, _ mime: String, _ size: Int) -> String {
            #"{"id":"20000000-0000-0000-0000-\#(String(format: "%012d", id))","title":"\#(title)","relativePath":"\#(path)","kind":"\#(kind)","mimeType":"\#(mime)","size":\#(size),"createdAt":0}"#
        }
        return Data("""
        {"artifacts":[\(item(1, "Niteharts set times header", "niteharts-header.png", "image", "image/png", 606939)),
        \(item(2, "Walk-in clip", "walkin.mov", "video", "video/quicktime", 8_400_000)),
        \(item(3, "Flight report", "flight-report.pdf", "document", "application/pdf", 128_000)),
        \(item(4, "Voice memo", "memo.m4a", "audio", "audio/mp4", 900_000)),
        \(item(5, "Missing export", "missing.png", "image", "image/png", 4096))],"revision":"a1"}
        """.utf8)
    }
}
