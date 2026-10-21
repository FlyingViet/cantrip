import Compression
import Foundation

/// gzip (RFC 1952) for Remote responses: the Compression framework's raw DEFLATE inside
/// gzip's header and CRC-32 trailer, which every HTTP client and URLSession understand.
enum HTTPCompression {
    /// Smaller bodies aren't worth the header and CPU.
    static let minimumBytes = 4 * 1024
    /// Larger bodies are mostly base64 artifact downloads (already-compressed media); gzip
    /// would take a second or more for little gain.
    static let maximumBytes = 8 * 1024 * 1024

    /// Whether an Accept-Encoding header allows gzip (`gzip` or `*`, without `q=0`).
    static func acceptsGzip(_ header: String?) -> Bool {
        guard let header else { return false }
        return header.split(separator: ",").contains { item in
            let parts = item.split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard let coding = parts.first, coding == "gzip" || coding == "*" else { return false }
            let quality = parts.dropFirst().first { $0.hasPrefix("q=") }.flatMap { Double($0.dropFirst(2)) }
            return quality.map { $0 > 0 } ?? true
        }
    }

    static func isCompressible(contentType: String) -> Bool {
        let type = contentType.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return type == "application/json" || type == "application/javascript"
            || type == "image/svg+xml" || type.hasPrefix("text/")
    }

    static func gzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        var result = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        result.append(deflated.prefix(written))
        appendLittleEndian(crc32(data), to: &result)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &result)
        return result
    }

    /// One gzip member, checked against its length and CRC; nil when malformed or over `limit`.
    static func gunzip(_ data: Data, limit: Int) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            guard let end = bytes[min(offset, bytes.count)...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        let trailer = bytes.count - 8
        guard offset <= trailer else { return nil }
        let expectedCRC = littleEndian(bytes, at: trailer)
        let size = Int(littleEndian(bytes, at: trailer + 4))
        guard size <= limit else { return nil }
        if size == 0 { return expectedCRC == 0 ? Data() : nil }
        var output = Data(count: size + 1)
        let decoded = output.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBufferPointer { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size + 1,
                    source.baseAddress! + offset, trailer - offset,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == size else { return nil }
        output.removeLast()
        return crc32(output) == expectedCRC ? output : nil
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF),
                                 UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }

    private static func littleEndian(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}
