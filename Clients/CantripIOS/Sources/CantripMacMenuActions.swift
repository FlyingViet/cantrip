import SwiftUI

struct CantripMacMenuActions: View {
    @ObservedObject var remote: CantripRemoteModel
    @Binding var showingMaintenance: Bool
    let onOpen: () -> Void

    var isEnabled: Bool { remote.isConfigured }

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
