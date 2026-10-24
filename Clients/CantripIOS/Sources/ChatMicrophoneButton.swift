import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Touch rules for the composer mic: recording starts on touch-down; hold and
/// release to finish (push-to-talk), or tap to start and tap again to finish;
/// a quick double-tap opens hands-free voice mode.
struct MicrophoneGesture {
    enum Action: Equatable { case none, start, finish, continuousVoice }

    static let holdThreshold: TimeInterval = 0.35
    static let doubleTapWindow: TimeInterval = 0.35

    private var pressStart: Date?
    private var startedByPress = false
    private var finishOnRelease = false
    private(set) var latched = false
    private var latchedAt: Date?

    mutating func touchDown(at now: Date, isActive: Bool) -> Action {
        pressStart = now
        startedByPress = false
        finishOnRelease = false
        if latched, let latchedAt, now.timeIntervalSince(latchedAt) <= Self.doubleTapWindow {
            reset()
            return .continuousVoice
        }
        if isActive {
            finishOnRelease = true
            return .none
        }
        reset()
        startedByPress = true
        return .start
    }

    mutating func touchUp(at now: Date) -> Action {
        guard let pressStart else { return .none }
        self.pressStart = nil
        if finishOnRelease {
            finishOnRelease = false
            reset()
            return .finish
        }
        guard startedByPress else { return .none }
        startedByPress = false
        if now.timeIntervalSince(pressStart) >= Self.holdThreshold { return .finish }
        latched = true
        latchedAt = now
        return .none
    }

    /// Listening ended some other way (timeout, error, interruption).
    mutating func reset() {
        latched = false
        latchedAt = nil
    }
}

struct ChatMicrophoneButton: View {
    let isListening: Bool
    let isEnabled: Bool
    let onStart: () -> Void
    let onFinish: () -> Void
    let onContinuousVoice: () -> Void

    @State private var gesture = MicrophoneGesture()
    @State private var pressed = false

    var body: some View {
        Image(systemName: isListening ? "mic.fill" : "mic")
            .font(.system(size: 24))
            .foregroundStyle(isListening ? Color.red : Color.accentColor)
            .frame(width: 44, height: 44)
            .scaleEffect(pressed && isListening ? 1.12 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed && isListening)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        perform(gesture.touchDown(at: Date(), isActive: isListening))
                    }
                    .onEnded { _ in
                        pressed = false
                        perform(gesture.touchUp(at: Date()))
                    }
            )
            .onChange(of: isListening) { _, listening in
                if !listening, !pressed { gesture.reset() }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .disabled(!isEnabled)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isListening ? "Finish dictation" : "Dictate")
            .accessibilityHint("Hold to talk and release to finish, or tap to start and tap again to finish. Double-tap for hands-free voice mode.")
            .accessibilityAction { tap() }
            .accessibilityAction(named: Text("Continuous voice mode"), continuousVoice)
            .accessibilityIdentifier("chat.microphone")
    }

    func perform(_ action: MicrophoneGesture.Action) {
        guard isEnabled else { return }
        switch action {
        case .none:
            return
        case .start:
            feedback()
            onStart()
        case .finish:
            feedback()
            onFinish()
        case .continuousVoice:
            onContinuousVoice()
        }
    }

    /// Accessibility and keyboard activation: toggles dictation.
    func tap() {
        guard isEnabled else { return }
        isListening ? onFinish() : onStart()
    }

    func continuousVoice() {
        guard isEnabled else { return }
        onContinuousVoice()
    }

    private func feedback() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
