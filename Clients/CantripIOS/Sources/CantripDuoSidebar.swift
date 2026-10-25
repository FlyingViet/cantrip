import SwiftUI

/// iPhone Duo unfolded on its side: Gateway Mac's sidebar beside the chat. Pip and Cantrip Home,
/// Home's sections, every project tab, and the open chat's skills, with the connection at the
/// bottom. Header and footer stay put; everything between them scrolls inside the sidebar, so the
/// keyboard shortens the list instead of hiding it.
struct CantripDuoSidebar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: CantripRemoteModel
    @ObservedObject var slashCommands: BackendSlashCommandStore
    /// Home (rather than a project tab) is showing, on `homeSection`.
    let isHomeShown: Bool
    let homeSection: CantripHomeSection
    /// The open tab's or Home chat's skills are listed (a chat is on screen).
    let showsSkills: Bool
    /// The composer's "/" token while it filters the skills; nil lists them grouped.
    let slashToken: String?
    /// The highlighted match while filtering (Return/Tab choose it).
    let highlighted: Int?
    let canOpenModelSettings: Bool
    let backgroundStatus: CantripDuoSidebarBackground?
    let isListening: Bool
    let isSpeaking: Bool
    let onSelectSection: (CantripHomeSection) -> Void
    let onSelectTab: (String) -> Void
    let onCreateTab: () -> Void
    let onRename: (CantripRemoteSession) -> Void
    let onClose: (String) -> Void
    let onOpenBackground: () -> Void
    let onCustomizeMascot: () -> Void
    let onChoose: (BackendCommandMatch) -> Void

    @AppStorage(CantripMascotOutfit.storageKey) private var outfit: CantripMascotOutfit = .starryPlush
    @AppStorage(CantripMascotName.storageKey) private var mascotName = ""
    @AppStorage("cantrip.duoSidebar.tabsExpanded") private var tabsExpanded = true
    @ObservedObject private var collapse = CantripTabSectionCollapse.shared
    @AppStorage("cantrip.duoSidebar.skillsExpanded") private var skillsExpanded = true
    @State private var expandedGroups: Set<BackendSkillsSidebar.Group> = Self.initialExpandedGroups

    static var width: CGFloat { 288 }

    private static var initialExpandedGroups: Set<BackendSkillsSidebar.Group> {
        var groups = Set(BackendSkillsSidebar.Group.allCases.filter { !$0.isCollapsedByDefault })
        #if DEBUG
        if CantripUITestFixtures.expandsUnavailableSkills { groups.insert(.unavailable) }
        #endif
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: in a LazyVStack a moved highlight was never redrawn (iOS 27.1).
                    VStack(alignment: .leading, spacing: 2) {
                        sections
                        tabs
                        if showsSkills { skills }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.never)
                .onChange(of: highlighted) { _, position in
                    guard let id = filteredMatchID(at: position) else { return }
                    withAnimation(nil) { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: slashToken != nil) { _, filtering in
                    if filtering { withAnimation(nil) { proxy.scrollTo(Self.skillsAnchor, anchor: .top) } }
                }
                #if DEBUG
                .task {
                    // Screenshots of the "Can't run here" group.
                    guard CantripUITestFixtures.expandsUnavailableSkills else { return }
                    try? await Task.sleep(for: .seconds(4))
                    proxy.scrollTo("duo.sidebar.skills.unavailable", anchor: .top)
                }
                #endif
            }
            footer
        }
        .frame(width: dynamicTypeSize.isAccessibilitySize ? 340 : Self.width)
        .background(Color(.secondarySystemBackground), ignoresSafeAreaEdges: .all)
        .onAppear { model.refreshSlashCommandsIfNeeded() }
        .onChange(of: model.slashCommandContext) { _, _ in model.refreshSlashCommandsIfNeeded() }
        .onChange(of: filteredCountAnnouncement) { _, text in
            if let text { BackendSlashAnnouncer.announce(text, polite: true) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .accessibilityIdentifier("duo.sidebar")
    }

    // MARK: Header and footer

    private var header: some View {
        Button(action: onCustomizeMascot) {
            HStack(spacing: 10) {
                CantripMascotView(mood: mood, outfit: outfit, size: 52)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CantripMascotName.display(mascotName))
                        .font(.headline)
                    Text("Cantrip Home")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityLabel(CantripMascotName.display(mascotName))
        .accessibilityValue(mood.accessibilityStatus ?? mood.title)
        .accessibilityHint("Customizes the mascot")
        .accessibilityIdentifier("duo.sidebar.mascot")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text("\(serverName) · \(model.connectionLabel.lowercased())")
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("duo.sidebar.connection")
    }

    // MARK: Home

    @ViewBuilder private var sections: some View {
        ForEach(CantripHomeSection.allCases) { section in
            let selected = isHomeShown && homeSection == section
            Button { onSelectSection(section) } label: {
                HStack(spacing: 10) {
                    Image(systemName: section.systemImage)
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    Text(section.title)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let badge = badge(for: section) {
                        Text("\(badge)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .sidebarRow(selected: selected)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(badge(for: section).map { "\($0)" } ?? "")
            .accessibilityIdentifier("duo.sidebar.section.\(section.rawValue)")
        }
        if let backgroundStatus {
            Button(action: onOpenBackground) {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(backgroundStatus.isActive ? CantripHomeBackgroundStyle.activeTint : Color.secondary)
                        .frame(width: 24)
                    Text("Background jobs")
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(backgroundStatus.text)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(backgroundStatus.isActive ? CantripHomeBackgroundStyle.activeTint : Color.secondary)
                }
                .sidebarRow(selected: false)
            }
            .buttonStyle(.plain)
            .accessibilityValue(backgroundStatus.text)
            .accessibilityHint("Shows background tasks and scheduled runs")
            .accessibilityIdentifier("duo.sidebar.background")
        }
    }

    // MARK: Tabs

    @ViewBuilder private var tabs: some View {
        if let groups = CantripTabGrouping.groups(model.sessions, sections: model.tabSections) {
            ForEach(groups) { group in
                sectionedTabs(group)
            }
        } else {
            flatTabs
        }
    }

    /// One section (or Tabs, the unfiled ones): a collapsible header with its own + and menu.
    @ViewBuilder private func sectionedTabs(_ group: CantripTabGrouping.Group) -> some View {
        let collapsed = collapse.isCollapsed(group.id, scope: model.tabSectionScope)
        let working = CantripHomeTabCounts.working(in: group.sessions)
        sectionHeader(
            title: "\(group.name) · \(group.sessions.count)",
            detail: working > 0 ? "\(working) working" : nil,
            isExpanded: !collapsed,
            toggle: { collapse.toggle(group.id, scope: model.tabSectionScope) },
            accessory: {
                Button {
                    if let section = group.section {
                        Task { if let id = await model.createTab(inSection: section.id) { onSelectTab(id) } }
                    } else {
                        onCreateTab()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.isConfigured || model.isMutating)
                .accessibilityLabel(group.section == nil ? "New Tab" : "New Tab in \(group.name)")
                .accessibilityIdentifier(group.section == nil ? "duo.sidebar.newTab" : "duo.sidebar.newTab.\(group.id)")
            }
        )
        .contextMenu {
            CantripTabSectionMenu(model: model, group: group, onNewTab: group.section.map { section in
                { Task { if let id = await model.createTab(inSection: section.id) { onSelectTab(id) } } }
            })
        }
        .accessibilityIdentifier(group.section == nil ? "duo.sidebar.tabsHeader" : "duo.sidebar.section.\(group.id)")
        ForEach(CantripTabGrouping.visible(group, collapsed: collapsed,
                                           selectedID: isHomeShown ? nil : model.selectedSessionID)) { session in
            tabRow(session)
        }
    }

    @ViewBuilder private var flatTabs: some View {
        sectionHeader(
            title: "Tabs · \(model.sessions.count)",
            detail: { let working = CantripHomeTabCounts.working(in: model.sessions)
                      return working > 0 ? "\(working) working" : nil }(),
            isExpanded: tabsExpanded,
            toggle: { tabsExpanded.toggle() },
            accessory: {
                Button(action: onCreateTab) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.isConfigured || model.isMutating)
                .accessibilityLabel("New Tab")
                .accessibilityIdentifier("duo.sidebar.newTab")
            }
        )
        .accessibilityIdentifier("duo.sidebar.tabsHeader")
        if tabsExpanded {
            ForEach(model.sessions) { session in
                tabRow(session)
            }
            if model.sessions.isEmpty {
                Text(model.isConfigured ? "No tabs yet" : "Not connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }

    private func tabRow(_ session: CantripRemoteSession) -> some View {
        let selected = !isHomeShown && session.id == model.selectedSessionID
        return Button { onSelectTab(session.id) } label: {
            HStack(spacing: 8) {
                CantripTabStatusIndicator(session: session)
                    .frame(width: 18)
                HStack(spacing: 3) {
                    if session.isLocalPrivate == true {
                        Image(systemName: "lock.shield.fill").font(.caption2)
                    } else if session.isLocked == true {
                        Image(systemName: "lock.fill").font(.caption2)
                    }
                    Text(session.title)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                CantripTabAgeText(date: session.lastActivityDate)
            }
            .sidebarRow(selected: selected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            CantripTabActions(model: model, session: session,
                              onRename: { onRename(session) }, onClose: { onClose(session.id) })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CantripSessionPicker.accessibilityTitle(for: session))
        .accessibilityValue(session.tabRowAccessibilityValue)
        .accessibilityHint("Opens this tab. Touch and hold for tab actions.")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("duo.sidebar.tab.\(session.id)")
    }

    // MARK: Skills

    private static let skillsAnchor = "duo.sidebar.skills"

    private var skillsContent: BackendSkillsSidebar.Content? {
        guard let context = model.slashCommandContext else { return nil }
        return BackendSkillsSidebar.content(
            response: slashCommands.response(for: context.key),
            isLoading: slashCommands.isLoading(context.key),
            token: slashToken, highlighted: highlighted
        )
    }

    @ViewBuilder private var skills: some View {
        if let content = skillsContent {
            let expanded = BackendSkillsSidebar.isExpanded(stored: skillsExpanded, isFiltering: slashToken != nil)
            sectionHeader(
                title: "Skills",
                detail: skillsDetail(content),
                detailIsActive: false,
                isExpanded: expanded,
                toggle: { skillsExpanded = !expanded },
                accessory: { EmptyView() }
            )
            .id(Self.skillsAnchor)
            .accessibilityIdentifier("duo.sidebar.skillsHeader")
            if expanded { skillRows(content) }
        }
    }

    @ViewBuilder private func skillRows(_ content: BackendSkillsSidebar.Content) -> some View {
        switch content {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading commands…").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        case .grouped(let groups, let status):
            ForEach(groups) { section in
                let open = expandedGroups.contains(section.group)
                Button {
                    if open { expandedGroups.remove(section.group) } else { expandedGroups.insert(section.group) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .accessibilityHidden(true)
                        Text(section.group.title)
                        Spacer(minLength: 4)
                        Text("\(section.matches.count)")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(section.group.title), \(section.matches.count)")
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                .accessibilityAddTraits(.isHeader)
                .id("duo.sidebar.skills.\(section.group.rawValue)")
                .accessibilityIdentifier("duo.sidebar.skills.\(section.group.rawValue)")
                if open {
                    ForEach(section.matches) { match in
                        skillRow(match, highlighted: false)
                    }
                }
            }
            statusRow(status)
        case .filtered(let matches, let highlighted, let status):
            if matches.isEmpty {
                Text("No matching commands")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            ForEach(Array(matches.enumerated()), id: \.element.id) { position, match in
                skillRow(match, highlighted: position == highlighted)
            }
            statusRow(status)
        }
    }

    private func skillRow(_ match: BackendCommandMatch, highlighted: Bool) -> some View {
        BackendSlashSuggestionButton(match: match, isHighlighted: highlighted, style: .sidebar,
                                     canOpenModelSettings: canOpenModelSettings, onChoose: onChoose)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .id("skill-\(match.id)")
    }

    @ViewBuilder private func statusRow(_ status: String?) -> some View {
        if let status {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityIdentifier("duo.sidebar.skills.status")
        }
    }

    private func skillsDetail(_ content: BackendSkillsSidebar.Content) -> String? {
        switch content {
        case .loading: nil
        case .grouped(let groups, _): "\(groups.reduce(0) { $0 + $1.matches.count })"
        case .filtered(let matches, _, _): "/\(slashToken ?? "") · \(matches.count)"
        }
    }

    private var filteredCountAnnouncement: String? {
        guard case .filtered(let matches, _, _)? = skillsContent else { return nil }
        return BackendSlashCommands.countAnnouncement(matches.count)
    }

    private func filteredMatchID(at position: Int?) -> String? {
        guard let position, case .filtered(let matches, _, _)? = skillsContent,
              matches.indices.contains(position) else { return nil }
        return "skill-\(matches[position].id)"
    }

    // MARK: Pieces

    private func sectionHeader<Accessory: View>(
        title: String, detail: String?, detailIsActive: Bool = true, isExpanded: Bool,
        toggle: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(title)
                        .textCase(.uppercase)
                    Spacer(minLength: 4)
                    if let detail {
                        Text(detail)
                            .foregroundStyle(detailIsActive ? CantripHomeBackgroundStyle.activeTint : Color.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses the section" : "Expands the section")
            .accessibilityAddTraits(.isHeader)
            accessory()
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.top, 10)
    }

    private var serverName: String {
        let name = model.servers.selected?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? model.endpointHost : name
    }

    /// Home's own snapshot while it shows, else its listed summary (a tab is open).
    private var home: CantripRemoteSession? {
        model.isHomeSelected ? model.selectedSession : model.homeSummary
    }

    private func badge(for section: CantripHomeSection) -> Int? {
        let count: Int
        switch section {
        case .chat: count = home?.isCantripHome == true ? home?.pendingInputCount ?? 0 : 0
        case .tasks: count = model.homeTasks.filter { $0.state == "running" }.count
        default: count = 0
        }
        return count > 0 ? count : nil
    }

    private var mood: CantripMascotMood {
        .resolve(
            isConnected: model.isConnected,
            isWorking: home?.isStreaming == true,
            activity: .current(status: home?.status,
                               transcript: model.isHomeSelected ? home?.transcript ?? [] : []),
            isListening: isListening,
            isSpeaking: isSpeaking,
            needsInput: (home?.pendingInputCount ?? 0) > 0,
            hasProblem: model.errorMessage != nil
        )
    }
}

/// The Background jobs row's state; nil hides the row.
struct CantripDuoSidebarBackground: Equatable {
    let text: String
    let isActive: Bool
}

private extension View {
    func sidebarRow(selected: Bool) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 40)
            .background(selected ? Color.accentColor.opacity(0.2) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
