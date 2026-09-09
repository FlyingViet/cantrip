import SwiftUI

struct CantripSessionBar<Actions: View>: View {
    let sessions: [CantripRemoteSession]
    let selectedSessionID: String?
    @Binding var deliveryMode: CantripDeliveryMode
    let isMutating: Bool
    let onOpenTabs: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            CantripSessionPicker(
                sessions: sessions, selectedSessionID: selectedSessionID, onOpenTabs: onOpenTabs
            )
            .contextMenu(menuItems: actions)
            .disabled(isMutating)

            if sessions.contains(where: { $0.id == selectedSessionID }) {
                CantripDeliveryPicker(deliveryMode: $deliveryMode)
                    .disabled(isMutating)
            }
        }
    }
}

struct CantripDeliveryPicker: View {
    @Binding var deliveryMode: CantripDeliveryMode

    var body: some View {
        Menu {
            Picker("Delivery", selection: $deliveryMode) {
                ForEach(CantripDeliveryMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(deliveryMode.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.caption.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.tint.opacity(0.12), in: Capsule())
            .frame(width: 84, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityIdentifier("cantrip-delivery-picker")
        .accessibilityLabel("Cantrip delivery override")
        .accessibilityValue(deliveryMode.title)
    }
}

struct CantripSessionPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let sessions: [CantripRemoteSession]
    let selectedSessionID: String?
    let onOpenTabs: () -> Void

    var selectedSession: CantripRemoteSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        // A Menu consumes long presses; a Button leaves them to the tab's context menu.
        Button(action: onOpenTabs) {
            HStack(spacing: 10) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: selectedSession?.isLocked == true ? "lock.fill" : "rectangle.stack")
                        .foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    CantripSessionTitle(
                        title: selectedSession?.title ?? (sessions.isEmpty ? "No tabs" : "Choose a tab"),
                        isStreaming: selectedSession?.isStreaming == true
                    )
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(switcherSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "sidebar.left")
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
        .disabled(sessions.isEmpty)
        .accessibilityIdentifier("cantrip-session-picker")
        .accessibilityLabel("Switch tab")
        .accessibilityValue(
            [selectedSession.map(Self.accessibilityTitle), switcherSummary]
                .compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityHint("Tap or swipe right from the left edge to open tabs. Touch and hold for tab actions.")
    }

    private var switcherSummary: String {
        let count = sessions.count == 1 ? "1 tab" : "\(sessions.count) tabs"
        let status = selectedSession.map(Self.statusSummary) ?? ""
        return status.isEmpty ? "\(count) - Swipe or tap" : "\(count) - \(status)"
    }

    static func statusSummary(for session: CantripRemoteSession) -> String {
        var parts: [String] = []
        if session.isLocked == true { parts.append("Locked") }
        if session.queuedCount > 0 { parts.append("\(session.queuedCount) queued") }
        return parts.joined(separator: ", ")
    }

    static func accessibilityTitle(for session: CantripRemoteSession) -> String {
        session.isStreaming ? "\(session.title), Working" : session.title
    }

    static func menuTitle(for session: CantripRemoteSession) -> String {
        let status = statusSummary(for: session)
        return status.isEmpty ? session.title : "\(session.title) - \(status)"
    }
}

struct CantripSessionTitle: View {
    let title: String
    let isStreaming: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
            if isStreaming {
                ThinkingView(size: 18)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
    }
}
