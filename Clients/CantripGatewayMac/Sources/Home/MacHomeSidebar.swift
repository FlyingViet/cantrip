import SwiftUI

/// A sidebar row: Home's sections, or one project tab.
enum MacHomeDestination: Hashable {
    case section(CantripHomeSection)
    case tab(String)
    /// Direct local mode: a model served on this Mac, not through Cantrip.
    case directLocal
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
    @ObservedObject private var collapse = CantripTabSectionCollapse.shared
    /// The section header a drag is over (outlined).
    @State private var dropTarget: String?

    var body: some View {
        // Header and footer sit outside the list (not as safe-area insets, which let rows scroll
        // underneath them), so Home's sections and the tabs scroll only inside their own box.
        VStack(spacing: 0) {
            header
            list
                .clipShape(Self.listBox)
                .background(Self.listBox.fill(.white.opacity(0.03)))
                .overlay(Self.listBox.strokeBorder(.white.opacity(0.08)))
                .padding(.horizontal, 8)
            footer
        }
    }

    private static let listBox = RoundedRectangle(cornerRadius: 12, style: .continuous)

    private var list: some View {
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
                MacDirectLocalRow()
                    .tag(MacHomeDestination.directLocal)
            } header: {
                Text("On This Mac")
            }
            if let groups = CantripTabGrouping.groups(remote.sessions, sections: remote.tabSections) {
                ForEach(groups) { group in
                    sectionedTabs(group)
                }
            } else {
                Section {
                    tabRows(remote.sessions)
                    if remote.sessions.isEmpty, remote.isConfigured {
                        Text("No tabs yet")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                } header: {
                    tabsHeader
                }
            }
            if remote.supportsTabSections {
                Section {
                    CantripNewSectionButton(model: remote)
                        .selectionDisabled()
                        .help("Add an empty section. Drop tabs on its header or use Move to Section.")
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar.list")
    }

    /// Rows reorder inside their list; dropping one on a section's header files it there.
    private func tabRows(_ sessions: [CantripRemoteSession]) -> some View {
        ForEach(sessions) { session in
            MacHomeTabRow(session: session)
                .tag(MacHomeDestination.tab(session.id))
                .contextMenu {
                    CantripTabActions(
                        model: remote, session: session,
                        onRename: { navigation.renamingTab = session },
                        onClose: { navigation.closeTab(session.id) },
                        onOpenTab: { navigation.openTab($0) }
                    )
                }
                // A child tab stays under its parent until its work merges.
                .itemProvider(session.isChildTab ? nil : {
                    NSItemProvider(object: (Self.dragPrefix + session.id) as NSString)
                })
        }
        .onMove { offsets, destination in
            guard let move = CantripTabReorder.move(sessions, fromOffsets: offsets, toOffset: destination) else { return }
            Task { await remote.moveTab(move.id, relativeTo: move.targetID, after: move.after) }
        }
    }

    private static let dragPrefix = "cantrip-tab:"
    private static let sectionDragPrefix = "cantrip-section:"

    /// A tab dropped on a section's header is filed there (after the section's last tab); a section's
    /// header dropped on another takes its place (on Tabs, which is always last: last).
    private func drop(_ providers: [NSItemProvider], onto group: CantripTabGrouping.Group) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            Task { @MainActor in
                if text.hasPrefix(Self.dragPrefix) {
                    let id = String(text.dropFirst(Self.dragPrefix.count))
                    guard !group.sessions.contains(where: { $0.id == id }) else { return }
                    await remote.fileTab(id, in: group.section?.id)
                } else if text.hasPrefix(Self.sectionDragPrefix) {
                    let id = String(text.dropFirst(Self.sectionDragPrefix.count))
                    guard id != group.section?.id else { return }
                    let position = group.section.flatMap { target in
                        remote.tabSections.firstIndex { $0.id == target.id }
                    } ?? remote.tabSections.count - 1
                    await remote.moveSection(id, to: position)
                }
            }
        }
        return true
    }

