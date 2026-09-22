import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ImageAttachmentPicker: View {
    @Binding var attachments: [ChatImageAttachment]
    @Binding var importID: UUID?
    @Binding var video: ChatVideoAttachment?
    let imageSupport: Bool?
    let videoSupport: Bool?
    let disabled: Bool

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var choosingVideoFile = false
    @State private var showVideos = false
    @State private var selectedVideo: PhotosPickerItem?
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?
    @State private var activeImportID: UUID?

    private var isImporting: Bool { importID != nil }

    init(attachments: Binding<[ChatImageAttachment]>, importID: Binding<UUID?>,
         imageSupport: Bool?, disabled: Bool, video: Binding<ChatVideoAttachment?> = .constant(nil),
         videoSupport: Bool? = nil) {
        _attachments = attachments; _importID = importID; _video = video
        self.imageSupport = imageSupport; self.disabled = disabled; self.videoSupport = videoSupport
    }

    var body: some View {
        Menu {
            if imageSupport == true {
                Button("Photo Library", systemImage: "photo.on.rectangle") {
                    showPhotos = true
                }
                .disabled(video != nil)
                Button("Choose Image File", systemImage: "folder") {
                    choosingVideoFile = false
                    showFiles = true
                }
                .disabled(video != nil)
                Button("Paste Image", systemImage: "doc.on.clipboard", action: pasteImage)
                    .disabled(video != nil)
            } else {
                Text(imageSupport == nil
                    ? "Update Cantrip on your Mac to attach images."
                    : "Choose a Claude, Copilot, or Codex backend on your Mac to attach images.")
            }
            Divider()
            if videoSupport == true {
                Button("Video Library", systemImage: "video") { showVideos = true }
                    .disabled(video != nil || !attachments.isEmpty)
                Button("Choose Video File", systemImage: "film") {
                    choosingVideoFile = true
                    showFiles = true
                }
                .disabled(video != nil || !attachments.isEmpty)
                Text("One MOV/MP4, up to 100 MB and five minutes.")
            } else {
                Text("Update Cantrip and choose a Claude, Copilot, or Codex backend to attach videos.")
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
        .accessibilityLabel(isImporting ? "Preparing attachment" : "Attach images or video")
        .accessibilityValue(video == nil ? "\(attachments.count) of \(ImageAttachmentProcessor.maximumCount) images" : "One video attached")
        .accessibilityIdentifier("chat.attach-images")
        .disabled(disabled || isImporting
            || attachments.count >= ImageAttachmentProcessor.maximumCount)
        .photosPicker(
            isPresented: $showPhotos,
            selection: $selectedPhotos,
            maxSelectionCount: max(1, ImageAttachmentProcessor.maximumCount - attachments.count),
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            load {
                var result: [ChatImageAttachment] = []
                for item in items {
                    try Task.checkCancellation()
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ImageAttachmentError.invalidImage
                    }
                    let image = try await Task.detached(priority: .userInitiated) {
                        try ImageAttachmentProcessor.prepare(data)
                    }.value
                    result.append(image)
                }
                return result
            }
            selectedPhotos = []
        }
        .photosPicker(isPresented: $showVideos, selection: $selectedVideo, matching: .videos,
                      preferredItemEncoding: .current)
        .onChange(of: selectedVideo) { _, item in
            guard let item else { return }
            loadVideo {
                guard let imported = try await item.loadTransferable(type: ImportedVideo.self) else {
                    throw VideoAttachmentError.invalid
                }
                return imported.attachment
            }
            selectedVideo = nil
        }
        .fileImporter(
            isPresented: $showFiles,
            allowedContentTypes: choosingVideoFile ? [.mpeg4Movie, .quickTimeMovie] : [.image],
            allowsMultipleSelection: !choosingVideoFile
        ) { result in
            switch result {
            case .success(let urls):
                if choosingVideoFile {
                    guard let url = urls.first, urls.count == 1 else {
                        errorMessage = VideoAttachmentError.invalid.localizedDescription
                        return
                    }
                    loadVideo { try await VideoAttachmentProcessor.importFile(url) }
                    return
                }
                guard urls.count + attachments.count <= ImageAttachmentProcessor.maximumCount else {
                    errorMessage = ImageAttachmentError.tooMany.localizedDescription
                    return
                }
                load {
                    try await Task.detached(priority: .userInitiated) {
                        try urls.map {
                            try ImageAttachmentProcessor.prepare(ImageAttachmentProcessor.readFile($0))
                        }
                    }.value
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
            guard video == nil else { throw VideoAttachmentError.mixedAttachments }
            guard attachments.count + imported.count <= ImageAttachmentProcessor.maximumCount else {
                throw ImageAttachmentError.tooMany
            }
            attachments.append(contentsOf: imported)
        }
    }

    private func loadVideo(_ operation: @escaping () async throws -> ChatVideoAttachment) {
        performImport {
            guard attachments.isEmpty, video == nil else { throw VideoAttachmentError.mixedAttachments }
            let imported = try await operation()
            try Task.checkCancellation()
            video = imported
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
