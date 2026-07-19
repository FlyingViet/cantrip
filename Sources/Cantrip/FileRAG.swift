import Foundation
import PDFKit

/// Tier-1 personal file RAG: rides Spotlight's existing content index.
/// As the user types, a debounced `mdfind` content search finds candidate
/// documents; the best excerpt from each is cached and injected at send
/// time. No index of our own — macOS already read every file.
final class FileRAG {
    static let shared = FileRAG()
    private let queue = DispatchQueue(label: "file-rag", qos: .userInitiated)
    private var pending: DispatchWorkItem?
    private var cached: (block: String, at: Date)?
    private init() {}

    private static let docExts: Set<String> = [
        "pdf", "txt", "md", "rtf", "doc", "docx", "pages", "csv", "tsv",
    ]

    /// Debounced; call on every keystroke.
    func prepare(for raw: String) {
        guard AppSettings.shared.fileRAGEnabled else { return }
        let terms = MemoryStore.terms(from: raw)
        guard raw.count >= 8, terms.count >= 1 else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.run(terms: terms) }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Latest prepared context, if fresh enough to belong to this prompt.
    func injection() -> String? {
        guard AppSettings.shared.fileRAGEnabled,
              let cached, Date().timeIntervalSince(cached.at) < 90,
              !cached.block.isEmpty else { return nil }
        return cached.block
    }

    // MARK: - Internals

    private func run(terms: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", NSHomeDirectory(), "-interpret",
                       terms.joined(separator: " ")]
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return }
        // Hard 3s budget on the search.
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return }
        guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                  encoding: .utf8) else { return }

        let vault = AppSettings.shared.memoryPath
        let candidates = output.components(separatedBy: "\n")
            .prefix(300)
            .filter { path in
                guard !path.isEmpty,
                      Self.docExts.contains((path as NSString).pathExtension.lowercased()),
                      !path.contains("/Library/"), !path.contains("/."),
                      !path.hasPrefix(vault),
                      !path.contains("/.cache/") else { return false }
                return true
            }
        guard !candidates.isEmpty else {
            cached = ("", Date())
            return
        }

        // Prefer recently modified documents.
        let ranked = candidates.sorted { a, b in mtime(a) > mtime(b) }.prefix(3)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        var sections: [String] = []
        for path in ranked {
            guard let text = Self.extractText(path), !text.isEmpty else { continue }
            let excerpt = Self.bestExcerpt(in: text, terms: terms)
            guard !excerpt.isEmpty else { continue }
            let modified = formatter.string(
                from: Date(timeIntervalSince1970: mtime(path)))
            sections.append("— \(path) (modified \(modified)):\n“\(excerpt)”")
        }
        cached = (sections.joined(separator: "\n\n"), Date())
        if !sections.isEmpty {
            Log.write("file-rag: prepared \(sections.count) excerpts")
        }
    }

    private func mtime(_ path: String) -> TimeInterval {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date)?.timeIntervalSince1970 ?? 0
    }

    private static func extractText(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return nil }
            var text = ""
            for i in 0..<min(doc.pageCount, 30) {
                text += doc.page(at: i)?.string ?? ""
                if text.count > 60_000 { break }
            }
            return text
        case "txt", "md", "csv", "tsv":
            return try? String(contentsOf: url, encoding: .utf8)
        case "rtf", "doc", "docx", "pages":
            return (try? NSAttributedString(url: url, options: [:],
                                            documentAttributes: nil))?.string
        default:
            return nil
        }
    }

    /// Best ~700-char window around the query terms.
    private static func bestExcerpt(in text: String, terms: [String]) -> String {
        let capped = String(text.prefix(120_000))
        let paragraphs = capped.components(separatedBy: "\n\n")
            .flatMap { $0.count > 1200 ? $0.chunked(1000) : [$0] }
        let best = paragraphs.max {
            MemoryStore.score($0.lowercased(), terms: terms)
                < MemoryStore.score($1.lowercased(), terms: terms)
        } ?? ""
        guard MemoryStore.score(best.lowercased(), terms: terms) > 0 else { return "" }
        return String(best.trimmingCharacters(in: .whitespacesAndNewlines).prefix(700))
    }
}

private extension String {
    func chunked(_ size: Int) -> [String] {
        var chunks: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(String(self[start..<end]))
            start = end
        }
        return chunks
    }
}
