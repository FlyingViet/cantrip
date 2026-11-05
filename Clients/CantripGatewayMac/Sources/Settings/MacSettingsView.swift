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
            .background { MacUnifiedToolbar().frame(width: 0, height: 0).accessibilityHidden(true) }
    }
}

/// A Settings scene's window gets a preferences toolbar, which centers items under the title, so a
/// nested page's back chevron sat mid-window. Unified, as in Home's window, it sits at the top left
/// beside the page's title.
private struct MacUnifiedToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window, window.toolbarStyle != .unified else { return }
            window.toolbarStyle = .unified
        }
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
