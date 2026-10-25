import SwiftUI

/// A named group of tabs on the Mac, like a Slack sidebar section. Tabs without one show under
/// "Tabs". The Mac keeps the sections; each device keeps which ones are collapsed.
struct CantripTabSection: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let name: String
}

/// A section name the user is asked for: a new section (optionally filing a tab in it) or a rename.
enum CantripSectionPrompt: Identifiable, Equatable {
    case create(fileTabID: String?)
    case rename(CantripTabSection)

    var id: String {
        switch self {
        case .create(let tab): return "create-\(tab ?? "")"
        case .rename(let section): return "rename-\(section.id)"
        }
    }
}

enum CantripTabGrouping {
    /// The group of tabs not in any section.
    static let looseID = "tabs"

    struct Group: Identifiable, Equatable {
        let id: String
        let name: String
        let sessions: [CantripRemoteSession]
        /// Nil for Tabs (unfiled).
        let section: CantripTabSection?
    }

    /// Tabs (unfiled, including tabs of deleted sections) first, then each section in the Mac's
    /// order; tabs keep the Mac's order inside a group. Nil when there are no sections: the list
    /// stays flat, as before sections.
    static func groups(_ sessions: [CantripRemoteSession], sections: [CantripTabSection]) -> [Group]? {
        guard !sections.isEmpty else { return nil }
        let known = Set(sections.map(\.id))
        var groups = [Group(id: looseID, name: "Tabs",
                            sessions: sessions.filter { $0.sectionID.map { !known.contains($0) } ?? true },
                            section: nil)]
        for section in sections {
            groups.append(Group(id: section.id, name: section.name,
                                sessions: sessions.filter { $0.sectionID == section.id }, section: section))
        }
        return groups
    }

    /// A collapsed group still shows the open tab and tabs that are working or waiting for an answer.
    static func visible(_ group: Group, collapsed: Bool, selectedID: String?) -> [CantripRemoteSession] {
        guard collapsed else { return group.sessions }
        return group.sessions.filter { $0.id == selectedID || $0.isStreaming || ($0.pendingInputCount ?? 0) > 0 }
    }

    /// A list drag (`onMove`: `destination` counts rows before the move) as the section's new
    /// position for `CantripRemoteModel.moveSection(_:to:)`.
    static func sectionPosition(movingFrom source: Int, to destination: Int) -> Int {
        destination > source ? destination - 1 : destination
    }

    /// The section a tab shows under, or nil for Tabs.
    static func sectionID(of session: CantripRemoteSession, sections: [CantripTabSection]) -> String? {
        session.sectionID.flatMap { id in sections.contains { $0.id == id } ? id : nil }
    }
}

/// Which sections this device keeps collapsed, per paired Mac (`CantripRemoteModel.tabSectionScope`).
@MainActor
final class CantripTabSectionCollapse: ObservableObject {
    static let shared = CantripTabSectionCollapse()
    static let storageKey = "cantrip.collapsedTabSections"

    @Published private var collapsed: [String: Set<String>]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
        collapsed = stored.mapValues(Set.init)
    }

    func isCollapsed(_ id: String, scope: String) -> Bool {
        collapsed[scope]?.contains(id) == true
    }

    func toggle(_ id: String, scope: String) {
        var ids = collapsed[scope] ?? []
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        collapsed[scope] = ids
        defaults.set(collapsed.mapValues { Array($0).sorted() }, forKey: Self.storageKey)
    }
}

/// A section header's menu: New Section on Tabs; rename, new tab, order and delete on a section.
struct CantripTabSectionMenu: View {
    let model: CantripRemoteModel
    let group: CantripTabGrouping.Group
    /// Opens a new tab in this section; nil hides New Tab Here.
    var onNewTab: (() -> Void)? = nil

    var body: some View {
        if let section = group.section {
            Button {
                model.sectionPrompt = .rename(section)
            } label: {
                Label("Rename Section", systemImage: "pencil")
            }
            if let onNewTab {
                Button(action: onNewTab) {
                    Label("New Tab Here", systemImage: "plus")
                }
            }
            Divider()
            Button {
                Task { await model.moveSection(section.id, offset: -1) }
            } label: {
                Label("Move Section Up", systemImage: "arrow.up")
            }
            .disabled(model.tabSections.first?.id == section.id)
            Button {
                Task { await model.moveSection(section.id, offset: 1) }
            } label: {
                Label("Move Section Down", systemImage: "arrow.down")
            }
            .disabled(model.tabSections.last?.id == section.id)
            Divider()
            Button(role: .destructive) {
                model.requestDeleteSection(section)
            } label: {
                Label(group.sessions.isEmpty ? "Delete Section" : "Delete Section…", systemImage: "trash")
            }
            Text("Its tabs move back to Tabs.")
        }
        Button {
            model.sectionPrompt = .create(fileTabID: nil)
        } label: {
            Label("New Section", systemImage: "folder.badge.plus")
        }
        Button {
            model.editingSections = true
        } label: {
            Label("Edit Sections…", systemImage: "list.bullet")
        }
    }
}

