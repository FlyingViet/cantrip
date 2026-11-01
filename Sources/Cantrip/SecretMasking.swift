import Foundation

// MARK: - Masking

/// Replaces secret values in a byte stream with `[secret:NAME]`. Holds back only a tail that could
/// still become a value, so ordinary output passes through without delay.
struct SecretMasker {
    /// Shorter values (a port, "true") would mangle ordinary output.
    static let minimumLength = 6

    private var patterns: [(bytes: [UInt8], label: [UInt8])] = []
    private var byFirstByte: [UInt8: [Int]] = [:]
    private var pending: [UInt8] = []

    init(_ values: [(label: String, value: String)]) {
        var seen = Set<[UInt8]>()
        var list: [(bytes: [UInt8], label: [UInt8])] = []
        for (label, value) in values {
            for form in Self.forms(of: value) {
                let bytes = Array(form.utf8)
                guard bytes.count >= Self.minimumLength, seen.insert(bytes).inserted else { continue }
                list.append((bytes, Array("[secret:\(label)]".utf8)))
            }
        }
        patterns = list.sorted { $0.bytes.count > $1.bytes.count }
        for (index, pattern) in patterns.enumerated() { byFirstByte[pattern.bytes[0], default: []].append(index) }
    }

    var isEmpty: Bool { patterns.isEmpty }

    /// The value, its JSON-escaped form, and each long line of a multi-line value (a key printed
    /// line by line).
    static func forms(of value: String) -> [String] {
        var forms = [value]
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
           let json = String(data: data, encoding: .utf8) {
            forms.append(String(json.dropFirst(2).dropLast(2)))
            let unescapedSlashes = forms.last!.replacingOccurrences(of: "\\/", with: "/")
            forms.append(unescapedSlashes)
        }
        if value.contains("\n") {
            forms += value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 16 && !$0.hasPrefix("-----") }
        }
        return forms
    }

    /// Masked output that's safe to pass on now.
    mutating func feed(_ chunk: some Sequence<UInt8>) -> [UInt8] {
        pending.append(contentsOf: chunk)
        guard !patterns.isEmpty else { defer { pending.removeAll() }; return pending }
        let (output, consumed) = scan(pending, final: false)
        pending.removeFirst(consumed)
        return output
    }

    /// Everything still held back, at the end of the stream.
    mutating func finish() -> [UInt8] {
        defer { pending.removeAll() }
        guard !patterns.isEmpty else { return pending }
        return scan(pending, final: true).output
    }

    func mask(_ text: String) -> String {
        guard !patterns.isEmpty else { return text }
        return String(decoding: scan(Array(text.utf8), final: true).output, as: UTF8.self)
    }

    func mask(_ data: Data) -> Data {
        guard !patterns.isEmpty else { return data }
        return Data(scan(Array(data), final: true).output)
    }

    private func scan(_ bytes: [UInt8], final: Bool) -> (output: [UInt8], consumed: Int) {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        outer: while index < bytes.count {
            if let candidates = byFirstByte[bytes[index]] {
                for candidate in candidates {
                    let pattern = patterns[candidate].bytes
                    let available = bytes.count - index
                    if available >= pattern.count {
                        if bytes[index..<(index + pattern.count)].elementsEqual(pattern) {
                            output.append(contentsOf: patterns[candidate].label)
                            index += pattern.count
                            continue outer
                        }
                    } else if !final, bytes[index...].elementsEqual(pattern[..<available]) {
                        // Could still become this value: hold the rest back for the next chunk.
                        return (output, index)
                    }
                }
            }
            output.append(bytes[index])
            index += 1
        }
        return (output, index)
    }
}

/// The values Cantrip's own log and run journals mask, loaded from the Keychain cache.
enum SecretRedaction {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var masker = SecretMasker([])

    static func update(_ values: [(label: String, value: String)]) {
        let next = SecretMasker(values)
        lock.withLock { masker = next }
    }

    static var isActive: Bool { lock.withLock { !masker.isEmpty } }

    static func redact(_ text: String) -> String {
        let current = lock.withLock { masker }
        return current.mask(text)
    }

    static func redact(_ data: Data) -> Data {
        let current = lock.withLock { masker }
        return current.mask(data)
    }
}
