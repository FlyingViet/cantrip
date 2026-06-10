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
/// A named voice: a model speaker plus an optional style `instruct` shaping
/// tone and articulation per generation.
struct QwenPreset: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let blurb: String
    let speaker: String
    let instruct: String?
}

/// MLX needs real Apple Silicon — on the simulator the engine reports
/// unavailable and `VoiceController` keeps using the system voice.
@MainActor
final class QwenVoiceEngine: ObservableObject {
    static let shared = QwenVoiceEngine()

    /// HF repo of the compressed model (808 MB; ~67% smaller than bf16 with
    /// near-identical quality). Includes the nested speech_tokenizer/ dir.
    static let repo = "AtomGradient/Qwen3-TTS-0.6B-CustomVoice-4bit-pruned-vocab-lite"
    static let speakers = ["Serena", "Vivian", "Aiden", "Ryan", "Eric", "Dylan", "Sohee", "Ono_anna", "Uncle_fu"]

    /// Curated presets: a speaker plus a per-generation `instruct` shaping tone
    /// and articulation. Clarity comes from the instruct + cooler sampling;
    /// reading SPEED comes from the time-pitch playback stage (`hermes.qwenRate`)
    /// — asking the model itself to rush makes it slur.
    static let gentlePresets: [QwenPreset] = [
        QwenPreset(id: "serena-gentle", name: "Serena · Gentle", blurb: "Warm and soft, crisp diction",
                   speaker: "Serena",
                   instruct: "A gentle, warm female voice with a soft tone and crisp, clear articulation."),
        QwenPreset(id: "vivian-bright", name: "Vivian · Bright", blurb: "Light and friendly, very clear",
                   speaker: "Vivian",
                   instruct: "A bright, friendly female voice, light and gentle, enunciating every word clearly."),
        QwenPreset(id: "sohee-soothing", name: "Sohee · Soothing", blurb: "Calm and soft-spoken, precise",
                   speaker: "Sohee",
                   instruct: "A soothing, calm female voice, soft-spoken but precisely articulated."),
        QwenPreset(id: "anna-light", name: "Anna · Light", blurb: "Airy and pleasant, clean delivery",
                   speaker: "Ono_anna",
                   instruct: "A light, airy female voice, gentle and pleasant, with clean, precise delivery."),
    ]
    /// The raw speakers, no styling — same voices the model ships with.
    static let plainPresets: [QwenPreset] = speakers.map {
        QwenPreset(id: "speaker-\($0)", name: $0.replacingOccurrences(of: "_", with: " ").capitalized,
                   blurb: "Speaker default", speaker: $0, instruct: nil)
    }
    static var allPresets: [QwenPreset] { gentlePresets + plainPresets }

    static var selectedPreset: QwenPreset {
        let id = UserDefaults.standard.string(forKey: "hermes.qwenPreset") ?? ""
        return allPresets.first { $0.id == id } ?? gentlePresets[0]
    }

