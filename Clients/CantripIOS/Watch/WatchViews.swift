import SwiftUI

struct WatchRootView: View {
    @ObservedObject var model: WatchVoiceModel

    var body: some View {
        NavigationStack {
            if model.isSetUp {
                WatchTalkView(model: model)
            } else {
                WatchSetupView(model: model)
            }
        }
    }
}

struct WatchTalkView: View {
    @ObservedObject var model: WatchVoiceModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    WatchMicButton(model: model)
                    WatchStatusText(phase: model.phase)
                    if model.needsSetupAgain {
                        Button("Set Up Again") { model.setUp() }
                            .disabled(model.isSettingUp)
                    }
                    WatchConversation(transcript: model.transcript, reply: model.reply)
                        .id(WatchConversation.scrollID)
                }
                .frame(maxWidth: .infinity)
                // The Stop Speaking button floats over the bottom; the reply's end can scroll above it.
                .padding(.bottom, model.phase == .speaking ? 48 : 0)
            }
            .onChange(of: model.reply != nil) { _, hasReply in
                guard hasReply else { return }
                withAnimation { proxy.scrollTo(WatchConversation.scrollID, anchor: .top) }
            }
        }
        .navigationTitle("Cantrip")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    WatchSettingsView(model: model)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .bottomBar) {
                if model.phase == .speaking {
                    Button(action: model.stopSpeaking) {
                        Label("Stop Speaking", systemImage: "speaker.slash.fill")
                    }
                }
            }
        }
    }
}

struct WatchConversation: View {
    static let scrollID = "conversation"
    let transcript: String?
    let reply: String?

    var body: some View {
        VStack(spacing: 8) {
            if let transcript {
                WatchMessageBlock(title: "You", text: transcript)
            }
            if let reply {
                WatchMessageBlock(title: "Cantrip Home", text: reply)
            }
        }
    }
}

struct WatchMicButton: View {
    @ObservedObject var model: WatchVoiceModel

    private var isListening: Bool { model.phase == .listening }

    var body: some View {
        Button(action: model.micTapped) {
            ZStack {
                Circle()
                    .fill(isListening ? Color.red : Color.cantripAccent)
                if isListening {
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 4)
                        .scaleEffect(1 + CGFloat(model.level) * 0.18)
                        .animation(.easeOut(duration: 0.1), value: model.level)
                }
                if model.phase == .sending {
                    ProgressView()
                } else {
                    Image(systemName: isListening ? "stop.fill" : "mic.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.phase == .sending)
        .accessibilityLabel(isListening ? "Stop and send" : "Talk to Cantrip")
        .accessibilityHint(isListening
            ? "Sends what you said to Cantrip Home."
            : "Records your request for Cantrip Home on your Mac.")
    }
}

struct WatchStatusText: View {
    let phase: WatchVoiceModel.Phase

    var body: some View {
        Text(phase.title)
            .font(phase.isFailure ? .footnote : .headline)
            .foregroundStyle(phase.isFailure ? Color.orange : Color.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(phase.isFailure ? "Error: \(phase.title)" : phase.title)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct WatchMessageBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct WatchSetupView: View {
    @ObservedObject var model: WatchVoiceModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title2)
                    .foregroundStyle(Color.cantripAccent)
                    .accessibilityHidden(true)
                Text("Talk to Cantrip Home")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Your iPhone links this watch to the Mac it's paired with. Keep it nearby, with Cantrip paired to your Mac over Tailscale.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.setUp()
                } label: {
                    if model.isSettingUp {
                        ProgressView()
                            .accessibilityLabel("Setting up")
                    } else {
                        Text("Set up with your iPhone")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.cantripAccent)
                .disabled(model.isSettingUp)
                if let error = model.setupError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .navigationTitle("Cantrip")
    }
}

struct WatchSettingsView: View {
    @ObservedObject var model: WatchVoiceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Toggle("Speak replies", isOn: $model.speakReplies)
                    .tint(.cantripAccent)
            } footer: {
                Text("Replies always show on screen.")
            }
            if let configuration = model.configuration {
                Section("Mac") {
                    Text(configuration.serverName ?? configuration.tailnet.host ?? "Your Mac")
                    Text(configuration.internet == nil ? "Internet route off" : "Internet route on")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    model.setUp()
                } label: {
                    if model.isSettingUp {
                        ProgressView().accessibilityLabel("Setting up")
                    } else {
                        Text("Set Up Again")
                    }
                }
                .disabled(model.isSettingUp)
                if let error = model.setupError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                Button("Forget This Mac", role: .destructive) {
                    model.forget()
                    dismiss()
                }
            } footer: {
                Text("To remove this watch from your Mac, use Cantrip on the Mac.")
            }
        }
        .navigationTitle("Settings")
    }
}
