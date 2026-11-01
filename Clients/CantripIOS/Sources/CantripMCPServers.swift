import SwiftUI

/// `GET/POST /api/v1/mcp`: the MCP servers Cantrip shares with every backend, and their sign-ins.
/// Tokens never leave the Mac; a sign-in waiting for approval comes with a picture of the page.
struct CantripMCPSnapshot: Decodable, Equatable {
    var servers: [CantripMCPServer]
    var tabDisabled: [String]?
}

struct CantripMCPServer: Decodable, Equatable, Identifiable {
    var id: String { name }
    var settingsRowID: String { "shared.\(name)" }
    var name: String
    var remote: Bool
    var oauth: Bool
    var relayed: Bool
    var enabled: Bool
    var disabledBackends: [String]
    var address: String?
    var state: CantripMCPState?
}

struct CantripMCPState: Decodable, Equatable {
    var phase: String
    var message: String?
    var screenshot: String?
    var expiresAt: String?
    var page: Page?

    struct Page: Decodable, Equatable {
        var title: String
        var host: String
    }

    var isActive: Bool { ["connecting", "awaitingApproval", "needsLogin"].contains(phase) }
}

/// Settings for shared MCP servers: connect remote ones (the page opens in the Mac's agent
/// Chrome), approve the consent page from here, and switch servers per backend or per tab.
struct CantripMCPServersView: View {
    @ObservedObject var remote: CantripRemoteModel
    /// The tab the sheet was opened from, for its own switches.
    let tabID: String?
    /// A page inside Settings, without its own navigation and Done: one row per server that
    /// opens its sign-in and switches.
    var embedded = false
    /// More sections at the end (Gateway Mac's local model tools).
    var extra: AnyView? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: CantripMCPSnapshot?
    @State private var error: String?
    @State private var working: String?
    static let backends = ["Copilot", "Claude Code", "Codex", "Antigravity"]

