import AppKit
import SwiftUI

/// Helpers for the ⌥Space panel's Artifacts list: Cantrip Home's saved documents and media,
/// read straight from this Mac's artifacts folder.
enum PanelArtifacts {
    /// The top-level artifacts folder a multi-file artifact is in; nil at the top level.
    static func folder(_ artifact: CantripHomeArtifact) -> String? {
        let parts = artifact.relativePath.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count > 1 ? String(parts[0]) : nil
    }

    static func fileName(_ artifact: CantripHomeArtifact) -> String {
        artifact.relativePath.split(separator: "/").last.map(String.init) ?? artifact.title
    }

    /// Artifacts whose title, file name, folder or kind contain every word of `query`, in order.
    static func matching(_ artifacts: [CantripHomeArtifact], query: String) -> [CantripHomeArtifact] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return artifacts }
        return artifacts.filter { artifact in
            let fields = [artifact.title, fileName(artifact), folder(artifact) ?? "", artifact.kind]
            return words.allSatisfy { word in fields.contains { $0.localizedCaseInsensitiveContains(word) } }
        }
    }

    /// The artifact's file on this Mac: a regular file inside the artifacts folder, else nil.
    static func fileURL(_ artifact: CantripHomeArtifact,
                        root: URL = CantripHomeStore.artifactDirectory) -> URL? {
        try? CantripHomeStore.downloadURL(artifact, root: root.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// "folder · Image · 1.2 MB · Nov 6, 2026"
    static func subtitle(_ artifact: CantripHomeArtifact, available: Bool = true) -> String {
        var parts: [String] = []
        if let folder = folder(artifact) { parts.append(folder) }
        parts.append(artifact.kind.capitalized)
        if available {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(artifact.size), countStyle: .file))
        } else {
            parts.append("File missing")
        }
        parts.append(artifact.createdAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }

    static func symbol(_ artifact: CantripHomeArtifact) -> String {
        switch artifact.kind {
        case "image": return "photo"
        case "video": return "film"
        case "audio": return "waveform"
        default:
            switch URL(fileURLWithPath: artifact.relativePath).pathExtension.lowercased() {
            case "pdf": return "doc.richtext"
            case "zip": return "doc.zipper"
            case "html", "htm": return "globe"
            case "csv", "tsv", "xlsx", "numbers": return "tablecells"
            default: return "doc.text"
            }
        }
    }
}

/// The panel's Artifacts list, newest first, kept current by Cantrip Home's store.
struct PanelArtifactsView: View {
    @ObservedObject var store: CantripHomeStore
    let maxHeight: CGFloat

    var body: some View {
        PanelArtifactsList(artifacts: store.artifacts, maxHeight: maxHeight)
    }
}

struct PanelArtifactsList: View {
    let artifacts: [CantripHomeArtifact]
    let maxHeight: CGFloat
    var root: URL = CantripHomeStore.artifactDirectory
    var thumbnails: CantripHomeArtifactThumbnails = .shared
    @State private var search = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Artifacts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.open(root)
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open the artifacts folder in Finder")
            }
            TextField("Search artifacts…", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            let shown = PanelArtifacts.matching(artifacts, query: search)
            if shown.isEmpty {
                Text(artifacts.isEmpty
                     ? "No artifacts yet. Documents and media Cantrip Home saves appear here."
                     : "No matches.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { artifact in
                            PanelArtifactRow(artifact: artifact, root: root, thumbnails: thumbnails) {
                                errorText = $0
                            }
                        }
                    }
                }
                .frame(maxHeight: maxHeight)
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
    }
}

private struct PanelArtifactRow: View {
    let artifact: CantripHomeArtifact
    let root: URL
    let thumbnails: CantripHomeArtifactThumbnails
    /// A failed Save As explains itself; nil clears the last message.
    let onError: (String?) -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        let url = PanelArtifacts.fileURL(artifact, root: root)
        HStack(spacing: 8) {
            Button {
                if let url { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 10) {
                    preview
                    VStack(alignment: .leading, spacing: 1) {
                        Text(artifact.title)
                            .font(.callout)
                            .foregroundStyle(url == nil ? .secondary : .primary)
                            .lineLimit(1)
                        Text(PanelArtifacts.subtitle(artifact, available: url != nil))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
            .help(url == nil ? "\(artifact.relativePath) is no longer in the artifacts folder"
                             : "Open \(artifact.relativePath)")
            .accessibilityLabel("\(artifact.title), \(PanelArtifacts.subtitle(artifact, available: url != nil))")

            if let url {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
                .accessibilityLabel("Show \(artifact.title) in Finder")

                Menu {
                    actions(url)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("Actions for \(artifact.title)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .contextMenu { if let url { actions(url) } }
        .task(id: artifact) {
            guard CantripHomeArtifactThumbnails.supports(artifact),
                  let made = try? await thumbnails.thumbnail(for: artifact) else { return }
            thumbnail = NSImage(data: made.jpeg)
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: PanelArtifacts.symbol(artifact))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func actions(_ url: URL) -> some View {
        Button("Open") { NSWorkspace.shared.open(url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Save As…") { saveAs(url) }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }

    /// A Save dialog opened in Downloads with the original file name; the panel stays open.
    private func saveAs(_ url: URL) {
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.presentKeepingPanelOpen(on: NSApp.keyWindow) { response in
            guard response == .OK, let destination = panel.url,
                  destination.standardizedFileURL != url.standardizedFileURL else { return }
            onError(nil)
            do {
                // The dialog already confirmed replacing an existing file.
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                onError("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}
