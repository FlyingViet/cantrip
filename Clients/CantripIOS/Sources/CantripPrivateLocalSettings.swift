import SwiftUI

/// The wire API the Private Local server speaks (`PrivateLocalAPI` on the Mac).
enum CantripPrivateLocalAPI: String, Codable, CaseIterable, Identifiable {
    case ollama
    case openAI = "openai"

    var id: String { rawValue }
    var label: String { self == .ollama ? "Ollama" : "OpenAI-compatible (oMLX, LM Studio, mlx-serve)" }
    var urlLabel: String { self == .ollama ? "Self-hosted Ollama URL" : "Self-hosted server base URL (ending in /v1)" }
    var urlPlaceholder: String { self == .ollama ? "https://your-llm-server/" : "https://your-llm-server/v1" }
}

struct CantripPrivateLocalConfiguration: Codable, Equatable {
    var baseURL = "http://127.0.0.1:11434"
    var model = ""
    var contextWindow = 8192
    var systemPrompt = ""
    /// Nil from a Mac that predates the API choice: saves then omit it and that Mac stays on Ollama.
    var api: CantripPrivateLocalAPI?
    /// Read-only tools; nil from a Mac that predates them (saves then omit it).
    var tools: CantripPrivateLocalTools?
}

/// `PrivateLocalToolSettings`: `servers` nil means every available server.
struct CantripPrivateLocalTools: Codable, Equatable {
    var enabled = false
    var servers: [String]?

    func uses(_ server: String) -> Bool { servers?.contains(server) ?? true }
}

/// `PrivateLocalToolServer` (GET …/private-tools): one server's read-only tools.
struct CantripPrivateLocalToolServer: Decodable, Equatable, Identifiable {
    let name: String
    let tools: [String]
    let excluded: [String]
    let onDemand: Bool
    let tokens: Int
    let service: String?
    let problem: String?
    let blocked: Bool

    var id: String { name }
    var usable: Bool { !blocked && !tools.isEmpty }

    var detail: String {
        if let problem { return problem }
        if tools.isEmpty { return "No read-only tools." }
        return "\(tools.count) read-only tool\(tools.count == 1 ? "" : "s"), \(onDemand ? "loaded when needed" : "always offered") (about \(tokens) tokens)"
            + (excluded.isEmpty ? "" : ", \(excluded.count) left out")
            + (service.map { ". Sends queries to \($0)." } ?? ". Runs on the Mac and may reach its own service.")
    }

    static let footer = "Private Local can look things up with the read-only tools of Cantrip's MCP servers: search, read, list and status, never send, create, change, delete or run. Tools run on the Mac; results go only to your self-hosted model, never to a cloud model. A service server (shown with its address) sends your query to that service, as it does from other tabs. Passwords, browser, file, form and build servers are never offered. Turning tools on starts this tab fresh: earlier messages stay visible but aren't sent to the model."
}

struct CantripPrivateLocalSettings: Decodable, Equatable {
    let configuration: CantripPrivateLocalConfiguration
    let revision: String
    let unavailableReason: String?
}

struct CantripPrivateLocalChange: Encodable {
    let revision: String
    let configuration: CantripPrivateLocalConfiguration
}

struct CantripSessionSettingsView: View {
    @ObservedObject var model: CantripRemoteModel
    let session: CantripRemoteSession
    let identity: UUID

    var body: some View {
        if session.isLocalPrivate == true {
            CantripPrivateLocalSettingsView(model: model, session: session, identity: identity)
        } else {
            CantripModelSettingsView(model: model, session: session, identity: identity)
        }
    }
}

struct CantripPrivateLocalSettingsView: View {
    @ObservedObject var model: CantripRemoteModel
    let session: CantripRemoteSession
    @State private var identity: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: CantripPrivateLocalSettings?
    @State private var configuration = CantripPrivateLocalConfiguration()
    @State private var models: [String] = []
    @State private var loading = false
    @State private var saving = false
    @State private var needsReload = false
    @State private var error: String?
    @State private var toolServers: [CantripPrivateLocalToolServer] = []
    @State private var loadingTools = false

