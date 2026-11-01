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
    /// Its credentials (headers or environment values) are in the Mac's keychain; absent from Macs
    /// before 1.1.13. Never the values themselves.
    var credentials: Bool?
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

    var expiry: Date? { expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) } }
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
                                #if os(macOS)
                                macRow(server)
                                #else
                                NavigationLink { detail(server.name) } label: { summary(server) }
                                    .accessibilityIdentifier("mcp.server.\(server.name)")
                                #endif
                            }
                        } header: {
                            Text("Servers")
                        } footer: {
                            #if os(macOS)
                            Text("Connect signs in on the Mac's agent Chrome; approve it here. The switches choose which backends use each server, the same as on the Mac.")
                            #else
                            Text("Tap a server to sign in or out and choose which backends and tabs use it.")
                            #endif
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

    /// A server's row in Settings: its name, state and which backends use it, and Connect (or
    /// Retry) when it needs a sign-in.
    private func summary(_ server: CantripMCPServer) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                Text(Self.status(server)).font(.caption).foregroundStyle(statusColor(server))
                Text(Self.kindAndBackends(server)).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if server.oauth, server.enabled, server.state?.phase != "ready", server.state?.isActive != true {
                connectButton(server)
                    .buttonStyle(.borderless)
                    .fixedSize()
            }
        }
    }

    #if os(macOS)
    /// Gateway Mac's row, as Cantrip's own Settings shows it: the server's switch, its state and
    /// sign-in, and a switch per backend (and for the tab the sheet was opened from).
    private func macRow(_ server: CantripMCPServer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(isOn: binding(server.enabled) { act(["action": "setEnabled", "name": server.name, "enabled": $0]) }) {
                    Text(server.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                }
                .accessibilityIdentifier("mcp.enabled.\(server.name)")
                Text(Self.kind(server)).font(.caption).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                Text(Self.status(server)).font(.caption).foregroundStyle(statusColor(server))
                    .multilineTextAlignment(.trailing)
                signInButton(server).fixedSize()
            }
            if let state = server.state, state.isActive || ["failed", "locked"].contains(state.phase) {
                signInPage(server, state).padding(.leading, 20)
            }
            if server.enabled {
                CantripChildFlowLayout(spacing: 12, lineSpacing: 4) {
                    ForEach(Self.backends, id: \.self) { backend in
                        Toggle(backend, isOn: binding(!server.disabledBackends.contains(backend)) {
                            act(["action": "setBackend", "name": server.name, "backend": backend, "enabled": $0])
                        })
                        .accessibilityIdentifier("mcp.backend.\(server.name).\(backend)")
                    }
                    if let tabID {
                        Toggle("This tab", isOn: binding(!(snapshot?.tabDisabled ?? []).contains(server.name)) {
                            act(["action": "setTab", "name": server.name, "tab": tabID, "enabled": $0])
                        })
                    }
                }
                .font(.caption)
                .padding(.leading, 20)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 4)
        .disabled(working != nil)
    }
    #endif

    /// Connect, or Retry after a sign-in failed (the Mac's reason shows with the server).
    private func connectButton(_ server: CantripMCPServer) -> some View {
        Button(Self.connectLabel(server)) { act(["action": "connect", "name": server.name]) }
            .disabled(working != nil)
            .accessibilityIdentifier("mcp.connect.\(server.name)")
    }

    @ViewBuilder
    private func signInButton(_ server: CantripMCPServer) -> some View {
        if server.oauth, server.enabled {
            if server.state?.isActive == true {
                Button("Cancel") { act(["action": "cancel", "name": server.name]) }
            } else if server.state?.phase == "ready" {
                Button("Sign Out") { act(["action": "signOut", "name": server.name]) }
            } else {
                connectButton(server)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func row(_ server: CantripMCPServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.status(server)).font(.subheadline).foregroundStyle(statusColor(server))
                Text(Self.kind(server)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            signInButton(server).fixedSize()
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
            .accessibilityIdentifier("mcp.enabled.\(server.name)")
        if server.enabled {
            ForEach(Self.backends, id: \.self) { backend in
                Toggle(backend, isOn: binding(!server.disabledBackends.contains(backend)) {
                    act(["action": "setBackend", "name": server.name, "backend": backend, "enabled": $0])
                })
                .accessibilityIdentifier("mcp.backend.\(server.name).\(backend)")
            }
            if let tabID {
                Toggle("This tab", isOn: binding(!(snapshot?.tabDisabled ?? []).contains(server.name)) {
                    act(["action": "setTab", "name": server.name, "tab": tabID, "enabled": $0])
                })
                .accessibilityIdentifier("mcp.tab.\(server.name)")
            }
        }
    }

    private func binding(_ value: Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: set)
    }

    /// What a server's sign-in is doing, in the words Cantrip's own Settings uses.
    static func status(_ server: CantripMCPServer) -> String {
        guard server.enabled else { return "Off" }
        guard server.oauth else { return server.credentials == true ? "Credentials in Mac keychain" : "Ready" }
        switch server.state?.phase {
        case "ready":
            return server.state?.expiry.map { "Signed in · token until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Signed in"
        case "connecting": return "Signing in…"
        case "awaitingApproval": return "Waiting for your OK"
        case "needsLogin": return "Log in to finish"
        case "locked": return "Mac keychain locked"
        case "failed": return "Sign-in failed"
        default: return "Not signed in"
        }
    }

    static func connectLabel(_ server: CantripMCPServer) -> String {
        server.state?.phase == "failed" ? "Retry" : "Connect"
    }

    static func kind(_ server: CantripMCPServer) -> String {
        [server.remote ? "Remote" : "Local", server.relayed ? "via Cantrip" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Local · All backends", or the backends that use it.
    static func kindAndBackends(_ server: CantripMCPServer) -> String {
        guard server.enabled else { return kind(server) }
        let on = backends.filter { !server.disabledBackends.contains($0) }
        let which = on.count == backends.count ? "All backends" : on.isEmpty ? "No backends" : on.joined(separator: ", ")
        return "\(kind(server)) · \(which)"
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
