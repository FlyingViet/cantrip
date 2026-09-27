import Foundation

/// A reply's markdown blocks: runs of lines split at blank lines outside code
/// fences. Finished subagent cards sit between blocks, where each agent ended.
/// The browser Remote and Cantrip Agent split text the same way.
enum ReplyBlocks {
    /// UTF-8 offset where each block starts.
    static func starts(in text: String) -> [Int] {
        var starts: [Int] = []
        var offset = 0
        var fence: String?
        var afterBlank = true
        for line in text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let trimmed = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                afterBlank = false
            } else if trimmed.isEmpty {
                afterBlank = true
            } else {
                if afterBlank { starts.append(offset) }
                afterBlank = false
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix(3)) }
            }
            offset += line.count + 1
        }
        return starts
    }

    /// How many blocks start before `offset`: a card recorded there follows the
    /// block that was streaming (0 = before the text).
    static func block(atOffset offset: Int, in text: String) -> Int {
        starts(in: text).filter { $0 < offset }.count
    }

    /// `text` cut before each block number in `blocks` (ascending); returns
    /// `blocks.count + 1` parts. Numbers past the last block cut at the end.
    static func split(_ text: String, before blocks: [Int]) -> [String] {
        guard !blocks.isEmpty else { return [text] }
        let starts = starts(in: text)
        let utf8 = text.utf8
        var parts: [String] = []
        var from = utf8.startIndex
        for block in blocks {
            let offset = block <= 0 ? 0 : block < starts.count ? starts[block] : utf8.count
            let to = max(from, utf8.index(utf8.startIndex, offsetBy: offset))
            parts.append(String(text[from..<to]).trimmingTrailingWhitespace)
            from = to
        }
        parts.append(String(text[from...]))
        return parts
    }
}

private extension String {
    var trimmingTrailingWhitespace: String {
        var result = Substring(self)
        while let last = result.last, last.isWhitespace { result = result.dropLast() }
        return String(result)
    }
}
