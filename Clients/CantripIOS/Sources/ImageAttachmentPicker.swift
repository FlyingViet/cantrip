import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The composer's + menu: one Photos picker showing photos and videos together, Files for any
/// document, and Paste Image. It also takes what's pasted into the message box. A message carries
/// up to four photos, one video and five files.
struct ImageAttachmentPicker: View {
    @Binding var attachments: [ChatImageAttachment]
    @Binding var importID: UUID?
    @Binding var video: ChatVideoAttachment?
    /// Photos, videos and files pasted into the message box (`composerPaste`).
    @Binding var paste: ComposerPasteRequest?
    let imageSupport: Bool?
    let videoSupport: Bool?
    let disabled: Bool
    /// nil hides Files (clients that don't keep file drafts).
    private let files: Binding<[ChatFileAttachment]>?
    let fileSupport: Bool?
    /// Older Macs take images or one video per message, not both.
    let mixedSupport: Bool?

    @State private var selectedMedia: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?
    @State private var activeImportID: UUID?

    private var isImporting: Bool { importID != nil }
    private var mixed: Bool { mixedSupport == true }
    private var fileCount: Int { files?.wrappedValue.count ?? 0 }
    private var imageSlots: Int { max(0, ImageAttachmentProcessor.maximumCount - attachments.count) }
    private var canAddImages: Bool { imageSupport == true && imageSlots > 0 && (mixed || video == nil) }
    private var canAddVideo: Bool { videoSupport == true && video == nil && (mixed || attachments.isEmpty) }
    private var canAddFiles: Bool {
        files != nil && fileCount < FileAttachmentProcessor.maximumCount
            && (fileSupport == true || canAddImages || canAddVideo)
    }

    init(attachments: Binding<[ChatImageAttachment]>, importID: Binding<UUID?>,
         imageSupport: Bool?, disabled: Bool, video: Binding<ChatVideoAttachment?> = .constant(nil),
         videoSupport: Bool? = nil, files: Binding<[ChatFileAttachment]>? = nil, fileSupport: Bool? = nil,
         mixedSupport: Bool? = nil, paste: Binding<ComposerPasteRequest?> = .constant(nil)) {
        _attachments = attachments; _importID = importID; _video = video; _paste = paste
        self.imageSupport = imageSupport; self.disabled = disabled; self.videoSupport = videoSupport
        self.files = files; self.fileSupport = fileSupport; self.mixedSupport = mixedSupport
    }

    /// What the Photos picker offers: both kinds when both still fit in the message.
    private var photoFilter: PHPickerFilter {
        if canAddImages && canAddVideo { return .any(of: [.images, .videos]) }
        return canAddVideo ? .videos : .images
    }

    private var photoLimit: Int { max(1, (canAddImages ? imageSlots : 0) + (canAddVideo ? 1 : 0)) }

    private var limitsText: String {
        var parts: [String] = []
        if imageSupport == true { parts.append("4 photos") }
        if videoSupport == true { parts.append("1 video") }
        if files != nil, fileSupport == true { parts.append("5 files") }
        guard !parts.isEmpty else { return "" }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return "Up to \(list) per message."
    }

    private var accessibilityValueText: String {
        var parts: [String] = []
        if !attachments.isEmpty { parts.append("\(attachments.count) of \(ImageAttachmentProcessor.maximumCount) photos") }
        if video != nil { parts.append("one video") }
        if fileCount > 0 { parts.append(fileCount == 1 ? "one file" : "\(fileCount) files") }
        return parts.isEmpty ? "No attachments" : parts.joined(separator: ", ")
    }

