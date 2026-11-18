import SwiftUI

// Home's views (docs/views.md): screens Home builds on request, each a card document the Mac
// resolves from live data. Listed under Tasks → Views; a view's screen draws its card with the
// card block views, refreshes it, and runs its confirmed buttons on the Mac.

// MARK: - Models

/// One view as the views list sends it.
struct CantripHomeViewSummary: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var subtitle: String?
    /// An SF Symbol; the row falls back to a generic one when it doesn't exist.
    var icon: String?
    var pinned: Bool
    /// Reads a private server (`personal`, or one the Privacy Gate keeps from cloud runs): a lock shows.
    var isPrivate: Bool
    /// Source kinds: records, tasks, tool, run, checked.
    var sources: [String]
    var createdAt: Date?
    var updatedAt: Date?
    /// When its tool data was read; nil when it has no tool data.
    var refreshedAt: Date?
    var refreshing: Bool
    /// Sources that couldn't be read, in the Mac's words.
    var problems: [String]

    init(id: String, name: String, subtitle: String? = nil, icon: String? = nil, pinned: Bool = false,
         isPrivate: Bool = false, sources: [String] = [], createdAt: Date? = nil, updatedAt: Date? = nil,
         refreshedAt: Date? = nil, refreshing: Bool = false, problems: [String] = []) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.icon = icon
        self.pinned = pinned
        self.isPrivate = isPrivate
        self.sources = sources
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.refreshedAt = refreshedAt
        self.refreshing = refreshing
        self.problems = problems
    }

    private enum Keys: String, CodingKey {
        case id, name, subtitle, icon, pinned, isPrivate = "private", sources, createdAt, updatedAt, refreshedAt, refreshing, problems
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "A view needs an ID.")
        }
        func text(_ key: Keys, limit: Int = 200) -> String? {
            ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap { $0.isEmpty ? nil : String($0.prefix(limit)) }
        }
        func flag(_ key: Keys) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false }
        func strings(_ key: Keys) -> [String] {
            let values = ((try? c.decodeIfPresent([CantripLossy<String>].self, forKey: key)) ?? nil) ?? []
            return Array(values.compactMap(\.value).filter { !$0.isEmpty }.prefix(12))
        }
        name = text(.name, limit: 80) ?? "View"
        subtitle = text(.subtitle)
        icon = text(.icon, limit: 80)
        pinned = flag(.pinned)
        isPrivate = flag(.isPrivate)
        sources = strings(.sources)
        createdAt = Self.date(c, .createdAt)
        updatedAt = Self.date(c, .updatedAt)
        refreshedAt = Self.date(c, .refreshedAt)
        refreshing = flag(.refreshing)
        problems = strings(.problems).map { String($0.prefix(400)) }
    }

    /// ISO 8601 (what the Mac sends), or seconds: Swift's default encoding counts from 2001, so a
    /// count past 2008 in Unix time reads as Unix time.
    private static func date(_ c: KeyedDecodingContainer<Keys>, _ key: Keys) -> Date? {
        if let text = try? c.decodeIfPresent(String.self, forKey: key) { return CantripCardProgress.date(text) }
        guard let seconds = try? c.decodeIfPresent(Double.self, forKey: key), seconds.isFinite else { return nil }
        return seconds > 1_200_000_000 ? Date(timeIntervalSince1970: seconds) : Date(timeIntervalSinceReferenceDate: seconds)
    }

    var symbol: String {
        if let icon, CantripCardStyle.symbolExists(icon) { return icon }
        return "rectangle.3.group"
    }

    /// Its subtitle, else when its data was read: "Updated 5 minutes ago".
    var detailLine: String? {
        if let subtitle { return subtitle }
        guard let date = refreshedAt ?? updatedAt else { return nil }
        return "Updated \(date.formatted(.relative(presentation: .named)))"
    }

    var spokenLabel: String {
        var parts = [name]
        if pinned { parts.append("Pinned") }
        if isPrivate { parts.append("Private") }
        if let detailLine { parts.append(detailLine) }
        if refreshing { parts.append("Refreshing") }
        if !problems.isEmpty { parts.append(problems.count == 1 ? "1 problem" : "\(problems.count) problems") }
        return parts.joined(separator: ", ")
    }
}

struct CantripHomeViewsSnapshot: Equatable {
    var views: [CantripHomeViewSummary]
    var revision: String
    var supportsActions: Bool
}

/// `GET /api/v1/home/views/<id>` (and a refresh): the view and its card, resolved on the Mac.
struct CantripHomeViewDetail: Decodable, Equatable {
    var view: CantripHomeViewSummary
    var card: CantripCard
    /// Seconds until the open view is worth fetching again.
    var refreshAfter: Int

    init(view: CantripHomeViewSummary, card: CantripCard, refreshAfter: Int = 30) {
        self.view = view
        self.card = card
        self.refreshAfter = refreshAfter
    }

