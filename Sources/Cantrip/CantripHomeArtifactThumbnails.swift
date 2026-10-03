import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A small JPEG preview for one Home artifact: a downscaled image or a video poster frame.
struct CantripHomeArtifactThumbnail: Codable, Equatable {
    var version = CantripHomeArtifactThumbnails.version
    /// Identifies the exact source file revision the thumbnail was made from.
    let key: String
    let width: Int
    let height: Int
    let durationSeconds: Double?
    let jpeg: Data
}

/// Builds and caches Artifacts-grid thumbnails off the main actor. Sources are read with the
/// same guards as remote previews: regular single-link files inside Home's artifact folder,
/// every folder opened without following symlinks, bounded bytes and pixels.
actor CantripHomeArtifactThumbnails {
    static let shared = CantripHomeArtifactThumbnails()
    static let version = 1
    static let maximumDimension = 600
    static let maximumJPEGBytes = 512 << 10
    static let maximumSourcePixels = 64_000_000
    static let maximumSourceSide = 16_384
    static let posterSeconds = 1.0
    static let videoTimeout: Duration = .seconds(15)

    enum Failure: Error, Equatable {
        case unsupported
        case unavailable
    }

    let artifactRoot: URL
    let cacheRoot: URL
    let maximumSourceBytes: Int
    /// How many thumbnails were generated rather than served from the cache.
    private(set) var generatedCount = 0

    init(
        artifactRoot: URL = CantripHomeStore.artifactDirectory,
        cacheRoot: URL = CantripHomeStore.rootDirectory.appendingPathComponent("thumbnails", isDirectory: true),
        maximumSourceBytes: Int = CantripHomeStore.maximumArtifactBytes
    ) {
        self.artifactRoot = artifactRoot
        self.cacheRoot = cacheRoot
        self.maximumSourceBytes = maximumSourceBytes
    }

    static func supports(_ artifact: CantripHomeArtifact) -> Bool {
        isImage(artifact) || isVideo(artifact)
    }

    private static func isImage(_ artifact: CantripHomeArtifact) -> Bool {
        artifact.kind == "image" || artifact.mimeType.hasPrefix("image/")
    }

    private static func isVideo(_ artifact: CantripHomeArtifact) -> Bool {
        artifact.kind == "video" || artifact.mimeType.hasPrefix("video/")
    }

    func thumbnail(for artifact: CantripHomeArtifact) async throws -> CantripHomeArtifactThumbnail {
        guard Self.supports(artifact) else { throw Failure.unsupported }
        let source = try openSource(artifact.relativePath)
        defer { close(source.descriptor) }
        let key = Self.key(artifact: artifact, size: source.size, modified: source.modified)
        let cached = cacheURL(artifact.id)
        if let data = try? Data(contentsOf: cached),
           let thumbnail = try? JSONDecoder().decode(CantripHomeArtifactThumbnail.self, from: data),
           thumbnail.version == Self.version, thumbnail.key == key {
            return thumbnail
        }
        let bytes = try readAll(source)
        let made: (CGImage, Double?)
        if Self.isImage(artifact) {
            made = (try Self.imageThumbnail(bytes), nil)
        } else {
            made = try await videoPoster(bytes, ext: URL(fileURLWithPath: artifact.relativePath).pathExtension)
        }
        let jpeg = try Self.jpeg(made.0)
        let thumbnail = CantripHomeArtifactThumbnail(
            key: key, width: made.0.width, height: made.0.height, durationSeconds: made.1, jpeg: jpeg
        )
        generatedCount += 1
        do {
            try prepareCacheDirectory()
            try JSONEncoder().encode(thumbnail).write(to: cached, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cached.path)
        } catch {
            Log.write("home: thumbnail cache write failed: \(error.localizedDescription)")
        }
        return thumbnail
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: cacheURL(id))
    }

    // MARK: - Source files

    private struct Source {
        let descriptor: Int32
        let size: Int
        let modified: timespec
    }

    private func cacheURL(_ id: UUID) -> URL {
        cacheRoot.appendingPathComponent("\(id.uuidString).json")
    }

    private static func key(artifact: CantripHomeArtifact, size: Int, modified: timespec) -> String {
        let text = "\(version)|\(artifact.id.uuidString)|\(artifact.relativePath)|\(size)|"
            + "\(modified.tv_sec).\(modified.tv_nsec)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Opens `relativePath` below the artifact folder, one component at a time.
    private func openSource(_ relativePath: String) throws -> Source {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.count <= 16, !relativePath.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relativePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw Failure.unavailable }
        let root = artifactRoot.standardizedFileURL
        guard root.resolvingSymlinksInPath().standardizedFileURL == root else { throw Failure.unavailable }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.unavailable }
        defer { close(directory) }
        for name in components.dropLast() {
            let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.unavailable }
            close(directory)
            directory = next
        }
        let descriptor = openat(directory, components[components.count - 1],
                                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= maximumSourceBytes else {
            close(descriptor)
            throw Failure.unavailable
        }
        return Source(descriptor: descriptor, size: Int(info.st_size), modified: info.st_mtimespec)
    }

    private func readAll(_ source: Source) throws -> Data {
        let handle = FileHandle(fileDescriptor: source.descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumSourceBytes + 1) ?? Data()
        guard data.count == source.size, data.count <= maximumSourceBytes else { throw Failure.unavailable }
        return data
    }

    private func prepareCacheDirectory() throws {
        try FileManager.default.createDirectory(
            at: cacheRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        guard cacheRoot.resolvingSymlinksInPath().standardizedFileURL == cacheRoot.standardizedFileURL else {
            throw Failure.unavailable
        }
    }

    // MARK: - Images

    private static let imageTypes: Set<String> = [
        UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier,
        UTType.webP.identifier, UTType.heic.identifier, UTType.heif.identifier
    ]

    static func imageThumbnail(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, imageTypes.contains(type),
              CGImageSourceGetCount(source) >= 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maximumSourceSide).contains(width), (1...maximumSourceSide).contains(height),
              width * height <= maximumSourcePixels,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw Failure.unavailable }
        return image
    }

    // MARK: - Videos

    /// AVFoundation needs a path, so the validated bytes are decoded from a private copy;
    /// the original is never reopened by path.
    private func videoPoster(_ data: Data, ext: String) async throws -> (CGImage, Double?) {
        try prepareCacheDirectory()
        let safeExtension = ["mov", "mp4", "m4v"].contains(ext.lowercased()) ? ext.lowercased() : "mov"
        let copy = cacheRoot.appendingPathComponent("source-\(UUID().uuidString).\(safeExtension)")
        guard FileManager.default.createFile(atPath: copy.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Failure.unavailable
        }
        defer { try? FileManager.default.removeItem(at: copy) }
        do {
            return try await withThrowingTaskGroup(of: (CGImage, Double?).self) { group in
                group.addTask { try await Self.poster(of: copy) }
                group.addTask {
                    try await Task.sleep(for: Self.videoTimeout)
                    throw Failure.unavailable
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw Failure.unavailable }
                return first
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            Log.write("home: video poster failed: \(error.localizedDescription)")
            throw Failure.unavailable
        }
    }

    static func poster(of url: URL) async throws -> (CGImage, Double?) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.unavailable
        }
        let size = try await track.load(.naturalSize)
        guard size.width >= 1, size.height >= 1, size.width <= CGFloat(maximumSourceSide),
              size.height <= CGFloat(maximumSourceSide),
              Int(size.width) * Int(size.height) <= maximumSourcePixels else { throw Failure.unavailable }
        let seconds = duration.isNumeric ? max(0, duration.seconds) : 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumDimension, height: maximumDimension)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        // About one second in skips black lead-in frames; very short clips use their middle.
        let time = seconds > posterSeconds * 2 ? posterSeconds : seconds / 2
        let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        return (image, seconds > 0 ? seconds : nil)
    }

    // MARK: - Encoding

    static func jpeg(_ image: CGImage) throws -> Data {
        for quality in [0.8, 0.65, 0.5] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil
            ) else { throw Failure.unavailable }
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: quality
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.unavailable }
            if output.length <= maximumJPEGBytes { return output as Data }
        }
        throw Failure.unavailable
    }
}
