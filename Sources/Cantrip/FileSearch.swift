import AppKit
import Foundation

/// Debounced Spotlight-index file search (mdfind) for the typeahead.
final class FileSearch: ObservableObject {
    static let shared = FileSearch()
    @Published private(set) var results: [URL] = []
    private var pending: DispatchWorkItem?
    private var process: Process?
    private init() {}

    func search(_ raw: String) {
        pending?.cancel()
        guard raw.utf8.count <= AppSearchMatcher.maximumQueryBytes else {
            clear()
            return
        }
        let query = raw.trimmingCharacters(in: .whitespaces)
        let words = query.split(separator: " ").count
        // Only for short, filename-ish queries — not sentences or commands.
        guard query.count >= 3, words <= 3,
              !query.lowercased().hasPrefix("open "),
              !query.contains("/") else {
            if !results.isEmpty { DispatchQueue.main.async { self.results = [] } }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.run(query) }
        pending = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func clear() {
        pending?.cancel()
        process?.terminate()
        DispatchQueue.main.async { self.results = [] }
    }

    private func run(_ query: String) {
        process?.terminate()
        // Only the first 400 paths are ranked, so keep the first 256 KB.
        guard let result = try? ProcessRunner.run(
            "/usr/bin/mdfind", ["-name", query, "-onlyin", NSHomeDirectory()],
            errorOutput: .discard, outputLimit: 256_000, launched: { [weak self] in self?.process = $0 }
        ), result.status == 0 else { return }
        let output = String(decoding: result.output, as: UTF8.self)

        let lowered = query.lowercased()
        let candidates = output.components(separatedBy: "\n")
            .prefix(400)
            .filter { !$0.isEmpty && !$0.contains("/Library/") && !$0.contains("/.") }
        // Rank: name-prefix matches first, then shallower paths.
        let ranked = candidates.sorted { a, b in
            let nameA = (a as NSString).lastPathComponent.lowercased()
            let nameB = (b as NSString).lastPathComponent.lowercased()
            let prefixA = nameA.hasPrefix(lowered), prefixB = nameB.hasPrefix(lowered)
            if prefixA != prefixB { return prefixA }
            let depthA = a.filter { $0 == "/" }.count
            let depthB = b.filter { $0 == "/" }.count
            if depthA != depthB { return depthA < depthB }
            return nameA < nameB
        }
        // Generous cap: the suggestions dropdown scrolls, so surfacing
        // more than a screenful is useful rather than overwhelming.
        let urls = ranked.prefix(30).map { URL(fileURLWithPath: $0) }
        DispatchQueue.main.async { self.results = urls }
    }
}
