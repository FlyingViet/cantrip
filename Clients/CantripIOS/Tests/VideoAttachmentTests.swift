import AVFoundation
import CryptoKit
import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class VideoRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { responseTask?.cancel() }
    override func startLoading() {
        responseTask = Task { @MainActor in
            do {
                let (status, data) = try await XCTUnwrap(Self.handler)(request)
                try Task.checkCancellation()
                let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status,
                                                           httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
}

@MainActor
final class VideoAttachmentTests: XCTestCase {
    private let sessionID = UUID().uuidString

    private func remote() async throws -> CantripRemoteModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VideoRequestProtocol.self]
        let client = URLSession(configuration: config)
        let model = CantripRemoteModel(urlSession: client)
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "video-token", tailscaleOnly: true)
        XCTAssertTrue(configured)
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            client.invalidateAndCancel()
            VideoRequestProtocol.handler = nil
        }
        return model
    }

    private func snapshot(support: Bool? = true, list: Bool = false, files: Bool? = nil,
                          mixed: Bool? = nil) throws -> Data {
        var session: [String: Any] = [
            "id": sessionID, "title": "Video tab", "workdir": "/tmp", "isStreaming": false,
            "canResume": false, "councilMode": false, "queuedCount": 0, "messages": [],
            "supportsImageAttachments": true, "supportsAutoDelivery": true,
        ]
        session["supportsVideoAttachments"] = support
        session["supportsFileAttachments"] = files
        session["supportsMixedAttachments"] = mixed
        return try JSONSerialization.data(withJSONObject: list ? ["sessions": [session]] : ["session": session])
    }

    private func fileDraft(name: String, bytes: Int) throws -> ChatFileAttachment {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID())")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let url = source.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return try FileAttachmentProcessor.prepare(url)
    }

    private func photo() throws -> ChatImageAttachment {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return try ImageAttachmentProcessor.prepare(try XCTUnwrap(image.pngData()))
    }

    func testFileImportCopiesHashesAndCleansUp() throws {
        var file: ChatFileAttachment? = try fileDraft(name: "Q3 \u{7}report.pdf", bytes: FileAttachmentProcessor.chunkBytes + 5)
        let copy = try XCTUnwrap(file).url
        XCTAssertEqual(file?.name, "Q3 report.pdf", "Control characters never reach the Mac")
        XCTAssertEqual(file?.bytes, FileAttachmentProcessor.chunkBytes + 5)
        XCTAssertEqual(file?.sha256, SHA256.hash(data: Data(repeating: 7, count: FileAttachmentProcessor.chunkBytes + 5))
            .map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(file?.systemImage, "doc.richtext")
        XCTAssertEqual(try FileAttachmentProcessor.chunk(XCTUnwrap(file), offset: FileAttachmentProcessor.chunkBytes).count, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        file = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "A removed draft deletes its copy")
        XCTAssertThrowsError(try fileDraft(name: "empty.txt", bytes: 0))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("folder-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try FileAttachmentProcessor.prepare(folder)) {
            XCTAssertEqual($0 as? FileAttachmentError, .invalid)
        }
        XCTAssertTrue(CantripRemoteAPI.isUploadRoute("/api/v1/sessions/S/files/F?offset=0&name=a%2Fb"))
        XCTAssertTrue(CantripRemoteAPI.isUploadRoute("/api/v1/sessions/S/videos/V/prepare"))
        XCTAssertFalse(CantripRemoteAPI.isUploadRoute("/api/v1/sessions/S/messages?name=/files/x"))
    }

    func testFilesPhotosAndVideoUploadThenSendOnePrompt() async throws {
        let model = try await remote(), video = try draft(bytes: 30)
        let name = "Lease & notes+v2 é?.pdf"
        let file = try fileDraft(name: name, bytes: FileAttachmentProcessor.chunkBytes + 9)
        let image = try photo()
        var fileReceived = 0, videoReceived = 0, prepared = false, messages = 0
        VideoRequestProtocol.handler = { request in
            let path = request.url!.path
            if path.contains("/files/") {
                XCTAssertTrue(path.hasSuffix("/files/\(file.id)"))
                if request.httpMethod == "GET" { return (404, Data(#"{"error":"File upload not found."}"#.utf8)) }
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.timeoutInterval, 60)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "name" }?.value, name, "Any file name round-trips")
                XCTAssertEqual(Int(query.first { $0.name == "offset" }!.value!)!, fileReceived)
                XCTAssertEqual(messages, 0)
                fileReceived += try self.body(request).count
                return (200, try JSONSerialization.data(withJSONObject: ["upload": [
                    "totalBytes": file.bytes, "receivedBytes": fileReceived, "sha256": file.sha256,
                ]]))
            }
            if path.contains("/videos/") {
                if request.httpMethod == "GET" { return (404, Data(#"{"error":"Video upload not found."}"#.utf8)) }
                if request.httpMethod == "PUT" {
                    videoReceived += try self.body(request).count
                    return (200, try self.uploadStatus(video, received: videoReceived))
                }
                prepared = true
                return (200, Data(#"{"ready":true}"#.utf8))
            }
            if request.httpMethod == "POST" {
                messages += 1
                XCTAssertTrue(prepared && fileReceived == file.bytes && videoReceived == video.bytes,
                              "The prompt goes only after every upload is complete")
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: self.body(request)) as? [String: Any])
                XCTAssertEqual(json["fileIDs"] as? [String], [file.id.uuidString])
                XCTAssertEqual(json["videoID"] as? String, video.id.uuidString)
                XCTAssertEqual((json["images"] as? [[String: Any]])?.count, 1)
                XCTAssertEqual(json["text"] as? String, "Read these")
                return (202, try self.snapshot(files: true, mixed: true))
            }
            return (200, try self.snapshot(files: true, mixed: true))
        }
        let sent = await model.send("Read these", mode: .queue, images: [image], video: video, files: [file],
                                    sessionID: sessionID)
        XCTAssertTrue(sent, model.errorMessage ?? "")
        XCTAssertEqual(messages, 1)
        XCTAssertNil(model.videoUploadProgress)
    }

    func testOlderMacsNeverUploadFilesOrMixedMedia() async throws {
        let video = try draft(bytes: 30), file = try fileDraft(name: "a.txt", bytes: 3), image = try photo()
        for (files, mixed, useFile) in [(Bool?.none, Bool?.none, true), (true, nil, false)] {
            let model = try await remote()
            var writes = 0
            VideoRequestProtocol.handler = { request in
                if request.httpMethod != "GET" { writes += 1 }
                return (200, try self.snapshot(files: files, mixed: mixed))
            }
            let sent = useFile
                ? await model.send("Read", mode: .queue, files: [file], sessionID: sessionID)
                : await model.send("Both", mode: .queue, images: [image], video: video, sessionID: sessionID)
            XCTAssertFalse(sent)
            XCTAssertEqual(writes, 0, "Nothing uploads when the Mac can't take the message")
            XCTAssertEqual(model.errorMessage, useFile
                ? FileAttachmentError.unsupportedHost.localizedDescription
                : VideoAttachmentError.mixedAttachments.localizedDescription)
        }
        let model = try await remote()
        var writes = 0
        VideoRequestProtocol.handler = { request in
            if request.httpMethod != "GET" { writes += 1 }
            return (200, try self.snapshot(files: true, mixed: true))
        }
        let command = await model.send("!rm -rf x", mode: .queue, files: [file], sessionID: sessionID)
        XCTAssertFalse(command)
        XCTAssertEqual(writes, 0, "Files attach to agent prompts, never shell commands")
    }

    private func draft(bytes: Int = 2 * VideoAttachmentProcessor.chunkBytes + 19) throws -> ChatVideoAttachment {
        let data = Data(repeating: 42, count: bytes)
        let video = ChatVideoAttachment(id: UUID(), format: "mp4", name: "A video.mp4", bytes: data.count,
                                        duration: 3, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                        thumbnail: Data())
        try FileManager.default.createDirectory(at: video.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: video.url)
        return video
    }

    private func uploadStatus(_ video: ChatVideoAttachment, received: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "upload": ["totalBytes": video.bytes, "receivedBytes": received, "sha256": video.sha256],
        ])
    }

    private func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw try XCTUnwrap(stream.streamError) }
            if count == 0 { return output }
            output.append(contentsOf: buffer.prefix(count))
        }
    }

    func testVideoUploadResumesAndOnlyThenSubmitsOnePrompt() async throws {
        let model = try await remote(), video = try draft()
        var received = VideoAttachmentProcessor.chunkBytes
        var offsets: [Int] = [], prepared = false, messages = 0
        VideoRequestProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer video-token")
            let path = request.url!.path
            if path.contains("/videos/") {
                if request.httpMethod == "GET" { return (200, try self.uploadStatus(video, received: received)) }
                XCTAssertEqual(request.timeoutInterval, 60)
                if request.httpMethod == "PUT" {
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                    let offset = Int(query.first { $0.name == "offset" }!.value!)!
                    XCTAssertEqual(offset, received)
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
                    let chunk = try self.body(request)
                    XCTAssertGreaterThan(chunk.count, 0)
                    XCTAssertLessThanOrEqual(chunk.count, VideoAttachmentProcessor.chunkBytes)
                    XCTAssertEqual(chunk, Data(repeating: 42, count: chunk.count))
                    offsets.append(offset); received += chunk.count
                    return (200, try self.uploadStatus(video, received: received))
                }
                XCTAssertTrue(path.hasSuffix("/prepare"))
                XCTAssertEqual(received, video.bytes)
                XCTAssertEqual(messages, 0)
                prepared = true
                return (200, Data(#"{"ready":true}"#.utf8))
            }
            if request.httpMethod == "POST" {
                messages += 1
                XCTAssertTrue(prepared, "Never send a prompt while a video is incomplete or unprepared")
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: self.body(request)) as? [String: Any])
                XCTAssertEqual(json["videoID"] as? String, video.id.uuidString)
                XCTAssertEqual(json["text"] as? String, "")
                XCTAssertEqual(json["mode"] as? String, "queue")
                XCTAssertNil(json["images"])
                return (202, try self.snapshot())
            }
            return (200, try self.snapshot())
        }
        let sent = await model.send("", mode: .queue, video: video, sessionID: sessionID)
        XCTAssertTrue(sent, model.errorMessage ?? "")
        XCTAssertEqual(offsets, [VideoAttachmentProcessor.chunkBytes, 2 * VideoAttachmentProcessor.chunkBytes])
        XCTAssertEqual(messages, 1)
        XCTAssertNil(model.videoUploadProgress)
        XCTAssertFalse(model.isUploadingVideo)
    }

    func testOldHostAndInvalidPromptNeverUploadVideo() async throws {
        let video = try draft(bytes: 30)
        for support: Bool? in [nil, false, true] {
            let model = try await remote()
            var writes = 0
            VideoRequestProtocol.handler = { request in
                if request.httpMethod != "GET" { writes += 1 }
                return (200, try self.snapshot(support: support))
            }
            let sent = await model.send(support == true ? "!echo unsafe" : "Analyze", mode: .queue,
                                        video: video, sessionID: sessionID)
            XCTAssertFalse(sent)
            XCTAssertEqual(writes, 0)
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testUncertainFinalPromptIsNeverReplayed() async throws {
        let model = try await remote(), video = try draft(bytes: 30)
        var messages = 0
        VideoRequestProtocol.handler = { request in
            if request.url!.path.contains("/videos/") {
                return request.httpMethod == "GET"
                    ? (200, try self.uploadStatus(video, received: video.bytes))
                    : (200, Data(#"{"ready":true}"#.utf8))
            }
            if request.httpMethod == "POST" {
                messages += 1
                throw URLError(.networkConnectionLost)
            }
            return (200, try self.snapshot())
        }
        let sent = await model.send("Analyze", mode: .queue, video: video, sessionID: sessionID)
        XCTAssertFalse(sent)
        XCTAssertEqual(messages, 1)
        XCTAssertTrue(model.errorMessage?.contains("may have reached") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.url.path), "Failed sends retain the caller's video draft")
    }

    func testSlowUploadAllowsPollingButBlocksServerSwitchAndCanCancel() async throws {
        let model = try await remote(), video = try draft(bytes: 30)
        var release: CheckedContinuation<Void, Never>?
        var messages = 0, lists = 0
        VideoRequestProtocol.handler = { request in
            let path = request.url!.path
            if path.contains("/videos/") {
                if request.httpMethod == "GET" { return (404, Data(#"{"error":"not found"}"#.utf8)) }
                await withCheckedContinuation { release = $0 }
                return (200, try self.uploadStatus(video, received: video.bytes))
            }
            if request.httpMethod == "POST" { messages += 1 }
            let list = path == "/api/v1/sessions"
            if list { lists += 1 }
            return (200, try self.snapshot(list: list))
        }
        model.setAppActive(true)
        let sending = Task { await model.send("Analyze", mode: .queue, video: video, sessionID: sessionID) }
        for _ in 0..<200 {
            if release != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(release)
        XCTAssertTrue(model.isUploadingVideo)
        let before = lists
        await model.refreshNow()
        XCTAssertGreaterThan(lists, before, "Video transfers do not hold the polling/mutation request gate")
        let changed = await model.configure(url: "https://other.example", pairingToken: "other", tailscaleOnly: true)
        XCTAssertFalse(changed)
        XCTAssertFalse(model.clearConfiguration())
        model.cancelVideoUpload()
        release?.resume()
        let sent = await sending.value
        XCTAssertFalse(sent)
        XCTAssertEqual(messages, 0)
        XCTAssertTrue(model.errorMessage?.contains("No prompt was sent") == true)
        XCTAssertFalse(model.isUploadingVideo)
        XCTAssertNil(model.videoUploadProgress)
    }

    private func movie(at url: URL, duration: Double = 3) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 7), CVPixelBufferGetBytesPerRow(pixels) * 48)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    func testImportPreservesOriginalAndOrientsThumbnailAndCleansOwnedDraft() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        try await movie(at: source)
        let original = try Data(contentsOf: source)
        var video: ChatVideoAttachment? = try await VideoAttachmentProcessor.importFile(source)
        let url = try XCTUnwrap(video?.url)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(video?.duration ?? 0, 3, accuracy: 0.05)
        XCTAssertEqual(video?.sha256, SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
        let preview = try XCTUnwrap(video.flatMap { UIImage(data: $0.thumbnail) })
        XCTAssertGreaterThan(preview.size.height, preview.size.width, "Respect the video's preferred orientation")
        video = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Never remove the user's original movie")
    }

    func testSourceSizeAndDurationLimitsAreExplicit() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data().write(to: source)
        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: UInt64(VideoAttachmentProcessor.maximumBytes + 1))
        try writer.close()
        do {
            _ = try await VideoAttachmentProcessor.importFile(source)
            XCTFail("Oversized source must not be copied or silently truncated")
        } catch VideoAttachmentError.tooLarge {}
        try FileManager.default.removeItem(at: source)
        try await movie(at: source, duration: 301)
        do {
            _ = try await VideoAttachmentProcessor.importFile(source)
            XCTFail("Long videos must not be silently clipped")
        } catch VideoAttachmentError.tooLong {}
    }

    func testFileDraftChipsFitNarrowAndAccessibilitySizes() async throws {
        let long = try fileDraft(name: "Quarterly lease renewal agreement with every addendum signed (final, v3).pdf", bytes: 12)
        let files = [long, try fileDraft(name: "notes.txt", bytes: 4)]
        for size in [DynamicTypeSize.large, .accessibility3] {
            let controller = UIHostingController(rootView:
                FileAttachmentPreviews(files: .constant(files), disabled: false)
                    .frame(width: 320)
                    .dynamicTypeSize(size)
            )
            let fitted = controller.sizeThatFits(in: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
            XCTAssertLessThanOrEqual(fitted.width, 320.5, "File chips fit a narrow phone at \(size)")
            XCTAssertGreaterThanOrEqual(fitted.height, 2 * 44, "Each chip keeps a 44pt remove target")
        }
    }

    func testVideoDraftPreviewAtNarrowAndAccessibilitySizes() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        try await movie(at: source)
        let video = try await VideoAttachmentProcessor.importFile(source)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for size in [DynamicTypeSize.large, .accessibility2] {
            let window = UIWindow(windowScene: scene)
            let controller = UIHostingController(rootView: ScrollView {
                VideoAttachmentPreview(video: video, disabled: false, remove: {}).padding()
            }.frame(width: 320).dynamicTypeSize(size))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(250))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Video draft \(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
            func scroll(in view: UIView) -> UIScrollView? {
                if let value = view as? UIScrollView { return value }
                return view.subviews.lazy.compactMap { scroll(in: $0) }.first
            }
            let viewport = try XCTUnwrap(scroll(in: controller.view))
            XCTAssertLessThanOrEqual(viewport.contentSize.width, viewport.bounds.width + 1)
            window.isHidden = true
        }
    }
}
