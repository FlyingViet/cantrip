import AppKit
import Combine

/// Apps and files for the ⌥Space panel while the background agents run the tabs: the panel is the
/// Home window plug-in's (`HomeWindow.openPanel`), and this app answers what it types with the
/// same matches as Cantrip's own panel (`AppCatalog`, `FileSearch`), then opens the one picked.
@MainActor
final class PanelSearch {
    static let shared = PanelSearch()

    /// Sends the current list to the panel.
    var publish: (([[String: Any]]) -> Void)?
    /// Something was opened: the panel goes away, as Cantrip's own does.
    var onOpened: (() -> Void)?

    private var app: AppMatch?
    private var files: [URL] = []
    private var query = ""
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = FileSearch.shared.$results
            .receive(on: DispatchQueue.main)
            .sink { [weak self] urls in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.files = self.query.isEmpty ? [] : urls
                    self.send()
                }
            }
    }

    func search(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
        app = query.isEmpty ? nil : AppCatalog.shared.match(query: query)
        if query.isEmpty {
            files = []
            FileSearch.shared.clear()
        } else {
            FileSearch.shared.search(query)
        }
        send()
    }

    func open(_ id: String) {
        if let app, id == Self.id(for: app) {
            AppCatalog.shared.launch(app)
            Log.write("panel: opened \(app.name)")
        } else if id.hasPrefix("file:"), let url = files.first(where: { "file:" + $0.path == id }) {
            NSWorkspace.shared.open(url)
            Log.write("panel: opened a file")
        } else {
            return
        }
        search("")
        onOpened?()
    }

    private static func id(for app: AppMatch) -> String { "app:" + app.url.path }

    private func send() {
        var list: [[String: Any]] = []
        if let app {
            list.append(["id": Self.id(for: app), "kind": "app",
                         "title": "\(app.isRunning ? "Switch to" : "Open") \(app.name)",
                         "action": app.isRunning ? "switch" : "open",
                         "icon": AppCatalog.shared.icon(for: app.url)])
        }
        for url in files {
            list.append(["id": "file:" + url.path, "kind": "file", "title": url.lastPathComponent,
                         "subtitle": (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                         "icon": AppCatalog.shared.icon(for: url)])
        }
        publish?(list)
    }
}
