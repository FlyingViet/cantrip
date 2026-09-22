import AVFoundation
import AVKit
import CoreTransferable
import CryptoKit
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ChatVideoAttachment: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let bytes: Int
    let duration: Double
    let sha256: String
    let thumbnail: Data
    private let directory: URL
    var format: String { url.pathExtension }

    init(id: UUID, format: String, name: String, bytes: Int, duration: Double, sha256: String, thumbnail: Data) {
        self.id = id
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-video-\(id)")
        self.url = directory.appendingPathComponent("video.\(format)")
        self.name = name; self.bytes = bytes
        self.duration = duration; self.sha256 = sha256; self.thumbnail = thumbnail
    }

    deinit {
        do { try FileManager.default.removeItem(at: directory) }
        catch { NSLog("Video draft cleanup failed: %@", error.localizedDescription) }
    }
}

enum VideoAttachmentError: LocalizedError {
    case invalid, tooLarge, tooLong, mixedAttachments, command
    var errorDescription: String? {
        switch self {
        case .invalid: return "Choose a playable MOV or MP4 video."
        case .tooLarge: return "Videos can be up to 100 MB. Trim or export a smaller clip first."
        case .tooLong: return "Videos can be up to five minutes. Trim the clip first."
        case .mixedAttachments: return "Attach one video or up to four images per message. Remove the current attachments first."
        case .command: return "Attach videos to an agent prompt, not a shell or slash command."
        }
    }
}

enum VideoAttachmentProcessor {
    static let maximumBytes = 100 << 20
    static let maximumDuration = 300.0
    static let chunkBytes = 1 << 20

    static func prepare(_ source: URL) async throws -> ChatVideoAttachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let format = source.pathExtension.lowercased()
        guard ["mov", "mp4"].contains(format) else { throw VideoAttachmentError.invalid }
        let info = try FileManager.default.attributesOfItem(atPath: source.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              let size = info[.size] as? NSNumber, size.int64Value > 0 else { throw VideoAttachmentError.invalid }
        guard size.int64Value <= maximumBytes else { throw VideoAttachmentError.tooLarge }
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-video-\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("video.\(format)")
        do {
            try Data().write(to: file)
            let reader = try FileHandle(forReadingFrom: source)
            let writer = try FileHandle(forWritingTo: file)
            defer { try? reader.close(); try? writer.close() }
            var bytes = 0, digest = SHA256()
            while let data = try reader.read(upToCount: chunkBytes), !data.isEmpty {
                try Task.checkCancellation()
                bytes += data.count
                guard bytes <= maximumBytes else { throw VideoAttachmentError.tooLarge }
                digest.update(data: data)
                try writer.write(contentsOf: data)
            }
            try writer.synchronize()
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard duration.isFinite, duration > 0,
                  let track = tracks.first else { throw VideoAttachmentError.invalid }
            guard duration <= maximumDuration else { throw VideoAttachmentError.tooLong }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            let start = try await track.load(.timeRange).start
            let frame = try await generator.image(at: start)
            guard let thumbnail = UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.8) else {
                throw VideoAttachmentError.invalid
            }
            try Task.checkCancellation()
            let name = source.lastPathComponent.replacingOccurrences(of: "\\p{Cc}", with: "", options: .regularExpression)
            return ChatVideoAttachment(id: id, format: format, name: String(name.prefix(160)),
                                       bytes: bytes, duration: duration,
                                       sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                                       thumbnail: thumbnail)
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { NSLog("Video import cleanup failed: %@", error.localizedDescription) }
            throw error
        }
    }

    static func importFile(_ url: URL) async throws -> ChatVideoAttachment {
        let task = Task.detached(priority: .userInitiated) { try await prepare(url) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func chunk(_ video: ChatVideoAttachment, offset: Int) throws -> Data {
        let reader = try FileHandle(forReadingFrom: video.url)
        defer { try? reader.close() }
        try reader.seek(toOffset: UInt64(offset))
        let expected = min(chunkBytes, video.bytes - offset)
        let data = try reader.read(upToCount: expected) ?? Data()
        guard data.count == expected else { throw VideoAttachmentError.invalid }
        return data
    }
}

struct ImportedVideo: Transferable {
    let attachment: ChatVideoAttachment
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            ImportedVideo(attachment: try await VideoAttachmentProcessor.importFile(received.file))
        }
    }
}

struct CantripVideoUploadStatus: Decodable {
    let totalBytes: Int
    let receivedBytes: Int
    let sha256: String
}

struct VideoUploadProgress: Equatable {
    let fraction: Double
    let isPreparing: Bool
    var label: String { isPreparing ? "Preparing video for analysis..." : "Uploading video: \(Int(fraction * 100))%" }
}

struct VideoAttachmentPreview: View {
    let video: ChatVideoAttachment
    let disabled: Bool
    let remove: () -> Void
    @State private var showPlayer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { showPlayer = true } label: {
                    ZStack {
                        if let image = UIImage(data: video.thumbnail) {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                        Image(systemName: "play.circle.fill").font(.largeTitle)
                            .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7))
                    }
                    .frame(width: 76, height: 76)
                }
                .accessibilityLabel("Preview video \(video.name)")
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.name).font(.subheadline).lineLimit(2)
                    Text("\(Int(video.duration)) seconds · \(ByteCountFormatter.string(fromByteCount: Int64(video.bytes), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                }
                .disabled(disabled)
                .accessibilityLabel("Remove video")
            }
            Text("Original video, audio and metadata go to your Mac. Analysis starts with four timed preview frames; audio is not automatically transcribed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showPlayer) { VideoAttachmentPlayer(video: video) }
    }
}

private struct VideoAttachmentPlayer: View {
    let video: ChatVideoAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(video: ChatVideoAttachment) {
        self.video = video
        _player = State(initialValue: AVPlayer(url: video.url))
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .navigationTitle(video.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
        }
        .onDisappear { player.pause() }
    }
}
