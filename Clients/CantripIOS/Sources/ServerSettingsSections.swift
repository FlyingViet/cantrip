import SwiftUI

struct ServerSettingsSections: View {
    @ObservedObject var servers: ServerProfiles
    var canChangeSelection = true
    let add: (ServerDraft) async throws -> Void
    let select: (SavedServer) async throws -> Void
    let remove: (SavedServer) throws -> Void
    /// Saves a re-entered credential for a saved server and connects to it.
    let reenter: (SavedServer, String) async throws -> Void
    @StateObject private var form = ServerFormModel()
    @State private var selecting = false
    @State private var actionError: String?
    @State private var removing: SavedServer?
    @State private var reentering: SavedServer?
    @State private var reenteredCredential = ""
    @FocusState private var editing: Bool

    var body: some View {
        savedServers
        addServer
    }

    private var savedServers: some View {
        Section {
            if servers.servers.isEmpty {
                Text("No saved servers").foregroundStyle(.secondary)
            }
            ForEach(servers.servers) { server in
                let missing = servers.missingCredentialIDs.contains(server.id)
                Button {
                    editing = false
                    actionError = nil
                    // A saved server without its credential on this device asks for it instead.
                    if servers.isMissingCredential(server) {
                        askForCredential(server)
                        return
                    }
                    selecting = true
                    Task {
                        defer { selecting = false }
                        do {
                            try await select(server)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                } label: {
                    SavedServerRow(server: server, isSelected: servers.selectedID == server.id,
                                   missingCredential: missing ? servers.kind.credentialName : nil)
                }
                .buttonStyle(.plain)
                .disabled(!canChangeSelection || selecting || form.saving)
                .accessibilityHint(missing ? "Re-enter its \(servers.kind.credentialName) to connect" : "")
                .contextMenu {
                    Button("Re-enter \(servers.kind.credentialTitle)", systemImage: "key") {
                        askForCredential(server)
                    }
                    .disabled(!canChangeSelection || selecting || form.saving)
                    Button("Remove Server", systemImage: "trash", role: .destructive) {
                        removing = server
                    }
                    .disabled(!canChangeSelection || selecting || form.saving)
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { removing = server }
                        .disabled(!canChangeSelection || selecting || form.saving)
                    Button("Re-enter \(servers.kind.credentialTitle)", systemImage: "key") {
                        askForCredential(server)
                    }
                    .tint(.orange)
                    .disabled(!canChangeSelection || selecting || form.saving)
                }
            }
            if selecting { ProgressView("Selecting server...") }
            if let error = actionError ?? servers.loadIssue {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("\(servers.kind.title) Servers")
        } footer: {
            Text("Tap a saved server to connect. One \(servers.kind.title) server is selected at a time. Swipe or touch and hold to re-enter its \(servers.kind.credentialName) or remove a configuration; removing does not delete work on the server.")
        }
        .task { servers.refreshCredentialStatus() }
        .alert(
            "Re-enter \(servers.kind.credentialTitle)",
            isPresented: Binding(
                get: { reentering != nil },
                set: { if !$0 { reentering = nil } }
            ),
            presenting: reentering
        ) { server in
            SecureField(servers.kind.credentialTitle, text: $reenteredCredential)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save and Connect") { saveCredential(for: server) }
            Button("Cancel", role: .cancel) { reenteredCredential = "" }
        } message: { server in
            Text(servers.missingCredentialIDs.contains(server.id)
                 ? "\(server.name) is saved, but its \(servers.kind.credentialName) isn't on this device. Enter it to reconnect. It stays in this device's Keychain."
                 : "Enter \(server.name)'s new \(servers.kind.credentialName). It replaces the saved one and reconnects.")
        }
        .confirmationDialog("Remove server?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            if let server = removing {
                Button("Remove \(server.name)", role: .destructive) {
                    do {
                        try remove(server)
                        actionError = nil
                    } catch {
                        actionError = error.localizedDescription
                    }
                    removing = nil
                }
            }
        } message: {
            Text("Only this saved configuration and its credential will be removed. An active connection to it will disconnect.")
        }
    }

    private func askForCredential(_ server: SavedServer) {
        editing = false
        reenteredCredential = ""
        reentering = server
    }

    private func saveCredential(for server: SavedServer) {
        let credential = reenteredCredential
        reenteredCredential = ""
        selecting = true
        actionError = nil
        Task {
            defer { selecting = false }
            do {
                try await reenter(server, credential)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private var addServer: some View {
        Section {
            TextField("Server name (optional)", text: $form.draft.name)
                .focused($editing)
            TextField(
                servers.kind == .hermes
                    ? "https://your-private-gateway.example.com"
                    : "Tailscale URL (optional)",
                text: $form.draft.url
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .focused($editing)
            SecureField(
                servers.kind == .hermes ? "API key (API_SERVER_KEY)" : "Pairing token",
                text: $form.draft.credential
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($editing)
            if servers.kind == .cantrip {
                TextField("Direct address, e.g. \(CantripDirectAddress.example)",
                          text: $form.draft.directAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .focused($editing)
                    .accessibilityHint("The Mac's IP address and direct port from its Remote control settings")
                Toggle("Tailscale only (skip local network)", isOn: $form.draft.tailscaleOnly)
            }
            Button("Add Server", systemImage: "plus.circle") {
                editing = false
                Task { await form.save(using: add) }
            }
            .disabled(form.draft.credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || (servers.kind == .hermes && form.draft.url.isEmpty))
            if form.saving { ProgressView("Saving server...") }
            if form.saved, form.draft == ServerDraft() {
                Label("Server saved. Select it above to connect.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            }
            if let error = form.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Add \(servers.kind.title)")
        } footer: {
            Text(servers.kind == .hermes
                ? "Use HTTPS through a private network or authenticated tunnel. Each server keeps its own API key and conversation history. Adding a server does not change your current connection."
                : "Use each Mac's own pairing token. A saved HTTPS URL is preferred; automatic mode falls back to local discovery only when needed. A direct address (the Mac's IP and the direct port set in its Remote control settings) reaches a Mac without Tailscale, end-to-end encrypted, wherever this device can route to it, such as through a home router's Tailscale subnet route. Credentials stay in Keychain. Adding a server does not change your current connection.")
        }
        .disabled(form.saving || selecting || servers.loadIssue != nil)
    }
}

struct SavedServerRow: View {
    let server: SavedServer
    let isSelected: Bool
    /// The credential's name (e.g. "pairing token") when this device doesn't have it.
    var missingCredential: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).foregroundStyle(.primary)
                Text(server.address).font(.caption).foregroundStyle(.secondary)
                if isSelected {
                    Text("Selected").font(.caption).foregroundStyle(.tint)
                }
                if let missingCredential {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "key.slash").foregroundStyle(.orange)
                        Text("\(missingCredential.prefix(1).uppercased())\(missingCredential.dropFirst()) missing")
                            .foregroundStyle(.primary)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
