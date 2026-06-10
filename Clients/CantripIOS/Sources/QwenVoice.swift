import Foundation
import AVFoundation
import Qwen3TTS
import MLX

/// On-device neural TTS — Qwen3-TTS 0.6B CustomVoice (4-bit, vocab-pruned) on
/// MLX. An opt-in alternative to `AVSpeechSynthesizer`: far more natural, but
/// costs an ~800 MB model download and runs the GPU while speaking.
///
/// Mirrors `VoiceController`'s streamed-reply contract (`beginReply` →
/// `enqueue` per chunk → `finishReply`, `onIdle` once everything spoken):
/// chunks are synthesized one at a time on a background actor and the PCM
/// buffers queue onto an `AVAudioPlayerNode`, so sentence N plays while
/// sentence N+1 is still generating.
///
/// MLX needs real Apple Silicon — on the simulator the engine reports
/// unavailable and `VoiceController` keeps using the system voice.
@MainActor
final class QwenVoiceEngine: ObservableObject {
    static let shared = QwenVoiceEngine()

    /// HF repo of the compressed model (808 MB; ~67% smaller than bf16 with
    /// near-identical quality). Includes the nested speech_tokenizer/ dir.
    static let repo = "AtomGradient/Qwen3-TTS-0.6B-CustomVoice-4bit-pruned-vocab-lite"
    static let speakers = ["Serena", "Vivian", "Aiden", "Ryan", "Eric", "Dylan", "Sohee", "Ono_anna", "Uncle_fu"]

    enum DownloadState: Equatable {
        case idle
        case downloading(Double)     // 0...1
        case ready
        case failed(String)
    }
    @Published private(set) var download: DownloadState = .idle
    @Published private(set) var speaking = false

