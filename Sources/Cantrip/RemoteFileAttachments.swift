import CryptoKit
import Foundation

struct RemoteFileUpload: Codable, Equatable, Sendable {
    let totalBytes: Int
    let name: String
    let sha256: String
    var receivedBytes: Int
    var claimed: Bool = false
}

/// Any document a remote client attaches (PDF, text, archive, spreadsheet...). Uploads arrive in
/// verified chunks like videos and keep their original bytes beside the session's other
/// attachments, so the agent reads the file itself; nothing here parses or opens it.
actor RemoteFileAttachments {
    static let shared = RemoteFileAttachments()
    static let maximumBytes = 100 << 20
    static let maximumCount = 5
    static let chunkBytes = 1 << 20
    static let maximumPendingBytes = 500 << 20
    static let storageRoot = RemoteImageAttachments.storageRoot
    static let marker = " - read this file; it is part of my request.)"

    private let root: URL

    init(root: URL = storageRoot) {
        self.root = root.resolvingSymlinksInPath()
    }

    /// The stored file's name: the client's base name without path separators, control
    /// characters or leading dots, so it can never escape or hide inside its upload folder.
    nonisolated static func storedName(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" && $0 != ":"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = "file" }
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let keep = ext.isEmpty || ext.count > 12 ? "" : "." + ext
            cleaned = String(cleaned.prefix(120 - keep.count)) + keep
        }
        // The volume is usually case-insensitive, so no variant may alias the manifest.
        return cleaned.lowercased() == "upload.json" ? "file-" + cleaned : cleaned
    }

    /// The prompt text before any image lines: the user's words (or a default request), then
    /// the video's analysis notes and one line per attached file.
    nonisolated static func prompt(_ text: String, video: String?, files: [String], imageCount: Int) -> String {
        var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty {
            prompt = video != nil ? "Please analyze the attached video."
                : files.isEmpty ? ""
                : imageCount > 0 ? "Please look at the attached images and files."
                : files.count == 1 ? "Please look at the attached file." : "Please look at the attached files."
        }
        if let video { prompt += "\n\n" + video }
        for file in files { prompt += "\n\n" + file }
        return prompt
    }

    func status(sessionID: UUID, uploadID: UUID) throws -> RemoteFileUpload {
        try manifest(in: directory(sessionID, uploadID))
    }

    func receive(sessionID: UUID, uploadID: UUID, offset: Int, upload: RemoteFileUpload,
                 data: Data) throws -> RemoteFileUpload {
        guard (1...Self.maximumBytes).contains(upload.totalBytes),
              !upload.name.isEmpty, upload.name.count <= 160,
              // Only control characters are refused: format characters (emoji joiners, RTL
              // marks) are ordinary in real names and are dropped from the stored name instead.
              !upload.name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              upload.sha256.count == 64, upload.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              offset >= 0, offset <= upload.totalBytes,
              !data.isEmpty, data.count <= Self.chunkBytes, data.count <= upload.totalBytes - offset else {
            throw RemoteVideoError(status: 400, message: "Invalid file upload. Files can be up to 100 MB.")
        }
        let folder = try directory(sessionID, uploadID)
        let fm = FileManager.default
        let metadataURL = folder.appendingPathComponent("upload.json")
        var current: RemoteFileUpload
        if fm.fileExists(atPath: metadataURL.path) {
            current = try manifest(in: folder)
            guard current.totalBytes == upload.totalBytes, current.name == upload.name,
                  current.sha256 == upload.sha256 else {
                throw RemoteVideoError(status: 409, message: "This file upload ID belongs to different content.")
            }
        } else {
            guard offset == 0 else { throw RemoteVideoError(status: 409, message: "Restart this file upload.") }
            try reservePendingSpace(upload.totalBytes)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            current = RemoteFileUpload(totalBytes: upload.totalBytes, name: upload.name,
                                       sha256: upload.sha256, receivedBytes: 0)
            try save(current, in: folder)
        }
        let file = try safeFile(Self.storedName(current.name), in: folder)
        if offset < current.receivedBytes {
            guard offset + data.count <= current.receivedBytes else {
                throw RemoteVideoError(status: 409, message: "File chunk overlaps unconfirmed data.")
            }
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            try reader.seek(toOffset: UInt64(offset))
            guard try reader.read(upToCount: data.count) == data else {
                throw RemoteVideoError(status: 409, message: "The repeated file chunk does not match.")
            }
            return current
        }
        guard offset == current.receivedBytes else {
            throw RemoteVideoError(status: 409, message: "File chunks must be uploaded in order.")
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

    /// Verifies a complete upload and returns the prompt line naming the saved file.
    func claim(sessionID: UUID, uploadID: UUID) throws -> String {
        let folder = try directory(sessionID, uploadID)
        var upload = try manifest(in: folder)
        guard upload.receivedBytes == upload.totalBytes else {
            throw RemoteVideoError(status: 409, message: "Finish uploading \(upload.name) before sending.")
        }
        let file = try safeFile(Self.storedName(upload.name), in: folder)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, values.fileSize == upload.totalBytes else {
            throw RemoteVideoError(status: 409, message: "\(upload.name) is no longer complete on the Mac.")
        }
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var digest = SHA256()
        while let data = try reader.read(upToCount: Self.chunkBytes), !data.isEmpty { digest.update(data: data) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == upload.sha256 else {
            throw RemoteVideoError(status: 409, message: "\(upload.name) failed its integrity check. Remove it and attach it again.")
        }
        if !upload.claimed {
            upload.claimed = true
            try save(upload, in: folder)
        }
        return "(Attached file: \(file.path)\(Self.marker)"
    }

    private func directory(_ session: UUID, _ upload: UUID) throws -> URL {
        let url = root.appendingPathComponent(session.uuidString).appendingPathComponent(upload.uuidString)
        guard url.resolvingSymlinksInPath().path == url.path else {
            throw RemoteVideoError(status: 404, message: "File upload is unavailable.")
        }
        return url
    }

    private func safeFile(_ name: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name)
        guard file.deletingLastPathComponent().path == directory.path,
              file.resolvingSymlinksInPath().path == file.path else {
            throw RemoteVideoError(status: 404, message: "File upload is unavailable.")
        }
        return file
    }

    private func manifest(in folder: URL) throws -> RemoteFileUpload {
        let file = try safeFile("upload.json", in: folder)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw RemoteVideoError(status: 404, message: "File upload not found.")
        }
        return try JSONDecoder().decode(RemoteFileUpload.self, from: Data(contentsOf: file))
    }

    private func save(_ upload: RemoteFileUpload, in folder: URL) throws {
        try JSONEncoder().encode(upload).write(to: try safeFile("upload.json", in: folder), options: .atomic)
    }

    /// Unsent uploads count against a shared budget and expire after a day. Folders without an
    /// upload manifest are image attachments and are never touched here.
    private func reservePendingSpace(_ bytes: Int) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        var pending = 0
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let session = root.appendingPathComponent(item.lastPathComponent)
            guard UUID(uuidString: session.lastPathComponent) != nil,
                  session.resolvingSymlinksInPath().path == session.path else { continue }
            for item in try fm.contentsOfDirectory(at: session, includingPropertiesForKeys: nil) {
                let folder = session.appendingPathComponent(item.lastPathComponent)
                guard UUID(uuidString: folder.lastPathComponent) != nil,
                      folder.resolvingSymlinksInPath().path == folder.path else { continue }
                let metadata = try safeFile("upload.json", in: folder)
                guard fm.fileExists(atPath: metadata.path) else { continue }
                let upload = try manifest(in: folder)
                guard !upload.claimed else { continue }
                let date = try fm.attributesOfItem(atPath: metadata.path)[.modificationDate] as? Date
                if let date, Date().timeIntervalSince(date) > 24 * 3600 {
                    try fm.removeItem(at: folder)
                } else {
                    pending += upload.totalBytes
                }
            }
        }
        guard pending + bytes <= Self.maximumPendingBytes else {
            throw RemoteVideoError(status: 413, message: "Too many unfinished file uploads on the Mac. Send or remove pending files, or wait for their 24-hour expiry.")
        }
    }
}
