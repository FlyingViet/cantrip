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
    /// Background-run requests waiting on the user.
    var inputCount = 0
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ChatHeaderIcon(systemName: "gearshape.2")
                .foregroundStyle(activeCount > 0 ? CantripHomeBackgroundStyle.activeTint : Color.primary)
                .symbolEffect(.pulse, isActive: activeCount > 0 && !reduceMotion)
                .frame(width: 44, height: 44)
                .overlay(alignment: .topTrailing) {
                    if inputCount > 0 {
                        Image(systemName: "questionmark")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(CantripHomeBackgroundStyle.badgeText)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(CantripHomeBackgroundStyle.activeTint, in: Capsule())
                            .offset(x: -1, y: 3)
                            .accessibilityHidden(true)
                    } else if activeCount > 0 {
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
        .accessibilityValue(inputCount > 0
            ? "\(inputCount) \(inputCount == 1 ? "needs" : "need") your input"
                + (activeCount > 0 ? ", \(activeCount) running" : "")
            : activeCount == 0 ? "Nothing running" : "\(activeCount) running")
        .accessibilityHint("Shows background tasks and scheduled runs")
        .accessibilityIdentifier("home.background")
    }
}

struct CantripHomeBackgroundView: View {
    @ObservedObject var remote: CantripRemoteModel
    let openLog: () -> Void
    /// Opens a live hidden run's conversation by ID.
    var openSession: ((String) -> Void)? = nil
    /// Opens the project tab a run was handed to.
    var openTab: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<UUID> = []
    /// Requests answered here, hidden until the next list no longer has them.
    @State private var answered: Set<UUID> = []
    @State private var answerError: String?

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
    private var canStop: Bool { snapshot?.supportsStop == true }

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
                    ScrollViewReader { proxy in
                        ScrollView {
                            content
                                .padding()
                        }
                        .refreshable { await remote.refreshHomeBackground() }
                        .onAppear { reveal(remote.homeBackgroundFocus, proxy) }
                        .onChange(of: remote.homeBackgroundFocus) { _, focus in reveal(focus, proxy) }
                        .onChange(of: snapshot?.runs.map(\.id)) { _, _ in reveal(remote.homeBackgroundFocus, proxy) }
                    }
                }
            }
            .navigationTitle("Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if snapshot != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Full Log", action: openLog)
                            .accessibilityHint("Opens the conversation that keeps finished background reports")
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
                    try? await Task.sleep(for: .seconds(needsInput.isEmpty ? 5 : 2))
                }
            }
            .onDisappear { remote.homeBackgroundFocus = nil }
        }
    }

    /// Running hidden runs waiting on the user, answered here rather than in their sessions.
    private var needsInput: [CantripHomeBackgroundRun] {
        (snapshot?.runs ?? []).filter { $0.needsInput && $0.sessionID != nil }
    }

    private func pendingInputs(_ run: CantripHomeBackgroundRun) -> [CantripInputRequest] {
        (run.inputs ?? []).filter { !answered.contains($0.id) }
    }

    private func reveal(_ focus: String?, _ proxy: ScrollViewProxy) {
        guard let focus, let run = snapshot?.runs.first(where: { $0.sessionID == focus }) else { return }
        withAnimation(.snappy) { proxy.scrollTo(run.id, anchor: .top) }
    }

    private func answer(_ run: CantripHomeBackgroundRun, _ request: CantripInputRequest,
                        _ answer: CantripInputAnswer) async {
        guard let sessionID = run.sessionID else { return }
        let accepted = await remote.respondToInput(
            sessionID: sessionID, id: request.id, answer: answer, identity: remote.usageIdentity,
            questionOnly: request.kind == "question"
        )
        if accepted {
            answered.insert(request.id)
            answerError = nil
            let result = switch answer.decision {
            case "approve": "Approved"
            case "deny": "Denied"
            case "cancel": "Skipped"
            default: "Answered"
            }
            AccessibilityNotification.Announcement("\(result). \(run.label) continues.").post()
        } else {
            answerError = remote.errorMessage ?? "Your answer could not be delivered. Nothing was retried."
        }
        await remote.refreshHomeBackground()
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !needsInput.isEmpty {
                section("Needs your input") {
                    ForEach(needsInput) { run in
                        runRow(run, inputs: pendingInputs(run))
                    }
                    if let answerError {
                        Label(answerError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let homeSessionID, !watchers.isEmpty {
                section("In this chat") {
                    CantripSubagentStack(remote: remote, sessionID: homeSessionID, subagents: watchers)
                }
            }
            if let queued = snapshot?.queued, !queued.isEmpty {
                section("Waiting") {
                    ForEach(queued) { item in
                        CantripHomeBackgroundQueuedRow(
                            item: item,
                            onSkip: canStop ? { await remote.stopHomeBackgroundRun(item.id) } : nil
                        )
                    }
                }
            }
            if let runs = snapshot?.runs.filter({ run in !needsInput.contains { $0.id == run.id } }), !runs.isEmpty {
                section("Scheduled and automated") {
                    ForEach(runs) { run in
                        runRow(run, inputs: [])
                    }
                }
                if let limit = snapshot?.maxParallel {
                    Text("Up to \(limit) run at once, each in its own hidden session. Incidents in a project an open tab owns go to that tab.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

    private func runRow(_ run: CantripHomeBackgroundRun, inputs: [CantripInputRequest]) -> some View {
        CantripHomeBackgroundRunRow(
            run: run,
            activity: run.isRunning ? snapshot?.activity : nil,
            isExpanded: Binding(
                get: { expanded.contains(run.id) },
                set: { if $0 { expanded.insert(run.id) } else { expanded.remove(run.id) } }
            ),
            onStop: canStop && run.canStop == true
                ? { await remote.stopHomeBackgroundRun(run.id) } : nil,
            onOpen: run.isRunning ? run.sessionID.flatMap { id in
                openSession.map { open in { open(id) } }
            } : nil,
            onOpenTab: openTab,
            inputs: inputs,
            inputBusy: remote.isMutating,
            onAnswer: { request, value in await answer(run, request, value) },
            isFocused: run.sessionID != nil && run.sessionID == remote.homeBackgroundFocus
        )
        .id(run.id)
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

/// Stop for a running run, Skip for one still waiting; both confirm first.
private struct CantripHomeBackgroundStopButton: View {
    let title: String
    let label: String
    let action: () async -> Bool
    @State private var confirming = false
    @State private var stopping = false

    var body: some View {
        Button(role: .destructive) {
            confirming = true
        } label: {
            Text(stopping ? "\(title == "Skip" ? "Skipping" : "Stopping")…" : title)
                .font(.caption.weight(.semibold))
                .frame(minHeight: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(stopping)
        .accessibilityLabel("\(title) \(label)")
        .confirmationDialog(
            title == "Skip" ? "Skip this run?" : "Stop this background run?",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("\(title) \(label)", role: .destructive) {
                Task {
                    stopping = true
                    _ = await action()
                    stopping = false
                }
            }
        } message: {
            Text(title == "Skip"
                 ? "It won't run until its next scheduled time."
                 : "Other background work keeps running.")
        }
    }
}

struct CantripHomeBackgroundQueuedRow: View {
    let item: CantripHomeBackgroundQueuedRun
    var onSkip: (() async -> Bool)? = nil

    var detail: String {
        let kind = item.kind == "incident" ? "Incident" : "Scheduled task"
        let reason = item.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = "\(kind) · \(reason.flatMap { $0.isEmpty ? nil : $0 } ?? "Waiting")"
        if let repeats = item.repeats, repeats > 0 { text += " · reported \(repeats + 1) times" }
        return text
    }

    var body: some View {
        CantripHomeBackgroundCard {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.label)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let onSkip {
                CantripHomeBackgroundStopButton(title: "Skip", label: item.label, action: onSkip)
                    .padding(.top, 4)
            }
        }
    }
}

struct CantripHomeBackgroundRunRow: View {
    let run: CantripHomeBackgroundRun
    var activity: String?
    @Binding var isExpanded: Bool
    var onStop: (() async -> Bool)? = nil
    var onOpen: (() -> Void)? = nil
    var onOpenTab: ((String) -> Void)? = nil
    /// Approvals and questions this run waits on, answered right here.
    var inputs: [CantripInputRequest] = []
    var inputBusy = false
    var onAnswer: ((CantripInputRequest, CantripInputAnswer) async -> Void)? = nil
    /// The run a notification or task pointed at.
    var isFocused = false

    private var result: String {
        if run.isRunning {
            let live = (run.activity ?? activity)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return live.flatMap { $0.isEmpty ? nil : $0 } ?? "Running…"
        }
        return run.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A run handed to a tab shows its handoff card instead of repeating its status.
    private var showsResult: Bool { !result.isEmpty && !run.isHandedOff }

    private var canExpand: Bool {
        showsResult && !run.isRunning && (result.count > 120 || result.contains("\n"))
    }

    private var tabTitle: String? {
        guard let title = run.tabHandoff?.tabTitle.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return title.isEmpty ? "its project tab" : title
    }

    var statusText: String {
        switch run.status {
        case "running": "Running"
        case "succeeded": "Done"
        case "failed": "Failed"
        case "cancelled": "Stopped"
        case "interrupted": "Interrupted"
        case "skipped": "Skipped"
        default: run.status.capitalized
        }
    }

    var body: some View {
        CantripHomeBackgroundCard {
            statusIcon
        } content: {
            if canExpand {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    summary.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(isExpanded ? "Collapses the result" : "Shows the full result")
            } else {
                summary.accessibilityElement(children: .combine)
            }
            if let handoffs = run.handoffs, !handoffs.isEmpty {
                CantripHandoffStack(handoffs: handoffs, onOpenTab: onOpenTab)
                    .padding(.top, 4)
            }
            if let onAnswer {
                ForEach(inputs) { request in
                    CantripInputCard(request: request, busy: inputBusy) { value in
                        Task { await onAnswer(request, value) }
                    }
                    .accessibilityIdentifier("home.background.input")
                }
                if inputs.isEmpty, run.needsInput {
                    // Older Macs don't list the request; the live run shows it.
                    Text("Open this run to answer it. Update Cantrip on your Mac to answer here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if onStop != nil || onOpen != nil {
                HStack(spacing: 8) {
                    if let onOpen {
                        Button(action: onOpen) {
                            Text("Open")
                                .font(.caption.weight(.semibold))
                                .frame(minHeight: 28)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Open \(run.label)")
                        .accessibilityHint("Shows this run's live conversation")
                    }
                    if let onStop {
                        CantripHomeBackgroundStopButton(title: "Stop", label: run.label, action: onStop)
                    }
                }
                .padding(.top, 4)
            }
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 2)
                    .accessibilityHidden(true)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Text(detail(now: timeline.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsResult {
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var statusIcon: some View {
        switch run.status {
        case "running":
            if run.needsInput {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(CantripHomeBackgroundStyle.activeTint)
                    .accessibilityLabel("Needs your input")
            } else if run.tabHandoff?.status == .queued {
                Image(systemName: "tray.full").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        case "succeeded":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "failed":
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case "skipped":
            Image(systemName: "forward.circle.fill").foregroundStyle(.secondary)
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
        let repeats = (run.repeats ?? 0) > 0 ? " · reported \((run.repeats ?? 0) + 1) times" : ""
        if run.isRunning {
            if let tabTitle {
                let state = run.tabHandoff?.status == .queued ? "Queued in" : "Running in"
                return "\(kind) · \(state) \(tabTitle) for \(elapsed)\(repeats)"
            }
            return "\(kind) · Running for \(elapsed)\(repeats)"
        }
        let when = (run.finishedAt ?? run.startedAt)
            .formatted(.relative(presentation: .named))
        let place = tabTitle.map { " in \($0)" } ?? ""
        if run.status == "skipped" {
            return "\(kind) · Skipped \(when)\(repeats)"
        }
        return "\(kind) · \(statusText)\(place) \(when) · took \(elapsed)\(repeats)"
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
