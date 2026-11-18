import SwiftUI

// Tasks → Upcoming: everything the Mac will run later (docs/cantrip-home.md "Upcoming"), in the
// groups and order the Mac sends, with Cancel, Stop or Pause (asked first) and Resume.

/// One thing set to run later, as `GET /api/v1/home/upcoming` lists it. Its `id` is opaque: it's
/// only sent back to cancel or resume the item.
struct CantripHomeUpcomingItem: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: String
    var title: String
    var detail: String?
    var nextRunAt: Date?
    var schedule: String
    var owner: String
    var ownerTabID: String?
    var state: String
    var group: CantripHomeUpcoming.Group
    /// "Cancel", "Stop" or "Pause"; nil when it can't be cancelled from here.
    var cancelLabel: String?
    /// The question to ask before cancelling, naming what will stop.
    var confirm: String?
    var canResume: Bool

    init(id: String, kind: String, title: String, detail: String? = nil, nextRunAt: Date? = nil,
         schedule: String, owner: String, ownerTabID: String? = nil, state: String = "scheduled",
         group: CantripHomeUpcoming.Group? = nil, cancelLabel: String? = nil, confirm: String? = nil,
         canResume: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.nextRunAt = nextRunAt
        self.schedule = schedule
        self.owner = owner
        self.ownerTabID = ownerTabID
        self.state = state
        self.group = group ?? CantripHomeUpcoming.Group(state: state, nextRunAt: nextRunAt)
        self.cancelLabel = cancelLabel
        self.confirm = confirm
        self.canResume = canResume
    }

    private enum Keys: String, CodingKey {
        case id, kind, title, detail, nextRunAt, schedule, owner, ownerTabID, state, group, cancelLabel, confirm, canResume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func text(_ key: Keys) -> String? {
            let value = ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        guard let id = text(.id), let title = text(.title) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "An item needs an id and a title."))
        }
        // Unix seconds (since 1970), not Foundation's 2001 reference date.
        let seconds = (try? c.decodeIfPresent(Double.self, forKey: .nextRunAt)) ?? nil
        let state = text(.state) ?? "scheduled"
        let nextRunAt = seconds.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        self.init(id: id, kind: text(.kind) ?? "", title: title, detail: text(.detail), nextRunAt: nextRunAt,
                  schedule: text(.schedule) ?? "", owner: text(.owner) ?? "", ownerTabID: text(.ownerTabID),
                  state: state, group: text(.group).flatMap(CantripHomeUpcoming.Group.init(rawValue:)),
                  cancelLabel: text(.cancelLabel), confirm: text(.confirm),
                  canResume: ((try? c.decodeIfPresent(Bool.self, forKey: .canResume)) ?? nil) ?? false)
    }

    /// The Mac's question, or one naming the item when an older Mac sent none.
    var confirmQuestion: String { confirm ?? "\(cancelLabel ?? "Cancel") “\(title)”?" }

    /// The question for an alert's title and what follows it for its message: "Cancel “X”?" and
    /// "The tab won't get this step at 10:35 PM."
    var confirmParts: (title: String, message: String?) {
        let question = confirmQuestion
        guard let end = question.range(of: "? ") else { return (question, nil) }
        let rest = question[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(question[..<end.lowerBound]) + "?", rest.isEmpty ? nil : rest)
    }
}

/// The list as the Mac sent it, with what a change did (`message`, from cancel and resume).
struct CantripHomeUpcomingSnapshot: Equatable, Sendable {
    var items: [CantripHomeUpcomingItem]
    var revision: String
    var message: String?
}

/// `GET /api/v1/home/upcoming` and the cancel and resume answers. An item this app can't read is
/// left out rather than failing the list.
struct CantripHomeUpcomingResponse: Decodable {
    let items: [CantripLossy<CantripHomeUpcomingItem>]?
    let revision: String?
    let unchanged: Bool?
    let message: String?
}

enum CantripHomeUpcoming {
    /// Where an item lists, in this order.
    enum Group: String, CaseIterable, Sendable {
        case next, waiting, repeating, paused