/// "New Section" at the end of a tab list: an empty section, shown when the Mac has sections.
struct CantripNewSectionButton: View {
    let model: CantripRemoteModel

    var body: some View {
        Button {
            model.sectionPrompt = .create(fileTabID: nil)
        } label: {
            Label("New Section", systemImage: "folder.badge.plus")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Adds an empty section. Move tabs into it from their menu.")
        .accessibilityIdentifier("cantrip-tab-new-section")
    }
}

extension CantripRemoteModel {
    /// Empty sections go at once; a section with tabs asks first (`sectionDeletion`).
    func requestDeleteSection(_ section: CantripTabSection) {
        if sessions.contains(where: { $0.sectionID == section.id }) {
            sectionDeletion = section
        } else {
            Task { await deleteSection(section.id) }
        }
    }
}

/// The visible "…" on a section header: the same menu as touch and hold.
struct CantripTabSectionMenuButton: View {
    let model: CantripRemoteModel
    let group: CantripTabGrouping.Group
    var onNewTab: (() -> Void)? = nil

    var body: some View {
        Menu {
            CantripTabSectionMenu(model: model, group: group, onNewTab: onNewTab)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(group.section == nil ? "Tabs options" : "\(group.name) section options")
        .accessibilityIdentifier("cantrip-tab-section-menu-\(group.id)")
    }
}

/// A section header's title: chevron, name, how many tabs and how many are working.
struct CantripTabSectionTitle: View {
    let group: CantripTabGrouping.Group
    let collapsed: Bool
    /// Shows the name in capitals (VoiceOver still reads it as written).
    var uppercase = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text(group.name)
                .lineLimit(1)
            Text("\(group.sessions.count)")
                .foregroundStyle(.tertiary)
            let working = CantripHomeTabCounts.working(in: group.sessions)
            if working > 0 {
                Text("· \(working) working")
                    .foregroundStyle(CantripHomeBackgroundStyle.activeTint)
            }
        }
        .textCase(uppercase ? .uppercase : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.name), \(group.sessions.count) \(group.sessions.count == 1 ? "tab" : "tabs")")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(collapsed ? "Shows this section's tabs" : "Hides this section's idle tabs")
        .accessibilityAddTraits([.isHeader, .isButton])
    }
}

extension View {
    /// Asks for a section's name when `model.sectionPrompt` is set (New Section, Rename Section),
    /// and shows Edit Sections when `model.editingSections` is set. Attach once per app.
    func cantripSectionPrompt(model: CantripRemoteModel) -> some View {
        modifier(CantripSectionPromptModifier(model: model, local: nil))
    }

    /// The same name prompt driven by `prompt`, for sheets that can't show the app's alert.
    func cantripSectionPrompt(model: CantripRemoteModel, prompt: Binding<CantripSectionPrompt?>) -> some View {
        modifier(CantripSectionPromptModifier(model: model, local: prompt))
    }
}

private struct CantripSectionPromptModifier: ViewModifier {
    @ObservedObject var model: CantripRemoteModel
    /// Nil: the app-wide prompt (`model.sectionPrompt`), which also presents Edit Sections.
    let local: Binding<CantripSectionPrompt?>?
    @State private var name = ""

    private var current: CantripSectionPrompt? {
        if let local { return local.wrappedValue }
        return model.sectionPrompt
    }

    private func dismissPrompt() {
        if let local { local.wrappedValue = nil } else { model.sectionPrompt = nil }
    }