    var body: some View {
        Menu {
            if imageSupport == true || videoSupport == true {
                Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
                    .disabled(!canAddImages && !canAddVideo)
                    .accessibilityHint(imageSupport == true && videoSupport == true
                        ? "Choose photos and videos from your library" : "")
            }
            if files != nil {
                Button("Files", systemImage: "folder") { showFiles = true }
                    .disabled(!canAddFiles)
                    .accessibilityHint(fileSupport == true ? "Attach any document from Files" : "")
            }
            if imageSupport == true {
                Button("Paste Image", systemImage: "doc.on.clipboard", action: pasteImage)
                    .disabled(!canAddImages)
            }
            if imageSupport != true && videoSupport != true {
                Text(imageSupport == nil
                    ? "Update Cantrip on your Mac to attach photos and files."
                    : "Choose a Claude, Copilot, or Codex backend on your Mac to attach photos, videos and files.")
            } else if !limitsText.isEmpty {
                Divider()
                Text(limitsText)
            }
            if files != nil, fileSupport != true, imageSupport == true {
                Text("Update Cantrip on your Mac to attach documents other than photos and videos.")
            }
        } label: {
            Group {
                if isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 24, weight: .regular))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(isImporting ? "Preparing attachment" : "Attach photos, videos or files")
        .accessibilityValue(accessibilityValueText)
        .accessibilityIdentifier("chat.attach-images")
        .disabled(disabled || isImporting || (!canAddImages && !canAddVideo && !canAddFiles))
        .photosPicker(
            isPresented: $showPhotos,
            selection: $selectedMedia,
            maxSelectionCount: photoLimit,
            matching: photoFilter,
            preferredItemEncoding: .current
        )
        .onChange(of: selectedMedia) { _, items in
            guard !items.isEmpty else { return }
            loadMedia(items)
            selectedMedia = []
        }
        .fileImporter(
            isPresented: $showFiles,
            allowedContentTypes: fileSupport == true ? [.data] : [.image, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                if fileSupport == true {
                    loadFiles(urls)
                } else {
                    loadLegacyFiles(urls)
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Attachment", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear {
            importTask?.cancel()
            if importID == activeImportID { importID = nil }
        }
        .onChange(of: importID) { _, id in
            if id == nil { importTask?.cancel() }
        }
        .onChange(of: paste) { _, request in
            guard let request else { return }
            paste = nil
            loadPasted(request.providers)
        }
    }

    /// Pasted items go where picked ones would: photos and a video as media, the rest as files.
    private func loadPasted(_ providers: [NSItemProvider]) {
        let items = ComposerPaste.classify(providers)
        do {
            guard !items.isEmpty else { throw FileAttachmentError.invalid }
            try checkPasted(items)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let photos = items.filter { $0.kind == .image }
        let videos = items.filter { $0.kind == .video }
        let documents = items.filter { $0.kind == .file }
        performImport {
            let folder = ComposerPaste.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            var images: [ChatImageAttachment] = []
            for item in photos {
                let data = try await ComposerPaste.loadData(item)
                try Task.checkCancellation()
                images.append(try await Task.detached(priority: .userInitiated) {
                    try ImageAttachmentProcessor.prepare(data)
                }.value)
            }
            var imported: ChatVideoAttachment?
            if let item = videos.first {
                imported = try await VideoAttachmentProcessor.importFile(try await ComposerPaste.copyFile(item, into: folder))
            }
            var urls: [URL] = []
            for item in documents { urls.append(try await ComposerPaste.copyFile(item, into: folder)) }
            try Task.checkCancellation()
            try add(images: images, video: imported)
            if let files, !urls.isEmpty {
                let attached = try await FileAttachmentProcessor.importFiles(urls)
                try Task.checkCancellation()
                guard files.wrappedValue.count + attached.count <= FileAttachmentProcessor.maximumCount else {
                    throw FileAttachmentError.tooMany
                }
                files.wrappedValue.append(contentsOf: attached)
            }
            var notes: [String] = []
            if videos.count > 1 { notes.append("You can send one video per message, so only the first one was added.") }
            let skipped = providers.count - items.count
            if skipped > 0 {
                notes.append("\(skipped == 1 ? "One item" : "\(skipped) items") couldn't be attached. Zip folders and packages first.")
            }
            if !notes.isEmpty { errorMessage = notes.joined(separator: "\n\n") }
        }
    }

    /// Refuses a paste this Mac or message can't take before anything is copied.
    private func checkPasted(_ items: [ComposerPaste.Item]) throws {
        let photos = items.filter { $0.kind == .image }.count
        let videos = items.filter { $0.kind == .video }.count
        let documents = items.filter { $0.kind == .file }.count
        if photos > 0 {
            guard imageSupport == true else {
                throw imageSupport == nil ? ComposerPasteError.updateMac : ComposerPasteError.chooseBackend
            }
            guard photos <= imageSlots else { throw ImageAttachmentError.tooMany }
        }
        if videos > 0 {
            guard videoSupport == true else {
                throw videoSupport == nil ? ComposerPasteError.updateMac : ComposerPasteError.chooseBackend
            }
            guard video == nil, mixed || (attachments.isEmpty && photos == 0) else {
                throw VideoAttachmentError.mixedAttachments
            }
        }
        if photos > 0, video != nil, !mixed { throw VideoAttachmentError.mixedAttachments }
        if documents > 0 {
            guard files != nil, fileSupport == true else { throw ComposerPasteError.documentsNeedUpdate }
            guard fileCount + documents <= FileAttachmentProcessor.maximumCount else { throw FileAttachmentError.tooMany }
        }
    }

    /// Photos and videos picked together: up to the open photo slots, and one video.
    private func loadMedia(_ items: [PhotosPickerItem]) {
        let isVideo: (PhotosPickerItem) -> Bool = { item in
            item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        }
        var notes: [String] = []
        var videos = canAddVideo ? items.filter(isVideo) : []
        var photos = canAddImages ? items.filter { !isVideo($0) } : []
        if items.contains(where: isVideo) && !canAddVideo {
            notes.append(video != nil
                ? "This message already has a video, so the videos you picked were left out."
                : "Update Cantrip on your Mac to send photos and a video together. The videos were left out.")
        }
        if videos.count > 1 {
            notes.append("You can send one video per message, so only the first one was added.")
            videos = [videos[0]]
        }
        if !mixed, !videos.isEmpty, !photos.isEmpty {
            notes.append("Update Cantrip on your Mac to send photos and a video together. The video was left out.")
            videos = []
        }
        if photos.count > imageSlots {
            notes.append("You can send four photos per message, so only the first \(imageSlots) were added.")
            photos = Array(photos.prefix(imageSlots))
        }
        let pickedVideo = videos.first
        performImport {
            var images: [ChatImageAttachment] = []
            for item in photos {
                try Task.checkCancellation()
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImageAttachmentError.invalidImage
                }
                images.append(try await Task.detached(priority: .userInitiated) {
                    try ImageAttachmentProcessor.prepare(data)
                }.value)
            }
            var imported: ChatVideoAttachment?
            if let pickedVideo {
                guard let file = try await pickedVideo.loadTransferable(type: ImportedVideo.self) else {
                    throw VideoAttachmentError.invalid
                }
                imported = file.attachment
            }
            try Task.checkCancellation()
            try add(images: images, video: imported)
            if !notes.isEmpty { errorMessage = notes.joined(separator: "\n\n") }
        }
    }

    private func loadFiles(_ urls: [URL]) {
        guard let files else { return }
        guard urls.count + files.wrappedValue.count <= FileAttachmentProcessor.maximumCount else {
            errorMessage = FileAttachmentError.tooMany.localizedDescription
            return
        }
        performImport {
            let imported = try await FileAttachmentProcessor.importFiles(urls)
            try Task.checkCancellation()
            guard files.wrappedValue.count + imported.count <= FileAttachmentProcessor.maximumCount else {
                throw FileAttachmentError.tooMany
            }
            files.wrappedValue.append(contentsOf: imported)
        }
    }

    /// Macs without file uploads still take photos and one video picked from Files.
    private func loadLegacyFiles(_ urls: [URL]) {
        let movies = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true }
        let images = urls.filter { !movies.contains($0) }
        guard movies.count <= 1, (movies.isEmpty || images.isEmpty || mixed) else {
            errorMessage = VideoAttachmentError.mixedAttachments.localizedDescription
            return
        }
        guard images.count + attachments.count <= ImageAttachmentProcessor.maximumCount else {
            errorMessage = ImageAttachmentError.tooMany.localizedDescription
            return
        }
        performImport {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try images.map { try ImageAttachmentProcessor.prepare(ImageAttachmentProcessor.readFile($0)) }
            }.value
            var imported: ChatVideoAttachment?
            if let movie = movies.first { imported = try await VideoAttachmentProcessor.importFile(movie) }
            try Task.checkCancellation()
            try add(images: prepared, video: imported)
        }
    }

