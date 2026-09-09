import SwiftUI

struct ChatMicrophoneButton: View {
    let isListening: Bool
    let isEnabled: Bool
    let onTap: () -> Void
    let onContinuousVoice: () -> Void

    var body: some View {
        Button(action: tap) {
            Image(systemName: isListening ? "mic.fill" : "mic")
                .font(.system(size: 24))
                .foregroundStyle(isListening ? Color.red : Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .highPriorityGesture(
            // A hold must not also toggle dictation when the finger lifts.
            LongPressGesture(minimumDuration: 0.5)
                .exclusively(before: TapGesture())
                .onEnded(handleGesture)
        )
        .disabled(!isEnabled)
        .accessibilityLabel(isListening ? "Stop listening" : "Start listening")
        .accessibilityHint("Tap for dictation. Touch and hold for continuous voice mode.")
        .accessibilityAction(named: Text("Continuous voice mode"), continuousVoice)
        .accessibilityIdentifier("chat.microphone")
    }

    func handleGesture(_ value: ExclusiveGesture<LongPressGesture, TapGesture>.Value) {
        switch value {
        case .first(true):
            continuousVoice()
        case .second:
            tap()
        case .first(false):
            break
        }
    }

    func tap() {
        guard isEnabled else { return }
        onTap()
    }

    func continuousVoice() {
        guard isEnabled else { return }
        onContinuousVoice()
    }
}
