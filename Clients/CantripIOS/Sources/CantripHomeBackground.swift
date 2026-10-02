import SwiftUI
import UIKit

/// Everything running behind Cantrip Home: the chat's own background watchers plus
/// scheduled-task and incident runs in the Mac's hidden background conversation.
enum CantripHomeBackgroundCount {
    static func active(transcript: [CantripRemoteMessage], session: CantripRemoteSession?) -> Int {
        CantripPinnedSubagents.liveBackground(in: transcript).count
            + max(0, session?.backgroundActiveCount ?? 0)
    }
}

enum CantripHomeBackgroundStyle {
    /// systemOrange is under 3:1 on light glass; light mode uses a deeper orange.
    static let activeTint = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemOrange
            : UIColor(red: 0.72, green: 0.33, blue: 0, alpha: 1)
    })
    static let badgeText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : .white
    })
}

/// Home's top-left action. Pulses and shows a count while anything is running.
struct CantripHomeBackgroundButton: View {
    let activeCount: Int
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ChatHeaderIcon(systemName: "gearshape.2")
                .foregroundStyle(activeCount > 0 ? CantripHomeBackgroundStyle.activeTint : Color.primary)
                .symbolEffect(.pulse, isActive: activeCount > 0 && !reduceMotion)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if activeCount > 0 {
                        Text(activeCount > 9 ? "9+" : "\(activeCount)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(CantripHomeBackgroundStyle.badgeText)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(CantripHomeBackgroundStyle.activeTint, in: Capsule())
                            .offset(x: -1, y: 3)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Background")
        .accessibilityValue(activeCount == 0 ? "Nothing running" : "\(activeCount) running")
        .accessibilityHint("Shows background tasks and scheduled runs")
        .accessibilityIdentifier("home.background")
    }
}

struct CantripHomeBackgroundView: View {
    @ObservedObject var remote: CantripRemoteModel
    let openLog: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<UUID> = []

    private var homeSessionID: String? {
        remote.selectedSession?.isCantripHome == true ? remote.selectedSessionID : nil
    }

    private var watchers: [CantripRemoteSubagent] {
        guard homeSessionID != nil else { return [] }
        return CantripPinnedSubagents.background(in: remote.selectedSession?.transcript ?? [])
    }

    private var supportsRuns: Bool { remote.selectedSession?.supportsBackgroundRuns == true }
    private var snapshot: CantripHomeBackgroundSnapshot? { supportsRuns ? remote.homeBackground : nil }
    private var hasRuns: Bool { !(snapshot?.runs.isEmpty ?? true) || !(snapshot?.queued.isEmpty ?? true) }

    var body: some View {
        NavigationStack {
            Group {
                if watchers.isEmpty, !hasRuns, remote.homeBackgroundError == nil {
                    if supportsRuns, snapshot == nil {
                        ProgressView("Loading background work…")
                    } else {
                        ContentUnavailableView(
                            "No background work",
                            systemImage: "gearshape.2",
                            description: Text(supportsRuns
                                ? "Scheduled tasks, incident investigations and background watchers appear here."
                                : "Background watchers appear here. Update Cantrip on your Mac to also see scheduled task and incident runs.")
                        )
                    }
                } else {
                    ScrollView {
                        content
                            .padding()
                    }
                    .refreshable { await remote.refreshHomeBackground() }
                }
            }
            .navigationTitle("Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if snapshot != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Full Log", action: openLog)
                            .accessibilityHint("Opens the conversation where background runs happen")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .top) {
                if !remote.isConnected {
                    Label("Disconnected. Showing the last known status.", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .task {
                while !Task.isCancelled {
                    await remote.refreshHomeBackground()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let homeSessionID, !watchers.isEmpty {
                section("In this chat") {
                    CantripSubagentStack(remote: remote, sessionID: homeSessionID, subagents: watchers)
                }
            }
            if let queued = snapshot?.queued, !queued.isEmpty {
                section("Waiting") {
                    ForEach(queued) { item in
                        CantripHomeBackgroundCard {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                        } content: {
                            Text(item.label)
                                .font(.subheadline.weight(.semibold))
                            Text("\(item.kind == "incident" ? "Incident" : "Scheduled task") · Waiting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let runs = snapshot?.runs, !runs.isEmpty {
                section("Scheduled and automated") {
                    ForEach(runs) { run in
                        CantripHomeBackgroundRunRow(
                            run: run,
                            activity: run.isRunning ? snapshot?.activity : nil,
                            isExpanded: Binding(
                                get: { expanded.contains(run.id) },
                                set: { if $0 { expanded.insert(run.id) } else { expanded.remove(run.id) } }
                            )
                        )
                    }
                }
            }
            if !supportsRuns {
                Text("Update Cantrip on your Mac to also see scheduled task and incident runs here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = remote.homeBackgroundError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

private struct CantripHomeBackgroundCard<Icon: View, Content: View>: View {
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4, content: content)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

struct CantripHomeBackgroundRunRow: View {
    let run: CantripHomeBackgroundRun
    var activity: String?
    @Binding var isExpanded: Bool

    private var result: String {
        run.isRunning
            ? (activity?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Running…"
            : run.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canExpand: Bool {
        !run.isRunning && (result.count > 120 || result.contains("\n"))
    }

    var statusText: String {
        switch run.status {
        case "running": "Running"
        case "succeeded": "Done"
        case "failed": "Failed"
        case "cancelled": "Stopped"
        case "interrupted": "Interrupted"
        default: run.status.capitalized
        }
    }

    var body: some View {
        if canExpand {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                card.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(isExpanded ? "Collapses the result" : "Shows the full result")
        } else {
            card.accessibilityElement(children: .combine)
        }
    }

    private var card: some View {
        CantripHomeBackgroundCard {
            statusIcon
        } content: {
            Text(run.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Text(detail(now: timeline.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !result.isEmpty {
                Text(Self.markdown(result))
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(isExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if canExpand {
                Label(isExpanded ? "Show less" : "Show full result",
                      systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch run.status {
        case "running":
            ProgressView().controlSize(.small)
        case "succeeded":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "failed":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        default:
            Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        }
    }

    func detail(now: Date) -> String {
        let kind = run.isIncident ? "Incident" : "Scheduled task"
        let elapsed = CantripSubagentFormat.elapsedLabel(
            startedAt: run.startedAt.timeIntervalSince1970,
            finishedAt: run.finishedAt?.timeIntervalSince1970, now: now
        )
        if run.isRunning {
            return "\(kind) · Running for \(elapsed)"
        }
        let when = (run.finishedAt ?? run.startedAt)
            .formatted(.relative(presentation: .named))
        return "\(kind) · \(statusText) \(when) · took \(elapsed)"
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
