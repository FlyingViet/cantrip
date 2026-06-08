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

    func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { resumeIfHandsFree(); return }
        if isListening { stopListening(finalize: false) }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
        isSpeaking = true
        let utt = AVSpeechUtterance(string: clean)
        utt.voice = AVSpeechSynthesisVoice(language: "en-US")
        utt.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utt)
    }

    func stopSpeaking() {
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func resumeIfHandsFree() {
        if handsFree { startListening() }
    }
}

extension VoiceController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            resumeIfHandsFree()
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = false }
    }
}
