import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ImageAttachmentPicker: View {
    @Binding var attachments: [ChatImageAttachment]
    @Binding var importID: UUID?
    @ObservedObject var remote: CantripRemoteModel
    let imageSupport: Bool?
    let disabled: Bool

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?
    @State private var activeImportID: UUID?

    private var isImporting: Bool { importID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty { previews }
            HStack(spacing: 8) {
                Menu {
                    if imageSupport == true {
                        Button("Photo Library", systemImage: "photo.on.rectangle") {
                            showPhotos = true
                        }
                        Button("Choose Image File", systemImage: "folder") {
                            showFiles = true
                        }
                        Button("Paste Image", systemImage: "doc.on.clipboard", action: pasteImage)
                    } else {
                        Text(imageSupport == nil
                            ? "Update Cantrip on your Mac to attach images."
                            : "Choose a Claude, Copilot, or Codex backend on your Mac to attach images.")
                    }
                } label: {
                    Label("Attach images", systemImage: "paperclip")
                        .font(.callout)
                }
                .disabled(disabled || isImporting
                    || attachments.count >= ImageAttachmentProcessor.maximumCount)
                if isImporting {
                    ProgressView().controlSize(.small)
                    Text("Preparing images...").font(.caption).foregroundStyle(.secondary)
                } else if !attachments.isEmpty {
                    Text("\(attachments.count)/4")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
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
        .fileImporter(
            isPresented: $showFiles,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
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
        .alert("Image attachment", isPresented: Binding(
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
    }

    private var previews: some View {
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
        guard !isImporting, !disabled else { return }
        let id = UUID()
        activeImportID = id
        importID = id
        importTask = Task { @MainActor in
            defer { if importID == id { importID = nil } }
            do {
                let imported = try await operation()
                try Task.checkCancellation()
                guard attachments.count + imported.count <= ImageAttachmentProcessor.maximumCount else {
                    throw ImageAttachmentError.tooMany
                }
                attachments.append(contentsOf: imported)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
