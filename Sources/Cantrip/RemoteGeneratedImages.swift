import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RemoteGeneratedImages {
    static let maximumCount = 8
    static let maximumSourceBytes = 30 << 20
    static let maximumImageBytes = 4 << 20
    static let maximumDimension = 4096
    static let thumbnailDimension = 960
    static let sourceRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/Cantrip", isDirectory: true)
    static let storageRoot = sourceRoot.appendingPathComponent("remote-previews", isDirectory: true)

    struct Reference {
        let id: String
        let source: URL
        let altText: String

        var markdownURL: String { "cantrip-preview://image/\(id)" }
        var snapshot: [String: String] { ["id": id, "altText": altText] }
    }

    struct Presentation {
        let text: String
        let images: [Reference]
    }

    // Only standalone image blocks opt in. Code examples, ordinary file links,
    // uploaded attachments and files outside the output directory stay untouched.
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"^ {0,3}!\[([^\]\r\n]*)\]\((<[^>\r\n]+>|[^()\r\n]+)\)[ \t]*\r?$"#
    )

    static func presentation(_ text: String, messageID: UUID, root: URL = sourceRoot) -> Presentation {
        guard text.contains("![") else { return Presentation(text: text, images: []) }
        var images: [Reference] = []
        var fence: (Character, Int)?
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                if trimmed.prefix(while: { $0 == active.0 }).count >= active.1,
                   trimmed.allSatisfy({ $0 == active.0 || $0.isWhitespace }) {
                    fence = nil
                }
                return line
            }
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 { fence = (first, count); return line }
            }
            let string = line as NSString
            guard let match = imagePattern.firstMatch(
                in: line, range: NSRange(location: 0, length: string.length)
            ) else { return line }
            var target = string.substring(with: match.range(at: 2))
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            guard let source = sourceURL(target, root: root) else { return line }
            let hash = SHA256.hash(data: Data(source.path.utf8)).map { String(format: "%02x", $0) }.joined()
            let id = "previews/\(messageID.uuidString)/\(hash).jpg"
            let reference: Reference
            if let existing = images.first(where: { $0.id == id }) {
                reference = existing
            } else {
                guard images.count < maximumCount else { return line }
                reference = Reference(id: id, source: source, altText: string.substring(with: match.range(at: 1)))
                images.append(reference)
            }
            return string.replacingCharacters(in: match.range(at: 2), with: reference.markdownURL)
        }
        return Presentation(text: lines.joined(separator: "\n"), images: images)
    }

    static func validID(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "previews", UUID(uuidString: String(parts[1])) != nil,
              parts[2].hasSuffix(".jpg") else { return false }
        let hash = parts[2].dropLast(4)
        return hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sourceURL(_ target: String, root: URL) -> URL? {
        let url: URL
        if target.hasPrefix("file:") {
            guard let file = URL(string: target), file.isFileURL,
                  file.host == nil || file.host == "" || file.host == "localhost",
                  file.query == nil, file.fragment == nil else { return nil }
            url = file
        } else {
            guard let path = target.removingPercentEncoding else { return nil }
            if path.hasPrefix("~/") {
                url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
            } else if path.hasPrefix("/") {
                url = URL(fileURLWithPath: path)
            } else {
                return nil
            }
        }
        guard !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !url.pathComponents.contains(".."),
              url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return nil }
        return url.standardizedFileURL
    }

    actor Store {
        let root: URL

        init(root: URL = storageRoot) { self.root = root }

        func read(_ reference: Reference, sessionID: UUID, thumbnail: Bool) throws -> Data {
            try RemoteGeneratedImages.read(reference, sessionID: sessionID, thumbnail: thumbnail, root: root)
        }
    }

    static func read(_ reference: Reference, sessionID: UUID, thumbnail: Bool,
                     root: URL = storageRoot) throws -> Data {
        guard validID(reference.id) else { throw unavailable() }
        let components = reference.id.split(separator: "/")
        let directory = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(String(components[1]), isDirectory: true)
        let cached = directory.appendingPathComponent(String(components[2]))
        guard cached.resolvingSymlinksInPath().standardizedFileURL == cached.standardizedFileURL else {
            throw unavailable()
        }
        let full: Data
        if FileManager.default.fileExists(atPath: cached.path) {
            full = try readFile(cached, limit: maximumImageBytes)
            _ = try imageSource(full, maximumPixels: maximumDimension * maximumDimension)
        } else {
            let data = try readFile(reference.source, limit: maximumSourceBytes)
            let source = try imageSource(data, maximumPixels: 64_000_000)
            full = try jpeg(source, dimension: maximumDimension)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
                throw unavailable()
            }
            try full.write(to: cached, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cached.path)
        }
        guard thumbnail else { return full }
        return try jpeg(imageSource(full, maximumPixels: maximumDimension * maximumDimension),
                        dimension: thumbnailDimension)
    }

    private static func readFile(_ url: URL, limit: Int) throws -> Data {
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
            throw unavailable()
        }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw unavailable() }
        defer { close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw unavailable() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= limit else { throw unavailable() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard !data.isEmpty, data.count <= limit else { throw unavailable() }
        return data
    }

    private static func imageSource(_ data: Data, maximumPixels: Int) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...16384).contains(width), (1...16384).contains(height),
              width * height <= maximumPixels else { throw unavailable() }
        return source
    }

    private static func jpeg(_ source: CGImageSource, dimension: Int) throws -> Data {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: dimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw unavailable() }
        for quality in [0.9, 0.75, 0.6, 0.45] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil
            ) else { throw unavailable() }
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: quality
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw unavailable() }
            if output.length <= maximumImageBytes { return output as Data }
        }
        throw RemoteImageAttachmentError.invalid("The generated image is too large to preview.")
    }

    private static func unavailable() -> RemoteImageAttachmentError {
        .invalid("The generated image is unavailable or is not a supported PNG or JPEG on the Mac.")
    }
}
