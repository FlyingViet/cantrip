import SwiftUI

/// The open tab's terminal, under its conversation: the Mac's persistent shell for the tab (the
/// same one as the Cantrip panel's terminal mode), so `cd` and exports carry over and the agent's
/// own commands show up here too. Up/Down browse history and Control-C interrupts.
struct MacTerminalPane: View {
    @ObservedObject var remote: CantripRemoteModel
    let session: CantripRemoteSession
    let onClose: () -> Void
    @AppStorage("cantrip.terminal.height") private var height = 240.0
    @StateObject private var terminal = CantripTerminalModel()
    @State private var command = ""
    @State private var history = CantripTerminalHistory()
    @State private var dragStart: Double?
    @FocusState private var focused: Bool

    static let minimumHeight = 120.0

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            header
            Divider()
            output
            Divider()
            prompt
        }
        .frame(height: height)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .onAppear { start() }
        .onChange(of: session.id) { _, _ in
            command = ""
            history.reset()
            start()
        }
        .onChange(of: remote.isConfigured) { _, _ in start() }
        .onDisappear { terminal.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.pane")
    }

    private func start() {
        guard session.supportsTerminal == true else { return terminal.stop() }
        terminal.start(remote: remote, sessionID: session.id)
        focused = true
    }

    /// Drag the top edge to resize; the height is kept for every tab.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 1)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? height
                    dragStart = start
                    height = min(900, max(Self.minimumHeight, start - value.translation.height))
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityLabel("Resize terminal")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Terminal", systemImage: "apple.terminal")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.semibold))
            Text(terminal.workdir.isEmpty ? session.workdir : terminal.workdir)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Group {
                if terminal.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Interrupt", systemImage: "stop.circle") { Task { await terminal.interrupt() } }
                        .help(terminal.isRunning ? "Interrupt the running command (Control-C)"
                              : "Stop the agent's command (Control-C)")
                }
                Button("Clear", systemImage: "eraser") { Task { await terminal.clear() } }
                    .help("Clear the terminal on every device")
                Button("Restart Shell", systemImage: "arrow.counterclockwise") { Task { await terminal.restart() } }
                    .help("Restart this tab's shell on the Mac (stops its running command)")
            }
            .disabled(!terminal.isLoaded || terminal.isSending)
            Button("Close Terminal", systemImage: "xmark") { onClose() }
                .help("Hide the terminal (⌃`)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let notice {
                        Text(notice)
                            .font(.callout)
                            .foregroundStyle(terminal.errorMessage == nil && session.supportsTerminal == true
                                             ? Color.secondary : Color.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6)
                    }
                    if !terminal.buffer.output.isEmpty {
                        Text(terminal.buffer.output)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("terminal.end")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: terminal.buffer.end) { _, _ in proxy.scrollTo("terminal.end", anchor: .bottom) }
            .onChange(of: terminal.buffer.epoch) { _, _ in proxy.scrollTo("terminal.end", anchor: .bottom) }
        }
        .accessibilityIdentifier("terminal.output")
    }

    private var notice: String? {
        if session.supportsTerminal == false { return "Shell commands and tools are disabled in Private Local." }
        if session.supportsTerminal == nil { return CantripTerminalModel.unsupported }
        if let error = terminal.errorMessage { return error }
        if !terminal.isLoaded { return "Connecting to the tab's shell…" }
        if terminal.buffer.output.isEmpty {
            return "This tab's shell on the Mac. The agent's commands appear here too; cd, exports and variables persist."
        }
        return nil
    }

    private var prompt: some View {
        HStack(spacing: 6) {
            Text("$")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            TextField(terminal.isRunning ? "input for the running command" : "command", text: $command)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .focused($focused)
                .disabled(session.supportsTerminal != true || !terminal.isLoaded)
                .onSubmit(submit)
                .onKeyPress(phases: [.down, .repeat]) { press in
                    if press.key == .upArrow || press.key == .downArrow {
                        if let line = history.step(backward: press.key == .upArrow,
                                                   history: terminal.history, current: command) {
                            command = line
                        }
                        return .handled
                    }
                    if press.key == KeyEquivalent("c"), press.modifiers.contains(.control) {
                        if terminal.isBusy {
                            Task { await terminal.interrupt() }
                        } else {
                            command = ""
                            history.reset()
                        }
                        return .handled
                    }
                    return .ignored
                }
                .accessibilityIdentifier("terminal.command")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func submit() {
        let line = command
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        command = ""
        history.reset()
        Task {
            if !(await terminal.run(line)) { command = line }
            focused = true
        }
    }
}

/// The toolbar's Terminal toggle; orange while a command runs with the pane hidden.
struct MacTerminalButton: View {
    @ObservedObject var navigation: MacHomeNavigation
    let session: CantripRemoteSession?

    var body: some View {
        let busy = session?.terminalBusy == true && !navigation.showingTerminal
        Button {
            withAnimation(.easeOut(duration: 0.15)) { navigation.showingTerminal.toggle() }
        } label: {
            Label(navigation.showingTerminal ? "Hide Terminal" : "Show Terminal", systemImage: "apple.terminal")
                .foregroundStyle(navigation.showingTerminal ? Color.accentColor : busy ? Color.orange : Color.primary)
        }
        .help(busy ? "Terminal: a command is running; click to watch (⌃`)"
              : "Terminal: this tab's shell on the Mac (⌃`)")
        .disabled(session == nil)
        .accessibilityIdentifier("terminal.toggle")
    }
}
