import SwiftUI

struct CantripPrivateLocalConfiguration: Codable, Equatable {
    var baseURL = "http://127.0.0.1:11434"
    var model = ""
    var contextWindow = 8192
    var systemPrompt = ""
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
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Self-hosted Ollama URL").font(.caption).foregroundStyle(.secondary)
                        TextField("https://your-llm-server", text: $configuration.baseURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL).accessibilityLabel("Self-hosted Ollama server URL")
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
                    Text("Cantrip connects to this server on your behalf. Use your own server's HTTPS URL, including a LAN or Tailscale hostname; reverse-proxy base paths are supported. HTTP is allowed only on loopback. Install models on that server. Context size depends on its model and RAM; saved history is not unlimited model context.")
                }
                .disabled(snapshot == nil || snapshot?.unavailableReason != nil)
                Section {
                    Text("Tools, shell commands, shared-memory logging, push summaries and automatic external content are disabled. Auto queues follow-ups locally. Changes apply to this tab only, while idle.")
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
            models = try await model.privateLocalModels(id: session.id, baseURL: configuration.baseURL)
            error = models.isEmpty ? "No self-hosted models found. Install a model with Ollama on the selected server." : nil
        } catch is CancellationError {
            return
        } catch { self.error = error.localizedDescription }
    }
}
