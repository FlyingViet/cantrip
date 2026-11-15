import SwiftUI

/// Home's Muse request in the Mac panel: the exact text Send delivers and, while it's open, Send,
/// Edit and Cancel. Acting here calls `MuseRequests` in-process.
struct MuseRequestCardView: View {
    let card: MuseRequestCard
    @State private var editing = false
    @State private var draft = ""
    @State private var error: String?
    @State private var confirmingOverride = false
    @State private var pendingOverrideText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Request for your Muse" + (card.demo == true ? " · demo account" : ""), systemImage: "sparkles")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: card.title)
                .font(.callout.weight(.semibold))
            if editing {
                TextEditor(text: $draft)
                    .font(.callout)
                    .frame(minHeight: 90, maxHeight: 260)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
                    .accessibilityLabel("Text to send to Muse")
            } else {
                Text(verbatim: card.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Text that Send delivers: \(card.text)")
            }
            Label(card.statusLine, systemImage: card.state == .held ? "hand.raised" : "info.circle")
                .font(.caption)
                .foregroundStyle(card.state == .held ? Color.orange : Color.secondary)
            if card.isOpen {
                HStack(spacing: 8) {
                    if editing {
                        Button("Send") { send(draft, override: false) }
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Save") { act(.edit(draft)) { editing = false } }
                        Button("Discard Changes") { editing = false; error = nil }
                    } else {
                        Button(card.state == .held ? "Send Anyway" : "Send") { send(card.text, override: card.state == .held) }
                            .buttonStyle(.borderedProminent)
                        Button("Edit") { draft = card.text; editing = true; error = nil }
                        Button("Cancel", role: .destructive) { act(.cancel) }
                    }
                }
                .controlSize(.small)
                Text("If unsent, it expires \(card.expiresAt.formatted(.relative(presentation: .named))).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let error {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request for your Muse: \(card.title)")
        .confirmationDialog("Send this to Muse anyway?", isPresented: $confirmingOverride, titleVisibility: .visible) {
            Button("Send Anyway", role: .destructive) {
                if let text = pendingOverrideText { act(.send(text: text, override: true)) { editing = false } }
            }
            Button("Don't Send", role: .cancel) {}
        } message: {
            Text(verbatim: "The Privacy Gate found \(MuseSendCheck.describe(reasons: card.findings ?? [])). Muse runs on Meta's servers.")
        }
    }

    private func send(_ text: String, override: Bool) {
        if override {
            pendingOverrideText = text
            confirmingOverride = true
        } else {
            act(.send(text: text, override: false)) { editing = false }
        }
    }

    private func act(_ action: MuseRequests.Action, then done: () -> Void = {}) {
        do {
            try MuseRequests.shared.perform(card.id, action, via: "Mac")
            error = nil
            done()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
