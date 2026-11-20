import SwiftUI

/// The app's one left menu, modelled on Gateway Mac's sidebar: Pip and Cantrip Home, Home's sections,
/// Background jobs, every project tab, and the open chat's skills, with the connection at the bottom.
/// It sits beside the chat on the unfolded iPhone Duo (or over it, upright), and is the tab drawer's
/// panel (iPhone, folded Duo, unfolded Duo with the sidebar put away) and iPad's sidebar column.
/// Header and footer stay put; everything between them scrolls inside it, so the keyboard shortens
/// the list instead of hiding it.
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
    var placement: CantripLeftMenuPlacement = .beside
    /// Over a dimmed chat (the drawer): VoiceOver starts at the header.
    var isModal = false
    /// Settings from the footer, where the screen has no other Settings button (iPhone, iPad); nil hides it.
    var onOpenSettings: (() -> Void)? = nil

    @AppStorage(CantripMascotOutfit.storageKey) private var outfit: CantripMascotOutfit = .starryPlush
    @AppStorage(CantripMascotName.storageKey) private var mascotName = ""
    @AppStorage("cantrip.duoSidebar.tabsExpanded") private var tabsExpanded = true
    @ObservedObject private var collapse = CantripTabSectionCollapse.shared
    @AppStorage("cantrip.duoSidebar.skillsExpanded") private var skillsExpanded = true
    @State private var expandedGroups: Set<BackendSkillsSidebar.Group> = Self.initialExpandedGroups
    @State private var query = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool
    @AccessibilityFocusState private var headerFocused: Bool

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
            if isSearching { searchField }
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: in a LazyVStack a moved highlight was never redrawn (iOS 27.1).
                    VStack(alignment: .leading, spacing: 2) {
                        if query.isEmpty {
                            sections
                            tabs
                            if showsSkills { skills }
                        } else {
                            searchResults
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.never)
                .accessibilityIdentifier(id("list"))
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
        .frame(width: placement == .beside ? (dynamicTypeSize.isAccessibilitySize ? 340 : Self.width) : nil)
        .frame(maxWidth: placement == .beside ? nil : .infinity, maxHeight: placement == .beside ? nil : .infinity)
        .background(Color(.secondarySystemBackground), ignoresSafeAreaEdges: .all)
        .onAppear {
            model.refreshSlashCommandsIfNeeded()
            headerFocused = isModal
        }
        .onChange(of: model.sessions.isEmpty) { _, empty in
            if empty { closeSearch() }
        }
        .onChange(of: model.slashCommandContext) { _, _ in model.refreshSlashCommandsIfNeeded() }
        .onChange(of: filteredCountAnnouncement) { _, text in
            if let text { BackendSlashAnnouncer.announce(text, polite: true) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .accessibilityIdentifier(placement == .beside ? "duo.sidebar" : "drawer.menu")
    }

    /// Accessibility identifiers: `duo.sidebar.*` beside the chat, `drawer.*` as the drawer's panel.
    private func id(_ name: String) -> String {
        (placement == .beside ? "duo.sidebar." : "drawer.") + name
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 0) {
            mascotButton
            Button {
                if isSearching { closeSearch() } else {
                    isSearching = true
                    searchFocused = true
                }
            } label: {
                Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.sessions.isEmpty)
            .accessibilityLabel(isSearching ? "Close Search" : "Search Tabs")
            .accessibilityIdentifier(id("searchButton"))
            .padding(.trailing, 6)
        }
    }

    private var mascotButton: some View {
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
        .accessibilityFocused($headerFocused)
        .accessibilityIdentifier(placement == .beside ? "duo.sidebar.mascot" : "drawer.homeHeader")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search tabs", text: $query)
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier(id("search"))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func closeSearch() {
        query = ""
        searchFocused = false
        isSearching = false
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.top, 8)
                    .accessibilityIdentifier("cantrip-tab-error")
            }
            HStack(spacing: 8) {
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
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(id("connection"))
                if let onOpenSettings {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier(id("settings"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, onOpenSettings == nil ? 10 : 0)
        .overlay(alignment: .top) { Divider() }
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
            .accessibilityIdentifier(id("section.\(section.rawValue)"))
        }
        if let backgroundStatus {
            Button(action: onOpenBackground) {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(backgroundStatus.isActive ? CantripHomeBackgroundStyle.activeTint : Color.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Background jobs")
                            .foregroundStyle(.primary)
                        ForEach(backgroundStatus.details, id: \.self) { line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(backgroundStatus.text)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(backgroundStatus.isActive ? CantripHomeBackgroundStyle.activeTint : Color.secondary)
                }
                .sidebarRow(selected: false)
            }
            .buttonStyle(.plain)
            .accessibilityValue(backgroundStatus.accessibilityValue)
            .accessibilityHint("Shows background tasks and scheduled runs")
            .accessibilityIdentifier(id("background"))
        }
    }

    // MARK: Tabs

    /// Tabs whose name, folder or latest line matches every word typed, in one list.
    @ViewBuilder private var searchResults: some View {
        let matches = CantripHomeTabSearch.filter(model.sessions, query: query)
        Text("Results · \(matches.count)")
            .textCase(.uppercase)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
        ForEach(matches) { session in
            tabRow(session)
        }
        if matches.isEmpty {
            Text("No tabs match “\(query)”")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var tabs: some View {
        if let groups = CantripTabGrouping.groups(model.sessions, sections: model.tabSections) {
            ForEach(groups) { group in
                sectionedTabs(group)
            }
        } else {
            flatTabs
        }
        if model.supportsTabSections {
            CantripNewSectionButton(model: model)
                .padding(.horizontal, 12)
        }
    }

    /// One section (or Tabs, the unfiled ones): a collapsible header with its own + and menu.
    @ViewBuilder private func sectionedTabs(_ group: CantripTabGrouping.Group) -> some View {
        let collapsed = collapse.isCollapsed(group.id, scope: model.tabSectionScope)
        let working = CantripHomeTabCounts.working(in: group.sessions)
        sectionHeader(
            title: "\(group.name) · \(group.sessions.count)",
            spokenTitle: "\(group.name), \(Self.tabCount(group.sessions.count))",
            detail: working > 0 ? "\(working) working" : nil,
            isExpanded: !collapsed,
            identifier: id(group.section == nil ? "tabsHeader" : "section.\(group.id)"),
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
                .accessibilityIdentifier(id(group.section == nil ? "newTab" : "newTab.\(group.id)"))
                CantripTabSectionMenuButton(model: model, group: group, onNewTab: group.section.map { section in
                    { Task { if let id = await model.createTab(inSection: section.id) { onSelectTab(id) } } }
                })
            }
        )
        .contextMenu {
            CantripTabSectionMenu(model: model, group: group, onNewTab: group.section.map { section in
                { Task { if let id = await model.createTab(inSection: section.id) { onSelectTab(id) } } }
            })
        }
        // Touch and hold, then drag, onto another header to reorder sections; drop a tab to file it.
        .cantripDraggable(group.section != nil ? CantripTabDrag.payload(section: group.id) : nil)
        .cantripDropTarget(cornerRadius: 10) { payload in
            guard let action = CantripTabDrag.drop(payload, onHeaderOf: group.section?.id,
                                                   sections: model.tabSections, sessions: model.sessions) else { return false }
            Task { await model.perform(action) }
            return true
        }
        ForEach(CantripTabGrouping.visible(group, collapsed: collapsed,
                                           selectedID: isHomeShown ? nil : model.selectedSessionID)) { session in
            tabRow(session)
        }
    }

    @ViewBuilder private var flatTabs: some View {
        sectionHeader(
            title: "Tabs · \(model.sessions.count)",
            spokenTitle: "Tabs, \(Self.tabCount(model.sessions.count))",
            detail: { let working = CantripHomeTabCounts.working(in: model.sessions)
                      return working > 0 ? "\(working) working" : nil }(),
            isExpanded: tabsExpanded,
            identifier: id("tabsHeader"),
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
                .accessibilityIdentifier(id("newTab"))
            }
        )
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
                    if session.isChildTab {
                        CantripChildTabGlyph()
                    }
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
                CantripTabBackgroundNote(count: session.backgroundTaskCount ?? 0, compact: true)
                CantripTabAgeText(date: session.lastActivityDate)
            }
            .sidebarRow(selected: selected)
            .cantripChildTabIndent(session, by: 16)
        }
        .buttonStyle(.plain)
        .contextMenu {
            CantripTabActions(model: model, session: session,
                              onRename: { onRename(session) }, onClose: { onClose(session.id) },
                              onOpenTab: onSelectTab)
        }
        // No handles: touch and hold, then drag, onto another tab to take its place.
        .cantripDraggable(canMove(session) ? CantripTabDrag.payload(tab: session.id) : nil)
        .cantripDropTarget(cornerRadius: 10) { payload in
            guard let action = CantripTabDrag.drop(payload, onTab: session, order: tabOrder) else { return false }
            Task { await model.perform(action) }
            return true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CantripSessionPicker.accessibilityTitle(for: session))
        .accessibilityValue(session.tabRowAccessibilityValue)
        .accessibilityHint("Opens this tab. Touch and hold for tab actions.")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier(id("tab.\(session.id)"))
        .accessibilityActions {
            if canMove(session), let index = tabOrder.firstIndex(where: { $0.id == session.id }) {
                if index > 0 {
                    Button("Move Tab Up") {
                        Task { await model.moveTab(session.id, relativeTo: tabOrder[index - 1].id, after: false) }
                    }
                }
                if index < tabOrder.count - 1 {
                    Button("Move Tab Down") {
                        Task { await model.moveTab(session.id, relativeTo: tabOrder[index + 1].id, after: true) }
                    }
                }
            }
        }
    }

    private func canMove(_ session: CantripRemoteSession) -> Bool {
        query.isEmpty && session.supportsTabReordering == true && model.sessions.count >= 2 && !model.isMutating
    }

    /// The tabs as shown here: grouped by section, leaving out collapsed sections' idle tabs.
    private var tabOrder: [CantripRemoteSession] {
        guard let groups = CantripTabGrouping.groups(model.sessions, sections: model.tabSections) else {
            return tabsExpanded ? model.sessions : []
        }
        return groups.flatMap { group in
            CantripTabGrouping.visible(group, collapsed: collapse.isCollapsed(group.id, scope: model.tabSectionScope),
                                       selectedID: isHomeShown ? nil : model.selectedSessionID)
        }
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
                identifier: id("skillsHeader"),
                toggle: { skillsExpanded = !expanded },
                accessory: { EmptyView() }
            )
            .id(Self.skillsAnchor)
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
                .accessibilityIdentifier(id("skills.\(section.group.rawValue)"))
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
                .accessibilityIdentifier(id("skills.status"))
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

    /// A collapsible header; `identifier` and `spokenTitle` (VoiceOver's name for it) go on its toggle,
    /// not on the row, so its + and … keep their own.
    private func sectionHeader<Accessory: View>(
        title: String, spokenTitle: String? = nil, detail: String?, detailIsActive: Bool = true, isExpanded: Bool,
        identifier: String, toggle: @escaping () -> Void, @ViewBuilder accessory: () -> Accessory
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
            .accessibilityLabel([spokenTitle ?? title, detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses the section" : "Expands the section")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
            accessory()
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.top, 10)
    }

    private static func tabCount(_ count: Int) -> String { "\(count) \(count == 1 ? "tab" : "tabs")" }

    private var serverName: String {
        let name = model.servers.selected?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? model.endpointHost : name
    }

    /// Home's own snapshot while it shows, else its listed summary (a tab is open).
    private var home: CantripRemoteSession? {
        model.isHomeSelected ? model.selectedSession : model.homeSummary
    }

    private func badge(for section: CantripHomeSection) -> Int? { model.homeSectionBadge(section) }

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

/// Where the left menu is: beside (or over) the chat on the unfolded iPhone Duo, or the tab drawer's
/// panel and iPad's sidebar column, which fill the width they're given.
enum CantripLeftMenuPlacement {
    case beside
    case drawer
}

/// The Background jobs row's state; nil hides the row.
struct CantripDuoSidebarBackground: Equatable {
    let text: String
    let isActive: Bool
    /// Lines under the title: tabs' background tasks ("3 in tabs") and the Mac's jobs ("2 jobs running · 1 waiting").
    var details: [String] = []
    var accessibilityValue: String

    init(text: String, isActive: Bool, details: [String] = [], accessibilityValue: String? = nil) {
        self.text = text
        self.isActive = isActive
        self.details = details
        self.accessibilityValue = accessibilityValue ?? text
    }

    init(_ summary: CantripBackgroundJobsSummary) {
        self.init(text: summary.status, isActive: summary.isActive, details: summary.details,
                  accessibilityValue: summary.accessibilityValue)
    }
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
