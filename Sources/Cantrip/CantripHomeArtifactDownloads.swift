import Darwin
import Foundation

/// A response body produced in pieces, so a large file never sits whole in memory.
protocol RemoteStreamBody: AnyObject {
    var length: Int { get }
    /// The next piece, or nil once all `length` bytes were produced. Throws when the
    /// source ends early or changed, so the connection closes short of Content-Length.
    func next(maxBytes: Int) throws -> Data?
}

/// One registered artifact chosen for a download: its file inside the artifacts folder and the
/// name it gets on the client (a file name, or a path inside the zip for folder downloads).
struct CantripHomeArtifactDownloadEntry: Equatable {
    let url: URL
    let name: String
    let modified: Date
}

/// A download of one artifact (its original bytes) or of every registered artifact in one
/// folder (an uncompressed zip). Only registered artifacts are ever opened, each with
/// `O_NOFOLLOW` and checked again by its open descriptor's real path, so a file swapped for a
/// link after registration can't send anything from outside the artifacts folder.
struct CantripHomeArtifactDownload {
    static let maximumFolderEntries = 1_000
    static let maximumFolderBytes = 2 * 1024 * 1024 * 1024

    let fileName: String
    let contentType: String
    let root: URL
    let entries: [CantripHomeArtifactDownloadEntry]
    let isArchive: Bool

    func makeBody() throws -> RemoteStreamBody {
        let realRoot = try Self.realPath(root)
        if !isArchive {
            guard let entry = entries.first, entries.count == 1 else { throw Self.unavailable }
            let handle = try Self.open(entry.url, realRoot: realRoot)
            let size = try Self.size(of: handle)
            return CantripHomeArtifactStream(
                segments: [.file(entry.url, size)], realRoot: realRoot, firstHandle: handle
            )
        }
        return try CantripHomeArtifactZip.body(entries: entries, realRoot: realRoot)
    }

    /// `attachment` with an ASCII fallback and the exact UTF-8 name (RFC 6266 / 5987).
    var contentDisposition: String {
        let name = fileName.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" }
        let fallback = String(String.UnicodeScalarView(name.map {
            $0.isASCII && $0 != "\"" && $0 != "\\" && $0 != "%" ? $0 : "_"
        }))
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~"
        )
        let encoded = String(String.UnicodeScalarView(name))
            .addingPercentEncoding(withAllowedCharacters: allowed) ?? fallback
        return "attachment; filename=\"\(fallback)\"; filename*=UTF-8''\(encoded)"
    }

    static let unavailable = CantripHomeError(404, "Artifact is no longer available on the Mac.")

    static func realPath(_ url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { throw unavailable }
        return String(cString: buffer)
    }

    /// Opens a regular file whose real path is inside `realRoot`; never follows a final link.
    static func open(_ url: URL, realRoot: String) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw unavailable }
        var info = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              fcntl(descriptor, F_GETPATH, &path) != -1,
              String(cString: path).hasPrefix(realRoot + "/") else {
            close(descriptor)
            throw unavailable
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func size(of handle: FileHandle) throws -> Int {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw unavailable }
        return Int(info.st_size)
    }
}

/// Plain bytes and file ranges sent in order; each file is read only while it is being sent.
final class CantripHomeArtifactStream: RemoteStreamBody {
    enum Segment {
        case bytes(Data)
        case file(URL, Int)
    }

    let length: Int
    private let segments: [Segment]
    private let realRoot: String
    private var index = 0
    private var handle: FileHandle?
    private var remaining = 0

    init(segments: [Segment], realRoot: String, firstHandle: FileHandle? = nil) {
        self.segments = segments
        self.realRoot = realRoot
        length = segments.reduce(0) { total, segment in
            switch segment {
            case .bytes(let data): return total + data.count
            case .file(_, let size): return total + size
            }
        }
        if let firstHandle, case .file(_, let size)? = segments.first {
            handle = firstHandle
            remaining = size
        }
    }

    func next(maxBytes: Int) throws -> Data? {
        while index < segments.count {
            switch segments[index] {
            case .bytes(let data):
                index += 1
                if !data.isEmpty { return data }
            case .file(let url, let size):
                if handle == nil {
                    handle = try CantripHomeArtifactDownload.open(url, realRoot: realRoot)
                    remaining = size
                }
                guard remaining > 0, let current = handle else {
                    handle = nil
                    index += 1
                    continue
                }
                let piece = try current.read(upToCount: min(max(maxBytes, 1), remaining)) ?? Data()
                guard !piece.isEmpty else { throw CantripHomeArtifactDownload.unavailable }
                remaining -= piece.count
                if remaining == 0 {
                    handle = nil
                    index += 1
                }
                return piece
            }
        }
        return nil
    }
}

