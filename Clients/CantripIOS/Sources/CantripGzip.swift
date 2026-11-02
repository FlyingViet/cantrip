import Compression
import Foundation

/// Decodes the gzip bodies Cantrip sends to clients that ask for them. URLSession does this
/// on its own; the local-network TLS route parses HTTP by hand and calls this instead.
enum CantripGzip {
    /// A response body as sent with `Content-Encoding`: unchanged when not encoded, decoded
    /// gzip, or nil for a corrupt body or an encoding this client never asks for.
    static func body(_ body: Data, contentEncoding: String?, limit: Int) -> Data? {
        switch contentEncoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case nil, "", "identity": return body
        case "gzip": return decode(body, limit: limit)
        default: return nil
        }
    }

    /// One gzip member (RFC 1952), checked against its length and CRC-32; nil when malformed
    /// or larger than `limit`.
    static func decode(_ data: Data, limit: Int) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { return nil }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
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
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func littleEndian(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}
