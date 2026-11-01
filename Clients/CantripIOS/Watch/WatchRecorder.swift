import AVFoundation
import Foundation

/// Records one request as AAC (m4a), mono 16 kHz, stopping on its own after a pause.
@MainActor
final class WatchRecorder {
    enum Outcome {
        case clip(URL)
        case noSpeech
        case cancelled
    }

    /// 0...1, for the listening animation.
    var onLevel: ((Float) -> Void)?

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Outcome, Never>?

    var isRecording: Bool { recorder != nil }

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Records until a pause after speech, the 60 s limit, `finish()`, or `cancel()`.
    func record() async throws -> Outcome {
        guard recorder == nil else { throw CantripWatchError.recordingFailed }
        guard await Self.requestPermission() else { throw CantripWatchError.microphoneDenied }

        let recorder: AVAudioRecorder
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            recorder = try Self.makeRecorder()
        } catch {
            deactivateSession()
            throw CantripWatchError.recordingFailed
        }
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            try? FileManager.default.removeItem(at: recorder.url)
            deactivateSession()
            throw CantripWatchError.recordingFailed
        }
        self.recorder = recorder

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            meterTask = Task { [weak self] in await self?.meter() }
        }
    }

    private static func makeRecorder() throws -> AVAudioRecorder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-\(UUID().uuidString).m4a")
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        if let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.prepareToRecord() {
            return recorder
        }
        // Some encoders reject the bit rate at 16 kHz; their default is still small.
        settings.removeValue(forKey: AVEncoderBitRateKey)
        return try AVAudioRecorder(url: url, settings: settings)
    }

    /// Stops and sends what was heard.
    func finish() { stop(sending: true) }

    /// Stops and throws the recording away.
    func cancel() { stop(sending: false) }

    private func meter() async {
        var detector = CantripSilenceDetector()
        let started = Date()
        while !Task.isCancelled, let recorder {
            try? await Task.sleep(for: .milliseconds(100))
            guard self.recorder === recorder else { return }
            recorder.updateMeters()
            let level = recorder.averagePower(forChannel: 0)
            onLevel?(max(0, min(1, (level + 50) / 50)))
            switch detector.add(level: level, at: Date().timeIntervalSince(started)) {
            case .keepRecording:
                continue
            case .speechEnded, .maxDuration:
                stop(sending: true)
            case .noSpeech:
                stop(sending: false, noSpeech: true)
            }
            return
        }
    }

    private func stop(sending: Bool, noSpeech: Bool = false) {
        meterTask?.cancel()
        meterTask = nil
        guard let recorder else { return }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        onLevel?(0)
        deactivateSession()
        let url = recorder.url
        let outcome: Outcome
        if sending, duration >= 0.5 {
            outcome = .clip(url)
        } else {
            try? FileManager.default.removeItem(at: url)
            outcome = noSpeech || sending ? .noSpeech : .cancelled
        }
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
