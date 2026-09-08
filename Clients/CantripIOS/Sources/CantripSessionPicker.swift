import SwiftUI

struct CantripSessionPicker: View {
    let sessions: [CantripRemoteSession]
    let selectedSessionID: String?
    let onSelect: (String) -> Void

    var selectedSession: CantripRemoteSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var selection: Binding<String?> {
        Binding(
            get: { selectedSession?.id },
            set: { id in
                if let id { onSelect(id) }
            }
        )
    }

    var body: some View {
        Menu {
            Picker("Tabs", selection: selection) {
                if selectedSession == nil {
                    Text("Choose a tab").tag(String?.none)
                        .disabled(true)
                }
                ForEach(sessions) { session in
                    Label(Self.menuTitle(for: session),
                          systemImage: session.isLocked == true ? "lock.fill" : "bubble.left")
                        .tag(Optional(session.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedSession?.isLocked == true ? "lock.fill" : "rectangle.stack")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedSession?.title ?? (sessions.isEmpty ? "No tabs" : "Choose a tab"))
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text(switcherSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selectedSession?.isStreaming == true {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(sessions.isEmpty)
        .accessibilityIdentifier("cantrip-session-picker")
        .accessibilityLabel("Switch tab")
        .accessibilityValue(
            [selectedSession?.title, switcherSummary].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityHint("Opens the list of Cantrip tabs")
    }

    private var switcherSummary: String {
        let count = sessions.count == 1 ? "1 tab" : "\(sessions.count) tabs"
        let status = selectedSession.map(Self.statusSummary) ?? ""
        return status.isEmpty ? "\(count) - Tap to switch" : "\(count) - \(status)"
    }

    static func statusSummary(for session: CantripRemoteSession) -> String {
        var parts: [String] = []
        if session.isLocked == true { parts.append("Locked") }
        if session.isStreaming { parts.append("Working") }
        if session.queuedCount > 0 { parts.append("\(session.queuedCount) queued") }
        return parts.joined(separator: ", ")
    }

    static func menuTitle(for session: CantripRemoteSession) -> String {
        let status = statusSummary(for: session)
        return status.isEmpty ? session.title : "\(session.title) - \(status)"
    }
}
