import Foundation
import Speech
import AVFoundation

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
    private let silenceSeconds: TimeInterval = 1.6

    override init() {
        super.init()
        synth.delegate = self
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
    func beginReply() { replyStreamDone = false }

    /// Speak the next chunk of a streamed reply (queued behind any in-flight chunk).
    func enqueue(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
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
        if pendingUtterances == 0 { isSpeaking = false; resumeIfHandsFree() }
    }

    /// One-shot speak of a complete string (used outside the streaming path).
    func speak(_ text: String) {
        replyStreamDone = true
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { resumeIfHandsFree(); return }
        enqueue(clean)
    }

    /// Stop all speech immediately and clear the queue (used by barge-in).
    func stopSpeaking() {
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
