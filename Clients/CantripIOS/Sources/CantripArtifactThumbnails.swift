import SwiftUI
import UIKit

struct CantripHomeArtifactThumbnailPayload: Decodable, Equatable {
    let data: Data
    let width: Int
    let height: Int
    let durationSeconds: Double?
}

struct CantripArtifactThumbnail {
    let image: UIImage
    let durationSeconds: Double?
}

/// Bounds how many thumbnails download at once, so a fast scroll can't flood the Mac.
actor CantripAsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Artifacts-grid thumbnails: memory first, then disk, then one request per artifact revision.
/// Failures are remembered until the next refresh so scrolling never retries in a loop.
@MainActor
final class CantripArtifactThumbnailStore {
    static let maximumBytes = 1 << 20
    static let maximumDimension = 600
    static let maximumDiskEntries = 300

    private final class Entry {
        let value: CantripArtifactThumbnail
        init(_ value: CantripArtifactThumbnail) { self.value = value }
    }

    private struct DiskEntry: Codable {
        let durationSeconds: Double?
        let jpeg: Data
    }

    let directory: URL
    private let memory = NSCache<NSString, Entry>()
    private var unavailable: Set<String> = []
    private var inFlight: [String: Task<CantripArtifactThumbnail?, Never>] = [:]
    private let limiter: CantripAsyncLimiter
    private var generation = 0
    /// Requests sent to the Mac; tests use it to prove cache hits.
    private(set) var fetchCount = 0

    init(
        directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CantripArtifactThumbnails", isDirectory: true),
        concurrentFetches: Int = 3
    ) {
        self.directory = directory
        limiter = CantripAsyncLimiter(limit: concurrentFetches)
        memory.countLimit = 200
    }

    /// Changes whenever the artifact's file is replaced (size or modification date).
    static func key(_ artifact: CantripHomeArtifact) -> String {
        let millis = Int64((artifact.createdAt.timeIntervalSince1970 * 1000).rounded())
        return "\(artifact.id.uuidString)-\(artifact.size)-\(millis)"
    }

    static func supports(_ artifact: CantripHomeArtifact) -> Bool {
        isImage(artifact) || isVideo(artifact)
    }

    static func isImage(_ artifact: CantripHomeArtifact) -> Bool {
        artifact.kind == "image" || artifact.mimeType.hasPrefix("image/")
    }

    static func isVideo(_ artifact: CantripHomeArtifact) -> Bool {
        artifact.kind == "video" || artifact.mimeType.hasPrefix("video/")
    }

    func cached(_ artifact: CantripHomeArtifact) -> CantripArtifactThumbnail? {
        memory.object(forKey: Self.key(artifact) as NSString)?.value
    }

    func isUnavailable(_ artifact: CantripHomeArtifact) -> Bool {
        unavailable.contains(Self.key(artifact))
    }

    func thumbnail(
        for artifact: CantripHomeArtifact,
        fetch: @escaping @MainActor () async throws -> CantripHomeArtifactThumbnailPayload?
    ) async -> CantripArtifactThumbnail? {
        guard Self.supports(artifact) else { return nil }
        let key = Self.key(artifact)
        if let hit = memory.object(forKey: key as NSString) { return hit.value }
        if unavailable.contains(key) { return nil }
        if let running = inFlight[key] { return await running.value }
        let generation = self.generation
        let file = directory.appendingPathComponent("\(key).json")
        let directory = self.directory
        let limiter = self.limiter
        let task = Task { @MainActor [weak self] () -> CantripArtifactThumbnail? in
            defer { if self?.generation == generation { self?.inFlight[key] = nil } }
            if let disk = await Task.detached(priority: .utility, operation: { Self.readDisk(file) }).value {
                guard let self, self.generation == generation else { return nil }
                self.memory.setObject(Entry(disk), forKey: key as NSString)
                return disk
            }
            await limiter.acquire()
            let payload: CantripHomeArtifactThumbnailPayload?
            do {
                guard let self, self.generation == generation else {
                    await limiter.release()
                    return nil
                }
                self.fetchCount += 1
                payload = try await fetch()
                await limiter.release()
            } catch {
                await limiter.release()
                if !(error is CancellationError), self?.generation == generation { self?.unavailable.insert(key) }
                return nil
            }
            guard let self, self.generation == generation else { return nil }
            guard let payload,
                  let image = try? await Task.detached(priority: .userInitiated, operation: {
                      try ChatImageDecoder.decode(payload.data, maximumDimension: Self.maximumDimension,
                                                  maximumBytes: Self.maximumBytes)
                  }).value,
                  self.generation == generation else {
                self.unavailable.insert(key)
                return nil
            }
            let value = CantripArtifactThumbnail(image: image, durationSeconds: payload.durationSeconds)
            self.memory.setObject(Entry(value), forKey: key as NSString)
            let entry = DiskEntry(durationSeconds: payload.durationSeconds, jpeg: payload.data)
            Task { @MainActor [weak self] in
                await Task.detached(priority: .utility) { Self.writeDisk(entry, to: file, directory: directory) }.value
                // Unpaired or switched Macs while writing: don't leave the old Mac's thumbnail behind.
                if self?.generation != generation { try? FileManager.default.removeItem(at: file) }
            }
            return value
        }
        inFlight[key] = task
        return await task.value
    }

