import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Network

/// Splits 16 kHz audio at natural pauses so finished phrases can be
/// transcribed while you keep talking, leaving only the tail for release.
struct DictationSegmenter {
    static let sampleRate = 16_000
    static let frameLength = 320

    var minimumSeconds = 1.6
    var pauseSeconds = 0.45
    var maximumSeconds = 12.0

    private(set) var pending: [Float] = []
    private var levels: [Float] = []

    mutating func append(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        let frame = Self.frameLength
        while (levels.count + 1) * frame <= pending.count {
            let start = levels.count * frame
            var energy: Float = 0
            for sample in pending[start..<(start + frame)] { energy += sample * sample }
            levels.append((energy / Float(frame)).squareRoot())
        }
        var segments: [[Float]] = []
        while let cut = nextCut() {
            let segment = Array(pending[..<cut])
            let speech = containsSpeech(levels[..<(cut / frame)])
            pending.removeFirst(cut)
            levels.removeFirst(cut / frame)
            if speech { segments.append(segment) }
        }
        // Long silence before any speech is not worth keeping.
        if levels.count > 150, !containsSpeech(levels[...]) {
            let drop = (levels.count - 25) * frame
            pending.removeFirst(drop)
            levels.removeFirst(levels.count - 25)
        }
        return segments
    }

    /// The remaining audio when recording ends, if it holds speech.
    mutating func flush() -> [Float]? {
        defer {
            pending = []
            levels = []
        }
        guard !pending.isEmpty else { return nil }
        if levels.count < 5 || containsSpeech(levels[...]) { return pending }
        return nil
    }

    private var threshold: Float {
        guard !levels.isEmpty else { return 0.01 }
        let sorted = levels.sorted()
        // Continuous speech must not raise the noise floor to speech level.
        let floor = min(0.005, max(0.0005, sorted[sorted.count / 10]))
        return max(floor * 3, floor + 0.004)
    }

    private func containsSpeech(_ slice: ArraySlice<Float>) -> Bool {
        let threshold = threshold
        return slice.filter { $0 > threshold }.count >= 5
    }

    private func nextCut() -> Int? {
        let frame = Self.frameLength
        let seconds = Double(pending.count) / Double(Self.sampleRate)
        guard seconds >= minimumSeconds, levels.count > 10 else { return nil }
        let threshold = threshold
        var silent = 0
        for level in levels.reversed() {
            guard level <= threshold else { break }
            silent += 1
        }
        let pauseFrames = Int(pauseSeconds * Double(Self.sampleRate) / Double(frame))
        if silent >= pauseFrames, silent < levels.count,
           containsSpeech(levels[..<(levels.count - silent)]) {
            return (levels.count - silent / 2) * frame
        }
        if seconds >= maximumSeconds {
            let limit = min(levels.count, Int(maximumSeconds * Double(Self.sampleRate)) / frame)
            let window = max(0, limit - 200)..<limit
            let quietest = window.min { levels[$0] < levels[$1] } ?? (levels.count - 1)
            return max(1, quietest) * frame
        }
        return nil
    }
}

/// Parakeet TDT 0.6B v2 (punctuated, cased English) plus CTC vocabulary
/// boosting, kept loaded between dictations and released while the neural
/// voice speaks.
actor DictationRecognizer {
    static let shared = DictationRecognizer()
    static let readyKey = "hermes.dictationModelsReady"

    struct Segment: Sendable {
        let text: String
        let raw: String
        let asrMilliseconds: Double
        let boostMilliseconds: Double
    }

    enum RecognizerError: Error {
        case notReady
    }

    private var asr: AsrManager?
    private var ctcModels: CtcModels?
    private var boosting: VocabularyBoostingSession?
    private var boostingSignature: Int?
    private var pendingTerms: [DictationTerm] = []
    private var termKeys: [[String]] = []
    private var loading: Task<Void, Error>?
    private var generation = 0

    static var modelsDownloaded: Bool {
        UserDefaults.standard.bool(forKey: readyKey)
    }

    var isLoaded: Bool { asr != nil }

    func prepare(progress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        if asr != nil { return }
        if let loading {
            try await loading.value
            return
        }
        generation += 1
        let current = generation
        let task = Task {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let models = try await AsrModels.downloadAndLoad(
                configuration: configuration, version: .v2
            ) { update in
                progress?(update.fractionCompleted * 0.85, "Dictation model")
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            UserDefaults.standard.set(true, forKey: Self.readyKey)
            // Released while loading: drop the model instead of keeping it next to the voice.
            guard current == generation else {
                await manager.cleanup()
                throw CancellationError()
            }
            asr = manager
            progress?(0.85, "Name boosting")
            if let ctc = try? await CtcModels.downloadAndLoad(variant: .ctc110m), current == generation {
                ctcModels = ctc
                await rebuildBoosting()
            }
            progress?(1, "Ready")
        }
        loading = task
        defer { if generation == current { loading = nil } }
        try await task.value
    }

    /// Waits for a load already in progress (from disk), but never for a download.
    func waitUntilUsable() async -> Bool {
        if asr != nil { return true }
        guard let loading, Self.modelsDownloaded else { return false }
        _ = try? await loading.value
        return asr != nil
    }

    func setVocabulary(_ terms: [DictationTerm]) async {
        pendingTerms = terms
        termKeys = terms.map { $0.text.split(separator: " ").map { DictationText.key(String($0)) } }
        await rebuildBoosting()
    }

    private func rebuildBoosting() async {
        var hasher = Hasher()
        for term in pendingTerms {
            hasher.combine(term.text)
            hasher.combine(term.aliases)
        }
        let signature = hasher.finalize()
        guard let ctcModels, signature != boostingSignature else { return }
        boostingSignature = signature
        guard !pendingTerms.isEmpty else {
            boosting = nil
            return
        }
        let vocabulary = CustomVocabularyContext(terms: pendingTerms.map {
            CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
        })
        boosting = try? await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctcModels)
    }

    func transcribe(_ samples: [Float]) async throws -> Segment {
        guard let asr else { throw RecognizerError.notReady }
        var audio = samples
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: DictationSegmenter.sampleRate)
        audio.append(contentsOf: repeatElement(0, count: max(DictationSegmenter.sampleRate / 4, minimum - audio.count)))
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await asr.transcribe(audio, decoderState: &state)
        let recognized = clock.now
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let boosting, let timings = result.tokenTimings, !timings.isEmpty, !text.isEmpty,
           let output = await boosting.rescore(text: text, tokenTimings: timings, audioSamples: audio),
           output.wasModified {
            text = DictationText.repairBoost(original: text, boosted: output.text, terms: termKeys)
        }
        let done = clock.now
        return Segment(
            text: text,
            raw: result.text,
            asrMilliseconds: (recognized - start) / .milliseconds(1),
            boostMilliseconds: (done - recognized) / .milliseconds(1)
        )
    }

    func release() async {
        generation += 1
        loading?.cancel()
        loading = nil
        await asr?.cleanup()
        asr = nil
        ctcModels = nil
        boosting = nil
        boostingSignature = nil
    }
}

