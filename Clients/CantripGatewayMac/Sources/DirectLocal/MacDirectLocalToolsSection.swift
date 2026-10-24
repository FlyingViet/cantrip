import SwiftUI

/// Local Model Settings: which MCP servers on this Mac the model may use, which of their tools,
/// and which tools run without asking. Edits `settings` (the draft); Save keeps them.
struct MacDirectLocalToolsSection: View {
    @ObservedObject var chat: DirectLocalChat
    @Binding var settings: DirectLocalToolSettings
    let contextWindow: Int
    let systemPromptCharacters: Int
    @State private var expanded: Set<String> = Self.initiallyExpanded

    private static var initiallyExpanded: Set<String> {
        #if DEBUG
        Set((UserDefaults.standard.string(forKey: "DirectLocalQAExpandTools") ?? "").split(separator: ",").map(String.init))
        #else
        []
        #endif
    }

    var body: some View {
        Section {
            if chat.mcpServers.isEmpty {
                Text("No MCP servers are set up on this Mac. Add them to ~/.copilot/mcp-config.json (Copilot CLI) or ~/.claude.json (Claude Code), then reopen these settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(chat.mcpServers) { server in
                serverRow(server)
            }
            if !settings.enabledServers.isEmpty { budget }
        } header: {
            Text("Tools from MCP servers")
        } footer: {
            Text("Servers come from ~/.copilot/mcp-config.json and ~/.claude.json and start on this Mac only when the model needs them, then stop after 5 idle minutes. Each tool asks before it runs unless you set it to Run Automatically. Tools can do whatever their server allows, such as reading mail or opening websites.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { chat.refreshMCPServers() }
    }

    // MARK: Server

    @ViewBuilder
    private func serverRow(_ server: DirectLocalMCPServer) -> some View {
        let enabled = settings.isEnabled(server.name) && server.isAvailable
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { enabled }, set: { on in
                settings.setEnabled(server.name, on)
                if on, chat.cachedTools(for: server) == nil { Task { await chat.loadTools(for: server) } }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.body.weight(.medium))
                    Text(server.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .disabled(!server.isAvailable)
            .accessibilityIdentifier("directLocal.tools.server.\(server.name)")
            if let reason = server.unavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if enabled { serverTools(server) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func serverTools(_ server: DirectLocalMCPServer) -> some View {
        let loading = chat.loadingToolServers.contains(server.name)
        if let error = chat.toolErrors[server.name] {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let tools = chat.cachedTools(for: server) {
            let allowed = tools.filter { server.allows($0.name) }
            let on = allowed.filter { settings.isEnabled(server.name, $0.name) }
            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(server.name) }, set: { open in
                if open { expanded.insert(server.name) } else { expanded.remove(server.name) }
            })) {
                VStack(alignment: .leading, spacing: 8) {
                    if allowed.count < tools.count {
                        Text("\(tools.count - allowed.count) more \(tools.count - allowed.count == 1 ? "tool is" : "tools are") left out by the tools list in \(server.source).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(allowed) { tool in toolRow(tool, server: server) }
                    HStack {
                        Button("All On") { allowed.forEach { settings.setEnabled(server.name, $0.name, true) } }
                        Button("All Off") { allowed.forEach { settings.setEnabled(server.name, $0.name, false) } }
                        Spacer()
                        Button(loading ? "Loading…" : "Reload Tools") { Task { await chat.loadTools(for: server) } }
                            .disabled(loading)
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            } label: {
                Text("\(on.count) of \(allowed.count) tools on")
                    .font(.callout)
            }
            .accessibilityIdentifier("directLocal.tools.list.\(server.name)")
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(loading ? "Starting \(server.name) to list its tools…" : "Load its tools to choose which the model can use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Load Tools") { Task { await chat.loadTools(for: server) } }
                        .accessibilityIdentifier("directLocal.tools.load.\(server.name)")
                }
            }
        }
    }

    // MARK: Tool

    private func toolRow(_ tool: DirectLocalMCPTool, server: DirectLocalMCPServer) -> some View {
        let enabled = settings.isEnabled(server.name, tool.name)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(isOn: Binding(get: { enabled }, set: { settings.setEnabled(server.name, tool.name, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name)
                        .font(.callout.monospaced())
                    if !tool.description.isEmpty {
                        Text(tool.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(tool.description)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            if tool.readOnly {
                Text("Read-only · runs automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("When the model calls \(tool.name)", selection: Binding(
                    get: { settings.isAutomatic(server.name, tool.name) },
                    set: { settings.setAutomatic(server.name, tool.name, $0) })) {
                    Text("Ask First").tag(false)
                    Text("Run Automatically").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!enabled)
            }
        }
    }

    // MARK: Budget

    private var budget: some View {
        let offered = chat.offeredTools(settings)
        let tokens = DirectLocalTools.tokens(characters: DirectLocalTools.characters(offered))
        let total = DirectLocalTools.tokens(characters: DirectLocalTools.characters(offered) + systemPromptCharacters)
        let share = Double(total) / Double(max(1, contextWindow))
        let tooMany = share > DirectLocalTools.maxContextShare
        return Label {
            Text(tooMany
                 ? "\(offered.count) tools use about \(tokens) of \(contextWindow) context tokens, more than Local Model allows. Turn some off before sending."
                 : "\(offered.count) \(offered.count == 1 ? "tool uses" : "tools use") about \(tokens) of \(contextWindow) context tokens on every message.\(share > 0.4 ? " Fewer tools leave more room for the conversation." : "")")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: tooMany ? "exclamationmark.octagon" : share > 0.4 ? "exclamationmark.triangle" : "gauge.with.dots.needle.33percent")
        }
        .font(.caption)
        .foregroundStyle(tooMany ? Color.red : share > 0.4 ? Color.orange : Color.secondary)
        .accessibilityIdentifier("directLocal.tools.budget")
    }
}
