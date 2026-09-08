import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RemoteImageUpload: Decodable {
    let data: Data
}

enum RemoteImageAttachmentError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

enum RemoteImageAttachments {
    static let maximumCount = 4
    static let maximumImageBytes = 1 << 20
    static let maximumRequestBytes = 7 << 20
    static let storageRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/Cantrip/remote-attachments", isDirectory: true)

    struct Presentation {
        let text: String
        let imageIDs: [String]
    }

    // Only our own complete upload markers become images; ordinary paths and
    // quoted agent output must never grant access to arbitrary Mac files.
    static func presentation(
        _ text: String, sessionID: UUID, root: URL = storageRoot
    ) -> Presentation {
        let prefix = root.appendingPathComponent(sessionID.uuidString).path + "/"
        guard text.contains("(Attached image: " + prefix) else {
            return Presentation(text: text, imageIDs: [])
        }
        let pattern = #"(?m)^\(Attached image: "#
            + NSRegularExpression.escapedPattern(for: prefix)
            + #"([A-Fa-f0-9-]{36}/image-[1-4]\.jpg) - view this image file; it is part of my request\.\)$"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
            .filter { validID(source.substring(with: $0.range(at: 1))) }
        guard !matches.isEmpty else { return Presentation(text: text, imageIDs: []) }
        let display = NSMutableString(string: text)
        for match in matches.reversed() { display.replaceCharacters(in: match.range, with: "") }
        var seen = Set<String>()
        let ids = matches.map { source.substring(with: $0.range(at: 1)) }
            .filter { seen.insert($0).inserted }
        return Presentation(
            text: (display as String).trimmingCharacters(in: .whitespacesAndNewlines),
            imageIDs: ids
        )
    }

    static func validID(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil
            && (1...maximumCount).contains(where: { parts[1] == "image-\($0).jpg" })
    }

    static func read(
        id: String, sessionID: UUID, thumbnail: Bool, root: URL = storageRoot
    ) throws -> Data {
        guard validID(id) else { throw RemoteImageAttachmentError.invalid("Invalid image ID.") }
        let base = root.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(sessionID.uuidString).appendingPathComponent(id)
        guard url.resolvingSymlinksInPath().path == url.path else {
            throw RemoteImageAttachmentError.invalid("The attached image is no longer available.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maximumImageBytes else {
            throw RemoteImageAttachmentError.invalid("The attached image is no longer available.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumImageBytes + 1) ?? Data()
        _ = try decode([["data": data.base64EncodedString()]])
        guard thumbnail else { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            throw RemoteImageAttachmentError.invalid("The image preview could not be created.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw RemoteImageAttachmentError.invalid("The image preview could not be created.") }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RemoteImageAttachmentError.invalid("The image preview could not be created.")
        }
        return output as Data
    }

    static func decode(_ value: Any?) throws -> [RemoteImageUpload] {
        guard let value else { return [] }
        guard let array = value as? [[String: Any]], array.count <= maximumCount else {
            throw RemoteImageAttachmentError.invalid("Attach at most four images.")
        }
        let images: [RemoteImageUpload]
        do {
            images = try JSONDecoder().decode(
                [RemoteImageUpload].self,
                from: JSONSerialization.data(withJSONObject: array)
            )
        } catch {
            throw RemoteImageAttachmentError.invalid("Images must contain base64-encoded JPEG data.")
        }
        for image in images {
            guard !image.data.isEmpty, image.data.count <= maximumImageBytes,
                  let source = CGImageSourceCreateWithData(image.data as CFData, nil),
                  CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...2048).contains(width), (1...2048).contains(height),
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw RemoteImageAttachmentError.invalid(
                    "Each image must be a valid JPEG, at most 1 MB and 2048 pixels per side."
                )
            }
        }
        return images
    }

    /// Keep uploaded files with the session's durable context so queued and
    /// recovered runs can still open them. Never use a client-supplied path.
    static func preparePrompt(
        _ text: String,
        images: [RemoteImageUpload],
        sessionID: UUID,
        root: URL = storageRoot
    ) throws -> String {
        guard !images.isEmpty else { return text }
        let directory = root
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty { prompt = "Please look at the attached images." }
        do {
            for (index, image) in images.enumerated() {
                let url = directory.appendingPathComponent("image-\(index + 1).jpg")
                try image.data.write(to: url, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                prompt += "\n\n(Attached image: \(url.path) - view this image file; it is part of my request.)"
            }
        } catch {
            do {
                try manager.removeItem(at: directory)
            } catch {
                // Report cleanup failures too; the caller reports the original write error.
                NSLog("Cantrip remote image cleanup failed: %@", error.localizedDescription)
            }
            throw error
        }
        return prompt
    }
}
