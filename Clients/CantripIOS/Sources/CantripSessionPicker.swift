import SwiftUI

struct CantripSessionBar<Actions: View>: View {
    let sessions: [CantripRemoteSession]
    let selectedSessionID: String?
    @Binding var deliveryMode: CantripDeliveryMode
    let isMutating: Bool
    let onSelect: (String) -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            CantripSessionPicker(
                sessions: sessions, selectedSessionID: selectedSessionID, onSelect: onSelect
            )
            .contextMenu(menuItems: actions)

            if sessions.contains(where: { $0.id == selectedSessionID }) {
                Menu {
                    Picker("Delivery", selection: $deliveryMode) {
                        ForEach(CantripDeliveryMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(deliveryMode.title)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: 120, minHeight: 52)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(isMutating)
                .accessibilityIdentifier("cantrip-delivery-picker")
                .accessibilityLabel("Cantrip delivery override")
                .accessibilityValue(deliveryMode.title)
            }
        }
    }
}

struct CantripSessionPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let sessions: [CantripRemoteSession]
    let selectedSessionID: String?
    let onSelect: (String) -> Void
    @State private var showingTabs = false

    var selectedSession: CantripRemoteSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var selection: Binding<String?> {
        Binding(
            get: { selectedSession?.id },
            set: { id in
                if let id {
                    showingTabs = false
                    onSelect(id)
                }
            }
        )
    }

    var body: some View {
        // A Menu consumes long presses; a Button leaves them to the tab's context menu.
        Button {
            showingTabs = true
        } label: {
            HStack(spacing: 10) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: selectedSession?.isLocked == true ? "lock.fill" : "rectangle.stack")
                        .foregroundStyle(.tint)
                }
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
                if selectedSession?.isStreaming == true && !dynamicTypeSize.isAccessibilitySize {
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
        .disabled(sessions.isEmpty)
        .accessibilityIdentifier("cantrip-session-picker")
        .accessibilityLabel("Switch tab")
        .accessibilityValue(
            [selectedSession?.title, switcherSummary].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityHint("Tap to switch tabs. Touch and hold to rename, lock, unlock, or close this tab.")
        .popover(isPresented: $showingTabs, arrowEdge: .top) {
            tabList
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: sessions.isEmpty) { _, isEmpty in
            if isEmpty { showingTabs = false }
        }
    }

    private var tabList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(sessions) { session in
                    Button {
                        selection.wrappedValue = session.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: session.isLocked == true ? "lock.fill" : "bubble.left")
                                .foregroundStyle(.tint)
                            Text(Self.menuTitle(for: session))
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .opacity(session.id == selectedSessionID ? 1 : 0)
                        }
                        .padding(12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cantrip-tab-\(session.id)")
                    .accessibilityAddTraits(session.id == selectedSessionID ? [.isSelected] : [])
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(idealWidth: 320, maxWidth: 360, maxHeight: 400)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("cantrip-tab-list")
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
