import AppKit
import SwiftUI

/// Settings > MCP Servers: the servers every backend shares, their sign-ins, and the page a
/// sign-in is waiting on (approve here instead of at the agent Chrome).
struct MCPServersView: View {
    @ObservedObject var hub: MCPServerHub
    @State private var preview: String?
    @State private var error: String?
    private static let backends: [BackendKind] = [.copilot, .claudeCode, .codex, .antigravity]

    init(hub: MCPServerHub? = nil) {
        self.hub = hub ?? .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MCP Servers").font(.caption.weight(.semibold))
            if hub.snapshot.importedAt == nil {
                Text("Copilot and Claude Code each keep their own MCP servers, and remote ones sign in separately. Cantrip can keep one list for every backend, sign in itself and hold credentials only in the keychain.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 8, lineSpacing: 4) {
                    Button("Preview") { run(apply: false) }
                    Button("Share with Every Backend") { run(apply: true) }
                }
                .font(.caption)
            }
            if let preview {
                Text(preview).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.caption2).foregroundStyle(.orange) }
            ForEach(hub.snapshot.servers) { server in
                MCPServerRow(server: server, state: hub.states[server.name], backends: Self.backends, hub: hub)
            }
        }
        .task { await hub.refreshStates() }
    }

    private func run(apply: Bool) {
        do {
            let report = try MCPMigration.run(dryRun: !apply)
            hub.reload()
            Task { await hub.refreshStates() }
            preview = ([apply ? "Shared \(report.servers.count) servers." : "Would share \(report.servers.count) servers: \(report.servers.joined(separator: ", "))",
                        "Through the relay: \(report.relayed.joined(separator: ", "))",
                        "\(report.secretsMoved) credential(s) \(apply ? "moved" : "would move") to the keychain."] + report.notes)
                .joined(separator: "\n")
            error = nil
        } catch {
            self.error = "Nothing changed: \(error.localizedDescription)"
        }
    }
}

/// One server: its switch, kind and sign-in, then which backends get it. Narrow panes move the
/// status under the name and wrap the backend switches, so nothing runs past the pane's edge and
/// the sign-in button stays whole.
struct MCPServerRow: View {
    let server: MCPServer
    let state: MCPServerHub.State?
    let backends: [BackendKind]
    @ObservedObject var hub: MCPServerHub

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    nameToggle
                    kind
                    Spacer(minLength: 6)
                    status
                    actions
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        nameToggle
                        kind
                        Spacer(minLength: 6)
                        actions
                    }
                    status.padding(.leading, 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        nameToggle
                        Spacer(minLength: 6)
                        actions
                    }
                    FlowLayout(spacing: 6, lineSpacing: 2) {
                        kind
                        status
                    }
                    .padding(.leading, 20)
                }
            }
            FlowLayout(spacing: 8, lineSpacing: 4) {
                ForEach(backends) { backend in
                    Toggle(backend.rawValue, isOn: Binding(get: { !server.disabledBackends.contains(backend.rawValue) }, set: { on in
                        try? hub.update { snapshot in
                            guard let index = snapshot.servers.firstIndex(where: { $0.name == server.name }) else { return }
                            var off = Set(snapshot.servers[index].disabledBackends)
                            if on { off.remove(backend.rawValue) } else { off.insert(backend.rawValue) }
                            snapshot.servers[index].disabledBackends = off.sorted()
                        }
                    }))
                    .toggleStyle(.checkbox).font(.caption2)
                }
            }
            .disabled(!server.enabled)
            .padding(.leading, 20)
            if let state, [.awaitingApproval, .needsLogin, .connecting, .failed, .locked].contains(state.phase) {
                MCPSignInPage(name: server.name, state: state, hub: hub)
                    .padding(.leading, 20)
            }
        }
    }

    private var nameToggle: some View {
        Toggle(isOn: Binding(get: { server.enabled }, set: { on in
            try? hub.update { snapshot in
                if let index = snapshot.servers.firstIndex(where: { $0.name == server.name }) { snapshot.servers[index].enabled = on }
            }
        })) {
            Text(server.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
    }

    private var kind: some View {
        HStack(spacing: 6) {
            Text(server.isRemote ? "remote" : "local")
            if server.isRelayed { Text("via Cantrip") }
        }
        .font(.caption2).foregroundStyle(.tertiary)
        .fixedSize()
    }

    private var status: some View {
        Text(statusText).font(.caption2).foregroundStyle(statusColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusText: String {
        MCPServerRow.statusText(server, state)
    }

    /// What the row says about a server's sign-in; Remote clients show the same words.
    static func statusText(_ server: MCPServer, _ state: MCPServerHub.State?) -> String {
        guard server.enabled else { return "Off" }
        guard server.oauth else { return server.secretHeaders.isEmpty && server.secretEnv.isEmpty ? "Ready" : "Credentials in keychain" }
        switch state?.phase {
        case .ready?:
            return state?.expiresAt.map { "Signed in · token until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Signed in"
        case .connecting?: return "Signing in…"
        case .awaitingApproval?: return "Waiting for your OK"
        case .needsLogin?: return "Log in to finish"
        case .locked?: return "Keychain locked"
        case .failed?: return "Sign-in failed"
        default: return "Not signed in"
        }
    }

    private var statusColor: Color {
        switch state?.phase {
        case .ready?: return .secondary
        case .awaitingApproval?, .needsLogin?: return .accentColor
        case .locked?, .failed?, .needsSignIn?, nil: return server.oauth ? .orange : .secondary
        default: return .secondary
        }
    }

    @ViewBuilder private var actions: some View {
        if server.oauth {
            Group {
                switch state?.phase {
                case .connecting?, .awaitingApproval?, .needsLogin?:
                    Button("Cancel") { hub.cancel(server.name) }
                case .ready?:
                    Button("Sign Out") { Task { await hub.signOut(server.name) } }
                case .failed?:
                    Button("Reconnect") { hub.connect(server.name) }
                default:
                    Button("Connect") { hub.connect(server.name) }
                }
            }
            .font(.caption2)
            .fixedSize()
        }
    }
}

/// The page a sign-in is on, as the agent Chrome shows it, with Approve when it's the consent page.
struct MCPSignInPage: View {
    let name: String
    let state: MCPServerHub.State
    @ObservedObject var hub: MCPServerHub

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let message = state.message {
                Text(message).font(.caption2).foregroundStyle(state.phase == .failed || state.phase == .locked ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let shot = state.screenshot.flatMap({ Data(base64Encoded: $0) }).flatMap(NSImage.init(data:)) {
                Image(nsImage: shot).resizable().scaledToFit().frame(maxWidth: 360, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .accessibilityLabel("The sign-in page for \(name)\(state.page.map { " on \($0.host)" } ?? "")")
            }
            if state.phase == .awaitingApproval {
                HStack {
                    Button("Approve") { hub.respond(name, approve: true) }.keyboardShortcut(.defaultAction)
                    Button("Decline") { hub.respond(name, approve: false) }
                }
                .font(.caption)
            }
        }
    }
}
