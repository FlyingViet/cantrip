import SwiftUI

/// Edit Sections (a tab's Move to Section menu): rename, reorder and delete the Mac's tab sections,
/// or add one. Every device shows the same names and order.
struct TabSectionsEditor: View {
    @ObservedObject var manager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var error: String?
    @State private var deleting: TabSection?
    @State private var renaming: TabSection?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Sections").font(.headline)
            Text("Drag a section, or use its arrows, to change the order. Names and order show on every device.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if manager.tabSections.isEmpty {
                Text("No sections yet. Add one below, or use a tab's Move to Section menu.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(manager.tabSections.enumerated()), id: \.element.id) { index, section in
                        row(section, index: index)
                    }
                    .onMove(perform: move)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .accessibilityLabel("Sections")
            }
            HStack {
                TextField("New section name", text: $newName)
                    .onSubmit(create)
                Button("Add Section", action: create)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            Text("Deleting a section moves its tabs back to Tabs.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 440)
        .alert("Rename Section", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { section in
            TextField("Section name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = renameText
                perform(nil) { try manager.renameSection(section.id, to: name) }
            }
        } message: { _ in
            Text("Up to \(TabSectionStore.maximumNameLength) characters.")
        }
        .confirmationDialog(deleting.map { "Delete \u{201C}\($0.name)\u{201D}?" } ?? "", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { section in
            Button("Delete Section", role: .destructive) {
                perform("Deleted \(section.name)") { try manager.deleteSection(section.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { section in
            let count = tabCount(section)
            Text(count == 0 ? "It has no tabs." : "Its \(count == 1 ? "tab moves" : "\(count) tabs move") back to Tabs.")
        }
    }

    private func row(_ section: TabSection, index: Int) -> some View {
        let last = manager.tabSections.count - 1
        let count = tabCount(section)
        return HStack(spacing: 8) {
            Text(section.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(count == 1 ? "1 tab" : "\(count) tabs")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button { promptRename(section) } label: { Image(systemName: "pencil") }
                .help("Rename Section")
                .accessibilityLabel("Rename \(section.name)")
            Button { move(section, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Move Up")
                .accessibilityLabel("Move \(section.name) up")
            Button { move(section, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == last)
                .help("Move Down")
                .accessibilityLabel("Move \(section.name) down")
            Button { deleting = section } label: { Image(systemName: "trash") }
                .help("Delete Section")
                .accessibilityLabel("Delete \(section.name)")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help("Drag to reorder. Double-click to rename.")
        .onTapGesture(count: 2) { promptRename(section) }
        .contextMenu {
            Button("Rename Section...") { promptRename(section) }
            Divider()
            Button("Move Up") { move(section, by: -1) }.disabled(index == 0)
            Button("Move Down") { move(section, by: 1) }.disabled(index == last)
            Divider()
            Button("Delete Section...", role: .destructive) { deleting = section }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.name), \(count == 1 ? "1 tab" : "\(count) tabs"), section \(index + 1) of \(last + 1)")
    }

    private func tabCount(_ section: TabSection) -> Int {
        manager.sessions.filter { manager.sectionID(of: $0) == section.id }.count
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        guard offsets.count == 1, let source = offsets.first, manager.tabSections.indices.contains(source) else { return }
        let section = manager.tabSections[source]
        let position = TabSectionStore.position(movingFrom: source, to: destination)
        guard position != source else { return }
        perform(announcement(section, position)) { try manager.moveSection(section.id, to: position) }
    }

    private func move(_ section: TabSection, by offset: Int) {
        guard let index = manager.tabSections.firstIndex(where: { $0.id == section.id }),
              manager.tabSections.indices.contains(index + offset) else { return }
        perform(announcement(section, index + offset)) { try manager.moveSection(section.id, to: index + offset) }
    }

    private func announcement(_ section: TabSection, _ position: Int) -> String {
        "Moved \(section.name) to position \(position + 1) of \(manager.tabSections.count)"
    }

    private func promptRename(_ section: TabSection) {
        renameText = section.name
        renaming = section
    }

    private func create() {
        let name = newName
        perform(nil) {
            try manager.createSection(named: name)
            newName = ""
        }
    }

    private func perform(_ announcement: String?, _ change: () throws -> Void) {
        do {
            try change()
            error = nil
            if let announcement { AccessibilityNotification.Announcement(announcement).post() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