    @ViewBuilder private func sectionedTabs(_ group: CantripTabGrouping.Group) -> some View {
        let collapsed = collapse.isCollapsed(group.id, scope: remote.tabSectionScope)
        Section {
            tabRows(CantripTabGrouping.visible(group, collapsed: collapsed, selectedID: selectedTabID))
            if group.sessions.isEmpty, !collapsed {
                Text(group.section == nil ? "No unfiled tabs" : "Drop a tab on this header, or use Move to Section")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
            }
        } header: {
            HStack(spacing: 4) {
                Button {
                    collapse.toggle(group.id, scope: remote.tabSectionScope)
                } label: {
                    CantripTabSectionTitle(group: group, collapsed: collapsed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help((collapsed ? "Show this section's tabs" : "Hide this section's idle tabs")
                      + (group.section == nil ? "" : ". Drag onto another section to reorder."))
                Button {
                    if let section = group.section {
                        Task { if let id = await remote.createTab(inSection: section.id) { navigation.openTab(id) } }
                    } else {
                        navigation.createTab()
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!remote.isConfigured || remote.isMutating)
                .help(group.section == nil ? "New Tab (⌘T)" : "New Tab in \(group.name)")
                .accessibilityLabel(group.section == nil ? "New Tab" : "New Tab in \(group.name)")
                .accessibilityIdentifier(group.section == nil ? "sidebar.newTab" : "sidebar.newTab.\(group.id)")
            }
            .contextMenu {
                CantripTabSectionMenu(model: remote, group: group, onNewTab: group.section.map { section in
                    { Task { if let id = await remote.createTab(inSection: section.id) { navigation.openTab(id) } } }
                })
            }
            .modifier(MacSectionDragSource(sectionID: group.section?.id, prefix: Self.sectionDragPrefix))
            // Dropping a tab on a section's header files it there; dropping a section moves it.
            .onDrop(of: [.plainText], isTargeted: Binding(
                get: { dropTarget == group.id },
                set: { targeted in
                    if targeted { dropTarget = group.id } else if dropTarget == group.id { dropTarget = nil }
                }
            )) { providers in
                drop(providers, onto: group)
            }
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.15))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2) }
                    .opacity(dropTarget == group.id ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("sidebar.section.\(group.id)")
        }
    }

    private var selectedTabID: String? {
        env.executionLane == .cantrip && !remote.isHomeSelected ? remote.selectedSessionID : nil
    }

    private var selection: Binding<MacHomeDestination?> {
        Binding(
            get: {
                if navigation.showingDirectLocal { return .directLocal }
                if env.executionLane == .cantrip, !remote.isHomeSelected {
                    return remote.selectedSessionID.map { .tab($0) }
                }
                return .section(navigation.section)
            },
            set: { destination in
                switch destination {
                case .section(let section): navigation.showHome(section)
                case .tab(let id): navigation.openTab(id)
                case .directLocal: navigation.showDirectLocal()
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
        .padding(.top, 6)
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

/// Direct local mode's sidebar row: clearly on this Mac and not synced.
struct MacDirectLocalRow: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text("Local Model")
                Text("Not synced")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "laptopcomputer")
        }
        .help("Chat with a model running on this Mac. Not sent through Cantrip and not synced. (⌘4)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Local Model on this Mac")
        .accessibilityValue("Not synced")
        .accessibilityIdentifier("sidebar.directLocal")
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
                if session.isChildTab {
                    CantripChildTabGlyph()
                }
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
        .cantripChildTabIndent(session, by: 14)
        .help(session.child.map { "Child tab of \($0.parentTitle) · \($0.statusLine)" }
              ?? CantripTabRowText.detail(for: session)?.text ?? session.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CantripSessionPicker.accessibilityTitle(for: session))
        .accessibilityValue(session.tabRowAccessibilityValue)
        .accessibilityIdentifier("sidebar.tab.\(session.id)")
    }
}

/// Lets a section's header be dragged onto another to reorder (Tabs stays last and doesn't drag).
private struct MacSectionDragSource: ViewModifier {
    let sectionID: String?
    let prefix: String

    @ViewBuilder func body(content: Content) -> some View {
        if let sectionID {
            content.onDrag { NSItemProvider(object: (prefix + sectionID) as NSString) }
        } else {
            content
        }
    }
}