/// An uncompressed (stored) zip whose sizes and CRCs are measured first, so the response has an
/// exact Content-Length and needs no data descriptors.
enum CantripHomeArtifactZip {
    static func body(entries: [CantripHomeArtifactDownloadEntry], realRoot: String) throws
        -> CantripHomeArtifactStream {
        guard !entries.isEmpty, entries.count <= CantripHomeArtifactDownload.maximumFolderEntries else {
            throw CantripHomeError(413, "This folder has too many artifacts to download as one zip.")
        }
        var segments: [CantripHomeArtifactStream.Segment] = []
        var central = Data()
        var offset = 0
        for entry in entries {
            let handle = try CantripHomeArtifactDownload.open(entry.url, realRoot: realRoot)
            let size = try CantripHomeArtifactDownload.size(of: handle)
            var crc: UInt32 = 0
            var measured = 0
            while measured < size {
                let piece = try handle.read(upToCount: min(1 << 20, size - measured)) ?? Data()
                guard !piece.isEmpty else { throw CantripHomeArtifactDownload.unavailable }
                crc = HTTPCompression.crc32(piece, continuing: crc)
                measured += piece.count
            }
            let name = Data(entry.name.utf8)
            guard name.count <= 0xFFFF else { throw CantripHomeArtifactDownload.unavailable }
            let (time, date) = dosTimestamp(entry.modified)
            var local = Data()
            local.appendLittleEndian(UInt32(0x0403_4B50))
            local.appendLittleEndian(UInt16(20))
            local.appendLittleEndian(UInt16(0x0800)) // UTF-8 names
            local.appendLittleEndian(UInt16(0)) // stored
            local.appendLittleEndian(time)
            local.appendLittleEndian(date)
            local.appendLittleEndian(crc)
            local.appendLittleEndian(UInt32(size))
            local.appendLittleEndian(UInt32(size))
            local.appendLittleEndian(UInt16(name.count))
            local.appendLittleEndian(UInt16(0))
            local.append(name)

            central.appendLittleEndian(UInt32(0x0201_4B50))
            central.appendLittleEndian(UInt16(0x0314)) // made by Unix, zip 2.0
            central.appendLittleEndian(UInt16(20))
            central.appendLittleEndian(UInt16(0x0800))
            central.appendLittleEndian(UInt16(0))
            central.appendLittleEndian(time)
            central.appendLittleEndian(date)
            central.appendLittleEndian(crc)
            central.appendLittleEndian(UInt32(size))
            central.appendLittleEndian(UInt32(size))
            central.appendLittleEndian(UInt16(name.count))
            central.appendLittleEndian(UInt16(0)) // extra
            central.appendLittleEndian(UInt16(0)) // comment
            central.appendLittleEndian(UInt16(0)) // disk
            central.appendLittleEndian(UInt16(0)) // internal attributes
            central.appendLittleEndian(UInt32(0o100644) << 16)
            central.appendLittleEndian(UInt32(offset))
            central.append(name)

            segments.append(.bytes(local))
            segments.append(.file(entry.url, size))
            offset += local.count + size
            guard offset <= CantripHomeArtifactDownload.maximumFolderBytes else {
                throw CantripHomeError(413, "This folder is too large to download as one zip.")
            }
        }
        var end = Data()
        end.appendLittleEndian(UInt32(0x0605_4B50))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(UInt16(entries.count))
        end.appendLittleEndian(UInt32(central.count))
        end.appendLittleEndian(UInt32(offset))
        end.appendLittleEndian(UInt16(0))
        segments.append(.bytes(central + end))
        return CantripHomeArtifactStream(segments: segments, realRoot: realRoot)
    }

    static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = min(max(parts.year ?? 1980, 1980), 2107)
        let time = (parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2
        let day = (year - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1)
        return (UInt16(time), UInt16(day))
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension CantripHomeStore {
    /// The original file of one registered artifact.
    func artifactDownload(id: UUID) throws -> CantripHomeArtifactDownload {
        guard let artifact = artifacts.first(where: { $0.id == id }) else {
            throw CantripHomeError(404, "Artifact not found.")
        }
        let root = Self.artifactDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let url = try Self.downloadURL(artifact, root: root)
        return CantripHomeArtifactDownload(
            fileName: url.lastPathComponent, contentType: artifact.mimeType, root: root,
            entries: [.init(url: url, name: url.lastPathComponent, modified: artifact.createdAt)],
            isArchive: false
        )
    }

    /// Every registered artifact in the top-level artifacts folder that holds `id` (subfolders
    /// included), zipped under the folder's name. Unregistered files in it are never included.
    func artifactFolderDownload(id: UUID) throws -> CantripHomeArtifactDownload {
        guard let artifact = artifacts.first(where: { $0.id == id }) else {
            throw CantripHomeError(404, "Artifact not found.")
        }
        let components = artifact.relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 1, let first = components.first else {
            throw CantripHomeError(404, "This artifact isn't in a folder.")
        }
        let folder = String(first)
        let root = Self.artifactDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let folderName = folder
        let members = artifacts
            .filter { $0.relativePath.hasPrefix(folder + "/") }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        guard members.count <= CantripHomeArtifactDownload.maximumFolderEntries,
              members.reduce(0, { $0 + max($1.size, 0) }) <= CantripHomeArtifactDownload.maximumFolderBytes else {
            throw CantripHomeError(413, "This folder is too large to download as one zip.")
        }
        let entries = members.compactMap { member -> CantripHomeArtifactDownloadEntry? in
            guard let url = try? Self.downloadURL(member, root: root) else { return nil }
            let inside = String(member.relativePath.dropFirst(folder.count + 1))
            return .init(url: url, name: folderName + "/" + inside, modified: member.createdAt)
        }
        guard !entries.isEmpty else { throw CantripHomeArtifactDownload.unavailable }
        return CantripHomeArtifactDownload(
            fileName: folderName + ".zip", contentType: "application/zip", root: root,
            entries: entries, isArchive: true
        )
    }

    private static func downloadURL(_ artifact: CantripHomeArtifact, root: URL) throws -> URL {
        let url = root.appendingPathComponent(artifact.relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CantripHomeArtifactDownload.unavailable
        }
        return url
    }
}
