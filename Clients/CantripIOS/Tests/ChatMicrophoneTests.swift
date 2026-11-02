import SwiftUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
final class ChatMicrophoneTests: XCTestCase {
    func testHoldIsPushToTalkAndQuickTapLatches() {
        let start = Date(timeIntervalSince1970: 0)
        var gesture = MicrophoneGesture()
        XCTAssertEqual(gesture.touchDown(at: start, isActive: false), .start)
        XCTAssertEqual(gesture.touchUp(at: start + 0.6), .finish, "Releasing a hold finishes at once")
        XCTAssertFalse(gesture.latched)

        XCTAssertEqual(gesture.touchDown(at: start + 5, isActive: false), .start)
        XCTAssertEqual(gesture.touchUp(at: start + 5.1), .none, "A quick tap keeps dictating hands-off")
        XCTAssertTrue(gesture.latched)
        XCTAssertEqual(gesture.touchDown(at: start + 8, isActive: true), .none)
        XCTAssertEqual(gesture.touchUp(at: start + 8.1), .finish, "The next tap finishes")
        XCTAssertFalse(gesture.latched)
    }

    func testDoubleTapOpensVoiceModeWithoutFinishing() {
        let start = Date(timeIntervalSince1970: 0)
        var gesture = MicrophoneGesture()
        XCTAssertEqual(gesture.touchDown(at: start, isActive: false), .start)
        XCTAssertEqual(gesture.touchUp(at: start + 0.08), .none)
        XCTAssertEqual(gesture.touchDown(at: start + 0.25, isActive: false), .continuousVoice)
        XCTAssertEqual(gesture.touchUp(at: start + 0.32), .none, "The second tap must not finish or restart dictation")
        XCTAssertFalse(gesture.latched)
    }

    func testLatchIsClearedWhenListeningEndsElsewhere() {
        let start = Date(timeIntervalSince1970: 0)
        var gesture = MicrophoneGesture()
        _ = gesture.touchDown(at: start, isActive: false)
        _ = gesture.touchUp(at: start + 0.1)
        gesture.reset()
        XCTAssertEqual(gesture.touchDown(at: start + 0.2, isActive: false), .start,
                       "After a timeout, a tap starts a new dictation instead of opening voice mode")
    }

    func testButtonDispatchesGestureActionsOnlyWhenEnabled() {
        for enabled in [true, false] {
            var starts = 0, finishes = 0, voice = 0
            let button = ChatMicrophoneButton(
                isListening: false, isEnabled: enabled,
                onStart: { starts += 1 }, onFinish: { finishes += 1 }, onContinuousVoice: { voice += 1 }
            )
            button.perform(.start)
            button.perform(.finish)
            button.perform(.continuousVoice)
            button.perform(.none)
            XCTAssertEqual([starts, finishes, voice], enabled ? [1, 1, 1] : [0, 0, 0])
        }
    }

    func testAccessibilityActivationTogglesDictation() {
        for listening in [false, true] {
            var starts = 0, finishes = 0, voice = 0
            let button = ChatMicrophoneButton(
                isListening: listening, isEnabled: true,
                onStart: { starts += 1 }, onFinish: { finishes += 1 }, onContinuousVoice: { voice += 1 }
            )
            button.tap()
            XCTAssertEqual([starts, finishes], listening ? [0, 1] : [1, 0])
            button.continuousVoice()
            XCTAssertEqual(voice, 1)
        }
    }

    func testMicrophoneRetainsCompactTapTargetAtAllTextSizes() {
        for size: DynamicTypeSize in [.large, .accessibility5] {
            for listening in [false, true] {
                let button = ChatMicrophoneButton(
                    isListening: listening, isEnabled: true,
                    onStart: {}, onFinish: {}, onContinuousVoice: {}
                )
                .environment(\.dynamicTypeSize, size)
                let controller = UIHostingController(rootView: button)
                controller.safeAreaRegions = []
                let measured = controller.sizeThatFits(in: CGSize(width: 320, height: 700))
                XCTAssertEqual(measured.width, 44, accuracy: 0.5)
                XCTAssertEqual(measured.height, 44, accuracy: 0.5)
            }
        }
    }

    func testIdleVoiceCleanupDoesNotInitializeAudioResources() {
        let qwen = QwenVoiceEngine()
        XCTAssertFalse(qwen.hasInitializedAudioGraph)
        qwen.stop()
        XCTAssertFalse(qwen.hasInitializedAudioGraph)

        let voice = VoiceController()
        XCTAssertFalse(voice.hasInitializedAudioResources)
        voice.stopListening(finalize: false)
        voice.stopSpeaking()
        XCTAssertFalse(voice.hasInitializedAudioResources)
    }

    func testContinuousVoiceEntryAndDismissalPreserveConversationAndWork() {
        let env = HermesEnv()
        let voice = VoiceController()
        let vm = ChatViewModel(env: env, remote: CantripRemoteModel(), voice: voice)
        vm.turns = [ChatTurn(role: .user, text: "Keep this conversation", executionLane: vm.activeLane)]
        vm.sending = true
        voice.partial = "Unfinished dictation"
        var finalizedTranscripts = 0
        voice.onFinalTranscript = { _ in finalizedTranscripts += 1 }
        defer { vm.sending = false }

        vm.enterVoiceMode()
        XCTAssertTrue(voice.handsFree)
        XCTAssertFalse(voice.isListening, "Do not interrupt ongoing work just by opening voice mode")
        vm.leaveVoiceMode()
        XCTAssertFalse(voice.handsFree)
        XCTAssertFalse(voice.isListening)
        XCTAssertFalse(voice.isPreparingRecognition)
        XCTAssertFalse(voice.isSpeaking)
        XCTAssertTrue(vm.sending, "Closing voice mode must not stop the agent's work")
        XCTAssertEqual(vm.turns.first?.text, "Keep this conversation")
        XCTAssertEqual(finalizedTranscripts, 0, "Closing must not submit unfinished dictation")
    }
}
