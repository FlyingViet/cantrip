import SwiftUI

/// Home replies' handoffs to project tabs, shown like nested tasks.
struct CantripHandoffStack: View {
    let handoffs: [CantripRemoteDelegation]
    var onOpenTab: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(handoffs) { handoff in
                CantripHandoffCard(handoff: handoff, onOpenTab: onOpenTab)
            }
        }
    }
}

/// A compact handoff card: status, tab, summary, elapsed time and Open tab. The tab's own
/// narration, results and errors stay in the tab, so a card stays a couple of lines tall.
struct CantripHandoffCard: View {
    let handoff: CantripRemoteDelegation
    var onOpenTab: ((String) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 18

    private var stacksRows: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        if handoff.status.isActive {
            TimelineView(.periodic(from: Date(), by: 1)) { timeline in
                card(now: timeline.date)
            }
        } else {
            card(now: Date())
        }
    }

    private var tabTitle: String {
        let title = CantripSubagentFormat.trimmed(handoff.tabTitle)
        return title.isEmpty ? "Project tab" : title
    }

    private var summary: String {
        let summary = CantripSubagentFormat.trimmed(handoff.summary)
        return summary.isEmpty ? CantripSubagentFormat.trimmed(handoff.prompt) : summary
    }

    private var canOpenTab: Bool {
        onOpenTab != nil && !CantripSubagentFormat.trimmed(handoff.tabID).isEmpty
    }

    /// Older Macs only say so in the tab's latest status.
    var needsAnswer: Bool {
        guard handoff.status == .running else { return false }
        let latest = CantripSubagentFormat.trimmed(handoff.latestStatus)
        return handoff.needsInput || latest == "Needs your answer" || latest == "Waiting for your input"
    }

    var statusText: String {
        if needsAnswer { return "Needs your answer" }
        switch handoff.status {
        case .queued: return "Queued in tab"
        case .running: return "Working in tab"
        case .completed: return "Done in tab"
        case .failed: return "Failed in tab"
        case .cancelled: return "Stopped"
        }
    }

    @ViewBuilder
    private func card(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(now: now))

            let footer = stacksRows
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
            footer {
                Text(CantripSubagentFormat.elapsedLabel(
                    startedAt: handoff.startedAt, finishedAt: handoff.finishedAt, now: now
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                if !stacksRows { Spacer(minLength: 8) }
                if canOpenTab {
                    Button {
                        onOpenTab?(handoff.tabID)
                    } label: {
                        Label("Open tab", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open \(tabTitle) tab")
                }
            }
            .padding(.leading, stacksRows ? 0 : iconSize + 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        // The 44pt Open tab target already leaves room below its label.
        .padding(.bottom, canOpenTab ? 0 : 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.separator).opacity(0.24))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
                .font(.caption)
                .frame(width: iconSize, height: iconSize)
            VStack(alignment: .leading, spacing: 4) {
                let statusRow = stacksRows
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(spacing: 6))
                statusRow {
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(needsAnswer ? Color.primary : Color.secondary)
                        .lineLimit(stacksRows ? nil : 1)
                    Label(tabTitle, systemImage: "rectangle.stack")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                        .lineLimit(stacksRows ? 2 : 1)
                }
                Text(summary)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(stacksRows ? 4 : 2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if needsAnswer {
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(CantripHomeBackgroundStyle.activeTint)
        } else {
            switch handoff.status {
            case .queued:
                Image(systemName: "clock").foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .cancelled:
                Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
            }
        }
    }

    private func accessibilityLabel(now: Date) -> String {
        let elapsed = CantripSubagentFormat.elapsedAccessibilityLabel(
            startedAt: handoff.startedAt, finishedAt: handoff.finishedAt, now: now
        )
        return "\(statusText), \(tabTitle): \(summary). \(elapsed)"
    }
}
