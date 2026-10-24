import MarkdownUI
import SwiftUI

enum CantripMemoryCategory: String, Decodable, CaseIterable {
    case core, notes, sessions

    var title: String {
        switch self {
        case .core: return "Core memory"
        case .notes: return "Saved notes"
        case .sessions: return "Session history"
        }
    }
}

struct CantripMemoryEntry: Decodable, Identifiable, Hashable {
    let id: String
    let category: CantripMemoryCategory
    let bytes: Int64
    let modifiedAt: Double
    let characterLimit: Int?

    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
    var title: String {
        switch id {
        case "MEMORY.md": return "Environment & conventions"
        case "USER.md": return "About you"
        default: return name
        }
    }
    var modifiedDate: Date { Date(timeIntervalSince1970: modifiedAt) }
}

struct CantripMemoryCatalog: Decodable {
    let enabled: Bool
    let exists: Bool
    let documents: [CantripMemoryEntry]
    let nextCursor: String?
}

struct CantripMemoryPage: Decodable {
    let document: CantripMemoryEntry
    let text: String
    let offset: Int
    let nextOffset: Int?
    let revision: String
}

@MainActor
final class CantripMemoryCatalogModel: ObservableObject {
    @Published private(set) var catalog: CantripMemoryCatalog?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var query = ""
    private var requestID = UUID()

    func load(query: String, more: Bool = false,
              fetch: (String, String?) async throws -> CantripMemoryCatalog) async {
        if more && (isLoading || catalog?.nextCursor == nil) { return }
        if query != self.query { catalog = nil }
        self.query = query
        let cursor = more ? catalog?.nextCursor : nil
        let request = UUID()
        requestID = request
        isLoading = true
        defer { if requestID == request { isLoading = false } }
        do {
            let value = try await fetch(query, cursor)
            try Task.checkCancellation()
            guard requestID == request else { return }
            guard value.nextCursor == nil
                    || (value.nextCursor == value.documents.last?.id && value.nextCursor != cursor) else {
                throw CantripRemoteError.invalidResponse
            }
            var documents = more ? catalog?.documents ?? [] : []
            let existing = Set(documents.map(\.id))
            documents += value.documents.filter { !existing.contains($0.id) }
            catalog = CantripMemoryCatalog(enabled: value.enabled, exists: value.exists,
                                           documents: documents, nextCursor: value.nextCursor)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard requestID == request else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor
final class CantripMemoryReaderModel: ObservableObject {
    enum Direction { case reload, previous, next }
    @Published private(set) var page: CantripMemoryPage?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var pageIndex = 0
    /// The code block the shown page starts inside, carried over from the pages before it.
    @Published private(set) var pageFence: CantripMemoryMarkdown.Fence?
    private var offsets = [0]
    private var fences: [CantripMemoryMarkdown.Fence?] = [nil]

    func load(_ direction: Direction,
              fetch: (Int, String?) async throws -> CantripMemoryPage) async {
        guard !isLoading else { return }
        let offset: Int
        let index: Int
        let revision: String?
        let fence: CantripMemoryMarkdown.Fence?
        switch direction {
        case .reload:
            offset = 0; index = 0; revision = nil; fence = nil
        case .previous:
            guard pageIndex > 0 else { return }
            index = pageIndex - 1; offset = offsets[index]; revision = page?.revision; fence = fences[index]
        case .next:
            guard let page, let next = page.nextOffset else { return }
            offset = next; index = pageIndex + 1; revision = page.revision
            fence = CantripMemoryMarkdown.fence(after: page.text, startingIn: fences[pageIndex])
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let value = CantripMemoryMarkdown.aligned(try await fetch(offset, revision))
            try Task.checkCancellation()
            if direction == .reload { offsets = [0]; fences = [nil] }
            if index == offsets.count { offsets.append(offset) }
            if index == fences.count { fences.append(fence) } else { fences[index] = fence }
            pageIndex = index
            page = value
            pageFence = fence
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Renders memory files as Markdown one 16 KiB page at a time: pages end at a line break, and a
/// page that starts inside a code block reopens it.
enum CantripMemoryMarkdown {
    struct Fence: Equatable {
        let marker: Character
        let count: Int
    }

    /// Ends a page that would split a line at its last line break; the next page starts there.
    static func aligned(_ page: CantripMemoryPage) -> CantripMemoryPage {
        let bytes = page.text.utf8
        guard page.nextOffset != nil, bytes.last != 0x0A,
              let newline = bytes.lastIndex(of: 0x0A) else { return page }
        let text = String(decoding: bytes[...newline], as: UTF8.self)
        return CantripMemoryPage(document: page.document, text: text, offset: page.offset,
                                 nextOffset: page.offset + text.utf8.count, revision: page.revision)
    }

    /// The ``` or ~~~ code block still open after `text`.
    static func fence(after text: String, startingIn open: Fence?) -> Fence? {
        var fence = open
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard let marker = trimmed.first, marker == "`" || marker == "~" else { continue }
            let count = trimmed.prefix { $0 == marker }.count
            guard count >= 3 else { continue }
            if let current = fence {
                if marker == current.marker, count >= current.count,
                   trimmed.dropFirst(count).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
            } else {
                fence = Fence(marker: marker, count: count)
            }
        }
        return fence
    }

    /// The Markdown to render for a page that may start inside a code block.
    static func renderable(_ text: String, startingIn fence: Fence?) -> String {
        guard let fence else { return text }
        return String(repeating: fence.marker, count: fence.count) + "\n" + text
    }
}

/// A memory page as formatted Markdown. Like the plain view it loads nothing from outside the
/// Mac: images show a placeholder, and only web and mail links open (in the browser).
struct CantripMemoryMarkdownText: View {
    let text: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        Markdown(text)
            .markdownImageProvider(CantripMemoryImagePlaceholder())
            .markdownInlineImageProvider(CantripMemoryInlineImagePlaceholder())
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
                openURL(url)
                return .handled
            })
    }
}

private struct CantripMemoryImagePlaceholder: ImageProvider {
    func makeImage(url: URL?) -> some View {
        Label("Image not loaded", systemImage: "photo")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

private struct CantripMemoryInlineImagePlaceholder: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        Image(systemName: "photo")
    }
}

struct CantripMemoryView: View {
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        CantripMemoryBrowser(remote: remote)
            .id(remote.usageIdentity)
    }
}

private struct CantripMemoryBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var remote: CantripRemoteModel
    @StateObject private var model = CantripMemoryCatalogModel()
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Read-only memory saved on your connected Mac. Core memory contains facts and preferences; notes hold procedures; session history records earlier conversations.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.catalog?.enabled == false {
                        Label("Memory is disabled on the Mac. Saved files are still available here.",
                              systemImage: "pause.circle")
                            .font(.caption)
                    }
                    if model.isLoading {
                        ProgressView("Loading memory...")
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        if model.catalog != nil {
                            Text("Showing the last loaded list.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Retry") { Task { await refresh() } }
                            .disabled(model.isLoading)
                    }
                }
                if let catalog = model.catalog {
                    ForEach(CantripMemoryCategory.allCases, id: \.self) { category in
                        let entries = catalog.documents.filter { $0.category == category }
                        if !entries.isEmpty {
                            Section(category.title) {
                                ForEach(entries) { entry in
                                    NavigationLink(value: entry) { CantripMemoryRow(entry: entry) }
                                }
                            }
                        }
                    }
                    if catalog.documents.isEmpty && !model.isLoading && model.error == nil {
                        ContentUnavailableView(
                            query.isEmpty ? "No saved memory yet" : "No matching memory files",
                            systemImage: "brain",
                            description: Text(catalog.exists
                                ? "Saved Markdown files will appear here."
                                : "Cantrip has not created its memory folder yet.")
                        )
                    }
                    if catalog.nextCursor != nil {
                        Button("Load more files") { Task { await refresh(more: true) } }
                            .disabled(model.isLoading)
                    }
                }
            }
            .navigationTitle("Cantrip Memory")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: CantripMemoryEntry.self) { entry in
                CantripMemoryReader(remote: remote, entry: entry)
            }
            .searchable(text: $query, prompt: "Find a memory file")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.isLoading)
                        .accessibilityLabel("Refresh Cantrip memory")
                }
            }
            .task(id: query) { await refresh() }
            .refreshable { await refresh() }
        }
    }

    private func refresh(more: Bool = false) async {
        await model.load(query: query, more: more) { try await remote.memoryCatalog(query: $0, after: $1) }
    }
}

