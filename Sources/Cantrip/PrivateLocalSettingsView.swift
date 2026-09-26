import SwiftUI

struct PrivateLocalSettingsView: View {
    @ObservedObject var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = PrivateLocalConfiguration()
    @State private var revision: String?
    @State private var models: [String] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Private Local Settings", systemImage: "lock.shield")
                .font(.headline)
            Text("Local means self-hosted, not limited to this Mac. Your Ollama server can run on another machine. Sessions stay saved on this Mac and accessible through Cantrip Remote and AgentGateway, with no cloud fallback.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Self-hosted Ollama URL", text: $configuration.baseURL)
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
            Text("Use your own server's HTTPS URL, including a LAN or Tailscale hostname. HTTP is allowed only on loopback. A reverse-proxy base path is supported. Install models on that server; context size depends on its model and RAM. No tools, shared memory, push summaries or automatic external content.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    }
}