    private enum Keys: String, CodingKey { case view, card, refreshAfter }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        view = try c.decode(CantripHomeViewSummary.self, forKey: .view)
        card = try c.decode(CantripCard.self, forKey: .card)
        // The card's ID keys its tabs' and lists' state; a fresh one on every fetch would reset them.
        if ((try? c.decode(CardID.self, forKey: .card))?.id ?? "").isEmpty { card.id = "view-\(view.id)" }
        let seconds = ((try? c.decodeIfPresent(Double.self, forKey: .refreshAfter)) ?? nil) ?? 30
        refreshAfter = Int(Swift.min(Swift.max(seconds.isFinite ? seconds : 30, 5), 3_600))
    }

    private struct CardID: Decodable { var id: String? }
}

/// What a confirmed button did on the Mac.
struct CantripHomeViewActionResult: Decodable, Equatable {
    /// "open", "record", "started", "refreshed" or "sent".
    var result: String
    var url: String?
    var taskID: String?
    var recordID: String?
    var message: String?
    var view: CantripHomeViewSummary?
    var card: CantripCard?

    init(result: String, url: String? = nil, taskID: String? = nil, recordID: String? = nil, message: String? = nil,
         view: CantripHomeViewSummary? = nil, card: CantripCard? = nil) {
        self.result = result
        self.url = url
        self.taskID = taskID
        self.recordID = recordID
        self.message = message
        self.view = view
        self.card = card
    }

    private enum Keys: String, CodingKey { case result, url, taskID, recordID, message, view, card }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        result = try c.decode(String.self, forKey: .result)
        func text(_ key: Keys) -> String? {
            ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap { $0.isEmpty ? nil : String($0.prefix(2_000)) }
        }
        url = text(.url)
        taskID = text(.taskID)
        recordID = text(.recordID)
        message = text(.message)
        view = (try? c.decodeIfPresent(CantripHomeViewSummary.self, forKey: .view)) ?? nil
        card = (try? c.decodeIfPresent(CantripCard.self, forKey: .card)) ?? nil
    }

    /// `open`: the link to open, only a public web page.
    var webURL: URL? {
        guard let url = url.flatMap(URL.init(string:)), CantripLinkPreview.isSafeWebURL(url) else { return nil }
        return url
    }

    /// `record`: the task and record to show.
    var record: CantripHomeViewRecordTarget? {
        guard let task = taskID.flatMap(UUID.init(uuidString:)), let record = recordID.flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        return CantripHomeViewRecordTarget(taskID: task, recordID: record)
    }
}

struct CantripHomeViewRecordTarget: Hashable {
    let taskID: UUID
    let recordID: UUID
}

// MARK: - List

