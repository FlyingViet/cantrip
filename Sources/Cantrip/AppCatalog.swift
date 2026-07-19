import AppKit
import Foundation

/// Installed-application index for Spotlight-style typeahead.
final class AppCatalog {
    static let shared = AppCatalog()
    private(set) var apps: [(name: String, url: URL)] = []
    private var lastScan: Date = .distantPast
    private init() { scan() }

    func scan() {
        guard Date().timeIntervalSince(lastScan) > 300 else { return }
        lastScan = Date()
        let dirs = ["/Applications",
                    "/System/Applications",
                    "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        var found: [(String, URL)] = []
        for dir in dirs {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            where item.hasSuffix(".app") {
                found.append((String(item.dropLast(4)),
                              URL(fileURLWithPath: "\(dir)/\(item)")))
            }
        }
        var seen = Set<String>()
        apps = found
            .filter { seen.insert($0.0.lowercased()).inserted }
            .sorted { $0.0.lowercased() < $1.0.lowercased() }
    }

    /// Top hit: the whole query must be a prefix of the app name, so
    /// "saf" matches Safari but "safari tips" matches nothing.
    func match(prefix raw: String) -> (name: String, url: URL)? {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2, !q.isEmpty else { return nil }
        scan() // cheap refresh at most every 5 min
        if let exact = apps.first(where: { $0.name.lowercased() == q }) { return exact }
        return apps.first(where: { $0.name.lowercased().hasPrefix(q) })
    }

    func icon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 24, height: 24)
        return icon
    }

    func launch(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration())
    }
}
