import Foundation
import SwiftUI
import UIKit

enum CantripSubagentFormat {
    static func displayName(for subagent: CantripRemoteSubagent) -> String {
        let name = trimmed(subagent.name)
        if !name.isEmpty { return name }
        let type = trimmed(subagent.agentType)
        if !type.isEmpty { return type.capitalized }
        return "Subagent"
    }

    static func tokenLabel(_ tokens: Int) -> String {
        let value = max(0, tokens)
        if value < 1_000 { return "\(value) tokens" }
        if value < 1_000_000 {
            return String(format: "%.1fk tokens", Double(value) / 1_000)
        }
        return String(format: "%.1fM tokens", Double(value) / 1_000_000)
    }

    static func tokenAccessibilityLabel(_ tokens: Int) -> String {
        let value = max(0, tokens)
        if value < 1_000 { return "\(value) tokens" }
        if value < 1_000_000 {
            return String(format: "%.1f thousand tokens", Double(value) / 1_000)
        }
        return String(format: "%.1f million tokens", Double(value) / 1_000_000)
    }

    static func elapsedLabel(startedAt: TimeInterval?, finishedAt: TimeInterval?, now: Date) -> String {
        let seconds = elapsedSeconds(startedAt: startedAt, finishedAt: finishedAt, now: now)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 {
            return String(format: "%dm %02ds", seconds / 60, seconds % 60)
        }
        return String(format: "%dh %02dm", seconds / 3_600, (seconds % 3_600) / 60)
    }

    static func elapsedAccessibilityLabel(startedAt: TimeInterval?, finishedAt: TimeInterval?, now: Date) -> String {
        let seconds = elapsedSeconds(startedAt: startedAt, finishedAt: finishedAt, now: now)
        if seconds < 60 { return "\(seconds) \(seconds == 1 ? "second" : "seconds")" }
        if seconds < 3_600 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            if remainder == 0 { return "\(minutes) \(minutes == 1 ? "minute" : "minutes")" }
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes") \(remainder) \(remainder == 1 ? "second" : "seconds")"
        }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if minutes == 0 { return "\(hours) \(hours == 1 ? "hour" : "hours")" }
        return "\(hours) \(hours == 1 ? "hour" : "hours") \(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    static func stepLabel(_ count: Int) -> String {
        let value = max(0, count)
        return "\(value) \(value == 1 ? "step" : "steps")"
    }

    static func readableError(_ error: Error) -> String {
        if case CantripRemoteError.http(_, let message) = error { return message }
        return error.localizedDescription
    }

    static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func elapsedSeconds(startedAt: TimeInterval?, finishedAt: TimeInterval?, now: Date) -> Int {
        guard let startedAt else { return 0 }
        let end = finishedAt ?? now.timeIntervalSince1970
        return max(0, Int((end - startedAt).rounded(.down)))
    }
}

/// Running subagents stay pinned above the composer so a growing reply can't
/// scroll them away; each card returns to its reply once it finishes.
struct CantripPinnedSubagents: View {
    @ObservedObject var remote: CantripRemoteModel
    let sessionID: String?
    let subagents: [CantripRemoteSubagent]
    let maxHeight: CGFloat

    @State private var contentHeight: CGFloat = 0

    static func live(in messages: [CantripRemoteMessage]) -> [CantripRemoteSubagent] {
        messages.flatMap { $0.subagents ?? [] }.filter(\.status.isLive)
    }

    var body: some View {
        if !subagents.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(subagents) { subagent in
                        CantripSubagentCard(remote: remote, sessionID: sessionID, subagent: subagent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maxHeight))
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Running subagents")
            .accessibilityIdentifier("chat.pinnedSubagents")
        }
    }
}

struct CantripSubagentStack: View {
    @ObservedObject var remote: CantripRemoteModel
    let sessionID: String?
    let subagents: [CantripRemoteSubagent]
    private let finishedInitiallyExpanded: Bool

    init(
        remote: CantripRemoteModel,
        sessionID: String?,
        subagents: [CantripRemoteSubagent],
        finishedInitiallyExpanded: Bool = false
    ) {
        self.remote = remote
        self.sessionID = sessionID
        self.subagents = subagents
        self.finishedInitiallyExpanded = finishedInitiallyExpanded
    }

