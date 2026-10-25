import SwiftUI

/// What a tab's action menu shows, snapshotted so menus rebuild only when it changes.
struct CantripTabActionState: Equatable {
    let id: String
    let isLocked: Bool
    let isLocalPrivate: Bool
    let supportsTabMetadata: Bool
    let supportsTabReordering: Bool
    let supportsInputRequests: Bool
    /// Nil from Macs before Start Fresh; false where it doesn't apply (Cantrip Home).
    let supportsStartFresh: Bool?
    let isBusy: Bool
    let isFirst: Bool
    let isLast: Bool
    let isMutating: Bool
    /// Sections it can be filed under; empty when the Mac has none or can't file this tab.
    let sections: [CantripTabSection]
    let canFileInSection: Bool
    let sectionID: String?
    /// A child tab's parent (it stays under it until its work merges).
    let parentID: String?
    let parentTitle: String?

    @MainActor
    init(session: CantripRemoteSession, model: CantripRemoteModel) {
        id = session.id
        isLocked = session.isLocked == true
        isLocalPrivate = session.isLocalPrivate == true
        supportsTabMetadata = session.supportsTabMetadata == true
        supportsTabReordering = session.supportsTabReordering == true
        supportsInputRequests = session.supportsInputRequests == true
        supportsStartFresh = CantripStartFresh.support(for: session)
        isBusy = session.isStreaming || session.queuedCount > 0
        isFirst = model.sessions.first?.id == session.id
        isLast = model.sessions.last?.id == session.id
        isMutating = model.isMutating
        canFileInSection = model.supportsTabSections && session.supportsTabSections == true
        sections = canFileInSection ? model.tabSections : []
        sectionID = CantripTabGrouping.sectionID(of: session, sections: model.tabSections)
        parentID = session.parentID
        parentTitle = session.child?.parentTitle
    }
}

struct CantripTabActions: View {
    let model: CantripRemoteModel
    let state: CantripTabActionState
    let onRename: () -> Void
    let onClose: () -> Void
    /// Opens another tab (a child tab's parent); nil hides Open Parent Tab.
    var onOpenTab: ((String) -> Void)? = nil

    init(model: CantripRemoteModel, state: CantripTabActionState,
         onRename: @escaping () -> Void, onClose: @escaping () -> Void,
         onOpenTab: ((String) -> Void)? = nil) {
        self.model = model
        self.state = state
        self.onRename = onRename
        self.onClose = onClose
        self.onOpenTab = onOpenTab
    }

    @MainActor
    init(model: CantripRemoteModel, session: CantripRemoteSession,
         onRename: @escaping () -> Void, onClose: @escaping () -> Void,
         onOpenTab: ((String) -> Void)? = nil) {
        self.init(model: model, state: CantripTabActionState(session: session, model: model),
                  onRename: onRename, onClose: onClose, onOpenTab: onOpenTab)
    }

    var body: some View {
        if let parentID = state.parentID, let onOpenTab {
            Button {
                onOpenTab(parentID)
            } label: {
                Label("Open Parent Tab", systemImage: CantripChildTabStyle.glyph)
            }
            Divider()
        }
        Button {
            model.showingMacAccess = true
        } label: {
            Label("Mac Permissions & View Mac", systemImage: "display")
        }
        if state.supportsInputRequests {
            Button {
                Task { await model.showInputRequests(sessionID: state.id) }
            } label: {
                Label("View Questions in Chat", systemImage: "person.crop.circle.badge.questionmark")
            }
            if !state.isLocalPrivate {
                Button {
                    Task { await model.send("/login github", mode: .queue, sessionID: state.id) }
                } label: {
                    Label("Sign in to GitHub on Mac", systemImage: "person.badge.key")
                }
                .disabled(state.isMutating || state.isBusy)
            }
        }
        Button {
            model.modelSettingsSession = model.sessions.first { $0.id == state.id }
                ?? (model.selectedSession?.id == state.id ? model.selectedSession : nil)
        } label: {
            Label(state.isLocalPrivate ? "Private Local Settings" : "Model Settings", systemImage: "slider.horizontal.3")
        }
        .disabled(state.isMutating)
        CantripStartFreshMenuItem(model: model, sessionID: state.id, support: state.supportsStartFresh,
                                  isDisabled: state.isMutating || state.isBusy)
        Button(action: onRename) {
            Label("Rename Tab", systemImage: "pencil")
        }
        .disabled(state.isMutating || !state.supportsTabMetadata)
        Button {
            Task { await model.updateTab(state.id, isLocked: !state.isLocked) }
        } label: {
            Label(state.isLocked ? "Unlock Tab" : "Lock Tab",
                  systemImage: state.isLocked ? "lock.open" : "lock")
        }
        .disabled(state.isMutating || !state.supportsTabMetadata || state.isLocalPrivate)
        if state.canFileInSection {
            Menu {
                Picker("Section", selection: Binding(
                    get: { state.sectionID ?? CantripTabGrouping.looseID },
                    set: { picked in
                        Task { await model.fileTab(state.id, in: picked == CantripTabGrouping.looseID ? nil : picked) }
                    }
                )) {
                    Text("Tabs").tag(CantripTabGrouping.looseID)
                    ForEach(state.sections) { section in
                        Text(section.name).tag(section.id)
                    }
                }
                .pickerStyle(.inline)
                Button {
                    model.sectionPrompt = .create(fileTabID: state.id)
                } label: {
                    Label("New Section", systemImage: "folder.badge.plus")
                }
                Button {
                    model.editingSections = true
                } label: {
                    Label("Edit Sections…", systemImage: "list.bullet")
                }
            } label: {
                Label("Move to Section", systemImage: "folder")
            }
            .disabled(state.isMutating)
        }
        if state.isLocalPrivate {
            Text("Permanent tab. History saved; self-hosted models only.")
        }
        if !state.supportsTabMetadata {
            Text("Update and reopen Cantrip to rename or lock tabs.")
        }
        Divider()
        if state.supportsTabReordering {
            Button {
                Task { await model.moveTab(state.id, offset: -1) }
            } label: {
                Label("Move Tab Up", systemImage: "arrow.up")
            }
            .disabled(state.isMutating || state.isFirst)
            Button {
                Task { await model.moveTab(state.id, offset: 1) }
            } label: {
                Label("Move Tab Down", systemImage: "arrow.down")
            }
            .disabled(state.isMutating || state.isLast)
        } else if state.parentID != nil {
            Text("Child tab of \(state.parentTitle ?? "another tab"). It stays under it until its work merges.")
        } else {
            Text("Update and reopen Cantrip to reorder tabs.")
        }
        Divider()
        Button(role: .destructive, action: onClose) {
            Label("Close Tab", systemImage: "xmark")
        }
        .disabled(state.isMutating || state.isLocked)
    }
}

struct CantripTabRenameSheet: View {
    @ObservedObject var model: CantripRemoteModel
    let session: CantripRemoteSession
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(model: CantripRemoteModel, session: CantripRemoteSession) {
        self.model = model
        self.session = session
        _name = State(initialValue: session.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? session.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tab name", text: $name)
                        .disabled(saving)
                } footer: {
                    Text("Up to 80 characters. Leave blank to use the automatic name.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.orange)
                }
            }
            .navigationTitle("Rename Tab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            if await model.updateTab(session.id, name: name) {
                                dismiss()
                            } else {
                                errorMessage = model.errorMessage ?? "The tab could not be renamed."
                            }
                            saving = false
                        }
                    }
                    .disabled(saving || model.isMutating)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }
}
