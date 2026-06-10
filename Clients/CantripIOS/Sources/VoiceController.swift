import Foundation
import Speech
import AVFoundation
import Combine

/// On-device speech: `SFSpeechRecognizer` for transcription + `AVSpeechSynthesizer`
/// for replies. Drives a hands-free loop — listen → (silence) → hand the final
/// transcript to the caller → speak the reply → listen again — with push-to-talk
/// as the manual fallback. No audio leaves the device.
@MainActor
final class VoiceController: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var authorized = false
    @Published var handsFree = false
    @Published var partial = ""

    /// Called with the finalized utterance when a listening turn ends.
    var onFinalTranscript: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    private var silenceTimer: Timer?
    /// How long a pause must last before the utterance is treated as finished
    /// (and sent). Read live from UserDefaults so the Settings slider applies
    /// immediately; default is generous so catching your breath / thinking
    /// mid-sentence doesn't fire the prompt early.
    private var silenceSeconds: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "hermes.voicePause")
        return v > 0 ? v : 2.5
    }

    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        synth.delegate = self
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
                self.resumeIfHandsFree()
            }
            .store(in: &cancellables)
    }

    func requestAuth() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            AVAudioApplication.requestRecordPermission { mic in
                Task { @MainActor in self?.authorized = (status == .authorized && mic) }
            }
        }
    }

    // MARK: Listening

    func toggleListening() { isListening ? stopListening(finalize: true) : startListening() }

    func startListening() {
        guard authorized, !isListening, !isSpeaking, let recognizer, recognizer.isAvailable else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
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
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                Task { @MainActor in
                    if let result {
                        self.partial = result.bestTranscription.formattedString
                        self.bumpSilenceTimer()
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        self.stopListening(finalize: error == nil)
                    }
                }
            }
        } catch {
            stopListening(finalize: false)
        }
    }

    func stopListening(finalize: Bool) {
        silenceTimer?.invalidate(); silenceTimer = nil
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        isListening = false
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        if finalize, !text.isEmpty { onFinalTranscript?(text) }
    }

    /// Reset the "user stopped talking" timer on every new partial; when it fires,
    /// the utterance is complete.
    private func bumpSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopListening(finalize: true) }
        }
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
        if QwenVoiceEngine.routeActive { QwenVoiceEngine.shared.beginReply() }
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
        if pendingUtterances == 0 { isSpeaking = false; resumeIfHandsFree() }
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
        synth.stopSpeaking(at: .immediate)
        pendingUtterances = 0
        replyStreamDone = true
        isSpeaking = false
    }

    private func prepareForSpeech() {
        if isListening { stopListening(finalize: false) }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
    }

    /// Speak a short sample with a given voice (used by the Settings preview).
    func preview(voiceId: String) {
        if isListening { stopListening(finalize: false) }
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
}

extension VoiceController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            pendingUtterances = max(0, pendingUtterances - 1)
            // Only resume listening once the queue is empty AND the reply has
            // fully streamed — otherwise we'd cut off later queued chunks.
            if pendingUtterances == 0, replyStreamDone {
                isSpeaking = false
                resumeIfHandsFree()
            }
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in pendingUtterances = max(0, pendingUtterances - 1) }
    }
}
