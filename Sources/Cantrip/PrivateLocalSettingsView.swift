import SwiftUI

struct PrivateLocalSettingsView: View {
    @ObservedObject var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = PrivateLocalConfiguration()
    @State private var revision: String?
    @State private var models: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var toolServers: [PrivateLocalToolServer] = []
    @State private var loadingTools = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Private Local Settings", systemImage: "lock.shield")
                .font(.headline)
            Text("Local means self-hosted, not limited to this Mac. Your self-hosted server can run on another machine. Sessions stay saved on this Mac and accessible through Cantrip Remote and Cantrip Agent, with no cloud fallback.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Server API", selection: $configuration.api) {
                    ForEach(PrivateLocalAPI.allCases, id: \.self) { Text($0.pickerLabel).tag($0) }
                }
                .accessibilityLabel("Server API")
                .onChange(of: configuration.api) { _, _ in models = [] }
                TextField(configuration.api.urlLabel, text: $configuration.baseURL,
                          prompt: Text(configuration.api.urlPlaceholder))
                    .accessibilityLabel(configuration.api.urlLabel)
                TextField("Installed model", text: $configuration.model)
                if !models.isEmpty {
                    Picker("Choose installed model", selection: $configuration.model) {
                        ForEach(Array(Set(models + [configuration.model])).sorted(), id: \.self) {
                            Text($0.isEmpty ? "Choose a model" : $0).tag($0)
                        }
                    }
                }
                TextField("Context tokens", value: $configuration.contextWindow, format: .number)
                TextField("System prompt", text: $configuration.systemPrompt, axis: .vertical)
                    .lineLimit(3...6)
            }
            Text("Use your own server's HTTPS URL, including a LAN or Tailscale hostname. HTTP is allowed only on loopback. A reverse-proxy base path is supported. Install models on that server; context size depends on its model and RAM, and OpenAI-compatible servers set it on the server. No shell, shared memory, push summaries or automatic external content.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            toolsSection
            if let error { Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Reload settings", action: reload)
                Button("Load server models") {
                    loading = true
                    let draft = configuration
                    Task {
                        let client = PrivateLocalClient()
                        defer { client.close(); loading = false }
                        do { models = try await client.models(draft); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    guard let revision else { return }
                    do {
                        try session.updatePrivateLocalSettings(configuration, revision: revision)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .disabled(revision == nil || session.isStreaming || !session.queued.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .disabled(loading)
        }
        .padding(24).frame(width: 580)
        .onAppear(perform: reload)
    }

    private func reload() {
        do {
            let snapshot = try session.privateLocalSnapshot()
            configuration = snapshot.configuration
            revision = snapshot.revision
            error = snapshot.unavailableReason
            models = []
        } catch { self.error = error.localizedDescription }
        loadTools(refresh: false)
    }

    private func loadTools(refresh: Bool) {
        loadingTools = true
        Task {
            let tools = PrivateLocalTools.shared
            toolServers = tools.summary(await tools.catalog(refresh: refresh))
            loadingTools = false
        }
    }

    @ViewBuilder private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Read-only tools", isOn: $configuration.tools.enabled)
                    .accessibilityIdentifier("privateLocal.tools")
                Spacer()
                if loadingTools { ProgressView().controlSize(.small) }
                Button("Refresh tools") { loadTools(refresh: true) }.disabled(loadingTools)
            }
            Text(PrivateLocalToolServer.footer).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if configuration.tools.enabled, configuration.api != .openAI {
                Text("Tools need an OpenAI-compatible server API.").font(.caption).foregroundStyle(.orange)
            }
            if configuration.tools.enabled {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(toolServers, id: \.name) { server in
                            VStack(alignment: .leading, spacing: 2) {
                                Toggle(server.name, isOn: serverBinding(server.name))
                                    .disabled(server.blocked || server.tools.isEmpty)
                                Text(server.detail).font(.caption).foregroundStyle(server.problem == nil ? Color.secondary : Color.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !server.tools.isEmpty {
                                    DisclosureGroup("Allowed tools (\(server.tools.count))") {
                                        Text(server.tools.joined(separator: ", ")).font(.caption.monospaced())
                                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        if !server.excluded.isEmpty {
                                            Text("Left out: " + server.excluded.joined(separator: ", "))
                                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func serverBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { configuration.tools.uses(name) }, set: { on in
            let usable = toolServers.filter { !$0.blocked && !$0.tools.isEmpty }.map(\.name)
            var servers = configuration.tools.servers ?? usable
            servers.removeAll { $0 == name }
            if on { servers.append(name) }
            configuration.tools.servers = servers.sorted()
        })
    }
}

extension PrivateLocalToolServer {
    static let footer = "Private Local can look things up with the read-only tools of Cantrip's MCP servers: search, read, list and status, never send, create, change, delete or run. Tools run on this Mac; results go only to your self-hosted model, never to a cloud model. A service server (shown with its address) sends your query to that service, as it does from other tabs. Passwords, browser, file, form and build servers are never offered."

    /// One line under the server's switch.
    var detail: String {
        if let problem { return problem }
        if tools.isEmpty { return "No read-only tools." }
        return "\(tools.count) read-only tools, \(onDemand ? "loaded when needed" : "always offered") (about \(tokens) tokens)"
            + (excluded.isEmpty ? "" : ", \(excluded.count) left out")
            + (service.map { ". Sends queries to \($0)." } ?? ". Runs on this Mac and may reach its own service.")
    }
}

extension PrivateLocalAPI {
    var pickerLabel: String { self == .ollama ? "Ollama" : "OpenAI-compatible (oMLX, LM Studio, mlx-serve)" }
    var urlLabel: String { self == .ollama ? "Self-hosted Ollama URL" : "Self-hosted server base URL" }
    var urlPlaceholder: String { self == .ollama ? "https://your-llm-server/" : "https://your-llm-server/v1" }
}
