import SwiftUI
import WidgetKit

struct CantripTabsEntry: TimelineEntry {
    let date: Date
    let cache: CantripLiveStatusCache?
    let paired: Bool
    let problem: String?

    static let sample: CantripTabsEntry = {
        let now = Date().timeIntervalSince1970
        let snapshot = CantripLiveStatusSnapshot(
            generatedAt: now, hostName: "Mac mini", running: 2, needsInput: 1, total: 6,
            tabs: [
                CantripLiveTab(id: UUID().uuidString, title: "Deploy the widget", state: "input",
                               startedAt: now - 300, detail: "Approve the TestFlight upload"),
                CantripLiveTab(id: UUID().uuidString, title: "Audit notifications", state: "running",
                               startedAt: now - 1_260, detail: "Running the test suite", subagents: 1),
                CantripLiveTab(id: UUID().uuidString, title: "Resume review", state: "running",
                               startedAt: now - 95, detail: "Reading resume.md"),
                CantripLiveTab(id: UUID().uuidString, title: "Pro features", state: "done", finishedAt: now - 720),
                CantripLiveTab(id: UUID().uuidString, title: "Figma research", state: "failed", finishedAt: now - 3_600),
                CantripLiveTab(id: UUID().uuidString, title: "Organize email", state: "done", finishedAt: now - 7_200),
            ])
        return CantripTabsEntry(date: Date(), cache: CantripLiveStatusCache(snapshot: snapshot, fetchedAt: Date(),
                                                                          serverID: ""),
                                paired: true, problem: nil)
    }()
}

struct CantripTabsProvider: TimelineProvider {
    func placeholder(in context: Context) -> CantripTabsEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (CantripTabsEntry) -> Void) {
        if context.isPreview {
            completion(.sample)
            return
        }
        Task { completion(await Self.entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CantripTabsEntry>) -> Void) {
        Task {
            let entry = await Self.entry()
            // The Mac pushes a refresh when a tab starts or finishes; this is the fallback.
            let active = entry.cache?.snapshot.isActive == true
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(active ? 300 : 1_800))))
        }
    }

    static func entry(now: Date = Date()) async -> CantripTabsEntry {
        guard let config = CantripSharedStore.loadConfig() else {
            return CantripTabsEntry(date: now, cache: nil, paired: false, problem: nil)
        }
        var cache = CantripSharedStore.loadCache().flatMap { $0.serverID == config.serverID ? $0 : nil }
        var problem: String?
        do {
            let snapshot = try await CantripLiveStatusFetcher.fetch(config)
            let fresh = CantripLiveStatusCache(snapshot: snapshot, fetchedAt: now, serverID: config.serverID)
            CantripSharedStore.saveCache(fresh)
            cache = fresh
        } catch CantripLiveStatusFetchError.noRoute {
            // Local-network-only pairing: the app keeps the shared cache fresh.
        } catch let error as CantripLiveStatusFetchError {
            problem = error.errorDescription
        } catch {
            problem = "Couldn't reach your Mac."
        }
        return CantripTabsEntry(date: now, cache: cache, paired: true, problem: problem)
    }
}

/// Hands the widget's push token to the Mac so tab changes refresh the widget.
struct CantripWidgetPushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let token = widgets.isEmpty ? "" : pushInfo.token.map { String(format: "%02x", $0) }.joined()
        CantripSharedStore.saveWidgetToken(token.isEmpty ? nil : token)
        guard let config = CantripSharedStore.loadConfig() else { return }
        // The app also uploads it; this covers adding the widget while the app is closed.
        Task { try? await CantripLiveStatusFetcher.subscribe(config, fields: ["widgetToken": token]) }
    }
}

struct CantripTabsWidget: Widget {
    static let kind = "CantripTabs"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: CantripTabsProvider()) { entry in
            CantripTabsWidgetView(entry: entry)
        }
        .configurationDisplayName("Cantrip Tabs")
        .description("See which Mac tabs are running, need your input, or just finished.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .pushHandler(CantripWidgetPushHandler.self)
    }
}

struct CantripTabsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CantripTabsEntry

    private var isLarge: Bool { family == .systemLarge }
    private var serverID: String? { entry.cache?.serverID.isEmpty == false ? entry.cache?.serverID : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: isLarge ? 8 : 6) {
            header
            if let snapshot = entry.cache?.snapshot {
                rows(snapshot)
            } else {
                placeholder
            }
            Spacer(minLength: 0)
            footer
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(CantripDeepLink.tabs(serverID: serverID))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Cantrip")
                .font(.subheadline.weight(.bold))
            if isLarge, let host = entry.cache?.snapshot.hostName, !host.isEmpty {
                Text(host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let snapshot = entry.cache?.snapshot {
                Text(snapshot.summary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(snapshot.needsInput > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func rows(_ snapshot: CantripLiveStatusSnapshot) -> some View {
        let limit = isLarge ? 7 : 3
        if snapshot.tabs.isEmpty {
            Text("No tabs open on \(snapshot.hostName).")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: isLarge ? 7 : 5) {
                ForEach(snapshot.tabs.prefix(limit)) { tab in
                    Link(destination: CantripDeepLink.tab(tab.id, serverID: serverID)) {
                        CantripLiveTabRow(tab: tab, showsDetail: isLarge)
                    }
                }
            }
            if snapshot.total > limit {
                Text("+\(snapshot.total - min(limit, snapshot.tabs.count)) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var placeholder: some View {
        Text(entry.paired ? (entry.problem ?? "Open Cantrip Agent to load your tabs.")
                          : "Open Cantrip Agent and pair it with your Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var footer: some View {
        if let cache = entry.cache, entry.date.timeIntervalSince(cache.fetchedAt) > 600 || entry.problem != nil {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .accessibilityHidden(true)
                Text("Updated \(cache.fetchedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))")
                if let problem = entry.problem {
                    Text("· \(problem)").lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview(as: .systemMedium) {
    CantripTabsWidget()
} timeline: {
    CantripTabsEntry.sample
}

#Preview(as: .systemLarge) {
    CantripTabsWidget()
} timeline: {
    CantripTabsEntry.sample
}