        var title: String {
            switch self {
            case .next: "Next up"
            case .waiting: "Waiting"
            case .repeating: "Repeating"
            case .paused: "Paused"
            }
        }

        /// The Mac's rule, for an item that came without a group this app knows.
        init(state: String, nextRunAt: Date?) {
            switch state {
            case "paused": self = .paused
            case "waiting": self = .waiting
            default: self = nextRunAt == nil ? .repeating : .next
            }
        }
    }

    enum Action: String, Sendable { case cancel, resume }

    /// Next up shows this many until Show all.
    static let nextUpLimit = 6

    struct GroupRows: Identifiable, Equatable {
        let group: Group
        /// The items to draw, in the Mac's order.
        let items: [CantripHomeUpcomingItem]
        /// How many the group holds, drawn or not.
        let total: Int
        var id: Group { group }
        /// Next up has more than fit before Show all.
        var canShowAll: Bool { group == .next && total > CantripHomeUpcoming.nextUpLimit }
    }

    /// The groups that have items, in order, each keeping the Mac's order; Next up cut to
    /// `nextUpLimit` unless `showsAllNext`.
    static func groups(_ items: [CantripHomeUpcomingItem], showsAllNext: Bool) -> [GroupRows] {
        Group.allCases.compactMap { group in
            let members = items.filter { $0.group == group }
            guard !members.isEmpty else { return nil }
            let shown = group == .next && !showsAllNext ? Array(members.prefix(nextUpLimit)) : members
            return GroupRows(group: group, items: shown, total: members.count)
        }
    }