    /// Playback speed (time-stretch, pitch preserved). >1 reads faster without
    /// touching how the model speaks — the reliable "read quickly" knob.
    static var playbackRate: Float {
        let v = UserDefaults.standard.float(forKey: "hermes.qwenRate")
        return v > 0 ? min(max(v, 0.8), 1.6) : 1.15
    }

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
    private let timePitch = AVAudioUnitTimePitch()   // speed without chipmunking
    private let audioEngine = AVAudioEngine()
    private var engineWired = false
    private static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: 24_000, channels: 1, interleaved: false)!

    init() {
        download = Self.modelOnDisk ? .ready : .idle
        // The mic engine re-taking the audio session (hands-free resume) stops
        // this engine out from under us, silently dropping scheduled buffers and
        // their completion callbacks. Reconcile the counter or the reply flow
        // hangs waiting for callbacks that will never fire.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: audioEngine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.scheduledBuffers > 0 else { return }
                self.scheduledBuffers = 0
                self.checkIdle()
            }
        }
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
        stopPlayback()
        scheduledBuffers = 0
        processing = false
        replyDone = true
        speaking = false
    }

    /// AVAudioPlayerNode raises an UNCATCHABLE NSException (`required condition
    /// is false: _engine->IsRunning()`) if touched while its engine is stopped —
    /// and the engine stops itself whenever the mic flips the audio session.
    /// Every player.play()/stop() must come through here or schedule().
    private func stopPlayback() {
        guard engineWired, audioEngine.isRunning else { return }
        player.stop()
        audioEngine.stop()
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
                    let preset = Self.selectedPreset
                    let samples = try await self.synth.synthesize(text, speaker: preset.speaker,
                                                                  instruct: preset.instruct,
                                                                  modelDir: Self.modelDir)
                    if gen == self.generation { self.schedule(samples, gen: gen) }
                } catch {
                    // Best-effort: skip the chunk (transient OOM/decode hiccup).
                    // The reply text is still on screen, so nothing is lost.
                    print("[QwenTTS] synthesis failed: \(error)")
                }
            }
            // A barge-in (gen bumped) already reset `processing` for the NEXT
            // reply's pump — only clear it if this loop is still the live one.
            if gen == self.generation {
                self.processing = false
                self.checkIdle()
            }
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
        guard audioEngine.isRunning else { return }   // see stopPlayback() — play() on a dead engine is fatal
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
            audioEngine.attach(timePitch)
            // player → timePitch (reading-speed control) → mixer, which also
            // resamples 24 kHz mono up to the session rate for us.
            audioEngine.connect(player, to: timePitch, format: Self.pcmFormat)
            audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: Self.pcmFormat)
            engineWired = true
        }
        timePitch.rate = Self.playbackRate    // re-read so the slider applies live
        if !audioEngine.isRunning { try audioEngine.start() }
    }

    /// Reply fully streamed AND every queued chunk played → flip `speaking`
    /// false. VoiceController observes `$speaking` (NOT a callback — a callback
    /// installed on this singleton gets stolen by SwiftUI's transient
    /// VoiceController instances) and handles the hands-free resume.
    private func checkIdle() {
        guard replyDone, pendingTexts.isEmpty, !processing, scheduledBuffers == 0, speaking else { return }
        // Release the audio engine BEFORE observers flip the session back to the
        // mic — a still-running playback engine during that flip is what used to
        // strand the player node on a dead engine (and crash the next touch).
        stopPlayback()
        speaking = false
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
    /// MLX synthesis is seconds of SYNCHRONOUS compute. On the default actor
    /// executor that pins a shared cooperative-pool thread, starving the rest of
    /// the app's async work (visible as scroll hitches while speaking) — so this
    /// actor runs on its own dispatch queue/thread instead.
    private let queue = DispatchSerialQueue(label: "hermes.qwen.tts", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var model: Qwen3TTSModel?

    func synthesize(_ text: String, speaker: String, instruct: String?, modelDir: URL) async throws -> [Float] {
        if model == nil {
            // Cap MLX's Metal buffer cache: left unbounded it grows with every
            // synthesis until iOS jetsams the app (crashes "after speaking").
            MLX.GPU.set(cacheLimit: 32 * 1024 * 1024)
            model = try await Qwen3TTSModel.fromPretrained(modelDir.path)
        }
        guard let model else { return [] }
        // The sync CustomVoice entry point (not async `generate`) keeps the
        // compute on this actor's dedicated thread — a non-isolated async func
        // would hop back onto the cooperative pool.
        // temperature 0.7 (package default 0.9): hot sampling is what makes
        // autoregressive TTS mumble/slur; cooler is stabler with no flatness yet.
        let audio = try model.generateCustomVoice(text: text, speaker: speaker,
                                                  language: "english",
                                                  instruct: instruct,
                                                  temperature: 0.7)
        return audio.asType(.float32).asArray(Float.self)
    }

    func unload() {
        model = nil
        MLX.GPU.clearCache()
    }
}
