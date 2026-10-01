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

struct CantripHandoffCard: View {
    let handoff: CantripRemoteDelegation
    var onOpenTab: ((String) -> Void)?

    @State private var showsFullResult = false
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

    private var statusText: String {
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
        VStack(alignment: .leading, spacing: 8) {
            header
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(now: now))

            if handoff.status.isActive, let latest = nonEmpty(handoff.latestStatus) {
                Text("Now: \(latest)")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result = nonEmpty(handoff.result) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsFullResult.toggle() }
                } label: {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(showsFullResult ? nil : 4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Result: \(result)")
                .accessibilityHint(showsFullResult ? "Shows less of the result" : "Shows the full result")
            }

            if let error = nonEmpty(handoff.error) {
                Label {
                    Text(error)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: handoff.status == .failed
                          ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(handoff.status == .failed ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }

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
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        // The 44pt Open tab target already leaves room below its label.
        .padding(.bottom, canOpenTab ? 2 : 12)
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
                        .foregroundStyle(.secondary)
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

    private func accessibilityLabel(now: Date) -> String {
        let elapsed = CantripSubagentFormat.elapsedAccessibilityLabel(
            startedAt: handoff.startedAt, finishedAt: handoff.finishedAt, now: now
        )
        return "\(statusText), \(tabTitle): \(summary). \(elapsed)"
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = CantripSubagentFormat.trimmed(value)
        return trimmed.isEmpty ? nil : trimmed
    }
}
