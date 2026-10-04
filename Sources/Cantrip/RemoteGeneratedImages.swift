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
    static let homeArtifactRoot = sourceRoot
        .appendingPathComponent("home/artifacts", isDirectory: true)
    static let storageRoot = sourceRoot.appendingPathComponent("remote-previews", isDirectory: true)

    /// Cantrip's own folders inside the shared output folder: per-session uploads, preview
    /// caches, transcripts and Home's state. Images anywhere else on the Mac preview when an
    /// assistant reply in the session references them; these never do.
    static let reservedSharedFolders: Set<String> = [
        "chats", "home", "maintenance", "notifications", "recovery",
        "remote-attachments", "remote-previews", "remote-videos", "runs"
    ]

    /// Agent-facing instructions; every backend that can reach the Remote apps gets them.
    static func agentGuidance(sessionFilesFolder: Bool) -> String {
        let folders = sessionFilesFolder
            ? "this session's files folder or ~/.cache/Cantrip/ (subfolders are fine)"
            : "~/.cache/Cantrip/ (subfolders are fine)"
        return """
        Cantrip's iPhone, browser and Mac Remote apps show images from this Mac inline. To show \
        the user a screenshot or generated image, put a Markdown image on its own line with the \
        absolute path of a PNG or JPEG: `![Short description](/absolute/path.png)`. Any folder on \
        the Mac works; save new files in \(folders). A Markdown link to the same file opens it \
        full size. Paths in backticks are not shown.
        """
    }

    struct Reference {
        let id: String
        let source: URL
        /// Cantrip's shared output folder, whose reserved subfolders never preview.
        let sharedRoot: URL
        /// Folders only this session may preview from, even inside reserved ones (Home artifacts).
        let ownedRoots: [URL]
        let altText: String

        var markdownURL: String { "cantrip-preview://image/\(id)" }
        var snapshot: [String: String] { ["id": id, "altText": altText] }
    }

    struct Presentation {
        let text: String
        let images: [Reference]
    }

    // Standalone image blocks become inline previews; ordinary links to the same kind of
    // file open the full-size viewer. Code, uploaded attachments and Cantrip's reserved
    // folders stay untouched.
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"^ {0,3}!\[([^\]\r\n]*)\]\((<[^>\r\n]+>|[^()\r\n]+)\)[ \t]*\r?$"#
    )
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"(?<![!\\])\[([^\[\]\r\n]*)\]\((<[^>\r\n]+>|[^()\s]+)\)"#
    )

    /// A PNG or JPEG anywhere on the Mac previews, except in Cantrip's reserved folders under
    /// `root` (the shared output folder). `additionalRoots` are owned by this session and preview
    /// even there (Home artifacts). Reads re-check the rule after resolving symlinks.
    static func presentation(
        _ text: String,
        messageID: UUID,
        root: URL = sourceRoot,
        additionalRoots: [URL] = []
    ) -> Presentation {
        guard text.contains("](") else { return Presentation(text: text, images: []) }
        var images: [Reference] = []
        func reference(_ target: String, altText: String) -> Reference? {
            var target = target
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            guard let source = sourceURL(target),
                  isAllowed(source, sharedRoot: root, ownedRoots: additionalRoots) else { return nil }
            let hash = SHA256.hash(data: Data(source.path.utf8)).map { String(format: "%02x", $0) }.joined()
            let id = "previews/\(messageID.uuidString)/\(hash).jpg"
            if let existing = images.first(where: { $0.id == id }) { return existing }
            guard images.count < maximumCount else { return nil }
            let created = Reference(id: id, source: source, sharedRoot: root, ownedRoots: additionalRoots,
                                    altText: altText)
            images.append(created)
            return created
        }
        var fence: (Character, Int)?
        var imageLines = Set<Int>()
        let lines = text.components(separatedBy: "\n").enumerated().map { index, line -> String in
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
            let whole = NSRange(location: 0, length: string.length)
            if let match = imagePattern.firstMatch(in: line, range: whole) {
                guard let image = reference(
                    string.substring(with: match.range(at: 2)),
                    altText: string.substring(with: match.range(at: 1))
                ) else { return line }
                imageLines.insert(index)
                return string.replacingCharacters(in: match.range(at: 2), with: image.markdownURL)
            }
            guard line.contains("](") else { return line }
            let code = codeSpans(in: string)
            var rewritten = line as NSString
            for match in linkPattern.matches(in: line, range: whole).reversed()
            where !code.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                guard let linked = reference(
                    string.substring(with: match.range(at: 2)),
                    altText: string.substring(with: match.range(at: 1))
                ) else { continue }
                rewritten = rewritten.replacingCharacters(in: match.range(at: 2), with: linked.markdownURL) as NSString
            }
            return rewritten as String
        }
        // "**Before**\n![..](..)" is one Markdown paragraph, and clients drop an image inside
        // text. A blank line between an image line and adjacent text keeps the image a block.
        var output: [String] = []
        for (index, line) in lines.enumerated() {
            if index > 0, imageLines.contains(index) != imageLines.contains(index - 1),
               !isBlank(line), !isBlank(lines[index - 1]) {
                output.append("")
            }
            output.append(line)
        }
        return Presentation(text: output.joined(separator: "\n"), images: images)
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    /// Inline code spans (`code`, ``code``) on one line, as UTF-16 ranges.
    private static func codeSpans(in line: NSString) -> [NSRange] {
        let tick: unichar = 96
        func run(at index: Int) -> Int {
            var end = index
            while end < line.length, line.character(at: end) == tick { end += 1 }
            return end - index
        }
        var spans: [NSRange] = []
        var index = 0
        while index < line.length {
            guard line.character(at: index) == tick else { index += 1; continue }
            let opening = run(at: index)
            var search = index + opening
            var closed = false
            while search < line.length {
                guard line.character(at: search) == tick else { search += 1; continue }
                let closing = run(at: search)
                if closing == opening {
                    spans.append(NSRange(location: index, length: search + closing - index))
                    index = search + closing
                    closed = true
                    break
                }
                search += closing
            }
            if !closed { index += opening }
        }
        return spans
    }

    static func validID(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "previews", UUID(uuidString: String(parts[1])) != nil,
              parts[2].hasSuffix(".jpg") else { return false }
        let hash = parts[2].dropLast(4)
        return hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func sourceURL(_ target: String) -> URL? {
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
              !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
              ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else { return nil }
        return url.standardizedFileURL
    }

    /// Everything previews except Cantrip's reserved folders in `sharedRoot`, unless the file is in
    /// a folder this session owns. The Mac's file system ignores case, so neither do the checks.
    private static func isAllowed(_ file: URL, sharedRoot: URL, ownedRoots: [URL]) -> Bool {
        func folded(_ url: URL) -> [String] {
            url.standardizedFileURL.pathComponents.map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            }
        }
        let components = folded(file)
        func within(_ root: [String]) -> Bool {
            components.count > root.count && Array(components.prefix(root.count)) == root
        }
        if ownedRoots.contains(where: { within(folded($0)) }) { return true }
        let shared = folded(sharedRoot)
        guard within(shared), components.count > shared.count + 1 else { return true }
        return !reservedSharedFolders.contains(components[shared.count])
    }

    /// The file's real path with every symlink resolved (`/tmp` becomes `/private/tmp`).
    private static func realPath(_ url: URL) -> URL? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
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
            // Resolve links first and check the real location, so a link elsewhere can't reach a
            // reserved folder; then open each folder from "/" without following links, so one
            // swapped in after this check can't either. An owned folder that is itself a link
            // elsewhere grants nothing.
            let owned = reference.ownedRoots.compactMap { root -> URL? in
                guard let real = realPath(root), real.standardizedFileURL.path == root.standardizedFileURL.path
                else { return nil }
                return real
            }
            guard let resolved = realPath(reference.source),
                  isAllowed(resolved, sharedRoot: realPath(reference.sharedRoot) ?? reference.sharedRoot,
                            ownedRoots: owned) else { throw unavailable() }
            let data = try readFile(resolved, under: URL(fileURLWithPath: "/"), limit: maximumSourceBytes)
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

    /// Opens every directory below `root` without following symlinks, so a folder swapped
    /// for a link after validation cannot redirect the read.
    private static func readFile(_ url: URL, under root: URL? = nil, limit: Int) throws -> Data {
        // Foundation's standardizing strips "/private", turning a resolved path back into links.
        let fromRoot = root?.path == "/"
        let file = fromRoot ? url : url.standardizedFileURL
        let base = fromRoot ? URL(fileURLWithPath: "/") : (root ?? file.deletingLastPathComponent()).standardizedFileURL
        // Below `base` the walk refuses links; above it, the path must already be link-free.
        guard fromRoot || url.resolvingSymlinksInPath().standardizedFileURL == file else {
            throw unavailable()
        }
        let prefix = base.pathComponents, components = file.pathComponents
        guard components.count > prefix.count, Array(components.prefix(prefix.count)) == prefix else {
            throw unavailable()
        }
        var directory = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw unavailable() }
        defer { close(directory) }
        for name in components.dropFirst(prefix.count).dropLast() {
            let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw unavailable() }
            close(directory)
            directory = next
        }
        let descriptor = openat(directory, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
