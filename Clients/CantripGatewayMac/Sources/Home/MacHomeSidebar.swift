import SwiftUI

/// A sidebar row: Home's sections, or one project tab.
enum MacHomeDestination: Hashable {
    case section(CantripHomeSection)
    case tab(String)
}

/// Pip, the connection, Home's sections (Chat, Tasks, Artifacts) and every project tab.
struct MacHomeSidebar: View {
    @ObservedObject var env: HermesEnv
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
                        .tag(MacHomeDestination.section(section))
                        .accessibilityIdentifier("home.section.\(section.rawValue)")
                }
            }
            Section {
                ForEach(remote.sessions) { session in
                    MacHomeTabRow(session: session)
                        .tag(MacHomeDestination.tab(session.id))
                        .contextMenu {
                            CantripTabActions(
                                model: remote, session: session,
                                onRename: { navigation.renamingTab = session },
                                onClose: { navigation.closeTab(session.id) }
                            )
                        }
                }
                .onMove { offsets, destination in
                    guard let move = CantripTabReorder.move(
                        remote.sessions, fromOffsets: offsets, toOffset: destination
                    ) else { return }
                    Task { await remote.moveTab(move.id, relativeTo: move.targetID, after: move.after) }
                }
                if remote.sessions.isEmpty, remote.isConfigured {
                    Text("No tabs yet")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            } header: {
                tabsHeader
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var selection: Binding<MacHomeDestination?> {
        Binding(
            get: {
                if env.executionLane == .cantrip, !remote.isHomeSelected {
                    return remote.selectedSessionID.map { .tab($0) }
                }
                return .section(navigation.section)
            },
            set: { destination in
                switch destination {
                case .section(let section): navigation.showHome(section)
                case .tab(let id): navigation.openTab(id)
                case nil: break
                }
            }
        )
    }

    private var tabsHeader: some View {
        HStack(spacing: 4) {
            Text("Tabs · \(remote.sessions.count)")
            Spacer(minLength: 4)
            let working = CantripHomeTabCounts.working(in: remote.sessions)
            if working > 0 {
                Text("\(working) working")
                    .foregroundStyle(CantripHomeBackgroundStyle.activeTint)
            }
            Button {
                navigation.createTab()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!remote.isConfigured || remote.isMutating)
            .help("New Tab (⌘T)")
            .accessibilityLabel("New Tab")
            .accessibilityIdentifier("sidebar.newTab")
        }
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

    /// Home itself while it is showing, else its listed summary (a tab is open).
    private var home: CantripRemoteSession? {
        remote.isHomeSelected ? remote.selectedSession : remote.homeSummary
    }

    private func badge(for section: CantripHomeSection) -> Int {
        switch section {
        case .chat: home?.isCantripHome == true ? home?.pendingInputCount ?? 0 : 0
        case .tasks: remote.homeTasks.filter { $0.state == "running" }.count
        case .artifacts: 0
        }
    }

    /// Same mood rules as the iOS Home header, from Home's state even while a tab is open.
    private var mood: CantripMascotMood {
        .resolve(
            isConnected: remote.isConnected,
            isWorking: home?.isStreaming == true,
            activity: .current(
                status: home?.status,
                transcript: remote.isHomeSelected ? home?.transcript ?? [] : []
            ),
            isListening: voice.isListening,
            isSpeaking: voice.isSpeaking,
            needsInput: (home?.pendingInputCount ?? 0) > 0,
            hasProblem: remote.errorMessage != nil
                || (remote.isHomeSelected && home?.transcript.last?.role == "error")
        )
    }
}

/// One project tab: spinner or dot, name, and how long ago it last ran.
struct MacHomeTabRow: View {
    let session: CantripRemoteSession

    var body: some View {
        HStack(spacing: 8) {
            CantripTabStatusIndicator(session: session)
                .frame(width: 16)
            HStack(spacing: 3) {
                if session.isLocalPrivate == true {
                    Image(systemName: "lock.shield.fill").font(.caption2)
                } else if session.isLocked == true {
                    Image(systemName: "lock.fill").font(.caption2)
                }
                Text(session.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CantripTabAgeText(date: session.lastActivityDate)
        }
        .help(CantripTabRowText.detail(for: session)?.text ?? session.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CantripSessionPicker.accessibilityTitle(for: session))
        .accessibilityValue(session.tabRowAccessibilityValue)
        .accessibilityIdentifier("sidebar.tab.\(session.id)")
    }
}
