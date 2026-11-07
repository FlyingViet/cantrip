import AppKit
import SwiftUI

extension SessionTabTests {
    /// The ⌥Space panel's Artifacts list: search across title, file, folder and kind; only
    /// regular files inside the artifacts folder can be opened; rows render with thumbnails.
    @MainActor
    static func testPanelArtifacts() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-panel-artifacts-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("trip-planner/maps"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("design-graph"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let now = Date()
        func artifact(_ title: String, _ path: String, kind: String = "document", mime: String = "text/markdown",
                      size: Int = 1_024, daysAgo: Double = 0) -> CantripHomeArtifact {
            CantripHomeArtifact(title: title, relativePath: path, kind: kind, mimeType: mime, size: size,
                                createdAt: now.addingTimeInterval(-daysAgo * 86_400))
        }
        let report = artifact("Quarterly budget review", "budget-review.md", size: 18_400)
        let graph = artifact("System design knowledge graph", "design-graph/graph.html",
                             mime: "text/html", size: 412_000, daysAgo: 1)
        let photo = artifact("Coastline sunset", "trip-planner/maps/sunset.png", kind: "image",
                             mime: "image/png", size: 96_000, daysAgo: 2)
        let clip = artifact("Launch walkthrough", "launch-walkthrough.mp4", kind: "video",
                            mime: "video/mp4", size: 2_400_000, daysAgo: 3)
        let gone = artifact("Old meeting notes", "old-notes.md", daysAgo: 9)
        let all = [report, graph, photo, clip, gone]

        precondition(PanelArtifacts.folder(report) == nil && PanelArtifacts.folder(photo) == "trip-planner",
                     "the folder is the top-level artifacts folder")
        precondition(PanelArtifacts.fileName(photo) == "sunset.png")

        // Every word must appear in the title, file name, folder or kind; order is kept.
        precondition(PanelArtifacts.matching(all, query: "  ") == all, "a blank search shows everything")
        precondition(PanelArtifacts.matching(all, query: "GRAPH design") == [graph], "words match in any order and case")
        precondition(PanelArtifacts.matching(all, query: "trip") == [photo], "searches folders")
        precondition(PanelArtifacts.matching(all, query: "sunset.png") == [photo], "searches file names")
        precondition(PanelArtifacts.matching(all, query: "video") == [clip], "searches kinds")
        precondition(PanelArtifacts.matching(all, query: "review") == [report])
        precondition(PanelArtifacts.matching(all, query: "graph sunset").isEmpty, "all words must match")

        // Only regular files inside the artifacts folder open.
        try Data("# Quarterly budget review\n".utf8).write(to: root.appendingPathComponent("budget-review.md"))
        try Data("<h1>Graph</h1>".utf8).write(to: root.appendingPathComponent("design-graph/graph.html"))
        try thumbnailTestPNG(width: 480, height: 320)
            .write(to: root.appendingPathComponent("trip-planner/maps/sunset.png"))
        try await thumbnailTestVideo(to: root.appendingPathComponent("launch-walkthrough.mp4"), seconds: 2)
        try Data("private".utf8).write(to: outside.appendingPathComponent("elsewhere.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.txt"),
                                                   withDestinationURL: outside.appendingPathComponent("elsewhere.txt"))
        precondition(PanelArtifacts.fileURL(report, root: root)?.path
                     == root.appendingPathComponent("budget-review.md").path, "a top-level file opens")
        precondition(PanelArtifacts.fileURL(photo, root: root) != nil, "a nested file opens")
        precondition(PanelArtifacts.fileURL(gone, root: root) == nil, "a deleted file has nothing to open")
        precondition(PanelArtifacts.fileURL(artifact("Linked", "linked.txt"), root: root) == nil,
                     "a link out of the artifacts folder never opens")
        precondition(PanelArtifacts.fileURL(artifact("Escape", "../outside/elsewhere.txt"), root: root) == nil,
                     "a path out of the artifacts folder never opens")
        precondition(PanelArtifacts.fileURL(artifact("Folder", "design-graph"), root: root) == nil,
                     "a folder isn't a file")

        precondition(PanelArtifacts.subtitle(photo).hasPrefix("trip-planner · Image · "),
                     PanelArtifacts.subtitle(photo))
        precondition(PanelArtifacts.subtitle(report).hasPrefix("Document · "), PanelArtifacts.subtitle(report))
        precondition(PanelArtifacts.subtitle(gone, available: false).contains("· File missing ·"))
        precondition(PanelArtifacts.symbol(graph) == "globe" && PanelArtifacts.symbol(clip) == "film"
                     && PanelArtifacts.symbol(photo) == "photo" && PanelArtifacts.symbol(report) == "doc.text")

        guard let directory = ProcessInfo.processInfo.environment["CANTRIP_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        let thumbnails = CantripHomeArtifactThumbnails(
            artifactRoot: root, cacheRoot: base.appendingPathComponent("thumbnails", isDirectory: true)
        )
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let list = PanelArtifactsList(artifacts: all, maxHeight: 360, root: root, thumbnails: thumbnails)
                .frame(width: 640)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: list)
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 640, height: 480),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<60 { try await Task.sleep(for: .milliseconds(50)) }
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("panel-artifacts-\(name).png"))
            window.close()
        }
    }
}
