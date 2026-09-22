import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RemoteVideoError: Error, LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct RemoteVideoUpload: Codable, Equatable, Sendable {
    let totalBytes: Int
    let format: String
    let name: String
    let sha256: String
    var receivedBytes: Int
    var claimed: Bool = false
}

actor RemoteVideoAttachments {
    static let shared = RemoteVideoAttachments()
    static let maximumBytes = 100 << 20
    static let chunkBytes = 1 << 20
    static let maximumDuration = 300.0
    static let maximumPendingBytes = 500 << 20
    static let storageRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/Cantrip/remote-videos", isDirectory: true)

    private let root: URL
    private let imageRoot: URL
    private var preparations: [String: Task<String, Error>] = [:]

    init(root: URL = storageRoot, imageRoot: URL = RemoteImageAttachments.storageRoot) {
        self.root = root.resolvingSymlinksInPath()
        self.imageRoot = imageRoot
    }

    func status(sessionID: UUID, uploadID: UUID) throws -> RemoteVideoUpload {
        try manifest(in: directory(sessionID, uploadID))
    }

    func receive(sessionID: UUID, uploadID: UUID, offset: Int, upload: RemoteVideoUpload,
                 data: Data) throws -> RemoteVideoUpload {
        guard (1...Self.maximumBytes).contains(upload.totalBytes),
              ["mov", "mp4"].contains(upload.format), !upload.name.isEmpty, upload.name.count <= 160,
              !upload.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              upload.sha256.count == 64, upload.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              offset >= 0, offset <= upload.totalBytes,
              !data.isEmpty, data.count <= Self.chunkBytes, data.count <= upload.totalBytes - offset else {
            throw RemoteVideoError(status: 400, message: "Invalid video upload. Use a MOV or MP4 of at most 100 MB.")
        }
        let folder = try directory(sessionID, uploadID)
        let fm = FileManager.default
        let metadataURL = folder.appendingPathComponent("upload.json")
        var current: RemoteVideoUpload
        if fm.fileExists(atPath: metadataURL.path) {
            current = try manifest(in: folder)
            guard current.totalBytes == upload.totalBytes, current.format == upload.format,
                  current.name == upload.name, current.sha256 == upload.sha256 else {
                throw RemoteVideoError(status: 409, message: "This video upload ID belongs to different content.")
            }
        } else {
            guard offset == 0 else { throw RemoteVideoError(status: 409, message: "Restart this video upload.") }
            try reservePendingSpace(upload.totalBytes)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            current = RemoteVideoUpload(totalBytes: upload.totalBytes, format: upload.format,
                                        name: upload.name, sha256: upload.sha256, receivedBytes: 0)
            try save(current, in: folder)
        }
        let file = try safeFile("video.\(current.format)", in: folder)
        if offset < current.receivedBytes {
            guard offset + data.count <= current.receivedBytes else {
                throw RemoteVideoError(status: 409, message: "Video chunk overlaps unconfirmed data.")
            }
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            try reader.seek(toOffset: UInt64(offset))
            guard try reader.read(upToCount: data.count) == data else {
                throw RemoteVideoError(status: 409, message: "The repeated video chunk does not match.")
            }
            return current
        }
        guard offset == current.receivedBytes else {
            throw RemoteVideoError(status: 409, message: "Video chunks must be uploaded in order.")
        }
        if offset == 0 && !fm.fileExists(atPath: file.path) {
            try Data().write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }
        // The manifest is the acknowledged boundary after a crash or lost reply.
        try writer.truncate(atOffset: UInt64(offset))
        try writer.seek(toOffset: UInt64(offset))
        try writer.write(contentsOf: data)
        try writer.synchronize()
        current.receivedBytes += data.count
        try save(current, in: folder)
        return current
    }

    func prepare(sessionID: UUID, uploadID: UUID) async throws {
        let folder = try directory(sessionID, uploadID)
        let prepared = try safeFile("prepared.json", in: folder)
        if FileManager.default.fileExists(atPath: prepared.path) {
            _ = try readPrompt(in: folder)
            return
        }
        let key = "\(sessionID)/\(uploadID)"
        if let pending = preparations[key] { _ = try await pending.value; return }
        let task = Task { try await self.makePrompt(sessionID: sessionID, uploadID: uploadID) }
        preparations[key] = task
        defer { preparations.removeValue(forKey: key) }
        _ = try await task.value
    }

    func claim(sessionID: UUID, uploadID: UUID) throws -> String {
        let folder = try directory(sessionID, uploadID)
        var upload = try manifest(in: folder)
        guard upload.receivedBytes == upload.totalBytes else {
            throw RemoteVideoError(status: 409, message: "Finish uploading the video before sending.")
        }
        let original = try safeFile("video.\(upload.format)", in: folder)
        guard try original.resourceValues(forKeys: [.fileSizeKey]).fileSize == upload.totalBytes else {
            throw RemoteVideoError(status: 409, message: "The original video is no longer complete on the Mac.")
        }
        let prompt = try readPrompt(in: folder)
        upload.claimed = true
        try save(upload, in: folder)
        return prompt
    }

    private func makePrompt(sessionID: UUID, uploadID: UUID) async throws -> String {
        let folder = try directory(sessionID, uploadID)
        let upload = try manifest(in: folder)
        guard upload.receivedBytes == upload.totalBytes else {
            throw RemoteVideoError(status: 409, message: "The video upload is incomplete.")
        }
        let file = try safeFile("video.\(upload.format)", in: folder)
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var digest = SHA256(), count = 0
        while let data = try reader.read(upToCount: Self.chunkBytes), !data.isEmpty {
            count += data.count
            guard count <= Self.maximumBytes else { throw RemoteVideoError(status: 413, message: "Video is too large.") }
            digest.update(data: data)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == upload.totalBytes, hash == upload.sha256 else {
            throw RemoteVideoError(status: 409, message: "Video integrity check failed. Remove it and attach it again.")
        }
        try reader.seek(toOffset: 0)
        let header = try reader.read(upToCount: 12) ?? Data()
        guard header.count >= 12, String(data: header[4..<8], encoding: .ascii) == "ftyp" else {
            throw RemoteVideoError(status: 422, message: "Choose a standard MOV or MP4 video.")
        }
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, duration <= Self.maximumDuration,
              let track = tracks.first else {
            throw RemoteVideoError(status: 422, message: "Choose a playable video no longer than five minutes.")
        }
        let range = try await track.load(.timeRange)
        guard range.start.seconds.isFinite, range.duration.seconds.isFinite, range.duration.seconds > 0 else {
            throw RemoteVideoError(status: 422, message: "The video has no readable frame timeline.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [RemoteImageUpload] = [], times: [String] = []
        for fraction in [0.0, 1.0 / 3.0, 2.0 / 3.0, 0.95] {
            try Task.checkCancellation()
            let frame = try await generator.image(at: CMTime(
                seconds: range.start.seconds + range.duration.seconds * fraction, preferredTimescale: 600
            ))
            frames += try RemoteImageAttachments.decode([["data": try preview(frame.image).base64EncodedString()]])
            times.append(String(format: "%.2f s", frame.actualTime.seconds))
        }
        let intro = """
        Video attachment: \(String(reflecting: upload.name)) (\(String(format: "%.2f", duration)) seconds).
        Original video on this Mac: \(file.path)
        The following four images are sparse preview frames, in order: \(times.joined(separator: ", ")).
        These frames do not capture every action. Inspect the original video with tools when motion, timing, or additional detail matters. Original audio is retained but has NOT been transcribed or analyzed by this attachment flow. Do not claim to have heard it without inspecting it.
        """
        let prompt = try RemoteImageAttachments.preparePrompt(intro, images: frames, sessionID: sessionID, root: imageRoot)
        try JSONEncoder().encode(prompt).write(to: folder.appendingPathComponent("prepared.json"), options: .atomic)
        return prompt
    }

    private func preview(_ image: CGImage) throws -> Data {
        for quality in [0.75, 0.6, 0.45, 0.3] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw RemoteVideoError(status: 422, message: "Could not create video preview frames.")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw RemoteVideoError(status: 422, message: "Could not create video preview frames.")
            }
            if output.length <= RemoteImageAttachments.maximumImageBytes { return output as Data }
        }
        throw RemoteVideoError(status: 422, message: "The video preview frames are too large to analyze.")
    }

    private func directory(_ session: UUID, _ upload: UUID) throws -> URL {
        let url = root.appendingPathComponent(session.uuidString).appendingPathComponent(upload.uuidString)
        guard url.resolvingSymlinksInPath().path == url.path else {
            throw RemoteVideoError(status: 404, message: "Video upload is unavailable.")
        }
        return url
    }

    private func safeFile(_ name: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name)
        guard file.resolvingSymlinksInPath().path == file.path else {
            throw RemoteVideoError(status: 404, message: "Video upload is unavailable.")
        }
        return file
    }

    private func manifest(in folder: URL) throws -> RemoteVideoUpload {
        let file = try safeFile("upload.json", in: folder)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw RemoteVideoError(status: 404, message: "Video upload not found.")
        }
        return try JSONDecoder().decode(RemoteVideoUpload.self, from: Data(contentsOf: file))
    }

    private func save(_ upload: RemoteVideoUpload, in folder: URL) throws {
        try JSONEncoder().encode(upload).write(to: try safeFile("upload.json", in: folder), options: .atomic)
    }

    private func readPrompt(in folder: URL) throws -> String {
        let file = try safeFile("prepared.json", in: folder)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw RemoteVideoError(status: 409, message: "Prepare the video for analysis before sending.")
        }
        return try JSONDecoder().decode(String.self, from: Data(contentsOf: file))
    }

    private func reservePendingSpace(_ bytes: Int) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        var pending = 0
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            // Directory enumeration may spell /var as /private/var. Rebase names
            // onto our canonical root before checking for substituted symlinks.
            let session = root.appendingPathComponent(item.lastPathComponent)
            guard UUID(uuidString: session.lastPathComponent) != nil,
                  session.resolvingSymlinksInPath().path == session.path else { continue }
            for item in try fm.contentsOfDirectory(at: session, includingPropertiesForKeys: nil) {
                let folder = session.appendingPathComponent(item.lastPathComponent)
                guard UUID(uuidString: folder.lastPathComponent) != nil,
                      folder.resolvingSymlinksInPath().path == folder.path else { continue }
                let metadata = try safeFile("upload.json", in: folder)
                let upload = fm.fileExists(atPath: metadata.path) ? try manifest(in: folder) : nil
                guard upload?.claimed != true else { continue }
                let date = try fm.attributesOfItem(atPath: (upload == nil ? folder : metadata).path)[.modificationDate] as? Date
                if let date, Date().timeIntervalSince(date) > 24 * 3600,
                   !preparations.keys.contains("\(session.lastPathComponent)/\(folder.lastPathComponent)") {
                    try fm.removeItem(at: folder)
                } else {
                    pending += upload?.totalBytes ?? 0
                }
            }
        }
        guard pending + bytes <= Self.maximumPendingBytes else {
            throw RemoteVideoError(status: 413, message: "Too many unfinished video uploads on the Mac. Finish pending uploads or wait for their 24-hour expiry.")
        }
    }
}
