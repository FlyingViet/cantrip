import FluidAudio
import XCTest
@testable import Hermes

/// Real FluidAudio inverse text normalization behind the guard, and the
/// pause segmenter. Made-up names only: this repository is public.
final class DictationPipelineTests: XCTestCase {
    private func normalize(_ text: String) -> String {
        DictationText.guardedNumbers(text) { TextNormalizer.shared.normalizeSentence($0) }
    }

    func testInverseTextNormalizationWritesQuantitiesButKeepsWords() throws {
        try XCTSkipUnless(TextNormalizer.shared.isNativeAvailable, "NeMo text processing is not linked")
        XCTAssertEqual(
            normalize("The Zephyrly offer expires on November fifteenth, twenty twenty six."),
            "The Zephyrly offer expires on November 15, 2026."
        )
        XCTAssertEqual(
            normalize("Send Odalys the expense report for three hundred forty dollars."),
            "Send Odalys the expense report for $340."
        )
        XCTAssertEqual(
            normalize("Open a tab for QuillPad and another one for Orbit Lane."),
            "Open a tab for QuillPad and another one for Orbit Lane."
        )
        XCTAssertEqual(
            normalize("First, update the node. Second, restart it."),
            "First, update the node. Second, restart it."
        )
        let screen = normalize("I have a screen with Harbor at nine thirty and a recruiter call at two.")
        XCTAssertTrue(screen.contains("and a recruiter call"), screen)
    }

    func testFinalizeRunsTheWholeDeterministicPipeline() throws {
        try XCTSkipUnless(TextNormalizer.shared.isNativeAvailable, "NeMo text processing is not linked")
        let terms = DictationVocabulary.assemble([
            DictationTerm(text: "QuillPad", kind: .project, weight: 1),
            DictationTerm(text: "Zephyrly", kind: .project, weight: 1),
        ], lexicon: FakeLexicon())
        let text = DictationText.finalize(
            "um so the quill pad build failed around 4.15 and zephyr ly owes us twelve hundred dollars",
            rules: DictationVocabulary.rules(terms, corrections: [])
        ) { TextNormalizer.shared.normalizeSentence($0) }
        XCTAssertEqual(text, "So the QuillPad build failed around 4:15 and Zephyrly owes us $1,200.")
    }

    func testSegmenterCutsAtPausesAndCapsLongSegments() {
        func tone(_ seconds: Double) -> [Float] {
            (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.09)) * 0.2 }
        }
        func silence(_ seconds: Double) -> [Float] {
            (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 1.3)) * 0.0004 }
        }
        var segmenter = DictationSegmenter()
        var segments: [[Float]] = []
        let audio = silence(0.3) + tone(2) + silence(0.7) + tone(1) + silence(0.2) + tone(1.5)
        var offset = 0
        while offset < audio.count {
            let end = min(audio.count, offset + 683)
            segments += segmenter.append(Array(audio[offset..<end]))
            offset = end
        }
        XCTAssertEqual(segments.count, 1, "A long pause after enough speech ends a segment")
        XCTAssertEqual(Double(segments[0].count) / 16_000, 2.52, accuracy: 0.1)
        let tail = segmenter.flush()
        XCTAssertNotNil(tail)
        XCTAssertEqual(Double(tail?.count ?? 0) / 16_000, 3.18, accuracy: 0.1,
                       "A short pause stays inside the tail segment")

        var long = DictationSegmenter()
        let continuous = long.append(tone(13))
        XCTAssertEqual(continuous.count, 1, "Speech without pauses is cut at the maximum length")
        XCTAssertLessThanOrEqual(Double(continuous[0].count) / 16_000, 12.01)

        var quiet = DictationSegmenter()
        XCTAssertTrue(quiet.append(silence(4)).isEmpty)
        XCTAssertNil(quiet.flush(), "Silence alone is never transcribed")
    }
}
