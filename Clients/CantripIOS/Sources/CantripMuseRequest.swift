import SwiftUI

/// Home's Muse request, as the Mac sends it (`museRequest` on a `handoff` message).
struct CantripRemoteMuseRequest: Decodable, Equatable, Identifiable {
    enum State: String {
        case waiting, held, sending, sent, replied, noReply, cancelled, failed, other
    }

    let id: String
    let title: String
    /// Exactly what Send delivers.
    let text: String
    let chat: String
    let state: State
    let statusLine: String
    let expiresAt: Double?
    /// The actions open now ("send", "edit", "cancel"); empty once it's sent, cancelled or expired.
    let actions: [String]
    /// "Send", or "Send anyway" when the Privacy Gate held it.
    let sendLabel: String
    let findings: [String]
    let edited: Bool
    let demo: Bool

    var isOpen: Bool { actions.contains("send") }
    var isHeld: Bool { state == .held }

    private enum CodingKeys: String, CodingKey {
        case id, title, text, chat, state, statusLine, expiresAt, actions, sendLabel, findings, edited, demo
    }

    init(id: String, title: String, text: String, chat: String = "", state: State, statusLine: String = "",
         expiresAt: Double? = nil, actions: [String] = [], sendLabel: String = "Send", findings: [String] = [],
         edited: Bool = false, demo: Bool = false) {
        (self.id, self.title, self.text, self.chat, self.state, self.statusLine) = (id, title, text, chat, state, statusLine)
        (self.expiresAt, self.actions, self.sendLabel, self.findings, self.edited, self.demo)
            = (expiresAt, actions, sendLabel, findings, edited, demo)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String { (try? container.decodeIfPresent(String.self, forKey: key)) ?? "" }
        self.init(
            id: string(.id), title: string(.title), text: string(.text), chat: string(.chat),
            state: State(rawValue: string(.state)) ?? .other, statusLine: string(.statusLine),
            expiresAt: try? container.decodeIfPresent(Double.self, forKey: .expiresAt),
            actions: (try? container.decodeIfPresent([String].self, forKey: .actions)) ?? [],
            sendLabel: string(.sendLabel).isEmpty ? "Send" : string(.sendLabel),
            findings: (try? container.decodeIfPresent([String].self, forKey: .findings)) ?? [],
            edited: (try? container.decodeIfPresent(Bool.self, forKey: .edited)) == true,
            demo: (try? container.decodeIfPresent(Bool.self, forKey: .demo)) == true
        )
    }
}

struct CantripMuseRequestResponse: Decodable {
    let card: CantripRemoteMuseRequest
}

enum CantripMuseRequestAction: Equatable {
    /// `text`: what the card showed (or the edited text); `override`: Send anyway.
    case send(text: String, override: Bool)
    case edit(String)
    case cancel

    var name: String {
        switch self {
        case .send: return "send"
        case .edit: return "edit"
        case .cancel: return "cancel"
        }
    }
}

/// Home's Muse request: the exact text Send delivers, with Send, Edit and Cancel while it's open.
/// Send asks for Face ID or Touch ID first, as approvals do; nothing reaches Muse before it.
struct CantripMuseRequestCard: View {
    let card: CantripRemoteMuseRequest
    @ObservedObject var remote: CantripRemoteModel
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmingOverride = false
    @State private var working = false
    @State private var error: String?

    private var tint: Color {
        switch card.state {
        case .held, .failed: return .orange
        case .replied: return .green
        case .cancelled, .noReply, .other: return Color(.tertiaryLabel)
        case .waiting, .sending, .sent: return .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(card.demo ? "Request for your Muse · demo account" : "Request for your Muse")
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Text(verbatim: card.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: card.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Text that Send delivers: \(card.text)")
                Label {
                    Text(verbatim: card.statusLine)
                } icon: {
                    Image(systemName: card.isHeld ? "hand.raised.fill" : "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(card.isHeld ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if card.isOpen {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { sendButton; editButton; cancelButton }
                        VStack(alignment: .leading, spacing: 8) {
                            sendButton
                            HStack(spacing: 8) { editButton; cancelButton }
                        }
                    }
                    .disabled(working || remote.isMutating)
                    if let expiresAt = card.expiresAt {
                        Text("If unsent, it expires \(Date(timeIntervalSince1970: expiresAt).formatted(.relative(presentation: .named))).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let error {
                    Text(verbatim: error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.separator).opacity(0.24))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request for your Muse: \(card.title)")
        .sheet(isPresented: $editing) {
            CantripMuseRequestEditor(card: card, draft: $draft, working: working) { action in
                Task { await act(action, closesEditor: true) }
            }
        }
        .confirmationDialog("Send this to Muse anyway?", isPresented: $confirmingOverride, titleVisibility: .visible) {
            Button("Send Anyway", role: .destructive) { Task { await act(.send(text: card.text, override: true)) } }
            Button("Don't Send", role: .cancel) {}
        } message: {
            Text(verbatim: "The Privacy Gate found " + (card.findings.isEmpty ? "private details" : card.findings.joined(separator: ", "))
                 + ". Muse runs on Meta's servers.")
        }
    }

    private var sendButton: some View {
        Button {
            if card.isHeld { confirmingOverride = true } else { Task { await act(.send(text: card.text, override: false)) } }
        } label: {
            Label(card.sendLabel, systemImage: "paperplane.fill")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Asks for Face ID or Touch ID, then sends this exact text to your Muse.")
    }

    private var editButton: some View {
        Button {
            draft = card.text
            error = nil
            editing = true
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        .buttonStyle(.bordered)
    }

    private var cancelButton: some View {
        Button(role: .destructive) {
            Task { await act(.cancel) }
        } label: {
            Label("Cancel", systemImage: "xmark")
        }
        .buttonStyle(.bordered)
    }

    private func act(_ action: CantripMuseRequestAction, closesEditor: Bool = false) async {
        working = true
        defer { working = false }
        if await remote.actOnMuseRequest(card.id, action: action) != nil {
            error = nil
            if closesEditor { editing = false }
        } else {
            error = remote.errorMessage ?? "Nothing was sent. Try again."
        }
    }
}

/// Editing a Muse request: the text, then Send (the edited text) or Save.
private struct CantripMuseRequestEditor: View {
    let card: CantripRemoteMuseRequest
    @Binding var draft: String
    let working: Bool
    let perform: (CantripMuseRequestAction) -> Void
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 200)
                    .accessibilityLabel("Text to send to Muse")
                Text("Send delivers exactly this text. The Privacy Gate checks it again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\(trimmed.count) of 4,000 characters")
                    .font(.caption2)
                    .foregroundStyle(trimmed.count > 4_000 ? Color.red : Color.secondary)
            }
            .padding()
            .navigationTitle(card.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { perform(.send(text: trimmed, override: false)) }
                        .disabled(working || trimmed.isEmpty || trimmed.count > 4_000)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") { perform(.edit(trimmed)) }
                        .disabled(working || trimmed.isEmpty || trimmed.count > 4_000 || trimmed == card.text)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }
}