    init(model: CantripRemoteModel, session: CantripRemoteSession, identity: UUID) {
        self.model = model
        self.session = session
        _identity = State(initialValue: identity)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Saved, self-hosted models", systemImage: "lock.shield")
                    Text("Local means self-hosted, not limited to the Cantrip Mac. Your LLM server can run on another machine. Conversations stay saved on the Mac and available through Remote, with no cloud fallback.")
                }
                if configuration.api != nil {
                    // Inline rows let the long OpenAI-compatible label wrap at narrow widths.
                    Section("Server API") {
                        Picker("Server API", selection: serverAPI) {
                            ForEach(CantripPrivateLocalAPI.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .accessibilityLabel("Server API")
                        .accessibilityIdentifier("privateLocal.api")
                    }
                    .disabled(snapshot == nil || snapshot?.unavailableReason != nil)
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedAPI.urlLabel).font(.caption).foregroundStyle(.secondary)
                        TextField(selectedAPI.urlPlaceholder, text: $configuration.baseURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL).accessibilityLabel(selectedAPI.urlLabel)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Installed model").font(.caption).foregroundStyle(.secondary)
                        TextField("Installed model", text: $configuration.model)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if !models.isEmpty {
                        Picker("Server model", selection: $configuration.model) {
                            ForEach(Array(Set(models + [configuration.model])).sorted(), id: \.self) {
                                Text($0.isEmpty ? "Choose a model" : $0).tag($0)
                            }
                        }
                    }
                    Button("Load server models") { Task { await loadModels() } }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Context tokens").font(.caption).foregroundStyle(.secondary)
                        TextField("Context tokens", value: $configuration.contextWindow, format: .number)
                            .keyboardType(.numberPad)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("System prompt").font(.caption).foregroundStyle(.secondary)
                        TextField("System prompt", text: $configuration.systemPrompt, axis: .vertical)
                            .lineLimit(3...8)
                    }
                } header: {
                    Text("Self-hosted LLM server")
                } footer: {
                    Text(Self.footer(for: selectedAPI))
                }
                .disabled(snapshot == nil || snapshot?.unavailableReason != nil)
                if configuration.tools != nil {
                    toolsSection.disabled(snapshot == nil || snapshot?.unavailableReason != nil)
                }
                Section {
                    Text("Shell commands, shared-memory logging, push summaries and automatic external content are disabled. Auto queues follow-ups locally. Changes apply to this tab only, while idle.")
                    Button("Reload settings") { Task { await load() } }
                    if loading || saving { ProgressView() }
                    if let message = error ?? snapshot?.unavailableReason {
                        Text(message).foregroundStyle(.orange)
                            .accessibilityIdentifier("privateLocal.error")
                    }
                }
            }
            .disabled(loading || saving)
            .navigationTitle("Private Local")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let snapshot else { return }
                        saving = true
                        let change = CantripPrivateLocalChange(revision: snapshot.revision, configuration: configuration)
                        Task {
                            if await model.updatePrivateLocalSettings(id: session.id, change: change, identity: identity) {
                                dismiss()
                            } else {
                                error = model.errorMessage
                                needsReload = true
                            }
                            saving = false
                        }
                    }
                    .disabled(snapshot == nil || loading || saving || needsReload || model.isMutating
                              || snapshot?.unavailableReason != nil || configuration.model.isEmpty)
                    .accessibilityIdentifier("privateLocal.save")
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .task { await load() }
        .onChange(of: model.usageIdentity) { _, _ in dismiss() }
    }

    private var selectedAPI: CantripPrivateLocalAPI { configuration.api ?? .ollama }

    @ViewBuilder private var toolsSection: some View {
        Section {
            Toggle("Let Private Local use read-only tools", isOn: Binding(
                get: { configuration.tools?.enabled ?? false },
                set: { configuration.tools = CantripPrivateLocalTools(enabled: $0, servers: configuration.tools?.servers) }))
                .accessibilityIdentifier("privateLocal.tools")
            if configuration.tools?.enabled == true {
                if selectedAPI != .openAI {
                    Text("Tools need an OpenAI-compatible server API.").foregroundStyle(.orange)
                }
                ForEach(toolServers) { server in
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(server.name, isOn: server.usable ? serverBinding(server.name) : .constant(false))
                            .disabled(!server.usable)
                            .accessibilityIdentifier("privateLocal.toolServer.\(server.name)")
                        Text(server.detail).font(.caption)
                            .foregroundStyle(server.problem == nil ? Color.secondary : Color.orange)
                        if !server.tools.isEmpty {
                            DisclosureGroup("Allowed tools (\(server.tools.count))") {
                                Text(server.tools.joined(separator: ", ")).font(.caption.monospaced()).textSelection(.enabled)
                                if !server.excluded.isEmpty {
                                    Text("Left out: " + server.excluded.joined(separator: ", "))
                                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
                if loadingTools { ProgressView() }
                Button("Refresh tools") { Task { await loadTools(refresh: true) } }.disabled(loadingTools)
            }
        } header: {
            Text("Read-only tools")
        } footer: {
            Text(CantripPrivateLocalToolServer.footer)
        }
    }

    private func serverBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { configuration.tools?.uses(name) ?? false }, set: { on in
            var tools = configuration.tools ?? CantripPrivateLocalTools()
            var servers = tools.servers ?? toolServers.filter(\.usable).map(\.name)
            servers.removeAll { $0 == name }
            if on { servers.append(name) }
            tools.servers = servers.sorted()
            configuration.tools = tools
        })
    }

    @MainActor
    private func loadTools(refresh: Bool) async {
        loadingTools = true
        defer { loadingTools = false }
        do {
            toolServers = try await model.privateLocalTools(id: session.id, refresh: refresh)
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
    }

    private var serverAPI: Binding<CantripPrivateLocalAPI> {
        Binding(get: { selectedAPI }, set: {
            guard $0 != configuration.api else { return }
            configuration.api = $0
            models = []
        })
    }

    static func footer(for api: CantripPrivateLocalAPI) -> String {
        "Cantrip connects to this server on your behalf. Use your own server's HTTPS URL, including a LAN or Tailscale hostname; reverse-proxy base paths are supported. HTTP is allowed only on loopback. Install models on that server. "
            + (api == .ollama
                ? "Context size depends on its model and RAM; saved history is not unlimited model context."
                : "Context size is set on the server for OpenAI-compatible servers; saved history is not unlimited model context.")
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let value = try await model.privateLocalSettings(id: session.id)
            guard model.usageIdentity == identity else { throw CancellationError() }
            snapshot = value
            configuration = value.configuration
            models = []
            error = nil
            needsReload = false
            if value.configuration.tools != nil { await loadTools(refresh: false) }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            needsReload = true
        }
    }

    @MainActor
    private func loadModels() async {
        loading = true
        defer { loading = false }
        do {
            models = try await model.privateLocalModels(id: session.id, baseURL: configuration.baseURL, api: configuration.api)
            error = models.isEmpty ? "No self-hosted models found. Install or load a model on the selected server." : nil
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
    }
}
