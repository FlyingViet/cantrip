import Foundation
import Speech
import AVFoundation
import Combine
import FluidAudio
#if os(iOS)
import UIKit
#endif

/// One finished composer dictation: the cleaned transcript at once, then the
/// Apple Intelligence cleanup when it passes the guardrails.
struct DictationOutcome: Equatable {
    let id: UUID
    var text: String
    var polished: String?
}

/// Fully on-device voice loop. Parakeet EOU is the primary transcription engine;
/// Apple Speech remains available as a fallback. Replies use Qwen or the selected
/// system voice. Microphone audio never leaves the device.
@MainActor
final class VoiceController: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var authorized = false
    @Published private(set) var isPreparingRecognition = false
    @Published private(set) var recognitionError: String?
    @Published private(set) var recognitionStatusText: String?
    @Published var handsFree = false
    @Published var partial = ""
    /// Composer dictation is push-to-talk: no end-of-speech timeout, and the
    /// text goes into the composer instead of being sent.
    enum ListeningMode { case conversation, dictation }
    @Published private(set) var listeningMode = ListeningMode.conversation
    @Published private(set) var isFinishing = false
    @Published private(set) var dictation: DictationOutcome?

    /// Called with the finalized utterance when a listening turn ends.
    var onFinalTranscript: ((String) -> Void)?
    /// Tab title and recent messages for the cleanup model.
    var polishContext: (() -> DictationPolishContext)?

    private lazy var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var microphoneAuthorized = false
    private var appleSpeechAuthorized = false
    private var audioEngine: AVAudioEngine?
    private var engine: AVAudioEngine {
        if let audioEngine { return audioEngine }
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        return audioEngine
    }
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var speechSynthesizer: AVSpeechSynthesizer?
    private var synth: AVSpeechSynthesizer {
        if let speechSynthesizer { return speechSynthesizer }
        let s = AVSpeechSynthesizer()
        s.delegate = self
        speechSynthesizer = s
        return s
    }
    private var ownsAudioSession = false
    var hasInitializedAudioResources: Bool {
        audioEngine != nil || speechSynthesizer != nil || ownsAudioSession
    }
    private var silenceTimer: Timer?
    private var maximumListenTimer: Timer?
    private var recognitionGeneration = UUID()
    private var activeInputEngine: SpeechInputEngine?
    private var parakeetContinuation: AsyncStream<AudioChunk>.Continuation?
    private var parakeetProcessingTask: Task<Void, Never>?
    private var parakeetStartTask: Task<Void, Never>?
    private var dictationSession: DictationSession?
    /// How long a pause must last before the utterance is treated as finished
    /// (and sent). Read live from UserDefaults so the Settings slider applies
    /// immediately; default is generous so catching your breath / thinking
    /// mid-sentence doesn't fire the prompt early.
    private var silenceSeconds: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "hermes.voicePause")
        return v > 0 ? v : 2.5
    }

    private var cancellables = Set<AnyCancellable>()

    private struct AudioChunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    override init() {
        super.init()
        DictationNetwork.start()
        // The Qwen engine's "everything spoken" moment — same hands-free resume
        // as the AVSpeech delegate's queue-drained path below. This must be an
        // OBSERVATION of the singleton, not a callback handed to it: ChatView's
        // init eagerly builds throwaway VoiceControllers (StateObject wrappedValue
        // on every parent re-render), and a callback installed by the latest
        // throwaway dies with it — stranding the live controller's isSpeaking at
        // true ("Hermes is speaking" forever). Each instance subscribing
        // independently is immune to that churn.
        QwenVoiceEngine.shared.$speaking
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] engineSpeaking in
                guard let self, !engineSpeaking, self.isSpeaking else { return }
                self.isSpeaking = false
                self.deactivateAudioSession()
                self.resumeIfHandsFree()
            }
            .store(in: &cancellables)

        ParakeetSpeechEngine.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, self.isPreparingRecognition else { return }
                switch state {
                case .preparing(let progress, let phase):
                    self.recognitionStatusText = "\(phase) · \(Int(progress * 100))%"
                case .ready:
                    self.recognitionStatusText = "Starting Parakeet…"
                default:
                    break
                }
            }
            .store(in: &cancellables)

        #if os(iOS)
        NotificationCenter.default.publisher(
            for: AVAudioSession.interruptionNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard self?.isListening == true else { return }
            self?.stopListening(finalize: false)
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: AVAudioSession.routeChangeNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] notification in
            guard self?.isListening == true else { return }
            guard let rawReason = notification.userInfo?[
                AVAudioSessionRouteChangeReasonKey
            ] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
            else {
                return
            }
            switch reason {
            case .oldDeviceUnavailable, .noSuitableRouteForCategory:
                self?.recognitionError = "The microphone route changed. Tap the mic to continue."
                self?.stopListening(finalize: false)
            default:
                // Activating .playAndRecord emits category/override changes.
                // Those are expected and must not tear down our own input tap.
                break
            }
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard self?.isListening != true else { return }
            Task { await DictationRecognizer.shared.release() }
        }
        .store(in: &cancellables)
        #endif
    }

    func requestAuth() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            AVAudioApplication.requestRecordPermission { mic in
                Task { @MainActor in
                    self?.appleSpeechAuthorized = status == .authorized
                    self?.microphoneAuthorized = mic
                    self?.refreshAuthorization()
                }
            }
        }
    }

    // MARK: Listening

    func toggleListening() { isListening ? stopListening(finalize: true) : startListening() }

    /// Push-to-talk composer dictation (hold, or tap to start and tap to finish).
    func startDictation() {
        if isSpeaking { stopSpeaking() }
        startListening(mode: .dictation)
    }

    func startListening(mode: ListeningMode = .conversation) {
        refreshAuthorization()
        guard authorized, !isListening, !isSpeaking, !isPreparingRecognition else {
            return
        }
        recognitionError = nil
        recognitionStatusText = nil
        listeningMode = handsFree ? .conversation : mode
        let generation = UUID()
        recognitionGeneration = generation
        switch selectedInputEngine {
        case .apple:
            startAppleListening(generation: generation)
        case .parakeet:
            startParakeetListening(generation: generation)
        }
    }

    private func startAppleListening(generation: UUID) {
        guard appleSpeechAuthorized, let recognizer, recognizer.isAvailable else {
            recognitionError = "Apple Speech recognition is unavailable."
            return
        }
        do {
            try prepareListeningAudioSession()

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = true
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            engine.prepare()
            try engine.start()

            partial = ""
            isListening = true
            activeInputEngine = .apple
            armMaximumListenTimer()
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                Task { @MainActor in
                    guard self.recognitionGeneration == generation else { return }
                    if let result {
                        // The recognizer streams duplicate (often empty) partials
                        // while waiting for speech — publishing each one is a
                        // re-render storm (visible flicker) and bumping the
                        // silence timer on them could time the mic out before a
                        // word was said. Only react to actual transcript changes.
                        let text = result.bestTranscription.formattedString
                        if text != self.partial {
                            self.partial = text
                            if self.listeningMode == .conversation { self.bumpSilenceTimer() }
                        }
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        self.stopListening(finalize: error == nil)
                    }
                }
            }
        } catch {
            recognitionError = error.localizedDescription
            stopListening(finalize: false)
        }
    }

    private func startParakeetListening(generation: UUID) {
        if QwenVoiceEngine.shared.hasInFlightSynthesis,
           appleSpeechAuthorized,
           recognizer?.supportsOnDeviceRecognition == true {
            QwenVoiceEngine.shared.stop()
            Task {
                await QwenVoiceEngine.shared.releaseMemory()
            }
            recognitionError = "Using on-device Apple Speech while the neural voice finishes stopping."
            startAppleListening(generation: generation)
            return
        }
        isPreparingRecognition = true
        recognitionStatusText = "Preparing Parakeet…"
        let session = DictationSession()
        dictationSession = session
        DictationPolisher.prewarm()
        parakeetStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                await QwenVoiceEngine.shared.releaseMemory()
                Self.prepareFinalPass()
                let speechEngine = ParakeetSpeechEngine.shared
                try await speechEngine.startSession(
                    silenceSeconds: silenceSeconds,
                    onPartial: { [weak self] text in
                        Task { @MainActor in
                            guard let self,
                                  self.recognitionGeneration == generation else {
                                return
                            }
                            self.acceptPartial(text)
                        }
                    },
                    onEndOfUtterance: { [weak self] _ in
                        Task { @MainActor in
                            guard let self,
                                  self.recognitionGeneration == generation,
                                  self.isListening,
                                  self.listeningMode == .conversation else {
                                return
                            }
                            self.stopListening(finalize: true)
                        }
                    }
                )
                guard recognitionGeneration == generation else {
                    await speechEngine.cancelSession()
                    isPreparingRecognition = false
                    return
                }

                let streamPair = AsyncStream.makeStream(
                    of: AudioChunk.self,
                    bufferingPolicy: .bufferingNewest(32)
                )
                parakeetContinuation = streamPair.continuation
                parakeetProcessingTask = Task { [weak self] in
                    do {
                        for await chunk in streamPair.stream {
                            try Task.checkCancellation()
                            await session.append(chunk.buffer)
                            try await speechEngine.process(chunk.buffer)
                        }
                    } catch is CancellationError {
                    } catch {
                        await MainActor.run {
                            guard let self,
                                  self.recognitionGeneration == generation else {
                                return
                            }
                            self.recognitionError = error.localizedDescription
                            self.stopListening(finalize: false)
                        }
                    }
                }

                try prepareListeningAudioSession()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    throw VoiceInputError.invalidMicrophoneFormat
                }
                input.removeTap(onBus: 0)
                let continuation = streamPair.continuation
                input.installTap(
                    onBus: 0,
                    bufferSize: 2048,
                    format: format
                ) { buffer, _ in
                    guard let copy = Self.copyPCMBuffer(buffer) else { return }
                    continuation.yield(AudioChunk(buffer: copy))
                }
                engine.prepare()
                try engine.start()

                partial = ""
                isPreparingRecognition = false
                recognitionStatusText = nil
                isListening = true
                activeInputEngine = .parakeet
                armMaximumListenTimer()
            } catch is CancellationError {
                stopAudioInput()
                isPreparingRecognition = false
                recognitionStatusText = nil
            } catch {
                await ParakeetSpeechEngine.shared.cancelSession()
                await session.cancel()
                dictationSession = nil
                stopAudioInput()
                isPreparingRecognition = false
                recognitionStatusText = nil
                if appleSpeechAuthorized,
                   recognizer?.supportsOnDeviceRecognition == true {
                    recognitionError = "Parakeet unavailable; using on-device Apple Speech."
                    startAppleListening(generation: generation)
                } else {
                    recognitionError = "Parakeet could not start: \(error.localizedDescription)"
                }
                refreshAuthorization()
            }
        }
    }

    func stopListening(finalize: Bool) {
        let releasedAt = ContinuousClock.now
        silenceTimer?.invalidate()
        silenceTimer = nil
        maximumListenTimer?.invalidate()
        maximumListenTimer = nil
        recognitionGeneration = UUID()
        parakeetStartTask?.cancel()
        parakeetStartTask = nil
        stopAudioInput()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        isPreparingRecognition = false
        recognitionStatusText = nil

        let capturedPartial = partial.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let inputEngine = activeInputEngine
        activeInputEngine = nil
        let mode = listeningMode
        let session = dictationSession
        dictationSession = nil
        if inputEngine == .parakeet {
            let processingTask = parakeetProcessingTask
            parakeetContinuation?.finish()
            parakeetContinuation = nil
            parakeetProcessingTask = nil
            if finalize {
                isPreparingRecognition = true
                isFinishing = true
                recognitionStatusText = "Transcribing…"
                Task {
                    _ = await processingTask?.result
                    let drained = ContinuousClock.now
                    async let streamed = try? ParakeetSpeechEngine.shared.finish()
                    let transcript = await session?.finish()
                    let streamedText = (await streamed ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if streamedText.isEmpty, transcript == nil, !capturedPartial.isEmpty {
                        recognitionError = nil
                    }
                    deliver(
                        streaming: streamedText.isEmpty ? capturedPartial : streamedText,
                        transcript: transcript,
                        mode: mode,
                        releasedAt: releasedAt,
                        drainedAt: drained
                    )
                }
            } else {
                processingTask?.cancel()
                partial = ""
                Task {
                    await session?.cancel()
                    await ParakeetSpeechEngine.shared.cancelSession()
                }
            }
        } else {
            partial = ""
            Task { await session?.cancel() }
            if finalize, !capturedPartial.isEmpty {
                deliver(
                    streaming: capturedPartial, transcript: nil, mode: mode,
                    releasedAt: releasedAt, drainedAt: releasedAt, engine: "Apple Speech"
                )
            }
        }
    }

    /// Final pass: the model transcript (or the streaming one as a fallback),
    /// deterministic cleanup, then the guarded Apple Intelligence edit pass —
    /// in the background for the composer, within a short budget hands-free.
    private func deliver(
        streaming: String,
        transcript: DictationTranscript?,
        mode: ListeningMode,
        releasedAt: ContinuousClock.Instant,
        drainedAt: ContinuousClock.Instant,
        engine: String? = nil
    ) {
        let cleanupStart = ContinuousClock.now
        let base = transcript?.text ?? streaming
        let store = DictationVocabularyStore.shared
        let text = DictationText.finalize(base, rules: store.rules) {
            TextNormalizer.shared.normalizeSentence($0)
        }
        let done = ContinuousClock.now
        partial = ""
        isPreparingRecognition = false
        isFinishing = false
        recognitionStatusText = nil
        guard !text.isEmpty else { return }
        DictationDiagnostics.shared.record(DictationReport(
            engine: engine ?? (transcript == nil ? "Parakeet EOU (fallback)" : "Parakeet TDT v2"),
            audioSeconds: transcript?.audioSeconds ?? 0,
            segments: transcript?.segments ?? 0,
            releaseToTextMilliseconds: (done - releasedAt) / .milliseconds(1),
            drainMilliseconds: (drainedAt - releasedAt) / .milliseconds(1),
            tailASRMilliseconds: transcript?.tailASRMilliseconds ?? 0,
            tailBoostMilliseconds: transcript?.tailBoostMilliseconds ?? 0,
            cleanupMilliseconds: (done - cleanupStart) / .milliseconds(1),
            streamingText: streaming,
            modelText: transcript?.raw ?? "",
            finalText: text
        ))
        var context = polishContext?() ?? DictationPolishContext()
        context.terms = DictationVocabulary.relevant(store.terms, to: text)
        let polishes = DictationPolisher.shouldPolish(text)
        switch mode {
        case .dictation:
            let outcome = DictationOutcome(id: UUID(), text: text)
            dictation = outcome
            guard polishes else { return }
            Task {
                let result = await DictationPolisher.polish(text, context: context)
                Self.recordPolish(result)
                guard let result, result.verdict == .accepted, dictation?.id == outcome.id else { return }
                dictation?.polished = result.text
            }
        case .conversation:
            guard polishes else {
                onFinalTranscript?(text)
                return
            }
            isFinishing = true
            Task {
                let result = await DictationPolisher.polish(text, context: context, budget: .milliseconds(1200))
                Self.recordPolish(result)
                isFinishing = false
                onFinalTranscript?(result?.verdict == .accepted ? result!.text : text)
            }
        }
    }

    private static func recordPolish(_ result: DictationPolishResult?) {
        DictationDiagnostics.shared.update { report in
            guard let result else {
                report.polishOutcome = "No reply in time"
                return
            }
            report.polishMilliseconds = result.milliseconds
            switch result.verdict {
            case .accepted:
                report.polishOutcome = "Applied \(result.edits.count) edit(s)"
                report.finalText = result.text
            case .rejected(let reason):
                report.polishOutcome = "Kept original: \(reason)"
            }
        }
    }

    /// Loads the final-pass model from disk, or downloads it once on an
    /// unmetered network (Settings can download it explicitly).
    private static func prepareFinalPass() {
        guard DictationRecognizer.modelsDownloaded || DictationNetwork.isUnmetered else { return }
        Task { try? await DictationRecognizer.shared.prepare() }
    }

    /// Reset the "user stopped talking" timer on every new partial; when it fires,
    /// the utterance is complete.
    private func bumpSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopListening(finalize: true) }
        }
    }

    private func acceptPartial(_ text: String) {
        guard text != partial else { return }
        partial = text
        if listeningMode == .conversation { bumpSilenceTimer() }
    }

    private func armMaximumListenTimer() {
        maximumListenTimer?.invalidate()
        maximumListenTimer = Timer.scheduledTimer(
            withTimeInterval: listeningMode == .dictation ? 300 : 120,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopListening(finalize: true)
            }
        }
    }

    private func prepareListeningAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.duckOthers, .defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        ownsAudioSession = true
    }

    private var selectedInputEngine: SpeechInputEngine {
        let raw = UserDefaults.standard.string(forKey: "hermes.sttEngine")
        return SpeechInputEngine(rawValue: raw ?? "") ?? .parakeet
    }

    private func refreshAuthorization() {
        authorized = microphoneAuthorized
            && (selectedInputEngine == .parakeet || appleSpeechAuthorized)
    }

    nonisolated private static func copyPCMBuffer(
        _ source: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard source.format.commonFormat == .pcmFormatFloat32,
              !source.format.isInterleaved,
              let sourceChannels = source.floatChannelData,
              let copy = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: source.frameLength
              ),
              let destinationChannels = copy.floatChannelData else {
            return nil
        }
        copy.frameLength = source.frameLength
        let byteCount = Int(source.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(source.format.channelCount) {
            memcpy(
                destinationChannels[channel],
                sourceChannels[channel],
                byteCount
            )
        }
        return copy
    }

    // MARK: Speaking

    // Streamed replies are spoken chunk-by-chunk (a sentence/paragraph as soon
    // as it arrives) by enqueuing utterances — AVSpeechSynthesizer plays a queue
    // in order. `pendingUtterances` is the queue depth so hands-free only resumes
    // listening once the WHOLE reply is spoken (not after each chunk), and
    // `replyStreamDone` bridges the gap between chunks while text is still streaming.
    private var pendingUtterances = 0
    private var replyStreamDone = true

    /// Begin a streamed spoken reply: chunks arrive via `enqueue`, end with `finishReply`.
    func beginReply() {
        replyStreamDone = false
        if QwenVoiceEngine.routeActive {
            Task {
                await ParakeetSpeechEngine.shared.releaseMemory()
                await DictationRecognizer.shared.release()
            }
            QwenVoiceEngine.shared.beginReply()
        }
    }

    /// Speak the next chunk of a streamed reply (queued behind any in-flight chunk).
    func enqueue(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if QwenVoiceEngine.routeActive {
            if !isSpeaking { prepareForSpeech() }
            isSpeaking = true
            QwenVoiceEngine.shared.enqueue(clean)
            return
        }
        if pendingUtterances == 0 { prepareForSpeech() }
        pendingUtterances += 1
        isSpeaking = true
        let utt = AVSpeechUtterance(string: clean)
        utt.voice = Self.selectedVoice()
        utt.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utt)
    }

    /// Mark the streamed reply finished; resume listening once the queue drains.
    func finishReply() {
        replyStreamDone = true
        if QwenVoiceEngine.routeActive {
            if !isSpeaking { resumeIfHandsFree(); return }   // nothing was enqueued
            QwenVoiceEngine.shared.finishReply()             // onIdle drives the resume
            return
        }
        finishSpeechIfIdle()
    }

    /// One-shot speak of a complete string (used outside the streaming path).
    /// Routed through begin/enqueue/finish so both engines behave the same.
    func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { replyStreamDone = true; resumeIfHandsFree(); return }
        beginReply()
        enqueue(clean)
        finishReply()
    }

    /// Stop all speech immediately and clear the queue (used by barge-in).
    func stopSpeaking() {
        QwenVoiceEngine.shared.stop()
        speechSynthesizer?.stopSpeaking(at: .immediate)
        pendingUtterances = 0
        replyStreamDone = true
        isSpeaking = false
        deactivateAudioSession()
    }

    private func prepareForSpeech() {
        if isListening { stopListening(finalize: false) }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            ownsAudioSession = true
        } catch {}
    }

    /// Speak a short sample with a given voice (used by the Settings preview).
    func preview(voiceId: String) {
        if isListening { stopListening(finalize: false) }
        prepareForSpeech()
        let utt = AVSpeechUtterance(string: "Hey, this is how I'll sound.")
        utt.voice = AVSpeechSynthesisVoice(identifier: voiceId) ?? AVSpeechSynthesisVoice(language: "en-US")
        isSpeaking = true
        synth.speak(utt)
    }

    /// English-language voices installed on the device, best quality first.
    static func voices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { a, b in
                a.quality.rawValue != b.quality.rawValue ? a.quality.rawValue > b.quality.rawValue : a.name < b.name
            }
    }

    /// The user's chosen voice (UserDefaults `hermes.voiceId`), else the highest-
    /// quality installed English voice (a downloaded Premium/Enhanced voice sounds
    /// close to Siri — far less robotic than the basic default).
    static func selectedVoice() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: "hermes.voiceId"), !id.isEmpty,
           let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return voices().first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func resumeIfHandsFree() {
        if handsFree { startListening() }
    }

    private func finishSpeechIfIdle() {
        guard pendingUtterances == 0, replyStreamDone else { return }
        isSpeaking = false
        deactivateAudioSession()
        resumeIfHandsFree()
    }

    private func deactivateAudioSession() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    private func stopAudioInput() {
        if let audioEngine {
            if audioEngine.isRunning { audioEngine.stop() }
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        deactivateAudioSession()
    }
}

private enum VoiceInputError: LocalizedError {
    case invalidMicrophoneFormat

    var errorDescription: String? {
        "The microphone returned an invalid audio format."
    }
}

extension VoiceController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            pendingUtterances = max(0, pendingUtterances - 1)
            // Only resume listening once the queue is empty AND the reply has
            // fully streamed — otherwise we'd cut off later queued chunks.
            finishSpeechIfIdle()
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            pendingUtterances = max(0, pendingUtterances - 1)
            finishSpeechIfIdle()
        }
    }
}
