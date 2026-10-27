import Foundation

/// Files only this user can read: folder 0700, file 0600, written atomically.
enum PrivateFile {
    static func write(_ data: Data, to file: URL) throws {
        let folder = file.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try data.write(to: file, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func write<Value: Encodable>(_ value: Value, to file: URL,
                                        encoder: JSONEncoder = JSONEncoder()) throws {
        try write(encoder.encode(value), to: file)
    }

    /// The saved value, or nil when there's no file yet. Throws when it can't be read or decoded.
    static func read<Value: Decodable>(_ type: Value.Type, from file: URL,
                                       decoder: JSONDecoder = JSONDecoder()) throws -> Value? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try decoder.decode(type, from: Data(contentsOf: file))
    }
}
