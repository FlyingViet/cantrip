import AVFoundation
import CryptoKit
import Foundation
import ImageIO

extension SessionTabTests {
    static func videoFixture(at url: URL, duration: Double = 3) async throws -> Data {
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
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<30 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData && Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            precondition(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels)!, Int32(index * 7), CVPixelBufferGetBytesPerRow(pixels) * 48)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            precondition(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed)
        return try Data(contentsOf: url)
    }

    @MainActor
    static func testRemoteVideos() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("video-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let bytes = try await videoFixture(at: root.appendingPathComponent("source.mp4"))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let info = RemoteVideoUpload(totalBytes: bytes.count, format: "mp4", name: "A video.mp4",
                                     sha256: digest, receivedBytes: 0)
        let videoRoot = root.appendingPathComponent("videos"), imageRoot = root.appendingPathComponent("images")
        let store = RemoteVideoAttachments(root: videoRoot, imageRoot: imageRoot)
        let session = UUID(), upload = UUID(), split = bytes.count / 2
        let first = try await store.receive(sessionID: session, uploadID: upload, offset: 0,
                                            upload: info, data: Data(bytes.prefix(split)))
        precondition(first.receivedBytes == split)
        let duplicate = try await store.receive(sessionID: session, uploadID: upload, offset: 0,
                                                upload: info, data: Data(bytes.prefix(split)))
        precondition(duplicate == first, "An uncertain chunk can be replayed without appending twice")
        do {
            _ = try await store.receive(sessionID: session, uploadID: upload, offset: 0,
                                         upload: info, data: Data(repeating: 1, count: split))
            preconditionFailure("Different bytes cannot replace a confirmed chunk")
        } catch let error as RemoteVideoError { precondition(error.status == 409) }
        do {
            try await store.prepare(sessionID: session, uploadID: upload)
            preconditionFailure("Incomplete videos cannot be prepared")
        } catch let error as RemoteVideoError { precondition(error.status == 409) }
        let restarted = RemoteVideoAttachments(root: videoRoot, imageRoot: imageRoot)
        let resumed = try await restarted.status(sessionID: session, uploadID: upload)
        precondition(resumed.receivedBytes == split, "The durable offset survives host restart")
        _ = try await restarted.receive(sessionID: session, uploadID: upload, offset: split,
                                        upload: info, data: Data(bytes.dropFirst(split)))
        try await restarted.prepare(sessionID: session, uploadID: upload)
        try await restarted.prepare(sessionID: session, uploadID: upload)
        let prompt = try await restarted.claim(sessionID: session, uploadID: upload)
        precondition(prompt.contains("A video.mp4") && prompt.contains("3.00"))
        precondition(prompt.contains("NOT been transcribed") && prompt.contains("sparse preview"))
        let images = RemoteImageAttachments.presentation(prompt, sessionID: session, root: imageRoot).imageIDs
        precondition(images.count == 4)
        let firstFrame = try RemoteImageAttachments.read(id: images[0], sessionID: session, thumbnail: false, root: imageRoot)
        let lastFrame = try RemoteImageAttachments.read(id: images[3], sessionID: session, thumbnail: false, root: imageRoot)
        precondition(firstFrame != lastFrame, "Video overview must sample different times, not repeat a keyframe")
        let source = CGImageSourceCreateWithData(firstFrame as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        precondition(properties[kCGImagePropertyPixelWidth] as? Int == 48
                     && properties[kCGImagePropertyPixelHeight] as? Int == 64, "Host previews respect portrait rotation")
        let original = videoRoot.appendingPathComponent("\(session)/\(upload)/video.mp4")
        let savedOriginal = try Data(contentsOf: original)
        precondition(savedOriginal == bytes, "Keep the exact original clip for audio/motion analysis")
        let storedImages = try fm.contentsOfDirectory(at: imageRoot.appendingPathComponent(session.uuidString), includingPropertiesForKeys: nil)
        precondition(storedImages.count == 1, "Preparing again reuses its durable image overview")
        do {
            _ = try await restarted.claim(sessionID: UUID(), uploadID: upload)
            preconditionFailure("Uploads are scoped to their owning session")
        } catch let error as RemoteVideoError { precondition(error.status == 404) }

        let corruptID = UUID()
        let wrongDigest = RemoteVideoUpload(totalBytes: bytes.count, format: "mp4", name: "Corrupt.mp4",
                                            sha256: String(repeating: "0", count: 64), receivedBytes: 0)
        _ = try await store.receive(sessionID: session, uploadID: corruptID, offset: 0, upload: wrongDigest, data: bytes)
        do {
            try await store.prepare(sessionID: session, uploadID: corruptID)
            preconditionFailure("Complete uploads require SHA256 integrity")
        } catch let error as RemoteVideoError { precondition(error.status == 409) }
        let longBytes = try await videoFixture(at: root.appendingPathComponent("long.mp4"), duration: 301)
        let longID = UUID()
        let long = RemoteVideoUpload(totalBytes: longBytes.count, format: "mp4", name: "long.mp4",
                                     sha256: SHA256.hash(data: longBytes).map { String(format: "%02x", $0) }.joined(), receivedBytes: 0)
        _ = try await store.receive(sessionID: session, uploadID: longID, offset: 0, upload: long, data: longBytes)
        do {
            try await store.prepare(sessionID: session, uploadID: longID)
            preconditionFailure("Do not silently truncate videos over five minutes")
        } catch let error as RemoteVideoError { precondition(error.status == 422) }

        let quotaRoot = root.appendingPathComponent("quota")
        let quota = RemoteVideoAttachments(root: quotaRoot, imageRoot: imageRoot)
        let full = RemoteVideoUpload(totalBytes: RemoteVideoAttachments.maximumBytes, format: "mp4", name: "planned.mp4",
                                     sha256: digest, receivedBytes: 0)
        let oversized = RemoteVideoUpload(totalBytes: RemoteVideoAttachments.maximumBytes + 1, format: "mp4",
                                          name: "oversized.mp4", sha256: digest, receivedBytes: 0)
        do {
            _ = try await quota.receive(sessionID: session, uploadID: UUID(), offset: 0, upload: oversized, data: Data([0]))
            preconditionFailure("Enforce the declared total-byte limit")
        } catch let error as RemoteVideoError { precondition(error.status == 400) }
        do {
            _ = try await quota.receive(sessionID: session, uploadID: UUID(), offset: 0, upload: full,
                                         data: Data(repeating: 0, count: RemoteVideoAttachments.chunkBytes + 1))
            preconditionFailure("Enforce the one-MiB chunk limit")
        } catch let error as RemoteVideoError { precondition(error.status == 400) }
        let pendingIDs = (0..<5).map { _ in UUID() }
        for id in pendingIDs {
            _ = try await quota.receive(sessionID: session, uploadID: id, offset: 0, upload: full, data: Data([0]))
        }
        do {
            _ = try await quota.receive(sessionID: session, uploadID: UUID(), offset: 0, upload: full, data: Data([0]))
            preconditionFailure("Unfinished uploads must be bounded")
        } catch let error as RemoteVideoError { precondition(error.status == 413) }
        let expired = quotaRoot.appendingPathComponent("\(session)/\(pendingIDs[0])")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)],
                             ofItemAtPath: expired.appendingPathComponent("upload.json").path)
        _ = try await quota.receive(sessionID: session, uploadID: UUID(), offset: 0, upload: full, data: Data([0]))
        precondition(!fm.fileExists(atPath: expired.path), "Expired unsubmitted uploads release their reservation")
        let linked = videoRoot.appendingPathComponent("\(session)/\(UUID())")
        try fm.createSymbolicLink(at: linked, withDestinationURL: root)
        do {
            _ = try await store.status(sessionID: session, uploadID: UUID(uuidString: linked.lastPathComponent)!)
            preconditionFailure("Never follow substituted upload directories")
        } catch let error as RemoteVideoError { precondition(error.status == 404) }

        let settings = AppSettings.shared, oldBackend = AppSettings.shared.backend
        settings.backend = .copilot
        defer { settings.backend = oldBackend }
        let manager = SessionManager(), serverID = UUID()
        manager.active.isStreaming = true
        defer { manager.active.isStreaming = false }
        let server = RemoteControlServer(manager: manager), port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(for: .milliseconds(300))
        let basePath = "/api/v1/sessions/\(manager.active.id)"
        func request(_ suffix: String, method: String = "GET", body: Data? = nil,
                     query: [String: String] = [:], auth: Bool = true) async throws -> (Int, [String: Any]) {
            var url = URLComponents(string: "http://127.0.0.1:\(port)\(basePath)\(suffix)")!
            url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: url.url!, timeoutInterval: 30)
            request.httpMethod = method; request.httpBody = body
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        let route = "/videos/\(serverID)"
        let query = ["offset": "0", "totalBytes": String(bytes.count), "format": "mp4", "name": "A video.mp4", "sha256": digest]
        let (unauthorized, _) = try await request(route, method: "PUT", body: bytes, query: query, auth: false)
        precondition(unauthorized == 401)
        let (_, detail) = try await request("")
        precondition((detail["session"] as! [String: Any])["supportsVideoAttachments"] as? Bool == true)
        let (accepted, _) = try await request(route, method: "PUT", body: bytes, query: query)
        precondition(accepted == 200 && manager.active.queued.isEmpty)
        let (ready, _) = try await request(route + "/prepare", method: "POST")
        precondition(ready == 200 && manager.active.queued.isEmpty, "Uploading/preparing must never send a prompt")
        let body = try JSONSerialization.data(withJSONObject: ["text": "", "mode": "queue", "videoID": serverID.uuidString])
        let (sent, snapshot) = try await request("/messages", method: "POST", body: body)
        precondition(sent == 202 && manager.active.queued.count == 1)
        let queued = (snapshot["session"] as! [String: Any])["queued"] as! [[String: Any]]
        precondition((queued.last?["images"] as? [[String: Any]])?.count == 4)
        precondition(manager.active.queued.last!.text.contains("Original video on this Mac:"))
        manager.active.isPrivate = true
        let (privateRead, _) = try await request(route)
        let (privateWrite, _) = try await request(route, method: "PUT", body: bytes, query: query)
        precondition(privateRead == 404 && privateWrite == 404)
        manager.active.isPrivate = false
        print("Remote videos: resumable verified chunks, real MP4 frames, durable originals, explicit send, and private-session protection passed")
    }
}
