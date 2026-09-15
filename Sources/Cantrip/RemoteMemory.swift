import Darwin
import Foundation

struct RemoteMemoryEntry: Codable {
    let id: String
    let category: String
    let bytes: Int64
    let modifiedAt: Double
    let characterLimit: Int?
}

struct RemoteMemoryCatalog: Encodable {
    let enabled: Bool
    let exists: Bool
    let documents: [RemoteMemoryEntry]
    let nextCursor: String?
}

struct RemoteMemoryPage: Encodable {
    let document: RemoteMemoryEntry
    let text: String
    let offset: Int
    let nextOffset: Int?
    let revision: String
}

struct RemoteMemoryError: Error {
    let status: Int
    let message: String

    static let notFound = Self(status: 404, message: "This memory file is no longer available.")
    static let changed = Self(status: 409, message: "This memory file changed. Reload it to read the latest version.")
}

struct RemoteMemory {
    static let catalogPageSize = 50
    static let documentPageBytes = 16 * 1024
    let directory: URL

    func catalog(enabled: Bool, query: String, after: String?) throws -> RemoteMemoryCatalog {
        guard query.count <= 200 else {
            throw RemoteMemoryError(status: 400, message: "Memory search is limited to 200 characters.")
        }
        let root = try openRoot()
        guard root >= 0 else {
            return RemoteMemoryCatalog(enabled: enabled, exists: false, documents: [], nextCursor: nil)
        }
        defer { close(root) }
        var entries = try list(root, prefix: "")
        let sessions = openat(root, "sessions", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if sessions >= 0 {
            defer { close(sessions) }
            entries += try list(sessions, prefix: "sessions/")
        } else if ![ENOENT, ENOTDIR, ELOOP].contains(errno) {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        entries = entries.filter { query.isEmpty || $0.id.localizedCaseInsensitiveContains(query) }
        let categories = ["core", "notes", "sessions"]
        entries.sort {
            if $0.category != $1.category {
                return categories.firstIndex(of: $0.category)! < categories.firstIndex(of: $1.category)!
            }
            return $0.category == "sessions" ? $0.id > $1.id : $0.id < $1.id
        }
        var start = 0
        if let after {
            guard let index = entries.firstIndex(where: { $0.id == after }) else {
                throw RemoteMemoryError(status: 409, message: "The memory list changed. Refresh the list.")
            }
            start = index + 1
        }
        let page = Array(entries.dropFirst(start).prefix(Self.catalogPageSize))
        return RemoteMemoryCatalog(enabled: enabled, exists: true, documents: page,
                                   nextCursor: start + page.count < entries.count ? page.last?.id : nil)
    }

    func document(id: String, offset: Int, revision expectedRevision: String?) throws -> RemoteMemoryPage {
        guard Self.validID(id), offset >= 0, offset == 0 || expectedRevision != nil else {
            throw RemoteMemoryError(status: 400, message: "Invalid memory file or page.")
        }
        let root = try openRoot()
        guard root >= 0 else { throw RemoteMemoryError.notFound }
        defer { close(root) }
        var parent = root
        if id.hasPrefix("sessions/") {
            parent = openat(root, "sessions", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw fileError() }
        }
        defer { if parent != root { close(parent) } }
        let name = String(id.split(separator: "/").last!)
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { close(descriptor) }
        let before = try attributes(descriptor)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
            throw RemoteMemoryError.notFound
        }
        let revision = version(before)
        guard expectedRevision == nil || expectedRevision == revision else { throw RemoteMemoryError.changed }
        guard Int64(offset) <= before.st_size else {
            throw RemoteMemoryError(status: 400, message: "Invalid memory page offset.")
        }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Self.documentPageBytes) ?? Data()
        guard version(try attributes(descriptor)) == revision else { throw RemoteMemoryError.changed }
        // A byte page may end inside a UTF-8 scalar; defer only those trailing bytes.
        for trimmed in 0...min(3, data.count) {
            let chunk = data.prefix(data.count - trimmed)
            if let text = String(data: chunk, encoding: .utf8) {
                let end = offset + chunk.count
                guard end == before.st_size || !chunk.isEmpty else { break }
                if trimmed > 0 && offset + data.count == before.st_size { break }
                return RemoteMemoryPage(document: entry(id, before), text: text, offset: offset,
                                        nextOffset: end < before.st_size ? end : nil, revision: revision)
            }
        }
        throw RemoteMemoryError(status: 422, message: "This memory file is not valid UTF-8 text.")
    }

    private static func validID(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && parts[0] == "sessions"),
              let name = parts.last, !name.hasPrefix("."), name.hasSuffix(".md"),
              !name.contains("\\"), !name.contains("\0"), name.utf8.count <= 255 else { return false }
        return true
    }

    private func openRoot() throws -> Int32 {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 && errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }

    private func list(_ descriptor: Int32, prefix: String) throws -> [RemoteMemoryEntry] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let stream = fdopendir(duplicate) else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(duplicate)
            throw error
        }
        defer { closedir(stream) }
        var entries: [RemoteMemoryEntry] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            let id = prefix + name
            guard Self.validID(id) else { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue } // A concurrently deleted note is no longer in the catalog.
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { continue }
            entries.append(entry(id, info))
        }
        return entries
    }

    private func attributes(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return info
    }

    private func entry(_ id: String, _ info: stat) -> RemoteMemoryEntry {
        let category = ["MEMORY.md", "USER.md"].contains(id) ? "core"
            : id.hasPrefix("sessions/") ? "sessions" : "notes"
        return RemoteMemoryEntry(id: id, category: category, bytes: info.st_size,
                                 modifiedAt: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                                 characterLimit: id == "MEMORY.md" ? MemoryStore.memoryCap
                                     : id == "USER.md" ? MemoryStore.userCap : nil)
    }

    private func version(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    private func fileError() -> Error {
        if [ENOENT, ENOTDIR, ELOOP].contains(errno) { return RemoteMemoryError.notFound }
        return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