    @ViewBuilder func body(content: Content) -> some View {
        if local == nil {
            prompted(content)
                .sheet(isPresented: $model.editingSections) {
                    CantripTabSectionsEditor(model: model)
                }
                .confirmationDialog(model.sectionDeletion.map { "Delete \u{201C}\($0.name)\u{201D}?" } ?? "Delete Section?",
                                    isPresented: Binding(get: { model.sectionDeletion != nil },
                                                         set: { if !$0 { model.sectionDeletion = nil } }),
                                    titleVisibility: .visible, presenting: model.sectionDeletion) { section in
                    Button("Delete Section", role: .destructive) {
                        Task { await model.deleteSection(section.id) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { section in
                    let count = model.sessions.filter { $0.sectionID == section.id }.count
                    Text("Its \(count == 1 ? "tab moves" : "\(count) tabs move") back to Tabs. No tabs are closed.")
                }
        } else {
            prompted(content)
        }
    }

    private func prompted(_ content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(
                get: { current != nil },
                set: { if !$0 { dismissPrompt() } }
            ), presenting: current) { prompt in
                TextField("Section name", text: $name)
                    .accessibilityIdentifier("section.name")
                Button("Cancel", role: .cancel) {}
                Button(prompt.isRename ? "Save" : "Create") {
                    let text = name
                    Task {
                        switch prompt {
                        case .create(let tab): await model.createSection(named: text, filing: tab)
                        case .rename(let section): await model.renameSection(section.id, to: text)
                        }
                    }
                }
            } message: { prompt in
                Text(prompt.isRename ? "Up to 40 characters."
                     : "Sections group tabs on every device. Up to 40 characters.")
            }
            .onChange(of: current) { _, prompt in
                if case .rename(let section) = prompt { name = section.name } else { name = "" }
            }
    }

    private var title: String { current?.isRename == true ? "Rename Section" : "New Section" }
}

private extension CantripSectionPrompt {
    var isRename: Bool { if case .rename = self { return true } else { return false } }
}

/// Touch-and-hold (or click-and-drag) moves in the tab lists, with no drag handles. Payloads match
/// the Mac and the browser: "cantrip-tab:<id>" and "cantrip-section:<id>".
enum CantripTabDrag {
    static let tabPrefix = "cantrip-tab:"
    static let sectionPrefix = "cantrip-section:"

    enum Item: Equatable {
        case tab(String)
        case section(String)
    }

    enum Action: Equatable {
        case moveTab(id: String, targetID: String, after: Bool)
        case fileTab(id: String, sectionID: String?)
        case moveSection(id: String, position: Int)
    }

    static func payload(tab id: String) -> String { tabPrefix + id }
    static func payload(section id: String) -> String { sectionPrefix + id }

    static func item(_ payload: String) -> Item? {
        if payload.hasPrefix(tabPrefix) { return .tab(String(payload.dropFirst(tabPrefix.count))) }
        if payload.hasPrefix(sectionPrefix) { return .section(String(payload.dropFirst(sectionPrefix.count))) }
        return nil
    }

    /// A tab dropped on another takes its place (after it moving down, before it moving up) and
    /// joins its section.
    static func drop(_ payload: String, onTab target: CantripRemoteSession, order: [CantripRemoteSession]) -> Action? {
        guard case .tab(let id)? = item(payload), id != target.id,
              let source = order.firstIndex(where: { $0.id == id }),
              let destination = order.firstIndex(where: { $0.id == target.id }),
              order[source].supportsTabReordering == true, target.supportsTabReordering == true else { return nil }
        return .moveTab(id: id, targetID: target.id, after: source < destination)
    }

    /// Dropped on a header: a tab joins that section (Tabs: none); a section takes the header's
    /// place (on Tabs: first).
    static func drop(_ payload: String, onHeaderOf sectionID: String?, sections: [CantripTabSection],
                     sessions: [CantripRemoteSession]) -> Action? {
        switch item(payload) {
        case .tab(let id)?:
            guard let tab = sessions.first(where: { $0.id == id }), tab.supportsTabSections == true,
                  CantripTabGrouping.sectionID(of: tab, sections: sections) != sectionID else { return nil }
            return .fileTab(id: id, sectionID: sectionID)
        case .section(let id)?:
            guard id != sectionID, let source = sections.firstIndex(where: { $0.id == id }) else { return nil }
            let position = sectionID.flatMap { target in sections.firstIndex { $0.id == target } } ?? 0
            return position == source ? nil : .moveSection(id: id, position: position)
        case nil:
            return nil
        }
    }
}

extension CantripRemoteModel {
    @discardableResult
    func perform(_ action: CantripTabDrag.Action) async -> Bool {
        switch action {
        case .moveTab(let id, let targetID, let after): return await moveTab(id, relativeTo: targetID, after: after)
        case .fileTab(let id, let sectionID): return await fileTab(id, in: sectionID)
        case .moveSection(let id, let position): return await moveSection(id, to: position)
        }
    }
}

extension View {
    /// Lets this row be dragged after touch and hold (or a click-drag on the Mac). A hold that
    /// doesn't move still opens the row's menu: `onDrag`'s drag interaction coordinates with the
    /// menu (`draggable` doesn't, and neither works on List rows that have a menu). Nil leaves the
    /// row in place.
    @ViewBuilder func cantripDraggable(_ payload: String?) -> some View {
        if let payload { onDrag { NSItemProvider(object: payload as NSString) } } else { self }
    }

    /// A row that takes dropped tabs or sections, outlined while a drag is over it.
    func cantripDropTarget(cornerRadius: CGFloat = 12, perform: @escaping (String) -> Bool) -> some View {
        modifier(CantripDropTarget(cornerRadius: cornerRadius, perform: perform))
    }
}

private struct CantripDropTarget: ViewModifier {
    let cornerRadius: CGFloat
    let perform: (String) -> Bool
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: String.self) { items, _ in
                guard items.count == 1, let payload = items.first else { return false }
                return perform(payload)
            } isTargeted: { targeted = $0 }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(targeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}
