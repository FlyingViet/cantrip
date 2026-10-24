import SwiftUI

/// Counts for Cantrip Home's Tabs button.
enum CantripHomeTabCounts {
    static func working(in sessions: [CantripRemoteSession]) -> Int {
        sessions.filter(\.isStreaming).count
    }

    /// Tabs with a question or request waiting on the user.
    static func needingInput(in sessions: [CantripRemoteSession]) -> Int {
        sessions.filter { ($0.pendingInputCount ?? 0) > 0 }.count
    }
}

/// Short "now / 5m / 3h / 2d / 4w" ages for tab lists.
enum CantripRelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / 604_800))w"
        }
    }

    static func spoken(_ date: Date, now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// The second line of a tab row: live status while working, else the latest reply's outcome.
enum CantripTabRowText {
    struct Detail: Equatable {
        let text: String
        /// Working or waiting on the user: shown in the active tint.
        let isActive: Bool
    }

    static func detail(for session: CantripRemoteSession) -> Detail? {
        if (session.pendingInputCount ?? 0) > 0 {
            return Detail(text: "Needs your input", isActive: true)
        }
        if session.isStreaming {
            return Detail(text: nonEmpty(session.status) ?? "Working…", isActive: true)
        }
        var parts: [String] = []
        if session.queuedCount > 0 { parts.append("\(session.queuedCount) queued") }
        if let preview = nonEmpty(session.preview) {
            parts.append(preview)
        } else if session.isLocalPrivate == true {
            parts.append("Self-hosted, saved")
        } else if let status = nonEmpty(session.status) {
            parts.append(status)
        }
        return parts.isEmpty ? nil : Detail(text: parts.joined(separator: " · "), isActive: false)
    }

    /// Working, Needs input, Idle, … for a tab's header and the Mac toolbar.
    static func state(for session: CantripRemoteSession?, connection: CantripRemoteConnectionState) -> Detail {
        switch connection {
        case .reconnecting: return Detail(text: "Reconnecting…", isActive: false)
        case .disconnected: return Detail(text: "Disconnected", isActive: false)
        case .connected: break
        }
        guard let session else { return Detail(text: "Idle", isActive: false) }
        if (session.pendingInputCount ?? 0) > 0 { return Detail(text: "Needs input", isActive: true) }
        if session.isStreaming { return Detail(text: "Working", isActive: true) }
        if session.queuedCount > 0 { return Detail(text: "\(session.queuedCount) queued", isActive: false) }
        return Detail(text: "Idle", isActive: false)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// A tab's spinner while working, a question mark while it waits on the user, else a dot.
struct CantripTabStatusIndicator: View {
    let session: CantripRemoteSession

    var body: some View {
        Group {
            if (session.pendingInputCount ?? 0) > 0 {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(CantripHomeBackgroundStyle.activeTint)
            } else if session.isStreaming {
                ProgressView()
                    .controlSize(.small)
                    .tint(CantripHomeBackgroundStyle.activeTint)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.7))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// How long ago a tab last ran; refreshes every minute.
struct CantripTabAgeText: View {
    let date: Date?

    var body: some View {
        if let date {
            // The schedule's dates fall on minute boundaries, up to a minute early; read the clock.
            TimelineView(.everyMinute) { _ in
                Text(CantripRelativeTime.short(date, now: Date()))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityHidden(true)
        }
    }
}

extension CantripRemoteSession {
    /// Name, state, latest line and age, read as one row by VoiceOver.
    var tabRowAccessibilityValue: String {
        var parts: [String] = []
        if isLocalPrivate == true { parts.append("Self-hosted, saved") } else if isLocked == true { parts.append("Locked") }
        if let detail = CantripTabRowText.detail(for: self) { parts.append(detail.text) }
        if let date = lastActivityDate { parts.append(CantripRelativeTime.spoken(date)) }
        return parts.joined(separator: ", ")
    }
}

/// Cantrip Home's top-left button: opens the tab drawer. The badge counts working tabs, or shows
/// a question mark while a tab or background job waits on the user.
struct CantripHomeTabsButton: View {
    let workingCount: Int
    var inputCount = 0
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChatHeaderIcon(systemName: "sidebar.left")
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if inputCount > 0 {
                        badge(Image(systemName: "questionmark").font(.caption2.weight(.heavy)))
                    } else if workingCount > 0 {
                        badge(Text(workingCount > 9 ? "9+" : "\(workingCount)")
                            .font(.caption2.weight(.bold)).monospacedDigit())
                    }
                }
                .contentShape(Rectangle())
        }
        .disabled(!isEnabled)
        .accessibilityLabel("Tabs")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows your project tabs and background jobs. You can also swipe right from the left edge.")
        .accessibilityIdentifier("home.tabs")
    }

    private var accessibilityValue: String {
        let working = workingCount == 0 ? "None working" : "\(workingCount) working"
        guard inputCount > 0 else { return working }
        return "\(inputCount) \(inputCount == 1 ? "needs" : "need") your input, " + working.lowercased()
    }

    private func badge(_ content: some View) -> some View {
        content
            .foregroundStyle(CantripHomeBackgroundStyle.badgeText)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(CantripHomeBackgroundStyle.activeTint, in: Capsule())
            .offset(x: 4, y: -2)
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// Narrow screens and large text drop the pill's "Home" label so the tab title keeps room.
    @Entry var cantripCompactBackPill = false
}

/// A project tab's way back: "‹ Home" with a still Pip.
struct CantripHomeBackPill: View {
    @Environment(\.chatDisplayTraits) private var displayTraits
    @Environment(\.cantripCompactBackPill) private var compact
    @AppStorage(CantripMascotOutfit.storageKey) private var outfit: CantripMascotOutfit = .starryPlush
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if displayTraits.hasVerticalBar {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                    CantripMascotView(mood: .idle, outfit: outfit, size: 24, frameTime: 1)
                    if !compact {
                        Text("Home")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, compact ? 8 : 12)
                .frame(minWidth: 44, minHeight: 44)
                .glassEffect(.regular.interactive(), in: Capsule())
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Home")
        .accessibilityHint("Returns to Cantrip Home. You can also swipe right from the left edge.")
        .accessibilityIdentifier("tab.home")
    }
}

/// A project tab's centered title with its Working / Idle state.
struct CantripTabHeaderTitle: View {
    let session: CantripRemoteSession?
    let connectionState: CantripRemoteConnectionState
    /// Leading in the sidebar layout's header, like Gateway Mac's toolbar title.
    var alignment: HorizontalAlignment = .center

    var body: some View {
        let state = CantripTabRowText.state(for: session, connection: connectionState)
        VStack(alignment: alignment, spacing: 1) {
            HStack(spacing: 4) {
                if session?.isLocalPrivate == true {
                    Image(systemName: "lock.shield.fill").font(.caption)
                } else if session?.isLocked == true {
                    Image(systemName: "lock.fill").font(.caption)
                }
                Text(session?.title ?? "Tab")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 4) {
                if session?.isStreaming == true, connectionState == .connected,
                   (session?.pendingInputCount ?? 0) == 0 {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(CantripHomeBackgroundStyle.activeTint)
                }
                Text(state.text)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.isActive ? CantripHomeBackgroundStyle.activeTint : Color.secondary)
        }
        .foregroundStyle(.primary)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session?.title ?? "Tab")
        .accessibilityValue([
            session?.isLocalPrivate == true ? "Self-hosted, saved" : session?.isLocked == true ? "Locked" : nil,
            state.text,
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("tab.header.title")
    }
}

/// Cantrip Home's left drawer: Home pinned first, then background jobs, then every project tab.
struct CantripHomeTabDrawer: View {
    @ObservedObject var model: CantripRemoteModel
    var isModal = true
    let backgroundActiveCount: Int
    let backgroundInputCount: Int
    let onDismiss: () -> Void
    let onSelectHome: () -> Void
    let onOpenBackground: () -> Void
    let onSelect: (String) -> Void
    let onCreate: () -> Void
    let onRename: (CantripRemoteSession) -> Void
    let onClose: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @AccessibilityFocusState private var titleFocused: Bool
    @AppStorage(CantripMascotOutfit.storageKey) private var outfit: CantripMascotOutfit = .starryPlush

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            searchField
            tabs
            footer
        }
        .padding(.top, 8)
        .onAppear { titleFocused = isModal }
        .onChange(of: model.sessions.isEmpty) { _, empty in
            if empty { query = "" }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("Cantrip")
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            Spacer(minLength: 0)
            Button {
                searchFocused = false
                if isModal { onDismiss() }
                onCreate()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.isConfigured || model.isMutating)
            .accessibilityLabel("New Tab")
            .accessibilityIdentifier("drawer.newTab")
        }
        .padding(.horizontal)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if isModal, CantripDrawerGesture.shouldClose(translation: value.translation) {
                        onDismiss()
                    }
                }
        )
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search tabs", text: $query)
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("drawer.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .disabled(model.sessions.isEmpty)
    }

    private var homeRow: some View {
        Button {
            searchFocused = false
            onSelectHome()
        } label: {
            HStack(spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    CantripMascotView(mood: model.isConnected ? .idle : .sleeping, outfit: outfit, size: 44, frameTime: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "house.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.purple)
                        Text("Cantrip Home")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(45))
                    }
                    Text(CantripHomeSection.allCases.map(\.title).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.purple.opacity(homeSelected ? 0.22 : 0.1), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                if homeSelected {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Color.purple.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .accessibilityLabel("Cantrip Home")
        .accessibilityValue("Pinned. " + CantripHomeSection.allCases.map(\.title).joined(separator: ", "))
        .accessibilityAddTraits(homeSelected ? .isSelected : [])
        .accessibilityIdentifier("drawer.home")
    }

    private var backgroundRow: some View {
        Button {
            searchFocused = false
            onOpenBackground()
        } label: {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(backgroundActive ? CantripHomeBackgroundStyle.activeTint : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(CantripHomeBackgroundStyle.activeTint.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 9))
                    Text("Background jobs")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(backgroundStatus)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(backgroundActive ? CantripHomeBackgroundStyle.activeTint : Color.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
            .frame(minHeight: 52)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .accessibilityLabel("Background jobs")
        .accessibilityValue(backgroundStatus)
        .accessibilityHint("Shows background tasks and scheduled runs")
        .accessibilityIdentifier("drawer.background")
    }

    private var tabsHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tabs · \(model.sessions.count)")
                .textCase(.uppercase)
                .accessibilityLabel("\(model.sessions.count) \(model.sessions.count == 1 ? "tab" : "tabs")")
            Spacer(minLength: 8)
            let working = CantripHomeTabCounts.working(in: model.sessions)
            if working > 0 {
                Text("\(working) working")
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var tabs: some View {
        CantripTabList(
            sessions: filteredSessions,
            selectedSessionID: model.isHomeSelected ? nil : model.selectedSessionID,
            onSelect: { id in
                searchFocused = false
                if isModal { onDismiss() }
                onSelect(id)
            },
            // Reordering a filtered list would move tabs relative to hidden ones.
            onMove: query.isEmpty ? { id, targetID, after in
                Task { await model.moveTab(id, relativeTo: targetID, after: after) }
            } : nil,
            header: {
                AnyView(VStack(alignment: .leading, spacing: 10) {
                    homeRow
                    if showsBackgroundJobs { backgroundRow }
                    tabsHeader
                    if filteredSessions.isEmpty { emptyTabs }
                }
                .padding(.bottom, 2))
            }
        ) { session in
            CantripTabActions(
                model: model, session: session,
                onRename: {
                    if isModal { onDismiss() }
                    onRename(session)
                },
                onClose: { onClose(session.id) }
            )
        }
        .disabled(model.isMutating && !model.isReorderingTabs)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var emptyTabs: some View {
        if model.sessions.isEmpty {
            ContentUnavailableView(
                model.isConfigured ? "No Tabs" : "Not Connected",
                systemImage: model.isConfigured ? "rectangle.stack" : "antenna.radiowaves.left.and.right.slash",
                description: Text(model.isConfigured
                    ? "Tap + to start a project tab on your Mac."
                    : "Pair with Cantrip in Settings to see your Mac's tabs.")
            )
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .accessibilityIdentifier("cantrip-tab-error")
            }
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text("\(serverName) · \(model.connectionLabel.lowercased())")
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.middle)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("drawer.connection")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: State

    private var homeSelected: Bool { model.isHomeSelected }

    private var homeSnapshot: CantripRemoteSession? {
        model.isHomeSelected ? model.selectedSession : model.homeSummary
    }

    private var showsBackgroundJobs: Bool {
        homeSnapshot?.supportsBackgroundRuns == true || backgroundActiveCount > 0 || backgroundInputCount > 0
    }

    private var backgroundActive: Bool { backgroundActiveCount > 0 || backgroundInputCount > 0 }

    private var backgroundStatus: String {
        if backgroundInputCount > 0 {
            return backgroundInputCount == 1 ? "Needs input" : "\(backgroundInputCount) need input"
        }
        return backgroundActiveCount > 0 ? "\(backgroundActiveCount) running" : "None running"
    }

    private var serverName: String {
        let name = model.servers.selected?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? model.endpointHost : name
    }

    private var filteredSessions: [CantripRemoteSession] {
        CantripHomeTabSearch.filter(model.sessions, query: query)
    }
}

enum CantripHomeTabSearch {
    /// Tabs whose name, folder or latest line contains every word of the query.
    static func filter(_ sessions: [CantripRemoteSession], query: String) -> [CantripRemoteSession] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return sessions }
        return sessions.filter { session in
            let haystack = [
                session.title, session.customTitle ?? "",
                (session.workdir as NSString).lastPathComponent, session.preview ?? "",
            ].joined(separator: "\n")
            return words.allSatisfy { haystack.localizedStandardContains($0) }
        }
    }
}
