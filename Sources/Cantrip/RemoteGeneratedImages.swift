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
    /// Every Copilot CLI session (each tab's and Home's) keeps agent output in
    /// `<copilotStateRoot>/<session UUID>/files/`.
    static let copilotStateRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".copilot/session-state", isDirectory: true)

    /// Allowed folders may contain subfolders, up to this depth.
    static let maximumNestedDirectories = 8
    /// Cantrip's own folders inside the shared output folder: per-session uploads, preview
    /// caches, transcripts and Home's state. Agents' subfolders preview; these never do.
    static let reservedSharedFolders: Set<String> = [
        "chats", "home", "maintenance", "notifications", "recovery",
        "remote-attachments", "remote-previews", "remote-videos", "runs"
    ]

    /// Agent-facing instructions; every backend that can reach the Remote apps gets them.
    static func agentGuidance(sessionFilesFolder: Bool) -> String {
        let folders = sessionFilesFolder
            ? "in this session's files folder or in ~/.cache/Cantrip/ (subfolders are fine in both)"
            : "in ~/.cache/Cantrip/ (subfolders are fine)"
        return """
        Cantrip's iPhone, browser and Mac Remote apps show images from this Mac inline. To show \
        the user a screenshot or generated image, save it as PNG or JPEG \(folders), then put a \
        Markdown image on its own line with the absolute path: \
        `![Short description](/absolute/path.png)`. A Markdown link to the same file opens it full \
        size. Paths in backticks are not shown, and images elsewhere on the Mac don't preview, so \
        copy them into one of those folders first.
        """
    }

    struct Reference {
        let id: String
        let source: URL
        /// The allowed folder the source was found under; reads walk down from it.
        let root: URL
        let altText: String

        var markdownURL: String { "cantrip-preview://image/\(id)" }
        var snapshot: [String: String] { ["id": id, "altText": altText] }
    }

    struct Presentation {
        let text: String
        let images: [Reference]
    }

    // Standalone image blocks become inline previews; ordinary links to the same kind of
    // file open the full-size viewer. Code, uploaded attachments and files outside the
    // allowed folders stay untouched.
    private static let imagePattern = try! NSRegularExpression(
        pattern: #"^ {0,3}!\[([^\]\r\n]*)\]\((<[^>\r\n]+>|[^()\r\n]+)\)[ \t]*\r?$"#
    )
    private static let linkPattern = try! NSRegularExpression(
        pattern: #"(?<![!\\])\[([^\[\]\r\n]*)\]\((<[^>\r\n]+>|[^()\s]+)\)"#
    )

    /// Images preview from `root` (the shared output folder, minus Cantrip's reserved folders),
    /// any Copilot session's `<sessionStateRoot>/<UUID>/files/` folder, and `additionalRoots`
    /// owned by this session (Home artifacts). Subfolders are allowed in all of them.
    static func presentation(
        _ text: String,
        messageID: UUID,
        root: URL = sourceRoot,
        sessionStateRoot: URL = copilotStateRoot,
        additionalRoots: [URL] = []
    ) -> Presentation {
        guard text.contains("](") else { return Presentation(text: text, images: []) }
        let roots = [(url: root, reserved: reservedSharedFolders)] + additionalRoots.map { (url: $0, reserved: []) }
        var images: [Reference] = []
        func reference(_ target: String, altText: String) -> Reference? {
            var target = target
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            guard let (source, base) = sourceURL(target, roots: roots, sessionStateRoot: sessionStateRoot)
            else { return nil }
            let hash = SHA256.hash(data: Data(source.path.utf8)).map { String(format: "%02x", $0) }.joined()
            let id = "previews/\(messageID.uuidString)/\(hash).jpg"
            if let existing = images.first(where: { $0.id == id }) { return existing }
            guard images.count < maximumCount else { return nil }
            let created = Reference(id: id, source: source, root: base, altText: altText)
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

    private static func sourceURL(_ target: String, roots: [(url: URL, reserved: Set<String>)],
                                  sessionStateRoot: URL) -> (URL, URL)? {
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
        let file = url.standardizedFileURL
        let components = file.pathComponents
        func allowed(_ directories: ArraySlice<String>, reserved: Set<String>) -> Bool {
            guard directories.count <= maximumNestedDirectories,
                  directories.allSatisfy({ !$0.hasPrefix(".") }) else { return false }
            // The Mac's file system ignores case, so "Remote-Attachments" is the same folder.
            guard let first = directories.first else { return true }
            return !reserved.contains(first.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil
            ))
        }
        for root in roots {
            let base = root.url.standardizedFileURL
            let prefix = base.pathComponents
            guard components.count > prefix.count, Array(components.prefix(prefix.count)) == prefix,
                  allowed(components.dropFirst(prefix.count).dropLast(), reserved: root.reserved) else { continue }
            return (file, base)
        }
        // <sessionStateRoot>/<CLI session UUID>/files/... for any tab's or Home's CLI session.
        let state = sessionStateRoot.standardizedFileURL
        let prefix = state.pathComponents
        guard components.count > prefix.count + 2, Array(components.prefix(prefix.count)) == prefix,
              UUID(uuidString: components[prefix.count]) != nil, components[prefix.count + 1] == "files",
              allowed(components.dropFirst(prefix.count + 2).dropLast(), reserved: []) else { return nil }
        let base = state.appendingPathComponent(components[prefix.count], isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
        return (file, base)
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
            let data = try readFile(reference.source, under: reference.root, limit: maximumSourceBytes)
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
    /// for a link after validation cannot redirect the read outside the allowed folder.
    private static func readFile(_ url: URL, under root: URL? = nil, limit: Int) throws -> Data {
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
            throw unavailable()
        }
        let file = url.standardizedFileURL
        let base = (root ?? file.deletingLastPathComponent()).standardizedFileURL
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
