import SwiftUI
import UIKit
import XCTest
@testable import Hermes

@MainActor
final class ChatMicrophoneTests: XCTestCase {
    func testTapAndHoldDispatchExclusiveActionsWhileIdleOrListening() {
        for listening in [false, true] {
            var taps = 0
            var holds = 0
            let button = ChatMicrophoneButton(
                isListening: listening, isEnabled: true,
                onTap: { taps += 1 }, onContinuousVoice: { holds += 1 }
            )
            button.handleGesture(.first(true))
            XCTAssertEqual(holds, 1)
            XCTAssertEqual(taps, 0, "Entering voice mode must not toggle/finalize dictation")
            button.handleGesture(.second(()))
            XCTAssertEqual(taps, 1)
            XCTAssertEqual(holds, 1)
            button.handleGesture(.first(false))
            XCTAssertEqual(taps, 1)
            XCTAssertEqual(holds, 1, "An unsuccessful hold must not open voice mode")
        }
    }

    func testDisabledMicrophoneBlocksGesturesAndAccessibilityActions() {
        let button = ChatMicrophoneButton(
            isListening: false, isEnabled: false,
            onTap: { XCTFail("Disabled dictation") },
            onContinuousVoice: { XCTFail("Disabled continuous voice") }
        )
        button.handleGesture(.first(true))
        button.handleGesture(.second(()))
        button.tap()
        button.continuousVoice()
    }

    func testAccessibilityAndKeyboardActionsMatchTouchActions() {
        var taps = 0
        var holds = 0
        let button = ChatMicrophoneButton(
            isListening: false, isEnabled: true,
            onTap: { taps += 1 }, onContinuousVoice: { holds += 1 }
        )
        button.tap()
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(holds, 0)
        button.continuousVoice()
        XCTAssertEqual(taps, 1)
        XCTAssertEqual(holds, 1)
    }

    func testMicrophoneRetainsCompactTapTargetAtAllTextSizes() {
        for size: DynamicTypeSize in [.large, .accessibility5] {
            for listening in [false, true] {
                let button = ChatMicrophoneButton(
                    isListening: listening, isEnabled: true,
                    onTap: {}, onContinuousVoice: {}
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