    /// Pull-to-refresh tries failed thumbnails again.
    func resetFailures() {
        unavailable.removeAll()
    }

    /// Unpairing or switching Macs drops every thumbnail, on disk too.
    func removeAll() {
        generation += 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        unavailable.removeAll()
        memory.removeAllObjects()
        // Synchronous (a few small files), so it can't race with a reconnect's new writes.
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated private static func readDisk(_ file: URL) -> CantripArtifactThumbnail? {
        guard let data = try? Data(contentsOf: file),
              let entry = try? JSONDecoder().decode(DiskEntry.self, from: data),
              let image = try? ChatImageDecoder.decode(entry.jpeg, maximumDimension: maximumDimension,
                                                       maximumBytes: maximumBytes) else { return nil }
        return CantripArtifactThumbnail(image: image, durationSeconds: entry.durationSeconds)
    }

    nonisolated private static func writeDisk(_ entry: DiskEntry, to file: URL, directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )
            guard files.count > maximumDiskEntries else { return }
            let oldest = files.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
            for url in oldest.prefix(files.count - maximumDiskEntries) { try? FileManager.default.removeItem(at: url) }
        } catch {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// The preview area of an artifact card: a thumbnail for images and videos (with a play
/// badge and duration), or a type icon for documents, audio and anything without one.
struct CantripArtifactThumbnailView: View {
    let artifact: CantripHomeArtifact
    let remote: CantripRemoteModel
    var onLoad: ((CantripArtifactThumbnail?) -> Void)?
    @State private var thumbnail: CantripArtifactThumbnail?
    @State private var loading: Bool

    init(artifact: CantripHomeArtifact, remote: CantripRemoteModel,
         onLoad: ((CantripArtifactThumbnail?) -> Void)? = nil) {
        self.artifact = artifact
        self.remote = remote
        self.onLoad = onLoad
        let cached = remote.artifactThumbnails.cached(artifact)
        _thumbnail = State(initialValue: cached)
        _loading = State(initialValue: cached == nil && CantripArtifactThumbnailStore.supports(artifact)
            && !remote.artifactThumbnails.isUnavailable(artifact))
    }

    var body: some View {
        Color.accentColor.opacity(0.1)
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail.image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: Self.icon(artifact))
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                }
            }
            .overlay {
                if thumbnail != nil, CantripArtifactThumbnailStore.isVideo(artifact) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration = thumbnail?.durationSeconds {
                    Text(Self.duration(duration))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(8)
                } else if loading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
            .task(id: CantripArtifactThumbnailStore.key(artifact)) {
                guard thumbnail == nil, CantripArtifactThumbnailStore.supports(artifact),
                      !remote.artifactThumbnails.isUnavailable(artifact) else {
                    loading = false
                    return
                }
                loading = true
                let loaded = await remote.homeArtifactThumbnail(artifact)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.15)) { thumbnail = loaded }
                loading = false
                onLoad?(loaded)
            }
    }

    static func icon(_ artifact: CantripHomeArtifact) -> String {
        switch artifact.kind {
        case "image": "photo"
        case "video": "play.rectangle.fill"
        case "audio": "waveform"
        default:
            artifact.mimeType == "application/pdf" ? "doc.richtext.fill" : "doc.text.fill"
        }
    }

    /// "0:07", "12:30" or "1:02:03", like Photos.
    static func duration(_ seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    static func spokenDuration(_ seconds: Double) -> String {
        Duration.seconds(max(1, seconds.rounded()))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// Window frames of the artifact cards' thumbnails, for the viewer's zoom transition.
@MainActor
final class CantripViewerSources {
    private var sources: [UUID: CantripViewerSource] = [:]

    func source(_ id: UUID) -> CantripViewerSource {
        if let existing = sources[id] { return existing }
        let created = CantripViewerSource()
        sources[id] = created
        return created
    }
}
