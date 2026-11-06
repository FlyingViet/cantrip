import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Everything running behind Cantrip Home: the chat's own background watchers plus
/// scheduled-task and incident runs in the Mac's hidden background conversation.
enum CantripHomeBackgroundCount {
    static func active(transcript: [CantripRemoteMessage], session: CantripRemoteSession?) -> Int {
        CantripPinnedSubagents.liveBackground(in: transcript).count
            + max(0, session?.backgroundActiveCount ?? 0)
    }
}

/// The Background jobs row in tab lists (drawer, Duo sidebar): Home's background runs, every
/// tab's background tasks and the Mac's build queue. Tab tasks and builds count as running jobs
/// and each get a line of their own.
struct CantripBackgroundJobsSummary: Equatable {
    var runs = 0
    var inputs = 0
    /// Background agents running in project tabs.
    var tabTasks = 0
    var buildsRunning = 0
    var buildsWaiting = 0

    /// Counts from Home's session (open or listed) and the tab list; `runs` covers the open Home
    /// chat's watchers too.
    init(runs: Int, inputs: Int, home: CantripRemoteSession?, tabs: [CantripRemoteSession] = []) {
        self.runs = max(0, runs)
        self.inputs = max(0, inputs)
        tabTasks = Self.tabTaskCount(in: tabs)
        buildsRunning = max(0, home?.buildsRunning ?? 0)
        buildsWaiting = max(0, home?.buildsWaiting ?? 0)
    }

    init(runs: Int = 0, inputs: Int = 0, tabTasks: Int = 0, buildsRunning: Int = 0, buildsWaiting: Int = 0) {
        self.runs = runs
        self.inputs = inputs
        self.tabTasks = tabTasks
        self.buildsRunning = buildsRunning
        self.buildsWaiting = buildsWaiting
    }

    static func tabTaskCount(in tabs: [CantripRemoteSession]) -> Int {
        tabs.filter { $0.isCantripHome != true }.reduce(0) { $0 + max(0, $1.backgroundTaskCount ?? 0) }
    }

    var isActive: Bool { inputs > 0 || runs + tabTasks + buildsRunning + buildsWaiting > 0 }

    var status: String {
        if inputs > 0 { return inputs == 1 ? "Needs input" : "\(inputs) need input" }
        let running = runs + tabTasks + buildsRunning
        if running > 0 { return "\(running) running" }
        return buildsWaiting > 0 ? "\(buildsWaiting) waiting" : "None running"
    }

    /// "3 in tabs"; nil while no tab has background work.
    var tabs: String? {
        tabTasks > 0 ? "\(tabTasks) in \(tabTasks == 1 ? "a tab" : "tabs")" : nil
    }

    /// The row's lines under its title: tab tasks, then builds.
    var details: [String] { [tabs, builds].compactMap { $0 } }

    /// "2 building · 1 waiting" (short enough for the Duo sidebar); nil while no build runs or waits.
    var builds: String? {
        switch (buildsRunning, buildsWaiting) {
        case (0, 0): return nil
        case (let running, 0): return "\(running) building"
        case (0, let waiting): return "\(waiting) \(waiting == 1 ? "build" : "builds") waiting"
        case (let running, let waiting): return "\(running) building · \(waiting) waiting"
        }
    }

