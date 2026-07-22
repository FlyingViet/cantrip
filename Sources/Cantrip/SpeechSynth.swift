import AVFoundation
import Foundation

/// Speaks assistant replies aloud (voice mode). Posts `didFinish` when an
/// utterance completes so the UI can resume listening.
@MainActor
final class SpeechSynth: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechSynth()
    nonisolated static let didFinish = Notification.Name("SpeechSynthDidFinish")

    private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let clean = Self.stripMarkdown(text)
        guard !clean.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: String(clean.prefix(1500)))
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                      didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.didFinish, object: nil)
        }
    }

    /// Markdown reads terribly aloud; strip structure, skip code blocks.
    static func stripMarkdown(_ text: String) -> String {
        var out: [String] = []
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }
            if inCode || trimmed.hasPrefix("|") { continue }
            var clean = trimmed
            for token in ["**", "*", "`", "#", "> "] {
                clean = clean.replacingOccurrences(of: token, with: "")
            }
            if clean.hasPrefix("- ") { clean = String(clean.dropFirst(2)) }
            if !clean.isEmpty { out.append(clean) }
        }
        return out.joined(separator: ". ")
    }
}
