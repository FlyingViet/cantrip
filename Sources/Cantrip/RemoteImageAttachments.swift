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
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/remote-attachments", isDirectory: true)
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