    var body: some View {
        CantripSheetStack(embedded: embedded) {
            List {
                Section {
                    Text("Every backend on your Mac shares these servers. Sign-ins open in the Mac's agent Chrome; approve them here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                if let snapshot, snapshot.servers.isEmpty {
                    Section { Text("Cantrip isn't sharing MCP servers yet. Turn it on in Cantrip's Settings > MCP Servers on the Mac.") }
                }
                if embedded {
                    if let servers = snapshot?.servers, !servers.isEmpty {
                        Section {
                            // Not keyed by bare name: Gateway Mac's local tools below list the same names.
                            ForEach(servers, id: \.settingsRowID) { server in
                                NavigationLink { detail(server.name) } label: { summary(server) }
                                    .accessibilityIdentifier("mcp.server.\(server.name)")
                            }
                        } header: {
                            Text("Servers")
                        } footer: {
                            Text("Tap a server to sign in or out and choose which backends and tabs use it.")
                        }
                    }
                } else {
                    ForEach(snapshot?.servers ?? []) { server in
                        Section {
                            serverContent(server)
                        } header: {
                            Text(server.name)
                        }
                    }
                }
                if let extra { extra }
            }
            .navigationTitle(embedded ? "Tools & sign-ins" : "MCP Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .task { await poll() }
            .refreshable { await load() }
        }
    }

    @ViewBuilder
    private func serverContent(_ server: CantripMCPServer) -> some View {
        row(server)
        if let state = server.state, state.isActive || ["failed", "locked"].contains(state.phase) {
            signInPage(server, state)
        }
        switches(server)
    }

    /// One server's page in Settings: its sign-in and switches, kept current while it polls.
    private func detail(_ name: String) -> some View {
        List {
            if let server = snapshot?.servers.first(where: { $0.name == name }) {
                Section { serverContent(server) }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A server's row in Settings: its name and state, and Connect when it needs a sign-in.
    private func summary(_ server: CantripMCPServer) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text(status(server)).font(.caption).foregroundStyle(statusColor(server))
            }
            Spacer(minLength: 8)
            if server.oauth, server.enabled, server.state?.phase != "ready", server.state?.isActive != true {
                Button("Connect") { act(["action": "connect", "name": server.name]) }
                    .buttonStyle(.borderless)
                    .disabled(working != nil)
                    .accessibilityIdentifier("mcp.connect.\(server.name)")
            }
        }
    }

    private func row(_ server: CantripMCPServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(status(server)).font(.subheadline).foregroundStyle(statusColor(server))
                Text([server.remote ? "Remote" : "Local", server.relayed ? "through Cantrip" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if server.oauth, server.enabled {
                if server.state?.isActive == true {
                    Button("Cancel") { act(["action": "cancel", "name": server.name]) }
                } else if server.state?.phase == "ready" {
                    Button("Sign Out") { act(["action": "signOut", "name": server.name]) }
                } else {
                    Button("Connect") { act(["action": "connect", "name": server.name]) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mcp.connect.\(server.name)")
                }
            }
        }
        .disabled(working != nil)
    }

    @ViewBuilder
    private func signInPage(_ server: CantripMCPServer, _ state: CantripMCPState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = state.message {
                Text(message).font(.footnote)
                    .foregroundStyle(["failed", "locked"].contains(state.phase) ? .orange : .secondary)
            }
            if let image = state.screenshot.flatMap({ Data(base64Encoded: $0) }).flatMap(UIImage.init(data:)) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("The sign-in page for \(server.name)\(state.page.map { " on \($0.host)" } ?? "")")
            }
            if state.phase == "awaitingApproval" {
                HStack {
                    Button("Decline", role: .cancel) { act(["action": "decline", "name": server.name]) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Approve") { act(["action": "approve", "name": server.name]) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mcp.approve.\(server.name)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func switches(_ server: CantripMCPServer) -> some View {
        Toggle("On", isOn: binding(server.enabled) { act(["action": "setEnabled", "name": server.name, "enabled": $0]) })
        if server.enabled {
            ForEach(Self.backends, id: \.self) { backend in
                Toggle(backend, isOn: binding(!server.disabledBackends.contains(backend)) {
                    act(["action": "setBackend", "name": server.name, "backend": backend, "enabled": $0])
                })
            }
            if let tabID {
                Toggle("This tab", isOn: binding(!(snapshot?.tabDisabled ?? []).contains(server.name)) {
                    act(["action": "setTab", "name": server.name, "tab": tabID, "enabled": $0])
                })
            }
        }
    }

    private func binding(_ value: Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: set)
    }

    private func status(_ server: CantripMCPServer) -> String {
        guard server.enabled else { return "Off" }
        guard server.oauth else { return "Ready" }
        switch server.state?.phase {
        case "ready": return "Signed in"
        case "connecting": return "Signing in…"
        case "awaitingApproval": return "Waiting for your OK"
        case "needsLogin": return "Log in to finish"
        case "locked": return "Mac keychain locked"
        case "failed": return "Sign-in failed"
        default: return "Not signed in"
        }
    }

    private func statusColor(_ server: CantripMCPServer) -> Color {
        switch server.state?.phase {
        case "awaitingApproval", "needsLogin": return .accentColor
        case "failed", "locked": return .orange
        case "ready": return .secondary
        default: return server.oauth && server.enabled ? .orange : .secondary
        }
    }

    private func act(_ body: [String: Any]) {
        working = body["action"] as? String
        Task {
            defer { working = nil }
            if let updated = await remote.mcpAction(body) {
                snapshot = updated
                error = nil
            } else {
                error = remote.errorMessage ?? "That didn't go through."
            }
            try? await Task.sleep(for: .milliseconds(600))
            await load()
        }
    }

    private func load() async {
        do {
            snapshot = try await remote.mcpServers(tab: tabID)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Fast while a sign-in is moving, slow otherwise.
    private func poll() async {
        while !Task.isCancelled {
            await load()
            let active = snapshot?.servers.contains { $0.state?.isActive == true } == true
            try? await Task.sleep(for: .seconds(active ? 1.5 : 8))
        }
    }
}
