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
            parts.append(CantripTabMentions.plain(preview))
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
        if let background = backgroundTaskCount, background > 0 {
            parts.append(CantripTabBackgroundNote.accessibilityText(background))
        }
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
                .chatBarItemFrame()
                .overlay(alignment: .topTrailing) {
                    CantripTabsBadge(workingCount: workingCount, inputCount: inputCount)
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
        CantripTabsBadge.accessibilityValue(workingCount: workingCount, inputCount: inputCount)
    }
}

/// The tabs button's count: "?" while a tab needs input, else how many are working.
struct CantripTabsBadge: View {
    let workingCount: Int
    var inputCount = 0

    var body: some View {
        if inputCount > 0 {
            badge(Image(systemName: "questionmark").font(.caption2.weight(.heavy)))
        } else if workingCount > 0 {
            badge(Text(workingCount > 9 ? "9+" : "\(workingCount)")
                .font(.caption2.weight(.bold)).monospacedDigit())
        }
    }

    static func accessibilityValue(workingCount: Int, inputCount: Int) -> String {
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
/// Home's sections in the tab drawer on the folded iPhone Duo. Its bar holds only actions and it has no
/// sidebar, so the drawer lists Chat, Tasks, Artifacts and Builds, as the unfolded Duo's sidebar does.
extension CantripRemoteModel {
    /// The count beside a Home section in the left menu: Chat's questions waiting for an
    /// answer, Tasks' running runs; nil when there is none.
    func homeSectionBadge(_ section: CantripHomeSection) -> Int? {
        let home = currentHomeSummary
        let count: Int
        switch section {
        case .chat: count = home?.isCantripHome == true ? home?.pendingInputCount ?? 0 : 0
        case .tasks: count = homeTasks.filter { $0.state == "running" }.count
        default: count = 0
        }
        return count > 0 ? count : nil
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