    var body: some View {
        if !subagents.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(primarySubagents) { subagent in
                    CantripSubagentCard(remote: remote, sessionID: sessionID, subagent: subagent)
                }
                if !finishedSubagents.isEmpty {
                    CantripSubagentFinishedGroup(
                        remote: remote,
                        sessionID: sessionID,
                        subagents: finishedSubagents,
                        initiallyExpanded: finishedInitiallyExpanded
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var groupsFinished: Bool { subagents.count > 3 }

    private var primarySubagents: [CantripRemoteSubagent] {
        groupsFinished ? subagents.filter(\.status.isLive) : subagents
    }

    private var finishedSubagents: [CantripRemoteSubagent] {
        groupsFinished ? subagents.filter { !$0.status.isLive } : []
    }
}

private struct CantripSubagentFinishedGroup: View {
    @ObservedObject var remote: CantripRemoteModel
    let sessionID: String?
    let subagents: [CantripRemoteSubagent]
    @State private var expanded: Bool

    init(
        remote: CantripRemoteModel,
        sessionID: String?,
        subagents: [CantripRemoteSubagent],
        initiallyExpanded: Bool
    ) {
        self.remote = remote
        self.sessionID = sessionID
        self.subagents = subagents
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(subagents) { subagent in
                    CantripSubagentCard(remote: remote, sessionID: sessionID, subagent: subagent)
                }
            }
            .padding(.top, 6)
        } label: {
            Label("\(subagents.count) finished", systemImage: "checkmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct CantripSubagentCard: View {
    @ObservedObject var remote: CantripRemoteModel
    let sessionID: String?
    let subagent: CantripRemoteSubagent

    @State private var expanded = false
    @State private var showingStopConfirmation = false
    @State private var isStopping = false
    @State private var stopError: String?

    var body: some View {
        if usesLiveTimeline {
            TimelineView(.periodic(from: Date(), by: 1)) { timeline in
                card(now: timeline.date)
            }
        } else {
            card(now: Date())
        }
    }

    private var usesLiveTimeline: Bool {
        subagent.status == .running || subagent.status == .idle
    }

    private var displayName: String {
        CantripSubagentFormat.displayName(for: subagent)
    }

    private var canStop: Bool {
        subagent.status.isCancellableState
            && subagent.canCancel
            && CantripSubagentFormat.trimmed(sessionID).isEmpty == false
    }

    @ViewBuilder
    private func card(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded.toggle()
                    }
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityLabel(accessibilityLabel(now: now))
                .accessibilityHint(expanded ? "Collapse subagent details" : "Expand subagent details")

                if canStop {
                    stopButton
                }
            }

            if let summaryLine {
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let current = currentWorkLine {
                Text("Now: \(current)")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(metaLine(now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let stopError {
                CantripSubagentErrorRow(stopError)
            }

            if expanded {
                details
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.separator).opacity(0.24))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(subagent.status.displayText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    badges
                }
                Text(displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 4)
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var badges: some View {
        let agentType = CantripSubagentFormat.trimmed(subagent.agentType)
        if !agentType.isEmpty {
            CantripSubagentBadge(agentType)
        }
        if subagent.background {
            CantripSubagentBadge("Background")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch subagent.status {
        case .running, .working:
            ProgressView()
                .controlSize(.small)
        case .idle:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.blue)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var stopButton: some View {
        Button {
            showingStopConfirmation = true
        } label: {
            Text(isStopping ? "Stopping..." : "Stop")
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(isStopping)
        .accessibilityLabel("Stop \(displayName)")
        .confirmationDialog("Stop this subagent?", isPresented: $showingStopConfirmation, titleVisibility: .visible) {
            Button("Stop \(displayName)", role: .destructive) {
                Task { await stopSubagent() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cantrip will stop this subagent if it is still running.")
        }
    }

    private var summaryLine: String? {
        let summary = CantripSubagentFormat.trimmed(subagent.summary)
        guard !summary.isEmpty, summary != displayName else { return nil }
        return summary
    }

    /// The latest reasoning step; tool calls stay on the Mac.
    private var currentWorkLine: String? {
        guard subagent.status == .running else { return nil }
        let reasoning = CantripSubagentFormat.trimmed(subagent.reasoning.last?.title)
        if !reasoning.isEmpty { return reasoning }
        let intent = CantripSubagentFormat.trimmed(subagent.intent)
        return intent.isEmpty ? nil : intent
    }

    private func metaLine(now: Date) -> String {
        var parts: [String] = []
        let model = CantripSubagentFormat.trimmed(subagent.model)
        if !model.isEmpty { parts.append(model) }
        parts.append(CantripSubagentFormat.elapsedLabel(
            startedAt: subagent.startedAt,
            finishedAt: subagent.finishedAt,
            now: now
        ))
        parts.append(CantripSubagentFormat.tokenLabel(subagent.tokens))
        return parts.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !subagent.reasoning.isEmpty {
                CantripReasoningStepList(steps: subagent.reasoning, streaming: subagent.status == .running)
            }
            let latest = CantripSubagentFormat.trimmed(subagent.latestMessage)
            if !latest.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Latest")
                        .font(.caption.weight(.semibold))
                    Text(latest)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            let error = CantripSubagentFormat.trimmed(subagent.error)
            if subagent.status == .failed, !error.isEmpty {
                CantripSubagentErrorRow(error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accessibilityLabel(now: Date) -> String {
        let type = CantripSubagentFormat.trimmed(subagent.agentType)
        let kind = type.isEmpty ? "Subagent" : "\(type.capitalized) subagent"
        return [
            kind,
            displayName,
            subagent.status.displayText.lowercased(),
            CantripSubagentFormat.elapsedAccessibilityLabel(
                startedAt: subagent.startedAt,
                finishedAt: subagent.finishedAt,
                now: now
            ),
            CantripSubagentFormat.tokenAccessibilityLabel(subagent.tokens),
        ].joined(separator: ", ")
    }

    private func stopSubagent() async {
        guard !isStopping, let sessionID else { return }
        isStopping = true
        stopError = nil
        defer { isStopping = false }
        do {
            _ = try await remote.cancelSubagent(sessionID: sessionID, agentID: subagent.agentID)
        } catch is CancellationError {
            return
        } catch {
            stopError = CantripSubagentFormat.readableError(error)
        }
    }
}

private struct CantripSubagentErrorRow: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

private struct CantripSubagentBadge: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}
