import SwiftUI

/// One section of a grouped workspace list, holding its records in saved order.
struct CantripHomeWorkspaceSection: Identifiable, Equatable {
    /// Key for the remembered collapse state: the group's title, or `otherID`.
    let id: String
    let title: String
    let records: [CantripHomeTaskRecord]
    let startsCollapsed: Bool
}

/// Splits a workspace list into the sections its `list.groupField` declares.
enum CantripHomeWorkspaceGrouping {
    static let otherID = "\u{1}other"

    /// Nil when the workspace isn't grouped. Explicit groups always show (with a count of 0
    /// when empty); one-per-option sections and Other only show when they have records.
    /// While searching, only sections with matches remain.
    static func sections(
        for workspace: CantripHomeTaskWorkspace, records: [CantripHomeTaskRecord],
        searching: Bool = false
    ) -> [CantripHomeWorkspaceSection]? {
        guard let key = workspace.list.groupField else { return nil }
        let explicit = workspace.list.groups
        let groups = explicit ?? (
            workspace.fields.first { $0.key == key }?.options ?? []
        ).map { CantripHomeTaskListGroup(title: $0, values: [$0]) }
        var groupIndex: [String: Int] = [:]
        for (index, group) in groups.enumerated() {
            for value in group.values where groupIndex[value] == nil {
                groupIndex[value] = index
            }
        }
        var buckets = Array(repeating: [CantripHomeTaskRecord](), count: groups.count)
        var other: [CantripHomeTaskRecord] = []
        for record in records {
            if let value = record.values[key], let index = groupIndex[value] {
                buckets[index].append(record)
            } else {
                other.append(record)
            }
        }
        var sections = zip(groups, buckets).map { group, records in
            CantripHomeWorkspaceSection(
                id: group.title, title: group.title, records: records,
                startsCollapsed: group.collapsed ?? false
            )
        }
        if explicit == nil {
            sections.removeAll { $0.records.isEmpty }
        }
        if !other.isEmpty {
            sections.append(.init(id: otherID, title: "Other", records: other, startsCollapsed: false))
        }
        if searching {
            sections.removeAll { $0.records.isEmpty }
        }
        return sections
    }
}

/// The sections a user collapsed or expanded, remembered per task on this device.
enum CantripHomeWorkspaceGroupState {
    static func key(taskID: UUID) -> String {
        "cantripHome.workspaceGroups.\(taskID.uuidString)"
    }

    static func load(taskID: UUID, defaults: UserDefaults = .standard) -> [String: Bool] {
        defaults.dictionary(forKey: key(taskID: taskID)) as? [String: Bool] ?? [:]
    }

    static func save(_ collapsed: [String: Bool], taskID: UUID, defaults: UserDefaults = .standard) {
        if collapsed.isEmpty {
            defaults.removeObject(forKey: key(taskID: taskID))
        } else {
            defaults.set(collapsed, forKey: key(taskID: taskID))
        }
    }
}

/// A section header that collapses its records, with the section's record count.
struct CantripHomeWorkspaceSectionHeader: View {
    #if os(iOS)
    private static let horizontalInset: CGFloat = 16
    #else
    private static let horizontalInset: CGFloat = 10
    #endif

    let title: String
    let count: Int
    let noun: String
    let expanded: Bool
    /// Search keeps every section with matches open, so the header doesn't toggle.
    let searching: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                // List headers dim their content; the title stays full strength.
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text(count, format: .number)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.16), in: Capsule())
                Spacer(minLength: 8)
                if !searching {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, Self.horizontalInset)
            .contentShape(Rectangle())
            // Plain lists pin headers over the rows scrolling beneath them.
            .background(.background)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .allowsHitTesting(!searching)
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) \(noun)")
        .accessibilityValue(searching ? "" : expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(searching ? "" : expanded ? "Collapses this section." : "Expands this section.")
        .accessibilityAddTraits(searching ? .isHeader : [.isHeader, .isButton])
        .accessibilityIdentifier("workspace.section.\(title)")
    }
}