    /// "Today 10:35 PM", "Tomorrow 3:00 AM", "Yesterday 9:00 AM", "Fri 9:50 AM" within the week ahead,
    /// else "Nov 28, 9:50 AM" (with the year when it isn't this year), in `calendar`'s time zone.
    static func timeLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
                          locale: Locale = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                   calendar: calendar, timeZone: calendar.timeZone))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Today \(time)"
        case 1: return "Tomorrow \(time)"
        case -1: return "Yesterday \(time)"
        case 2...6: return "\(date.formatted(style.weekday(.abbreviated))) \(time)"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            let day = sameYear ? style.month(.abbreviated).day() : style.month(.abbreviated).day().year()
            return "\(date.formatted(day)), \(time)"
        }
    }

    /// When it runs: its next time, else its schedule ("Every 15 minutes", "Waiting, until …").
    static func when(_ item: CantripHomeUpcomingItem, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
                     locale: Locale = .autoupdatingCurrent) -> [String] {
        guard let next = item.nextRunAt else { return item.schedule.isEmpty ? [] : [item.schedule] }
        var parts = [timeLabel(next, now: now, calendar: calendar, locale: locale)]
        // "Once" adds nothing beside a time; a repeating schedule does.
        if !item.schedule.isEmpty, item.schedule.caseInsensitiveCompare("Once") != .orderedSame { parts.append(item.schedule) }
        return parts
    }

    /// The row's second line: "Today 10:35 PM · Daily at 3:00 AM · Cantrip Home".
    static func secondaryLine(_ item: CantripHomeUpcomingItem, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
                              locale: Locale = .autoupdatingCurrent) -> String {
        (when(item, now: now, calendar: calendar, locale: locale) + (item.owner.isEmpty ? [] : [item.owner]))
            .joined(separator: " · ")
    }

    /// The row as VoiceOver reads it: title, paused, when, who set it up and its detail.
    static func spokenLabel(_ item: CantripHomeUpcomingItem, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
                            locale: Locale = .autoupdatingCurrent) -> String {
        var parts = [item.title]
        if item.state == "paused" { parts.append("Paused") }
        parts += when(item, now: now, calendar: calendar, locale: locale)
        if !item.owner.isEmpty { parts.append("set up by \(item.owner)") }
        if let detail = item.detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }

    /// Why a read or change failed, in the Mac's words when it gave a reason.
    static func errorMessage(_ error: Error) -> String {
        switch error {
        case CantripRemoteError.http(let status, let message) where (400..<500).contains(status) && !message.isEmpty:
            return message
        case let error where CantripRemoteError.isRouteFailure(error):
            return "Can't reach Cantrip on your Mac. Check the connection and try again."
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Rows

/// Tasks → Upcoming's rows: a short heading per group, the first six of Next up until Show all, and
/// "Nothing scheduled" when the Mac has nothing. What a change did goes to `report`, which shows it
/// where it can be seen from anywhere in the list.
struct CantripHomeUpcomingRows: View {
    let items: [CantripHomeUpcomingItem]
    let error: String?
    /// The item a change is being sent for.
    let changingID: String?
    let remote: CantripRemoteModel
    /// The Mac's message, or why the change failed (`failed`).
    let report: (_ message: String, _ failed: Bool) -> Void
    @State private var showsAllNext = false

    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if items.isEmpty {
            Label("Nothing scheduled", systemImage: "calendar")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        ForEach(CantripHomeUpcoming.groups(items, showsAllNext: showsAllNext)) { rows in
            Text(rows.group.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
                .padding(.top, 4)
                .listRowSeparator(.hidden)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows.items) { item in
                CantripHomeUpcomingRow(item: item, changing: changingID == item.id, busy: changingID != nil) {
                    change(item, $0)
                }
            }
            if rows.canShowAll {
                Button(showsAllNext ? "Show fewer" : "Show all \(rows.total)") {
                    withAnimation(.snappy(duration: 0.2)) { showsAllNext.toggle() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
                .buttonStyle(.borderless)
                .accessibilityLabel(showsAllNext ? "Show fewer in Next up" : "Show all \(rows.total) in Next up")
                .accessibilityIdentifier("home.upcoming.showAll")
            }
        }
    }

    private func change(_ item: CantripHomeUpcomingItem, _ action: CantripHomeUpcoming.Action) {
        Task {
            let message = action == .cancel
                ? await remote.cancelHomeUpcoming(id: item.id)
                : await remote.resumeHomeUpcoming(id: item.id)
            if let message {
                report(message, false)
                AccessibilityNotification.Announcement(message).post()
            } else if let problem = remote.homeUpcomingError {
                report(problem, true)
                AccessibilityNotification.Announcement(problem).post()
            }
        }
    }
}

/// One item: its title, when it runs with its schedule and who set it up, its detail, and a small
/// Cancel/Stop/Pause (asked first) or Resume. VoiceOver reads it as one element with those as actions.
struct CantripHomeUpcomingRow: View {
    let item: CantripHomeUpcomingItem
    /// This item's change is being sent.
    let changing: Bool
    /// Some item's change is being sent; the buttons wait for it.
    let busy: Bool
    let perform: (CantripHomeUpcoming.Action) -> Void
    @State private var confirming = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TimelineView(.everyMinute) { context in
            let large = typeSize.isAccessibilitySize
            let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(large ? nil : 3)
                    Text(CantripHomeUpcoming.secondaryLine(item, now: context.date))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(large ? nil : 2)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(large ? nil : 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actionButton
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CantripHomeUpcoming.spokenLabel(item, now: context.date))
            .accessibilityActions {
                if !busy, let label = item.cancelLabel {
                    Button(label) { confirming = true }
                } else if !busy, item.canResume {
                    Button("Resume") { perform(.resume) }
                }
            }
            .accessibilityIdentifier("home.upcoming.\(item.id)")
        }
        .alert(item.confirmParts.title, isPresented: $confirming) {
            Button(item.cancelLabel ?? "Cancel", role: .destructive) { perform(.cancel) }
            Button("Keep", role: .cancel) {}
        } message: {
            if let message = item.confirmParts.message { Text(message) }
        }
    }

    @ViewBuilder private var actionButton: some View {
        if changing {
            ProgressView()
                .controlSize(.small)
        } else if let label = item.cancelLabel {
            Button(label) { confirming = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(busy)
        } else if item.canResume {
            Button("Resume") { perform(.resume) }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .controlSize(.small)
                .fixedSize()
                .disabled(busy)
        }
    }
}