struct CantripMemoryRow: View {
    let entry: CantripMemoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title).font(.headline)
            if entry.title != entry.name {
                Text(entry.name).font(.caption).foregroundStyle(.secondary)
            }
            Text("Updated \(entry.modifiedDate.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct CantripMemoryReader: View {
    @ObservedObject var remote: CantripRemoteModel
    let entry: CantripMemoryEntry
    @StateObject private var model = CantripMemoryReaderModel()
    /// Formatted Markdown or the file's exact text; remembered across files.
    @AppStorage("cantrip.memory.formatted") private var formatted = true

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    if model.page != nil {
                        Text("Showing previously loaded text.").font(.caption)
                    }
                    Button("Reload file") { Task { await load(.reload) } }.disabled(model.isLoading)
                }
                .padding()
            }
            if model.isLoading { ProgressView("Loading saved memory...").padding() }
            if let page = model.page {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        CantripMemoryRow(entry: page.document)
                        if let cap = page.document.characterLimit, page.offset == 0, page.nextOffset == nil {
                            Text("\(page.text.count) / \(cap) characters")
                                .font(.caption).foregroundStyle(page.text.count > cap ? .orange : .secondary)
                        }
                        Picker("Show", selection: $formatted) {
                            Text("Formatted").tag(true)
                            Text("Markdown source").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("memory.format")
                        Group {
                            if page.text.isEmpty {
                                Text("(Empty file)")
                            } else if formatted {
                                CantripMemoryMarkdownText(
                                    text: CantripMemoryMarkdown.renderable(page.text, startingIn: model.pageFence)
                                )
                            } else {
                                Text(page.text)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .id("\(page.revision):\(page.offset)")
                HStack {
                    Button("Previous") { Task { await load(.previous) } }
                        .disabled(model.isLoading || model.pageIndex == 0)
                    Spacer()
                    Text("Page \(model.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Next") { Task { await load(.next) } }
                        .disabled(model.isLoading || page.nextOffset == nil)
                }
                .padding()
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { Task { await load(.reload) } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.isLoading)
                .accessibilityLabel("Reload memory file")
        }
        .task { await load(.reload) }
    }

    private func load(_ direction: CantripMemoryReaderModel.Direction) async {
        await model.load(direction) { try await remote.memoryDocument(id: entry.id, offset: $0, revision: $1) }
    }
}
