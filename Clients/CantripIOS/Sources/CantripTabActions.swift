import SwiftUI

struct CantripTabActions: View {
    @ObservedObject var model: CantripRemoteModel
    let session: CantripRemoteSession
    let onRename: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onRename) {
            Label("Rename Tab", systemImage: "pencil")
        }
        .disabled(model.isMutating || session.supportsTabMetadata != true)
        Button {
            Task { await model.updateTab(session.id, isLocked: session.isLocked != true) }
        } label: {
            Label(session.isLocked == true ? "Unlock Tab" : "Lock Tab",
                  systemImage: session.isLocked == true ? "lock.open" : "lock")
        }
        .disabled(model.isMutating || session.supportsTabMetadata != true)
        if session.supportsTabMetadata != true {
            Text("Update and reopen Cantrip to rename or lock tabs.")
        }
        Divider()
        Button(role: .destructive, action: onClose) {
            Label("Close Session", systemImage: "xmark")
        }
        .disabled(model.isMutating || session.isLocked == true)
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
