import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct ChatImageAttachment: Identifiable, Equatable, Sendable {
    let id = UUID()
    let data: Data

    var preview: UIImage? { UIImage(data: data) }
}

struct ChatMessageImage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var sessionID: String?
    var data: Data?

    init(id: String, sessionID: String? = nil, data: Data? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.data = data
    }

    init(_ attachment: ChatImageAttachment) {
        self.init(id: attachment.id.uuidString, data: attachment.data)
    }

    func inSession(_ id: String) -> Self {
        Self(id: self.id, sessionID: id)
    }

    static func validRemoteID(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil
            && (1...ImageAttachmentProcessor.maximumCount).contains {
                parts[1] == "image-\($0).jpg"
            }
    }
}

enum ImageAttachmentError: LocalizedError {
    case invalidImage
    case tooLarge
    case tooMany
    case emptyClipboard

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "This file could not be read as an image."
        case .tooLarge: return "This image is too large. Choose a smaller image or crop it first."
        case .tooMany: return "You can attach up to four images per message."
        case .emptyClipboard: return "Copy a photo or screenshot first, then tap Paste Image."
        }
    }
}

enum ImageAttachmentProcessor {
    static let maximumCount = 4
    static let maximumSourceBytes = 30 << 20
    static let maximumImageBytes = 1 << 20
    static let maximumDimension = 2048

    static func prepare(_ data: Data) throws -> ChatImageAttachment {
        guard data.count <= maximumSourceBytes else { throw ImageAttachmentError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw ImageAttachmentError.invalidImage }

        // Re-encode oriented pixels only, without the original photo's metadata.
        for quality in [0.9, 0.75, 0.6, 0.45] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil
            ) else { throw ImageAttachmentError.invalidImage }
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: quality
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ImageAttachmentError.invalidImage
            }
            if output.length <= maximumImageBytes {
                return ChatImageAttachment(data: output as Data)
            }
        }
        throw ImageAttachmentError.tooLarge
    }

    static func readFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maximumSourceBytes {
            throw ImageAttachmentError.tooLarge
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
}

struct CantripMessageBody: Encodable {
    let text: String
    let mode: String
    let images: [ImageUpload]?

    struct ImageUpload: Encodable {
        let data: Data
    }

    init(text: String, mode: CantripDeliveryMode, images: [ChatImageAttachment]) {
        self.text = text
        self.mode = mode.rawValue
        self.images = images.isEmpty ? nil : images.map { ImageUpload(data: $0.data) }
    }
}
