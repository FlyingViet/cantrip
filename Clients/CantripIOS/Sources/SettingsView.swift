import SwiftUI

struct SettingsView: View {
    @ObservedObject var env: HermesEnv
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var testing = false
    @State private var testResult: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://agent.example-home.com", text: $env.baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("API key (API_SERVER_KEY)", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: key) { _, v in env.setAPIKey(v) }
                    TextField("Model", text: $env.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Hermes Gateway") }
                footer: { Text("The gateway's OpenAI-compatible API server (/v1/responses). Use the LAN address at home or the Cloudflare tunnel hostname anywhere.") }

                Section {
                    Button { Task { await test() } } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            if testing { ProgressView() }
                            else if let ok = testResult {
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ok ? .green : .red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { key = env.apiKey }
        }
    }

    private func test() async {
        testing = true; testResult = nil
        testResult = await env.client?.health() ?? false
        testing = false
    }
}
