import SwiftUI

struct ServerSettingsSections: View {
    @ObservedObject var servers: ServerProfiles
    var canChangeSelection = true
    let add: (ServerDraft) async throws -> Void
    let select: (SavedServer) async throws -> Void
    let remove: (SavedServer) throws -> Void
    @StateObject private var form = ServerFormModel()
    @State private var selecting = false
    @State private var actionError: String?
    @State private var removing: SavedServer?
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
                Button {
                    editing = false
                    selecting = true
                    actionError = nil
                    Task {
                        defer { selecting = false }
                        do {
                            try await select(server)
                        } catch {
                            actionError = error.localizedDescription
                        }
                    }
                } label: {
                    SavedServerRow(server: server, isSelected: servers.selectedID == server.id)
                }
                .buttonStyle(.plain)
                .disabled(!canChangeSelection || selecting || form.saving)
                .contextMenu {
                    Button("Remove Server", systemImage: "trash", role: .destructive) {
                        removing = server
                    }
                    .disabled(!canChangeSelection || selecting || form.saving)
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { removing = server }
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
            Text("Tap a saved server to connect. One \(servers.kind.title) server is selected at a time. Swipe or touch and hold to remove a configuration; this does not delete work on the server.")
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
                : "Use each Mac's own pairing token. A saved HTTPS URL is preferred; automatic mode falls back to local discovery only when needed. Credentials stay in Keychain. Adding a server does not change your current connection.")
        }
        .disabled(form.saving || selecting || servers.loadIssue != nil)
    }
}

struct SavedServerRow: View {
    let server: SavedServer
    let isSelected: Bool

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
