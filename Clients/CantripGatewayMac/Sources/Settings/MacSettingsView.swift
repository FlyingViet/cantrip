import SwiftUI

/// Settings (⌘,): the same pages as the iPhone app's Settings, beside a sidebar, in a window you
/// can resize. Tools & sign-ins also lists this Mac's local model tools.
struct MacSettingsView: View {
    @ObservedObject var env: HermesEnv
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject var voice: VoiceController
    @ObservedObject var directLocal: DirectLocalChat

    var body: some View {
        SettingsView(env: env, remote: remote, voice: voice,
                     macTools: AnyView(MacLocalModelToolsSettings(chat: directLocal)))
            .frame(minWidth: 780, idealWidth: 900, maxWidth: .infinity,
                   minHeight: 540, idealHeight: 680, maxHeight: .infinity)
    }
}

/// Settings › Tools & sign-ins on this Mac: which MCP tools the local model on this Mac may use.
/// Saved as each one changes.
struct MacLocalModelToolsSettings: View {
    @ObservedObject var chat: DirectLocalChat
    @State private var error: String?

    var body: some View {
        Section {
            Text("The local model runs on this Mac without your paired Cantrip. These switches are this Mac's own; they don't change the servers above.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text("Local model on this Mac")
        }
        MacDirectLocalToolsSection(
            chat: chat,
            settings: Binding(get: { chat.configuration.tools }, set: { tools in
                var next = chat.configuration
                next.tools = tools
                do {
                    try chat.save(next)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }),
            contextWindow: chat.configuration.contextWindow,
            systemPromptCharacters: chat.configuration.systemPrompt.count
        )
    }
}
