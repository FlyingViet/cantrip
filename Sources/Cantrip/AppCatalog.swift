import AppKit
import Foundation

struct AppMatch {
    let name: String
    let url: URL
    let isRunning: Bool
}

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
    func match(prefix raw: String) -> AppMatch? {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2, !q.isEmpty else { return nil }
        let running = runningApps()
        scan() // cheap refresh at most every 5 min

        var seen = Set<String>()
        let candidates = (running + apps.map {
            AppMatch(name: $0.name, url: $0.url, isRunning: false)
        }).filter {
            seen.insert($0.name.lowercased()).inserted
        }

        if let exact = candidates.first(where: { $0.name.lowercased() == q }) {
            return exact
        }
        return candidates.first(where: { $0.name.lowercased().hasPrefix(q) })
    }

    func icon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 24, height: 24)
        return icon
    }

    func launch(_ app: AppMatch) {
        if app.isRunning,
           let running = runningApplication(at: app.url),
           running.activate(options: [.activateAllWindows]) {
            return
        }
        NSWorkspace.shared.openApplication(at: app.url,
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    private func runningApps() -> [AppMatch] {
        NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular &&
                    !$0.isTerminated &&
                    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            .compactMap { app in
                guard let name = app.localizedName,
                      let url = app.bundleURL else { return nil }
                return AppMatch(name: name, url: url, isRunning: true)
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private func runningApplication(at url: URL) -> NSRunningApplication? {
        let targetPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == targetPath
        }
    }
}
