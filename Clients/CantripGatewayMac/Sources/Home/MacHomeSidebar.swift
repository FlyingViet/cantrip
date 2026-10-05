import SwiftUI

/// Pip, the connection, and Home's sections (Chat, Tasks, Artifacts).
struct MacHomeSidebar: View {
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var navigation: MacHomeNavigation
    let customizeMascot: () -> Void
    @AppStorage(CantripMascotOutfit.storageKey) private var outfit: CantripMascotOutfit = .starryPlush
    @AppStorage(CantripMascotName.storageKey) private var mascotName = ""

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(CantripHomeSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .badge(badge(for: section))
                        .tag(section)
                        .accessibilityIdentifier("home.section.\(section.rawValue)")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var selection: Binding<CantripHomeSection?> {
        Binding(get: { navigation.section }, set: { if let section = $0 { navigation.section = section } })
    }

    private var header: some View {
        VStack(spacing: 6) {
            Button(action: customizeMascot) {
                CantripMascotView(mood: mood, outfit: outfit, size: 88)
                    .frame(width: 96, height: 96)
            }
            .buttonStyle(.plain)
            .help("Customize \(CantripMascotName.display(mascotName))")
            .accessibilityLabel(CantripMascotName.display(mascotName))
            .accessibilityValue(mood.accessibilityStatus ?? mood.title)
            .accessibilityHint("Customizes the mascot")
            Text(CantripMascotName.display(mascotName))
                .font(.title3.weight(.semibold))
            Text("Cantrip Home")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            ChatConnectionIndicator(
                host: remote.endpointHost, isConnected: remote.isConnected,
                statusOverride: remote.connectionLabel
            )
            .frame(height: 28)
            if !remote.isConfigured {
                SettingsLink {
                    Label("Connect to Cantrip…", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func badge(for section: CantripHomeSection) -> Int {
        switch section {
        case .chat: remote.selectedSession?.isCantripHome == true
            ? remote.selectedSession?.pendingInputCount ?? 0 : 0
        case .tasks: remote.homeTasks.filter { $0.state == "running" }.count
        case .artifacts: 0
        }
    }

    /// Same mood rules as the iOS Home header.
    private var mood: CantripMascotMood {
        .resolve(
            isConnected: remote.isConnected,
            isWorking: remote.selectedSession?.isStreaming == true,
            activity: .current(
                status: remote.selectedSession?.status,
                transcript: remote.selectedSession?.transcript ?? []
            ),
            isListening: voice.isListening,
            isSpeaking: voice.isSpeaking,
            needsInput: (remote.selectedSession?.pendingInputCount ?? 0) > 0,
            hasProblem: remote.errorMessage != nil
                || remote.selectedSession?.transcript.last?.role == "error"
        )
    }
}
