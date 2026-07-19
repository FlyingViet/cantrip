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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-name", query, "-onlyin", NSHomeDirectory()]
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return }
        process = p
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                  encoding: .utf8) else { return }

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
        let urls = ranked.prefix(5).map { URL(fileURLWithPath: $0) }
        DispatchQueue.main.async { self.results = urls }
    }
}