/// The transcript of one dictation from the final-pass model.
struct DictationTranscript: Sendable {
    let text: String
    let raw: String
    let segments: Int
    let audioSeconds: Double
    let tailASRMilliseconds: Double
    let tailBoostMilliseconds: Double
    let waitMilliseconds: Double
}

/// One recording: resamples microphone audio, cuts it at pauses and
/// transcribes each finished segment in order while recording continues.
actor DictationSession {
    private let recognizer: DictationRecognizer
    private var segmenter = DictationSegmenter()
    private let converter = AudioConverter()
    private var chain: Task<Void, Never>?
    private var results: [DictationRecognizer.Segment?] = []
    private var samples = 0
    private var cancelled = false

    init(recognizer: DictationRecognizer = .shared) {
        self.recognizer = recognizer
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let resampled = try? converter.resampleBuffer(buffer) else { return }
        append(samples: resampled)
    }

    func append(samples resampled: [Float]) {
        samples += resampled.count
        for segment in segmenter.append(resampled) { enqueue(segment) }
    }

    private func enqueue(_ audio: [Float]) {
        guard !cancelled else { return }
        let index = results.count
        results.append(nil)
        let previous = chain
        let recognizer = recognizer
        chain = Task {
            await previous?.value
            guard await recognizer.waitUntilUsable() else { return }
            let segment = try? await recognizer.transcribe(audio)
            self.store(segment, at: index)
        }
    }

    private func store(_ segment: DictationRecognizer.Segment?, at index: Int) {
        guard !cancelled, results.indices.contains(index) else { return }
        results[index] = segment
    }

    /// Transcribes the tail and joins every segment, or nil when the model
    /// was not ready or any segment failed (the caller falls back to EOU).
    func finish() async -> DictationTranscript? {
        let clock = ContinuousClock()
        let start = clock.now
        guard !cancelled else { return nil }
        if let tail = segmenter.flush() { enqueue(tail) }
        await chain?.value
        guard !results.isEmpty, results.allSatisfy({ $0 != nil }) else { return nil }
        let segments = results.compactMap { $0 }
        let tail = segments.last
        return DictationTranscript(
            text: DictationText.joinSegments(segments.map(\.text)),
            raw: DictationText.joinSegments(segments.map(\.raw)),
            segments: segments.count,
            audioSeconds: Double(samples) / Double(DictationSegmenter.sampleRate),
            tailASRMilliseconds: tail?.asrMilliseconds ?? 0,
            tailBoostMilliseconds: tail?.boostMilliseconds ?? 0,
            waitMilliseconds: (clock.now - start) / .milliseconds(1)
        )
    }

    /// Waits for segments already cut to finish (used by the speed test).
    func settle() async {
        await chain?.value
    }

    func cancel() {
        cancelled = true
        chain?.cancel()
        chain = nil
        results = []
    }
}

/// Whether a one-time model download may start without asking (not on
/// cellular or Low Data Mode).
enum DictationNetwork {
    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "hermes.dictation.network"))
        return monitor
    }()

    static func start() { _ = monitor }

    static var isUnmetered: Bool {
        let path = monitor.currentPath
        return path.status == .satisfied && !path.isExpensive && !path.isConstrained
    }
}