/// A view in Tasks → Views: its icon, name, a lock when it's private, its subtitle or when it was
/// updated, and a pin when it's pinned.
struct CantripHomeViewRow: View {
    let view: CantripHomeViewSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: view.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(view.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if view.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let line = view.detailLine {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if view.refreshing {
                    Label("Refreshing…", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let problem = view.problems.first {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if view.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(45))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(view.spokenLabel)
        .accessibilityIdentifier("home.view.\(view.id)")
    }
}

// MARK: - A view's screen

/// A view on its own screen: its card at the full readable width, fetched again every
/// `refreshAfter` seconds while it's showing. Pull to refresh (or Refresh) has the Mac read its
/// tools again; Pin and Delete change it on the Mac; its buttons ask, then run there.
struct CantripHomeViewScreen: View {
    let remote: CantripRemoteModel
    let viewID: String
    /// Shows Home's Chat (an `ask` button's question is there).
    let showChat: () -> Void
    /// DEBUG fixture screens draw a saved answer without a Mac.
    private let fixture: CantripHomeViewDetail?
    @State private var summary: CantripHomeViewSummary
    @State private var detail: CantripHomeViewDetail?
    @State private var loadError: String?
    /// Why the last change didn't go through.
    @State private var notice: String?
    /// A started run's message, shown for a moment.
    @State private var status: String?
    @State private var runningActionID: String?
    @State private var isRefreshing = false
    @State private var isChanging = false
    @State private var confirmingDelete = false
    @State private var record: CantripHomeViewRecordTarget?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(remote: CantripRemoteModel, summary: CantripHomeViewSummary, showChat: @escaping () -> Void,
         fixture: CantripHomeViewDetail? = nil) {
        self.remote = remote
        viewID = summary.id
        self.showChat = showChat
        self.fixture = fixture
        _summary = State(initialValue: summary)
        _detail = State(initialValue: fixture)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CantripHomeViewStatus(summary: summary, isRefreshing: isRefreshing, notice: notice, status: status)
                content
            }
            .frame(maxWidth: 1_000, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable { await refresh() }
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .pageBack(to: "Tasks")
        .toolbar { toolbar }
        .task(id: viewID) { await follow() }
        .task(id: status) {
            guard status != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            status = nil
        }
        .confirmationDialog("Delete \(summary.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete View", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from the Mac and from every paired device.")
        }
        .navigationDestination(item: $record) { target in
            CantripHomeTaskRecordDetailView(remote: remote, taskID: target.taskID, recordID: target.recordID)
        }
        .accessibilityIdentifier("home.viewScreen")
    }

    @ViewBuilder private var content: some View {
        if let detail {
            CantripCardPanel(card: detail.card, remote: remote, maxWidth: .infinity)
                .environment(\.cantripCardActions, CantripCardActionContext(perform: run, runningID: runningActionID))
        } else if let loadError {
            ContentUnavailableView("View unavailable", systemImage: "rectangle.3.group", description: Text(loadError))
        } else {
            ProgressView("Loading \(summary.name)…")
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)
            .accessibilityIdentifier("home.view.refresh")
            Button {
                Task { await togglePin() }
            } label: {
                Label(summary.pinned ? "Unpin" : "Pin", systemImage: summary.pinned ? "pin.slash" : "pin")
            }
            .disabled(isChanging)
            .accessibilityIdentifier("home.view.pin")
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isChanging)
            .accessibilityIdentifier("home.view.delete")
        }
    }

    // MARK: Loading

    /// Fetches the view now and every `refreshAfter` seconds until the screen goes away.
    private func follow() async {
        guard fixture == nil else { return }
        while !Task.isCancelled {
            let seconds: Int
            do {
                let fresh = try await remote.homeView(id: viewID)
                apply(fresh)
                loadError = nil
                seconds = fresh.refreshAfter
            } catch is CancellationError {
                return
            } catch {
                if detail == nil { loadError = Self.message(error) }
                seconds = detail?.refreshAfter ?? 30
            }
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    private func apply(_ fresh: CantripHomeViewDetail) {
        if detail != fresh { detail = fresh }
        if summary != fresh.view { summary = fresh.view }
    }

    private func refresh() async {
        guard fixture == nil, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            apply(try await remote.refreshHomeView(id: viewID))
            loadError = nil
            notice = nil
        } catch is CancellationError {
        } catch {
            notice = Self.message(error)
        }
    }

    private func togglePin() async {
        guard !isChanging else { return }
        guard fixture == nil else { summary.pinned.toggle(); return }
        isChanging = true
        defer { isChanging = false }
        do {
            let updated = try await remote.setHomeViewPinned(id: viewID, pinned: !summary.pinned)
            summary = updated
            detail?.view = updated
            notice = nil
        } catch is CancellationError {
        } catch {
            notice = Self.message(error)
        }
    }

    private func delete() async {
        guard fixture == nil, !isChanging else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            try await remote.deleteHomeView(id: viewID)
            dismiss()
        } catch is CancellationError {
        } catch {
            notice = Self.message(error)
        }
    }

    // MARK: Buttons

    /// A button the person confirmed: posted once, then what it did is shown here.
    private func run(_ button: CantripCard.ActionButton) {
        guard let id = button.id, runningActionID == nil, fixture == nil else { return }
        runningActionID = id
        Task {
            defer { runningActionID = nil }
            do {
                show(try await remote.runHomeViewAction(viewID: viewID, actionID: id))
                notice = nil
            } catch is CancellationError {
            } catch {
                notice = Self.message(error)
            }
        }
    }

    private func show(_ result: CantripHomeViewActionResult) {
        switch result.result {
        case "open":
            if let url = result.webURL {
                openURL(url)
            } else {
                notice = "That link can't be opened here."
            }
        case "record":
            guard let target = result.record else { return }
            Task { await remote.refreshHomeData() }
            record = target
        case "started":
            announce(result.message ?? "Started.")
        case "refreshed":
            if let view = result.view { summary = view }
            if var card = result.card {
                // A view's card keeps its ID (`view-<id>`), and with it the tab that's showing.
                card.id = detail?.card.id ?? "view-\(viewID)"
                detail = CantripHomeViewDetail(view: summary, card: card, refreshAfter: detail?.refreshAfter ?? 30)
            }
        case "sent":
            showChat()
        default:
            break
        }
    }

    private func announce(_ message: String) {
        status = message
        AccessibilityNotification.Announcement(message).post()
    }

    static func message(_ error: Error) -> String {
        switch error {
        case CantripRemoteError.http(404, _):
            return "This view is no longer on the Mac."
        case let error where CantripRemoteError.isRouteFailure(error):
            return "Can't reach Cantrip on your Mac. Check the connection and try again."
        default:
            return error.localizedDescription
        }
    }
}

/// Above a view's card: Refreshing, what its sources couldn't read, why a change failed, and a
/// started run's message. Each is one element VoiceOver reads.
private struct CantripHomeViewStatus: View {
    let summary: CantripHomeViewSummary
    let isRefreshing: Bool
    let notice: String?
    let status: String?

    var body: some View {
        if isRefreshing || summary.refreshing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Refreshing…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Refreshing \(summary.name)")
        }
        ForEach(Array(summary.problems.enumerated()), id: \.offset) { _, problem in
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Problem: \(problem)")
        }
        if let notice {
            Label(notice, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let status {
            Label(status, systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.14), in: Capsule())
                .transition(.opacity)
                .accessibilityIdentifier("home.view.status")
        }
    }
}
