import SwiftUI

/// Edit Sections: every section in the Mac's order, to rename, reorder, delete or add. Drag rows to
/// reorder (iOS: the ≡ handles); Move Up and Move Down are in each row's menu and VoiceOver
/// actions (Mac: its arrows). Names and order sync to every device. Shown by
/// `cantripSectionPrompt(model:)` when `model.editingSections` is set.
struct CantripTabSectionsEditor: View {
    @ObservedObject var model: CantripRemoteModel
    @Environment(\.dismiss) private var dismiss
    /// Rename or New Section, asked inside this sheet (the app's alert can't show over it).
    @State private var prompt: CantripSectionPrompt?
    @State private var deleting: CantripTabSection?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.tabSections.isEmpty {
                        Text("No sections yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.tabSections.enumerated()), id: \.element.id) { index, section in
                        row(section, index: index)
                    }
                    .onMove(perform: move)
                    #if os(iOS)
                    .onDelete { offsets in
                        if let index = offsets.first, model.tabSections.indices.contains(index) {
                            confirmDelete(model.tabSections[index])
                        }
                    }
                    #endif
                } footer: {
                    Text(footer)
                }
                Section {
                    Button {
                        prompt = .create(fileTabID: nil)
                    } label: {
                        Label("New Section", systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("sections.editor.new")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("Edit Sections")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("sections.editor.done")
                }
                if model.isMutating {
                    ToolbarItem(placement: .cancellationAction) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving")
                    }
                }
            }
        }
        .cantripSectionPrompt(model: model, prompt: $prompt)
        .confirmationDialog(deleting.map { "Delete \u{201C}\($0.name)\u{201D}?" } ?? "Delete Section?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { section in
            Button("Delete Section", role: .destructive) { delete(section) }
            Button("Cancel", role: .cancel) {}
        } message: { section in
            let count = tabCount(section)
            Text("Its \(count == 1 ? "tab moves" : "\(count) tabs move") back to Tabs.")
        }
        .onChange(of: model.errorMessage) { _, message in
            if let message { error = message }
        }
        .onAppear { error = nil }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 460, minHeight: 400, idealHeight: 460)
        #endif
        .accessibilityIdentifier("sections.editor")
    }

    private var footer: String {
        #if os(iOS)
        "Drag ≡ to reorder. Tap a section to rename it. Names and order show on every device; deleting a section moves its tabs back to Tabs."
        #else
        // One line in a macOS list footer; Delete's confirmation says where the tabs go.
        "Drag or use the arrows to reorder. Changes show on every device."
        #endif
    }

    @ViewBuilder private func row(_ section: CantripTabSection, index: Int) -> some View {
        let last = model.tabSections.count - 1
        let count = tabCount(section)
        let tabs = count == 1 ? "1 tab" : "\(count) tabs"
        #if os(iOS)
        Button {
            prompt = .rename(section)
        } label: {
            HStack {
                Text(section.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(tabs)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        // Plain, so names read as text rather than links.
        .buttonStyle(.plain)
        .contextMenu { rowMenu(section, index: index, last: last) }
        .accessibilityLabel("\(section.name), \(tabs)")
        .accessibilityValue("Section \(index + 1) of \(last + 1)")
        .accessibilityHint("Renames the section. Actions move or delete it.")
        .accessibilityActions { rowActions(section, index: index, last: last) }
        .accessibilityIdentifier("sections.editor.row.\(section.id)")
        #else
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
                .accessibilityHidden(true)
            Text(section.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(tabs)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { prompt = .rename(section) } label: { Image(systemName: "pencil") }
                .help("Rename Section")
                .accessibilityLabel("Rename \(section.name)")
            Button { move(section, to: index - 1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
                .help("Move Up")
                .accessibilityLabel("Move \(section.name) up")
            Button { move(section, to: index + 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == last)
                .help("Move Down")
                .accessibilityLabel("Move \(section.name) down")
            Button { confirmDelete(section) } label: { Image(systemName: "trash") }
                .help("Delete Section")
                .accessibilityLabel("Delete \(section.name)")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { prompt = .rename(section) }
        .contextMenu { rowMenu(section, index: index, last: last) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.name), \(tabs), section \(index + 1) of \(last + 1)")
        .accessibilityIdentifier("sections.editor.row.\(section.id)")
        #endif
    }

    @ViewBuilder private func rowMenu(_ section: CantripTabSection, index: Int, last: Int) -> some View {
        Button { prompt = .rename(section) } label: { Label("Rename Section", systemImage: "pencil") }
        Divider()
        Button { move(section, to: index - 1) } label: { Label("Move Up", systemImage: "arrow.up") }
            .disabled(index == 0)
        Button { move(section, to: index + 1) } label: { Label("Move Down", systemImage: "arrow.down") }
            .disabled(index == last)
        Divider()
        Button(role: .destructive) { confirmDelete(section) } label: { Label("Delete Section", systemImage: "trash") }
    }

    @ViewBuilder private func rowActions(_ section: CantripTabSection, index: Int, last: Int) -> some View {
        if index > 0 { Button("Move Up") { move(section, to: index - 1) } }
        if index < last { Button("Move Down") { move(section, to: index + 1) } }
        Button("Delete Section") { confirmDelete(section) }
    }

    private func tabCount(_ section: CantripTabSection) -> Int {
        model.sessions.filter { $0.sectionID == section.id }.count
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        guard offsets.count == 1, let source = offsets.first, model.tabSections.indices.contains(source) else { return }
        move(model.tabSections[source], to: CantripTabGrouping.sectionPosition(movingFrom: source, to: destination))
    }

    private func move(_ section: CantripTabSection, to position: Int) {
        guard model.tabSections.indices.contains(position) else { return }
        error = nil
        let total = model.tabSections.count
        Task {
            if await model.moveSection(section.id, to: position) {
                AccessibilityNotification.Announcement("Moved \(section.name) to position \(position + 1) of \(total)").post()
            }
        }
    }

    /// Sections with tabs ask first (their tabs move back to Tabs); empty ones go at once.
    private func confirmDelete(_ section: CantripTabSection) {
        if tabCount(section) == 0 { delete(section) } else { deleting = section }
    }

    private func delete(_ section: CantripTabSection) {
        error = nil
        Task {
            if await model.deleteSection(section.id) {
                AccessibilityNotification.Announcement("Deleted \(section.name)").post()
            }
        }
    }
}