    /// True when "Qwen3 (Neural)" is selected in Settings AND the model is on
    /// disk — the single routing switch `VoiceController` consults per chunk.
    static var routeActive: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return UserDefaults.standard.string(forKey: "hermes.voiceEngine") == "qwen"
            && shared.download == .ready
        #endif
    }

    static var selectedSpeaker: String {
        UserDefaults.standard.string(forKey: "hermes.qwenSpeaker") ?? "Serena"
    }

    /// Fires (on main) when the reply has fully streamed AND every queued chunk
    /// has played — the hands-free "resume listening" moment.
    var onIdle: (() -> Void)?

    private let synth = QwenSynth()
    private var pendingTexts: [String] = []
    private var processing = false
    private var scheduledBuffers = 0
    private var replyDone = true
    /// Bumped by `stop()` so in-flight synthesis/buffer callbacks from a
    /// barged-in reply can't re-schedule audio or fire `onIdle`.
    private var generation = 0
    private var downloadTask: Task<Void, Never>?

    private let player = AVAudioPlayerNode()
    private let audioEngine = AVAudioEngine()
    private var engineWired = false
    private static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: 24_000, channels: 1, interleaved: false)!

    init() {
        download = Self.modelOnDisk ? .ready : .idle
    }

    // MARK: - Streamed-reply queue (same shape as VoiceController's)

    func beginReply() { replyDone = false }

    func enqueue(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        speaking = true
        pendingTexts.append(clean)
        pump()
    }

    func finishReply() {
        replyDone = true
        checkIdle()
    }

    /// Barge-in: drop everything queued, kill playback, invalidate in-flight work.
    func stop() {
        generation += 1
        pendingTexts.removeAll()
        if engineWired { player.stop() }
        scheduledBuffers = 0
        processing = false
        replyDone = true
        speaking = false
    }

    /// Short sample with the (newly) selected speaker — Settings preview.
    func preview() {
        stop()
        beginReply()
        enqueue("Hey, this is how I'll sound.")
        finishReply()
    }

    /// Serialize synthesis: one chunk at a time through the actor, in order, so
    /// buffers schedule in reply order. Playback overlaps the next generation.
    private func pump() {
        guard !processing, !pendingTexts.isEmpty else { return }
        processing = true
        let gen = generation
        Task {
            while gen == self.generation, !self.pendingTexts.isEmpty {
                let text = self.pendingTexts.removeFirst()
                do {
                    let samples = try await self.synth.synthesize(text, speaker: Self.selectedSpeaker,
                                                                  modelDir: Self.modelDir)
                    if gen == self.generation { self.schedule(samples, gen: gen) }
                } catch {
                    // Best-effort: skip the chunk (transient OOM/decode hiccup).
                    // The reply text is still on screen, so nothing is lost.
                    print("[QwenTTS] synthesis failed: \(error)")
                }
            }
            self.processing = false
            self.checkIdle()
        }
    }

    private func schedule(_ samples: [Float], gen: Int) {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        do { try startAudioEngine() } catch { return }
        scheduledBuffers += 1
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in
                guard gen == self.generation else { return }
                self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                self.checkIdle()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func startAudioEngine() throws {
        if !engineWired {
            audioEngine.attach(player)
            // The mixer resamples 24 kHz mono up to the session rate for us.
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: Self.pcmFormat)
            engineWired = true
        }
        if !audioEngine.isRunning { try audioEngine.start() }
    }

    private func checkIdle() {
        guard replyDone, pendingTexts.isEmpty, !processing, scheduledBuffers == 0, speaking else { return }
        speaking = false
        onIdle?()
    }

    // MARK: - Model on disk

    private static let modelDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QwenTTS", isDirectory: true)
            .appendingPathComponent(repo.components(separatedBy: "/").last!, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    /// Written only after every file lands — a partial download never counts.
    private static var completeMarker: URL { modelDir.appendingPathComponent(".download-complete") }
    private static var modelOnDisk: Bool { FileManager.default.fileExists(atPath: completeMarker.path) }

    var modelSizeBytes: Int64 {
        guard let files = FileManager.default.enumerator(at: Self.modelDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in files {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func deleteModel() {
        downloadTask?.cancel()
        stop()
        Task { await synth.unload() }
        try? FileManager.default.removeItem(at: Self.modelDir)
        try? FileManager.default.createDirectory(at: Self.modelDir, withIntermediateDirectories: true)
        download = .idle
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        download = .idle
    }

    func downloadModel() {
        guard downloadTask == nil else { return }
        download = .downloading(0)
        downloadTask = Task {
            do {
                try await Self.fetchModel { [weak self] p in
                    Task { @MainActor in
                        if case .downloading = self?.download { self?.download = .downloading(p) }
                    }
                }
                FileManager.default.createFile(atPath: Self.completeMarker.path, contents: Data())
                self.download = .ready
            } catch is CancellationError {
                self.download = .idle
            } catch {
                self.download = .failed(error.localizedDescription)
            }
            self.downloadTask = nil
        }
    }

    /// Mirror the HF repo tree (recursive — the model has a nested
    /// speech_tokenizer/ dir) into `modelDir`, streaming each file to disk.
    private nonisolated static func fetchModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        struct TreeEntry: Decodable { let type: String; let path: String; let size: Int64? }
        let treeURL = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")!
        let (treeData, treeResp) = try await URLSession.shared.data(from: treeURL)
        guard (treeResp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let files = try JSONDecoder().decode([TreeEntry].self, from: treeData)
            .filter { $0.type == "file" }
            .filter { !$0.path.hasPrefix(".") && !$0.path.hasSuffix(".md") }
        let total = max(1, files.reduce(Int64(0)) { $0 + ($1.size ?? 0) })

        var done: Int64 = 0
        for f in files {
            try Task.checkCancellation()
            let dest = modelDir.appendingPathComponent(f.path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Resume across attempts: a file already fully present is skipped.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
               (attrs[.size] as? Int64) == f.size, f.size != nil {
                done += f.size ?? 0
                progress(Double(done) / Double(total))
                continue
            }
            let src = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(f.path)")!
            let (bytes, resp) = try await URLSession.shared.bytes(from: src)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let handle = try FileHandle(forWritingTo: dest)
            defer { try? handle.close() }
            var buffer = Data(); buffer.reserveCapacity(1 << 20)
            var written: Int64 = 0
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(Double(done + written) / Double(total))
                }
            }
            try handle.write(contentsOf: buffer)
            done += written + Int64(buffer.count)
            progress(Double(done) / Double(total))
        }
    }
}

/// Owns the (non-Sendable) MLX model off the main actor. Synthesis is
/// serialized by actor isolation; the model loads lazily on first use and
/// stays resident so later sentences skip the multi-second load.
private actor QwenSynth {
    private var model: Qwen3TTSModel?

    func synthesize(_ text: String, speaker: String, modelDir: URL) async throws -> [Float] {
        if model == nil {
            model = try await Qwen3TTSModel.fromPretrained(modelDir.path)
        }
        guard let model else { return [] }
        let audio = try await model.generate(text: text, speaker: speaker, language: "english")
        return audio.asArray(Float.self)
    }

    func unload() { model = nil }
}
