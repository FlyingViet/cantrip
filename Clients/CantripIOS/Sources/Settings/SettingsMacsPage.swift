import SwiftUI

/// Settings › Macs: the Macs this device is paired with, like a linked-devices list. Each row
/// shows whether it's the active Mac and when this device last reached it; its page switches to
/// it, re-enters its pairing token or removes it. Hermes gateways show below while a Hermes
/// backend is in the picker.
struct SettingsMacsPage: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel
    var canChangeGateway = true
    @ObservedObject private var servers: ServerProfiles
    @State private var pairing = false

    init(env: HermesEnv, remote: CantripRemoteModel, canChangeGateway: Bool = true) {
        self.env = env
        self.remote = remote
        self.canChangeGateway = canChangeGateway
        _servers = ObservedObject(wrappedValue: remote.servers)
    }

    var body: some View {
        Form {
            Section { SettingsScopeLabel.thisDevice() }
            Section {
                if servers.servers.isEmpty {
                    Text("No Mac paired yet.").foregroundStyle(.secondary)
                }
                ForEach(servers.servers) { mac in
                    NavigationLink {
                        SettingsMacDetail(remote: remote, macID: mac.id, canChange: canChangeGateway)
                            .settingsBack(to: SettingsPage.macs.title)
                    } label: {
                        SettingsMacRow(
                            mac: mac,
                            isActive: servers.selectedID == mac.id,
                            isLocal: remote.localServerID == mac.id,
                            status: status(of: mac)
                        )
                    }
                    .accessibilityIdentifier("settings.mac.\(mac.name)")
                }
                Button {
                    pairing = true
                } label: {
                    Label("Pair a Mac", systemImage: "plus.circle")
                }
                .disabled(!canChangeGateway || servers.loadIssue != nil)
                .accessibilityIdentifier("settings.pairMac")
            } header: {
                Text("Macs")
            } footer: {
                Text("This device works with one Mac at a time. Tap a Mac to switch to it, re-enter its pairing token, or remove it. Pairing tokens stay in this device's Keychain.")
            }
            if let issue = servers.loadIssue ?? remote.errorMessage {
                Section {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            SettingsManifestSections(page: "macs")
            if env.hermesLanesShown {
                ServerSettingsSections(
                    servers: env.servers,
                    canChangeSelection: canChangeGateway,
                    add: { try env.addServer($0) },
                    select: {
                        try env.selectServer($0)
                        _ = await env.refreshGateway()
                    },
                    remove: env.removeServer,
                    reenter: {
                        try env.reenterCredential($1, for: $0)
                        _ = await env.refreshGateway()
                    }
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Macs")
        .navigationBarTitleDisplayMode(.inline)
        .task { servers.refreshCredentialStatus() }
        .sheet(isPresented: $pairing) {
            SettingsPairMacSheet(remote: remote)
        }
    }

    private func status(of mac: SavedServer) -> SettingsMacRow.Status {
        if servers.missingCredentialIDs.contains(mac.id) { return .missingToken }
        if servers.selectedID == mac.id { return remote.isConnected ? .connected(remote.routeLabel) : .connecting(remote.connectionLabel) }
        return mac.lastConnectedAt.map(SettingsMacRow.Status.lastSeen) ?? .neverConnected
    }
}

/// A Mac's row: its name, an Active badge for the one in use, and how it's doing.
struct SettingsMacRow: View {
    enum Status: Equatable {
        case connected(String)
        case connecting(String)
        case lastSeen(Date)
        case neverConnected
        case missingToken

        var text: String {
            switch self {
            case .connected(let route): return "Connected · \(route)"
            case .connecting(let label): return label
            case .lastSeen(let date): return "Last seen \(date.formatted(.relative(presentation: .named)))"
            case .neverConnected: return "Not connected yet"
            case .missingToken: return "Pairing token missing on this device"
            }
        }

        var color: Color {
            switch self {
            case .connected: return .green
            case .missingToken: return .orange
            default: return .secondary
            }
        }
    }

    let mac: SavedServer
    let isActive: Bool
    /// The Cantrip running on this device (Cantrip.app's Home window).
    var isLocal = false
    let status: Status

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mac.name)
                    if isActive {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                Text(isLocal ? "Cantrip on this Mac · \(status.text)" : status.text)
                    .font(.caption)
                    .foregroundStyle(status.color)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// One Mac: switch to it, re-enter its pairing token, its addresses under Advanced, and Remove.
struct SettingsMacDetail: View {
    @ObservedObject var remote: CantripRemoteModel
    let macID: UUID
    var canChange = true
    @ObservedObject private var servers: ServerProfiles
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?
    @State private var reentering = false
    @State private var token = ""
    @State private var confirmingRemove = false

    init(remote: CantripRemoteModel, macID: UUID, canChange: Bool = true) {
        self.remote = remote
        self.macID = macID
        self.canChange = canChange
        _servers = ObservedObject(wrappedValue: remote.servers)
    }

    private var mac: SavedServer? { servers.servers.first { $0.id == macID } }
    private var isActive: Bool { servers.selectedID == macID }
    private var missingToken: Bool { servers.missingCredentialIDs.contains(macID) }
    private var isLocal: Bool { remote.localServerID == macID }

    var body: some View {
        Form {
            if let mac {
                Section {
                    LabeledContent("Name", value: mac.name)
                    LabeledContent("Status", value: statusText(mac))
                    if !isActive {
                        Button("Use This Mac", systemImage: "checkmark.circle") { use(mac) }
                            .disabled(!canChange || working || missingToken)
                            .accessibilityIdentifier("settings.mac.use")
                    }
                } footer: {
                    Text(isLocal
                         ? "The Cantrip running on this Mac. Its address and token come from Cantrip itself."
                         : isActive
                         ? "This device uses this Mac now."
                         : "Switching moves this device's tabs, Home and settings to this Mac.")
                }
                if !isLocal {
                    Section {
                        Button("Re-enter Pairing Token", systemImage: "key") {
                            token = ""
                            reentering = true
                        }
                        .disabled(!canChange || working)
                        .accessibilityIdentifier("settings.mac.reenter")
                    } footer: {
                        Text(missingToken
                             ? "This Mac's pairing token isn't on this device, for example after moving to a new one. Enter it to connect again."
                             : "Use this when the Mac's pairing token changed. It replaces the saved one and reconnects.")
                    }
                    Section {
                        LabeledContent("Address", value: mac.url.isEmpty ? "Local network discovery" : mac.url)
                        LabeledContent("Direct address", value: mac.directAddress ?? "None")
                        LabeledContent("Tailscale only", value: mac.tailscaleOnly ? "On" : "Off")
                    } header: {
                        Text("Advanced")
                    } footer: {
                        Text("How this device reaches the Mac. To change them, remove the Mac and pair it again.")
                    }
                    Section {
                        Button("Remove Mac…", systemImage: "trash", role: .destructive) { confirmingRemove = true }
                            .disabled(!canChange || working)
                            .accessibilityIdentifier("settings.mac.remove")
                    } footer: {
                        Text("Removes this pairing and its token from this device. Nothing on the Mac is deleted.")
                    }
                }
                if working { ProgressView() }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mac?.name ?? "Mac")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Re-enter Pairing Token", isPresented: $reentering) {
            SecureField("Pairing token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save and Connect") { saveToken() }
            Button("Cancel", role: .cancel) { token = "" }
        } message: {
            Text("Find it in Cantrip's Settings › Remote control on the Mac. It stays in this device's Keychain.")
        }
        .confirmationDialog("Remove \(mac?.name ?? "this Mac")?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device forgets the pairing and its token. If it's the Mac in use, this device disconnects.")
        }
    }

    private func statusText(_ mac: SavedServer) -> String {
        if missingToken { return "Pairing token missing" }
        if isActive { return remote.isConnected ? "Connected · \(remote.routeLabel)" : remote.connectionLabel }
        return mac.lastConnectedAt.map { "Last seen \($0.formatted(.relative(presentation: .named)))" } ?? "Not connected yet"
    }

    private func use(_ mac: SavedServer) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await remote.selectServer(mac) } catch { self.error = error.localizedDescription }
        }
    }

    private func saveToken() {
        guard let mac else { return }
        let entered = token
        token = ""
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await remote.reenterCredential(entered, for: mac) } catch { self.error = error.localizedDescription }
        }
    }

    private func remove() {
        guard let mac else { return }
        do {
            try remote.removeServer(mac)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Pair a Mac, step by step: where to find the token on the Mac, the token, then the optional
/// addresses under Advanced. The first Mac paired becomes the active one.
struct SettingsPairMacSheet: View {
    @ObservedObject var remote: CantripRemoteModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = ServerFormModel()
    @State private var showsAdvanced = false
    @State private var paired: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("On your Mac, open Cantrip, then Settings › Remote control. Turn it on and copy the pairing token. A pairing link from `cantrip pair` opened on this device fills this in for you.")
                        .font(.callout)
                } header: {
                    Text("1. On your Mac")
                }
                Section {
                    TextField("Name, for example Studio (optional)", text: $form.draft.name)
                    SecureField("Pairing token", text: $form.draft.credential)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pair.token")
                    TextField("Tailscale address (optional)", text: $form.draft.url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("2. Enter the token")
                } footer: {
                    Text("With a Tailscale address this device reaches the Mac from anywhere; without one, only on the same network. Tokens stay in this device's Keychain.")
                }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        TextField("Direct address, e.g. \(CantripDirectAddress.example)", text: $form.draft.directAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                            .accessibilityHint("The Mac's IP address and direct port from its Remote control settings")
                        Toggle("Tailscale only (skip the local network)", isOn: $form.draft.tailscaleOnly)
                    }
                } footer: {
                    Text("A direct address reaches the Mac without Tailscale, still encrypted, wherever this device can route to it, such as through a home router's Tailscale subnet route.")
                }
                Section {
                    Button("Pair", systemImage: "checkmark.circle", action: pair)
                        .disabled(form.saving || form.draft.credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("pair.save")
                    if form.saving { ProgressView("Pairing…") }
                    if let paired {
                        Label(paired, systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                    if let error = form.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } header: {
                    Text("3. Pair")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(paired == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    private func pair() {
        let before = Set(remote.servers.servers.map(\.id))
        Task {
            await form.save { try remote.addServer($0) }
            guard let added = remote.servers.servers.first(where: { !before.contains($0.id) }) else { return }
            // The first Mac becomes the active one; another waits until you switch to it.
            if remote.servers.selectedID == nil {
                do {
                    try await remote.selectServer(added)
                    paired = "Paired with \(added.name)."
                } catch {
                    paired = "Saved \(added.name), but it didn't connect: \(error.localizedDescription)"
                }
            } else {
                paired = "Saved \(added.name). Open it in Macs to switch to it."
            }
        }
    }
}