    private func add(images: [ChatImageAttachment], video imported: ChatVideoAttachment?) throws {
        if imported != nil {
            guard video == nil, mixed || (attachments.isEmpty && images.isEmpty) else {
                throw VideoAttachmentError.mixedAttachments
            }
        }
        if !images.isEmpty {
            guard mixed || (video == nil && imported == nil) else { throw VideoAttachmentError.mixedAttachments }
            guard attachments.count + images.count <= ImageAttachmentProcessor.maximumCount else {
                throw ImageAttachmentError.tooMany
            }
        }
        attachments.append(contentsOf: images)
        if let imported { video = imported }
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image,
              let data = image.pngData() else {
            errorMessage = ImageAttachmentError.emptyClipboard.localizedDescription
            return
        }

        load {
            let attachment = try await Task.detached(priority: .userInitiated) {
                try ImageAttachmentProcessor.prepare(data)
            }.value
            return [attachment]
        }
    }

    private func load(_ operation: @escaping () async throws -> [ChatImageAttachment]) {
        performImport {
            let imported = try await operation()
            try Task.checkCancellation()
            try add(images: imported, video: nil)
        }
    }

    private func performImport(_ operation: @escaping () async throws -> Void) {
        guard !isImporting, !disabled else { return }
        let id = UUID()
        activeImportID = id
        importID = id
        importTask = Task { @MainActor in
            defer { if importID == id { importID = nil } }
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct ImageAttachmentPreviews: View {
    @Binding var attachments: [ChatImageAttachment]
    @ObservedObject var remote: CantripRemoteModel
    let disabled: Bool
    let isImporting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                            ZStack(alignment: .topTrailing) {
                                ChatImageThumbnail(
                                    source: ChatMessageImage(attachment), remote: remote,
                                    index: index, size: 76
                                )
                                Button {
                                    attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.7))
                                        .font(.title3)
                                        .frame(width: 32, height: 32)
                                        .contentShape(Rectangle())
                                }
                                .disabled(disabled || isImporting)
                                .accessibilityLabel("Remove image \(index + 1)")
                            }
                        }
                    }
                }
                .frame(height: 80)
            }
            if isImporting {
                Text("Preparing attachment...").font(.caption).foregroundStyle(.secondary)
            } else if !attachments.isEmpty {
                Text("\(attachments.count)/4").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
