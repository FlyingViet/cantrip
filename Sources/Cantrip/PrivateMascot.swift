import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Optional artwork owned by this host, never bundled with the app or its public source.
enum PrivateMascot {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cantrip/PrivateMascot", isDirectory: true)
    }

    struct Snapshot: Encodable {
        let version: Int
        let revision: String
        let sparkX: Double
        let sparkY: Double
        let portrait: Data
        let blink: Data
    }

    private struct Manifest: Decodable {
        let version: Int
        let sparkX: Double
        let sparkY: Double
    }

    enum Failure: LocalizedError {
        case invalid

        var errorDescription: String? {
            "The personal mascot pack is invalid. Use a version 1 manifest and two matching square PNGs, "
                + "at most 1024 pixels and 2 MB each."
        }
    }

    final class Store {
        private let directory: URL
        private let lock = NSLock()
        private var stamp: [Stamp]?
        private var cached: Result<Snapshot?, Error>?

        private struct Stamp: Equatable {
            let modified: Date?
            let size: Int?
            let identifier: String
        }

        init(directory: URL = PrivateMascot.directory) {
            self.directory = directory
        }

        func snapshot() throws -> Snapshot? {
            lock.lock()
            defer { lock.unlock() }
            let manifest = directory.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else {
                stamp = nil
                cached = nil
                return nil
            }
            let files = ["manifest.json", "portrait.png", "blink.png"].map {
                directory.appendingPathComponent($0)
            }
            let current = try files.map { url -> Stamp in
                let values = try url.resourceValues(forKeys: [
                    .contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey,
                    .isRegularFileKey, .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.invalid }
                return Stamp(modified: values.contentModificationDate, size: values.fileSize,
                             identifier: String(describing: values.fileResourceIdentifier))
            }
            if stamp == current, let cached { return try cached.get() }
            let result = Result<Snapshot?, Error> {
                guard (current[0].size ?? Int.max) <= 1024,
                      current.dropFirst().allSatisfy({ (1...2_000_000).contains($0.size ?? 0) })
                else { throw Failure.invalid }
                let manifestData = try Data(contentsOf: files[0])
                let description = try JSONDecoder().decode(Manifest.self, from: manifestData)
                guard description.version == 1, description.sparkX.isFinite, description.sparkY.isFinite,
                      (0...1).contains(description.sparkX), (0...1).contains(description.sparkY)
                else { throw Failure.invalid }
                let portrait = try Data(contentsOf: files[1])
                let blink = try Data(contentsOf: files[2])
                guard try dimension(portrait) == dimension(blink) else { throw Failure.invalid }
                var hash = SHA256()
                for data in [manifestData, portrait, blink] { hash.update(data: data) }
                return Snapshot(
                    version: 1, revision: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                    sparkX: description.sparkX, sparkY: description.sparkY, portrait: portrait, blink: blink
                )
            }
            stamp = current
            cached = result
            return try result.get()
        }

        private func dimension(_ data: Data) throws -> Int {
            guard (1...2_000_000).contains(data.count),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width == height, (1...1024).contains(width),
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
            else { throw Failure.invalid }
            return width
        }
    }
}
