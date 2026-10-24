import Foundation

/// Dead-simple file logger: ~/Library/Logs/Cantrip.log, rotated past `maximumBytes` into
/// Cantrip.log.1 … .`archiveCount` (.1 is the newest).
enum Log {
    static let maximumBytes: UInt64 = 10 * 1024 * 1024
    static let archiveCount = 3

    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Cantrip.log")
    }()
    static var fileURL: URL { url }
    private static let queue = DispatchQueue(label: "log")
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        queue.async {
            let line = "[\(df.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                let size = handle.seekToEndOfFile() + UInt64(data.count)
                handle.write(data)
                try? handle.close()
                if size > maximumBytes {
                    LogRotation.rotate(url, maximumBytes: maximumBytes, archives: archiveCount)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Waits for queued lines, for code paths that exit immediately.
    static func flush() {
        queue.sync {}
    }
}

enum LogRotation {
    static func archive(of url: URL, _ number: Int) -> URL {
        URL(fileURLWithPath: url.path + ".\(number)")
    }

    /// Moves the log to `.1`, shifting older archives up and dropping the oldest. A log far over
    /// the limit (written before rotation existed) keeps only its newest `maximumBytes`.
    static func rotate(_ url: URL, maximumBytes: UInt64, archives: Int) {
        let files = FileManager.default
        guard archives > 0 else {
            try? files.removeItem(at: url)
            return
        }
        try? files.removeItem(at: archive(of: url, archives))
        for number in stride(from: archives - 1, through: 1, by: -1)
        where files.fileExists(atPath: archive(of: url, number).path) {
            try? files.moveItem(at: archive(of: url, number), to: archive(of: url, number + 1))
        }
        let size = (try? files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size > maximumBytes * 2, let tail = tail(of: url, bytes: maximumBytes) {
            try? tail.write(to: archive(of: url, 1), options: .atomic)
            try? files.removeItem(at: url)
        } else {
            try? files.moveItem(at: url, to: archive(of: url, 1))
        }
    }

    /// The file's last `bytes`, starting at a line boundary.
    static func tail(of url: URL, bytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        guard size > bytes else {
            handle.seek(toFileOffset: 0)
            return handle.readDataToEndOfFile()
        }
        handle.seek(toFileOffset: size - bytes)
        let data = handle.readDataToEndOfFile()
        guard let newline = data.firstIndex(of: 0x0A) else { return data }
        return data.subdata(in: data.index(after: newline)..<data.endIndex)
    }
}
