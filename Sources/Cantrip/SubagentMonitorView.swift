import SwiftUI

/// Live cards for the subagents a conversation spawned (Progress pane).
struct SubagentMonitorView: View {
    let activities: [ToolActivity]
    let stop: ((SubagentInfo, @escaping (String?) -> Void) -> Void)?
    @State private var showAllFinished = false
    private let finishedLimit = 6

    private var active: [ToolActivity] {
        activities.filter { $0.subagent?.isActive == true }
    }

    /// Newest first: the one that just ended is the one you're looking for.
    private var finished: [ToolActivity] {
        activities.filter { $0.subagent?.isActive == false }.reversed()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(active) { activity in
                SubagentCard(activity: activity, stop: stop)
            }
            let shown = showAllFinished ? finished : Array(finished.prefix(finishedLimit))
            ForEach(shown) { activity in
                SubagentCard(activity: activity, stop: stop)
            }
            if finished.count > finishedLimit {
                Button(showAllFinished ? "Show fewer"
                       : "Show \(finished.count - finishedLimit) earlier subagents") {
                    showAllFinished.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}

struct SubagentCard: View {
    let activity: ToolActivity
    let stop: ((SubagentInfo, @escaping (String?) -> Void) -> Void)?
    @State private var showSteps = false
    @State private var stopping = false
    @State private var stopError: String?

    private var info: SubagentInfo { activity.subagent ?? SubagentInfo(agentID: "", name: "", agentType: "", summary: "") }

    static let queuedHint = "Starts when the main agent waits for it or finishes its turn."

    private var currentStep: ToolActivity? {
        activity.children.last(where: { $0.state == .running }) ?? activity.children.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                SubagentStatusIcon(status: info.status)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    badges
                }
                Spacer(minLength: 4)
                if info.isActive, info.canCancel, stop != nil {
                    Button(action: requestStop) {
                        if stopping {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("Stop", systemImage: "stop.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(stopping)
                    .help("Stop only this subagent. The reply keeps going.")
                    .accessibilityLabel("Stop \(info.displayName)")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if !info.summary.isEmpty, info.summary != info.name {
                    Text(info.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if info.status == .queued {
                    Text(Self.queuedHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if info.status == .running, let now = info.intent ?? currentStep?.title {
                    Label {
                        Text(now).lineLimit(2)
                    } icon: {
                        Image(systemName: "arrow.forward.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Now: \(now)")
                }
                metaLine
                if let error = info.error {
                    problem(error, systemImage: "exclamationmark.triangle.fill")
                }
                if let stopError {
                    problem(stopError, systemImage: "exclamationmark.circle.fill")
                }
                if !activity.children.isEmpty || info.latestMessage != nil {
                    DisclosureGroup(isExpanded: $showSteps) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let latest = info.latestMessage {
                                Text(latest)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                                    .background(.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                                    .accessibilityLabel("Latest message: \(latest)")
                            }
                            ForEach(activity.children) { step in
                                ToolActivityRow(activity: step)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Text(activity.children.isEmpty ? "Latest message"
                             : "\(activity.children.count) \(activity.children.count == 1 ? "step" : "steps")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 21)
        }
        .padding(9)
        .background(.quaternary.opacity(info.isActive ? 0.45 : 0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if info.isActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 2)
                    .padding(.vertical, 6)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary(now: Date()))
    }

    /// Primary text keeps contrast in light mode; the red icon marks it as a problem.
    private func problem(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text).lineLimit(4)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.red)
        }
        .font(.caption)
        .foregroundStyle(.primary)
    }

    private var badges: some View {
        HStack(spacing: 4) {
            if !info.agentType.isEmpty { badge(info.agentType) }
            if info.background { badge("Background") }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var metaLine: some View {
        if info.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                metaText(now: context.date)
            }
        } else {
            metaText(now: Date())
        }
    }

    private func metaText(now: Date) -> some View {
        Text(metaParts(now: now).joined(separator: " · "))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func metaParts(now: Date) -> [String] {
        let steps = info.toolCalls ?? activity.children.count
        var parts = [SubagentStatusIcon.label(info.status),
                     SubagentInfo.elapsedLabel(info.elapsed(now: now))]
        if steps > 0 { parts.append("\(steps) \(steps == 1 ? "step" : "steps")") }
        if info.tokens > 0 { parts.append(SubagentInfo.tokenLabel(info.tokens)) }
        if let model = info.model { parts.append(info.effort.map { "\(model) (\($0))" } ?? model) }
        return parts
    }

    private func accessibilitySummary(now: Date) -> String {
        var parts = ["\(info.displayName) subagent"]
        if !info.agentType.isEmpty { parts.append(info.agentType) }
        if info.background { parts.append("background") }
        parts += metaParts(now: now)
        return parts.joined(separator: ", ")
    }

    private func requestStop() {
        guard let stop else { return }
        stopping = true
        stopError = nil
        stop(info) { error in
            stopping = false
            stopError = error
        }
    }
}

struct SubagentStatusIcon: View {
    let status: SubagentInfo.Status

    static func label(_ status: SubagentInfo.Status) -> String {
        switch status {
        case .queued: return "Queued"
        case .running: return "Running"
        case .idle: return "Waiting"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }

    var body: some View {
        Group {
            switch status {
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.mini)
            case .idle:
                Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .cancelled:
                Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Self.label(status))
    }
}

/// Compact subagent summary (pinned while running, then in the reply); opens the monitor.
struct SubagentStrip: View {
    let activities: [ToolActivity]
    let open: () -> Void

    private var agents: [SubagentInfo] { activities.compactMap(\.subagent) }
    private var active: [ToolActivity] { activities.filter { $0.subagent?.isActive == true } }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                if active.isEmpty {
                    Image(systemName: agents.contains { $0.status == .failed }
                          ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
                if active.isEmpty {
                    Text(summary(now: Date()))
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(summary(now: context.date))
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "sidebar.trailing")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show subagent progress in the Progress pane")
        .accessibilityHint("Opens the Progress pane with each subagent's details")
    }

    private func summary(now: Date) -> String {
        let noun = { (count: Int) in count == 1 ? "subagent" : "subagents" }
        if let lead = active.first(where: { $0.subagent?.status == .running }) ?? active.first,
           let info = lead.subagent {
            let statuses = active.compactMap(\.subagent?.status)
            let state = statuses.contains(.running) ? "running"
                : statuses.allSatisfy { $0 == .queued } ? "queued" : "waiting"
            var parts = ["\(active.count) \(noun(active.count)) \(state)"]
            let step = lead.children.last(where: { $0.state == .running })?.title
            parts.append(info.displayName + ((info.intent ?? step).map { ": \($0)" } ?? ""))
            parts.append(SubagentInfo.elapsedLabel(info.elapsed(now: now)))
            let done = agents.count - active.count
            if done > 0 { parts.append("\(done) finished") }
            return parts.joined(separator: " · ")
        }
        let failed = agents.filter { $0.status == .failed }.count
        let stopped = agents.filter { $0.status == .cancelled }.count
        var parts = ["\(agents.count) \(noun(agents.count)) finished"]
        if failed > 0 { parts.append("\(failed) failed") }
        if stopped > 0 { parts.append("\(stopped) stopped") }
        let longest = agents.map { $0.elapsed(now: now) }.max() ?? 0
        parts.append(SubagentInfo.elapsedLabel(longest))
        let tokens = agents.reduce(0) { $0 + $1.tokens }
        if tokens > 0 { parts.append(SubagentInfo.tokenLabel(tokens)) }
        return parts.joined(separator: " · ")
    }
}
