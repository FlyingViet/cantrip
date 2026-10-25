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
                Task { await model.deleteSection(section.id) }
            } label: {
                Label("Delete Section", systemImage: "trash")
            }
            Text("Its tabs move back to Tabs.")
        }
        Button {
            model.sectionPrompt = .create(fileTabID: nil)
        } label: {
            Label("New Section", systemImage: "folder.badge.plus")
        }
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
    /// Asks for a section's name when `model.sectionPrompt` is set (New Section, Rename Section).
    func cantripSectionPrompt(model: CantripRemoteModel) -> some View {
        modifier(CantripSectionPromptModifier(model: model))
    }
}

private struct CantripSectionPromptModifier: ViewModifier {
    @ObservedObject var model: CantripRemoteModel
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(
                get: { model.sectionPrompt != nil },
                set: { if !$0 { model.sectionPrompt = nil } }
            ), presenting: model.sectionPrompt) { prompt in
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
            .onChange(of: model.sectionPrompt) { _, prompt in
                if case .rename(let section) = prompt { name = section.name } else { name = "" }
            }
    }

    private var title: String { model.sectionPrompt?.isRename == true ? "Rename Section" : "New Section" }
}

private extension CantripSectionPrompt {
    var isRename: Bool { if case .rename = self { return true } else { return false } }
}
