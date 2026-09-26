import SwiftUI

struct CantripMacMenuActions: View {
    // Not observed: polling would rebuild the open menu and reset its scroll.
    // The enclosing StableMenu rebuilds this section when `isConfigured` changes.
    let remote: CantripRemoteModel
    @Binding var showingMaintenance: Bool
    let isEnabled: Bool
    let onOpen: () -> Void

    init(remote: CantripRemoteModel, showingMaintenance: Binding<Bool>, onOpen: @escaping () -> Void) {
        self.remote = remote
        _showingMaintenance = showingMaintenance
        isEnabled = remote.isConfigured
        self.onOpen = onOpen
    }

    var body: some View {
        Section("Cantrip Mac") {
            Button(action: openMacAccess) {
                Label("Mac Permissions & View Mac", systemImage: "display")
            }
            .accessibilityIdentifier("chat.macAccess")
            Button(action: openMaintenance) {
                Label("Update & Rebuild Cantrip", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("chat.cantripMaintenance")
        }
        .disabled(!isEnabled)
    }

    func openMacAccess() {
        onOpen()
        remote.showingMacAccess = true
    }

    func openMaintenance() {
        onOpen()
        showingMaintenance = true
    }
}

struct CantripMaintenanceSheet: View {
    @ObservedObject var remote: CantripRemoteModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CantripMaintenanceView(remote: remote)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .onChange(of: remote.usageIdentity) { _, _ in dismiss() }
        .onChange(of: remote.notificationNavigationID) { _, _ in dismiss() }
    }
}
