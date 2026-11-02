import ActivityKit
import SwiftUI
import WidgetKit

/// One Live Activity for all running Mac tabs, updated by pushes from the Mac.
struct CantripTabsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CantripTabsAttributes.self) { context in
            CantripLiveActivityView(state: context.state, hostName: context.attributes.hostName)
                .padding(14)
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(context.state.primaryLink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("Cantrip").font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(.blue)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.summary)
                        .font(.caption)
                        .foregroundStyle(context.state.needsInput > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    let waiting = context.state.waitingTab
                    VStack(alignment: .leading, spacing: 5) {
                        if let waiting {
                            Link(destination: CantripDeepLink.tab(waiting.id, serverID: nil)) {
                                CantripLiveRequestCallout(tab: waiting, others: context.state.needsInput - 1, compact: true)
                            }
                        }
                        ForEach(context.state.tabs.filter { $0.id != waiting?.id }.prefix(waiting == nil ? 3 : 1)) { tab in
                            Link(destination: CantripDeepLink.tab(tab.id, serverID: nil)) {
                                CantripLiveTabRow(tab: tab, compact: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.needsInput > 0 ? "exclamationmark.bubble.fill" : "sparkles")
                    .foregroundStyle(context.state.needsInput > 0 ? .orange : .blue)
                    .accessibilityLabel("Cantrip")
            } compactTrailing: {
                CantripCompactStatus(state: context.state)
            } minimal: {
                Image(systemName: context.state.needsInput > 0 ? "exclamationmark.bubble.fill"
                      : context.state.isActive ? "sparkles" : "checkmark.circle.fill")
                    .foregroundStyle(context.state.needsInput > 0 ? .orange : context.state.isActive ? .blue : .green)
                    .accessibilityLabel(context.state.summary)
            }
            .widgetURL(context.state.primaryLink)
            .keylineTint(context.state.needsInput > 0 ? .orange : .blue)
        }
    }
}

struct CantripCompactStatus: View {
    let state: CantripTabsAttributes.ContentState

    var body: some View {
        Group {
            if let waiting = state.waitingTab {
                // Waiting beats elapsed time: it's the thing to act on.
                HStack(spacing: 2) {
                    Image(systemName: (waiting.request ?? .other).symbol)
                    if state.needsInput > 1 { Text("\(state.needsInput)") }
                }
                .foregroundStyle(.orange)
            } else if let start = state.oldestRunningStart {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } else {
                Image(systemName: "checkmark").foregroundStyle(.green)
            }
        }
        .font(.caption2.weight(.semibold))
        .accessibilityLabel(state.summary)
    }
}

struct CantripLiveActivityView: View {
    let state: CantripTabsAttributes.ContentState
    let hostName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: state.isActive ? "sparkles" : "checkmark.circle.fill")
                    .foregroundStyle(state.isActive ? .blue : .green)
                    .accessibilityHidden(true)
                Text("Cantrip")
                    .font(.subheadline.weight(.bold))
                if !hostName.isEmpty {
                    Text(hostName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(state.isActive ? state.summary : "All done")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state.needsInput > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            if let waiting {
                Link(destination: CantripDeepLink.tab(waiting.id, serverID: nil)) {
                    CantripLiveRequestCallout(tab: waiting, others: state.needsInput - 1)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(others) { tab in
                    Link(destination: CantripDeepLink.tab(tab.id, serverID: nil)) {
                        CantripLiveTabRow(tab: tab)
                    }
                }
            }
            if hidden > 0 {
                Text("+\(hidden) more tab\(hidden == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var waiting: CantripLiveTab? { state.waitingTab }

    /// Stays within the Lock Screen's 160 pt. The callout takes the space of about three
    /// rows, so it leaves room for one more row; the header already counts the rest.
    private var others: [CantripLiveTab] {
        let rest = state.tabs.filter { $0.id != waiting?.id }
        if waiting != nil { return Array(rest.prefix(1)) }
        return Array(rest.prefix(state.total > 4 ? 3 : 4))
    }

    private var hidden: Int { waiting == nil ? max(0, state.total - others.count) : 0 }
}

#Preview("Lock Screen", as: .content, using: CantripTabsAttributes(hostName: "Mac mini")) {
    CantripTabsLiveActivity()
} contentStates: {
    CantripTabsAttributes.ContentState(CantripTabsEntry.sample.cache!.snapshot)
}
