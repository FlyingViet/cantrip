import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A document picked from Files (PDF, text, spreadsheet, archive...). It's copied into the app's
/// temporary folder when picked, so the upload doesn't depend on the Files grant, and it uploads
/// to the Mac in verified chunks like a video. The agent reads the original bytes there.
final class ChatFileAttachment: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let bytes: Int
    let sha256: String
    let typeIdentifier: String?
    private let directory: URL

    init(id: UUID, name: String, bytes: Int, sha256: String, typeIdentifier: String?) {
        self.id = id
        directory = Self.directory(for: id)
        url = directory.appendingPathComponent("file")
        self.name = name; self.bytes = bytes; self.sha256 = sha256; self.typeIdentifier = typeIdentifier
    }

    deinit {
        do { try FileManager.default.removeItem(at: directory) }
        catch { NSLog("File draft cleanup failed: %@", error.localizedDescription) }
    }

    static func directory(for id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-file-\(id)")
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    var systemImage: String {
        guard let type = typeIdentifier.flatMap(UTType.init) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audiovisualContent) { return "film" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

enum FileAttachmentError: LocalizedError {
    case invalid, tooLarge, tooMany, unsupportedHost
    var errorDescription: String? {
        switch self {
        case .invalid: return "Choose a regular file. Folders and packages can't be attached; zip them first."
        case .tooLarge: return "Files can be up to 100 MB each."
        case .tooMany: return "Attach up to five files per message."
        case .unsupportedHost: return "Update Cantrip on your Mac to attach files."
        }
    }
}

enum FileAttachmentProcessor {
    static let maximumBytes = 100 << 20
    static let maximumCount = 5
    static let chunkBytes = 1 << 20

    /// Copies a picked file while hashing it, so the upload can be verified and resumed.
    static func prepare(_ source: URL) throws -> ChatFileAttachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw FileAttachmentError.invalid
        }
        guard size <= maximumBytes else { throw FileAttachmentError.tooLarge }
        let name = String(source.lastPathComponent
            .replacingOccurrences(of: "\\p{Cc}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        let id = UUID()
        let directory = ChatFileAttachment.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let file = directory.appendingPathComponent("file")
            try Data().write(to: file)
            let reader = try FileHandle(forReadingFrom: source)
            let writer = try FileHandle(forWritingTo: file)
            defer { try? reader.close(); try? writer.close() }
            var bytes = 0, digest = SHA256()
            while let data = try reader.read(upToCount: chunkBytes), !data.isEmpty {
                try Task.checkCancellation()
                bytes += data.count
                guard bytes <= maximumBytes else { throw FileAttachmentError.tooLarge }
                digest.update(data: data)
                try writer.write(contentsOf: data)
            }
            try writer.synchronize()
            guard bytes > 0 else { throw FileAttachmentError.invalid }
            return ChatFileAttachment(
                id: id, name: name.isEmpty ? "file" : name, bytes: bytes,
                sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                typeIdentifier: values.contentType?.identifier
            )
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { NSLog("File import cleanup failed: %@", error.localizedDescription) }
            throw error
        }
    }

    static func importFiles(_ urls: [URL]) async throws -> [ChatFileAttachment] {
        let task = Task.detached(priority: .userInitiated) {
            try urls.map { try prepare($0) }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func chunk(_ file: ChatFileAttachment, offset: Int) throws -> Data {
        let reader = try FileHandle(forReadingFrom: file.url)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(offset))
        let expected = min(chunkBytes, file.bytes - offset)
        let data = try reader.read(upToCount: expected) ?? Data()
        guard data.count == expected else { throw FileAttachmentError.invalid }
        return data
    }
}

/// Picked files under the composer: icon, name and size, each removable.
struct FileAttachmentPreviews: View {
    @Binding var files: [ChatFileAttachment]
    let disabled: Bool

    var body: some View {
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(files) { file in
                    HStack(spacing: 10) {
                        Image(systemName: file.systemImage)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name)
                                .font(.subheadline)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Text(file.sizeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("File \(file.name), \(file.sizeText)")
                        Spacer(minLength: 0)
                        Button {
                            files.removeAll { $0.id == file.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.7))
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(disabled)
                        .accessibilityLabel("Remove file \(file.name)")
                    }
                    .padding(.leading, 10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Text("\(files.count)/\(FileAttachmentProcessor.maximumCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
