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
                .widgetURL(CantripDeepLink.tabs(serverID: nil))
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
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(context.state.tabs.prefix(3)) { tab in
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
            .widgetURL(CantripDeepLink.tabs(serverID: nil))
            .keylineTint(.blue)
        }
    }
}

struct CantripCompactStatus: View {
    let state: CantripTabsAttributes.ContentState

    var body: some View {
        Group {
            if let start = state.oldestRunningStart {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } else if state.needsInput > 0 {
                Text("\(state.needsInput)").foregroundStyle(.orange)
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(state.tabs.prefix(4)) { tab in
                    Link(destination: CantripDeepLink.tab(tab.id, serverID: nil)) {
                        CantripLiveTabRow(tab: tab)
                    }
                }
            }
            if state.total > 4 {
                Text("+\(state.total - min(4, state.tabs.count)) more tabs")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Lock Screen", as: .content, using: CantripTabsAttributes(hostName: "Mac mini")) {
    CantripTabsLiveActivity()
} contentStates: {
    CantripTabsAttributes.ContentState(CantripTabsEntry.sample.cache!.snapshot)
}