    /// "Builds: 2 running, 1 waiting".
    var buildsAccessibilityText: String? {
        guard builds != nil else { return nil }
        return "Builds: " + [buildsRunning > 0 ? "\(buildsRunning) running" : nil,
                             buildsWaiting > 0 ? "\(buildsWaiting) waiting" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    var accessibilityValue: String {
        [status, tabTasks > 0 ? "Background tasks in tabs: \(tabTasks)" : nil, buildsAccessibilityText]
            .compactMap { $0 }.joined(separator: ". ")
    }
}

/// A tab's running background tasks in tab lists: "⚙ 2 in background" on two-line rows, "⚙ 2"
/// where the row is one line.
struct CantripTabBackgroundNote: View {
    let count: Int
    var compact = false

    static func accessibilityText(_ count: Int) -> String {
        "\(count) background \(count == 1 ? "task" : "tasks") running"
    }

    var body: some View {
        if count > 0 {
            HStack(spacing: 3) {
                Image(systemName: "gearshape.2")
                    .imageScale(.small)
                Text(compact ? "\(count)" : "\(count) in background")
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(CantripHomeBackgroundStyle.activeTint)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityText(count))
        }
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
    /// A Mac sheet draws no navigation-bar items; Full Log sits beside Done there.
    #if os(macOS)
    static let logPlacement = ToolbarItemPlacement.cancellationAction
    #else
    static let logPlacement = ToolbarItemPlacement.topBarLeading
    #endif

    @ObservedObject var remote: CantripRemoteModel
    /// Opens the background log as a Remote tab; clients without Remote tabs pass nil.
    var openLog: (() -> Void)?
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

    // Home's listed summary while a project tab is open: the tab lists' Background jobs row opens this there too.
    private var supportsRuns: Bool { remote.currentHomeSummary?.supportsBackgroundRuns == true }
    private var snapshot: CantripHomeBackgroundSnapshot? { supportsRuns ? remote.homeBackground : nil }
    private var builds: CantripBuildQueueSnapshot? { snapshot?.builds.flatMap { $0.isEmpty ? nil : $0 } }
    private var tabTasks: [CantripTabBackgroundTasks] { (snapshot?.tabTasks ?? []).filter { !$0.tasks.isEmpty } }
    private var hasRuns: Bool {
        !(snapshot?.runs.isEmpty ?? true) || !(snapshot?.queued.isEmpty ?? true) || builds != nil || !tabTasks.isEmpty
    }
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
                                ? (snapshot?.builds != nil
                                    ? "Scheduled tasks, incident investigations, background tasks in your tabs and builds taking turns on your Mac appear here."
                                    : "Scheduled tasks, incident investigations and background watchers appear here.")
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
                if snapshot != nil, let openLog {
                    ToolbarItem(placement: Self.logPlacement) {
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
            if !tabTasks.isEmpty {
                section("In tabs") {
                    ForEach(tabTasks) { tab in
                        CantripTabBackgroundGroup(remote: remote, tab: tab, onOpenTab: openTab)
                    }
                }
            }
            if let builds {
                section("Builds") {
                    CantripBuildQueueList(builds: builds, onOpenTab: openTab)
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
            remote: remote,
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

/// One tab's running background tasks: the tab (opens it), then each task as in the tab itself,
/// with its own Stop.
struct CantripTabBackgroundGroup: View {
    @ObservedObject var remote: CantripRemoteModel
    let tab: CantripTabBackgroundTasks
    var onOpenTab: ((String) -> Void)? = nil

    private var title: String {
        let trimmed = tab.tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "A tab" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let onOpenTab {
                Button { onOpenTab(tab.tabID) } label: { heading(chevron: true) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens \(title)")
            } else {
                heading(chevron: false)
            }
            CantripSubagentStack(remote: remote, sessionID: tab.tabID, subagents: tab.tasks)
        }
    }

    private func heading(chevron: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Text("· \(tab.tasks.count) \(tab.tasks.count == 1 ? "task" : "tasks")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The Mac's build queue: builds holding a slot, then the ones waiting, in turn order.
struct CantripBuildQueueList: View {
    let builds: CantripBuildQueueSnapshot
    /// Opens the tab a build came from.
    var onOpenTab: ((String) -> Void)? = nil

    var body: some View {
        ForEach(Array(builds.running.enumerated()), id: \.offset) { _, build in
            CantripBuildQueueRow(build: build, place: nil, onOpenTab: onOpenTab)
        }
        ForEach(Array(builds.waiting.enumerated()), id: \.offset) { index, build in
            CantripBuildQueueRow(build: build, place: index + 1, onOpenTab: onOpenTab)
        }
        Text(CantripBuildQueueFormat.footnote(builds))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum CantripBuildQueueFormat {
    /// "Smart card loading", "Child tab · Docs", "CI · cantrip · iOS TestFlight", "Home background run".
    static func origin(_ build: CantripBuildQueueSnapshot.Build) -> String {
        let tab = build.tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch build.source {
        case "ci": return build.job.map { "CI · \($0)" } ?? "CI job"
        case "background": return "Home background run"
        case "child": return tab.map { "Child tab · \($0)" } ?? "Child tab"
        default: return tab ?? "A tab"
        }
    }

    /// Running: "Smart card loading · 3m 12s". Waiting: "Waiting · 2nd in line · CI job · 45s".
    static func detail(_ build: CantripBuildQueueSnapshot.Build, place: Int?, now: Date) -> String {
        let elapsed = CantripSubagentFormat.elapsedLabel(startedAt: build.since, finishedAt: nil, now: now)
        guard let place else { return "\(origin(build)) · \(elapsed)" }
        let line = place == 1 ? "Next" : "\(ordinal(place)) in line"
        return "Waiting · \(line) · \(origin(build)) · \(elapsed)"
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }

    static func footnote(_ builds: CantripBuildQueueSnapshot) -> String {
        if builds.limit < builds.slots {
            let reason = builds.reason.map { " while \($0)" } ?? " while the Mac is busy"
            return "1 build at a time\(reason) (normally \(builds.slots)). Your tabs go first, then child tabs and CI, then Home's background runs."
        }
        let count = builds.slots == 1 ? "1 build" : "\(builds.slots) builds"
        return "Up to \(count) at once on your Mac. Your tabs go first, then child tabs and CI, then Home's background runs."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct CantripBuildQueueRow: View {
    let build: CantripBuildQueueSnapshot.Build
    /// Place in line while waiting; nil while it holds a slot.
    let place: Int?
    var onOpenTab: ((String) -> Void)? = nil

    private var openTab: (() -> Void)? {
        guard let id = build.tabID, build.tabTitle != nil, let onOpenTab else { return nil }
        return { onOpenTab(id) }
    }

    var body: some View {
        if let openTab {
            Button(action: openTab) { card(chevron: true) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens \(build.tabTitle ?? "its tab")")
        } else {
            card(chevron: false)
        }
    }

    private func card(chevron: Bool) -> some View {
        CantripHomeBackgroundCard {
            if place == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "hourglass").foregroundStyle(.secondary)
            }
        } content: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(build.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(CantripBuildQueueFormat.detail(build, place: place, now: timeline.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    /// Loads a question's Mac images through the run's own session.
    var remote: CantripRemoteModel? = nil
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
            if !run.isRunning, let cards = run.cards, !cards.isEmpty, let remote {
                CantripCardStack(cards: cards, remote: remote)
                    .padding(.top, 4)
                    .accessibilityIdentifier("home.background.cards")
            }
            if let handoffs = run.handoffs, !handoffs.isEmpty {
                CantripHandoffStack(handoffs: handoffs, onOpenTab: onOpenTab)
                    .padding(.top, 4)
            }
            if let onAnswer {
                ForEach(inputs) { request in
                    CantripInputCard(request: request, busy: inputBusy,
                                     sessionID: run.sessionID, remote: remote) { value in
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
                if !run.isRunning, CantripHomeRunSummaryText.isLabelledSummary(result) {
                    // A "Summary:" section: every line stays visible, each wrapping a little.
                    CantripHomeRunSummaryText(summary: result, lineLimit: isExpanded ? nil : 2)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(Self.markdown(result))
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(isExpanded ? nil : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
