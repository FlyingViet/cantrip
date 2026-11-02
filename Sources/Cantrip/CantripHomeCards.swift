import Foundation

// MARK: - Cards on run results

/// Cards on a scheduled-task or incident run's result: the run's own `weather`, `places` and
/// `card` blocks, resolved on the Mac as the run finishes (no extra model tokens). Link previews
/// and automatic tool cards stay off for runs. Resolving has a deadline and never fails a run: a
/// card that can't resolve in time is left out.
enum RunCards {
    static let maximumCards = 4
    /// Seconds a run's cards may take; the run's completion waits at most this long.
    nonisolated(unsafe) static var deadline: TimeInterval = 12

    /// Taught to every scheduled-task and incident run (Home's background protocol), on every backend.
    static let guidance = """
    Run result cards: when the task asks for a card, end the reply (after the Summary section) with \
    up to \(maximumCards) fenced blocks; Cantrip strips them and shows the cards on this run's result \
    in Background, the task's runs and the run's report. `weather` {"place":"City, ST"} ({} for the \
    Mac's location) gets an Open-Meteo forecast; `places` {"near":"City, ST","places":[{"name":"…", \
    "query":"Name City ST"}]} gets a map. A `card` block shows values from a tool you called this \
    run, citing it: {"title":"…","cite":{"tool":"<tool name>"},"blocks":[{"type":"keyValue","rows": \
    [{"key":"…","value":"…"}]},{"type":"list","items":[{"title":"…","subtitle":"…","trailing":"…"}]}]}; \
    every number, time and link in it must appear in that tool's output, or it shows as plain text. \
    Never write values a tool or resolver didn't return. No link previews appear on run results.
    """

    struct Pending: Sendable {
        var places: PlaceBlockProposal?
        var weather: WeatherBlockProposal?
        /// `card` blocks whose values were found in the tool they cite.
        var checked: [CardDocument] = []

        var isEmpty: Bool { places == nil && weather == nil && checked.isEmpty }
        var needsResolving: Bool { places != nil || weather != nil }
    }

    /// Strips every card block from a run's reply. Checked `card` blocks are kept; one whose values
    /// aren't in the tool it cites comes back as plain text for the reply.
    static func extract(from text: inout String, activities: [ToolActivity]) -> (pending: Pending, unshown: [String]) {
        var pending = Pending()
        pending.places = PlaceCardResolver.extractProposal(from: &text)
        pending.weather = WeatherBlock.extract(from: &text)
        var unshown: [String] = []
        for proposal in ModelCards.extract(from: &text) {
            if let card = ModelCards.verified(proposal, activities: activities) {
                pending.checked.append(card)
            } else if !proposal.card.plainText.isEmpty {
                unshown.append(proposal.card.plainText)
            }
        }
        return (pending, unshown)
    }

    /// The run's cards in a stable order (forecast, map, then checked cards as written), at most
    /// four. Whatever hasn't resolved by the deadline is left out.
    static func resolve(_ pending: Pending, context: WeatherCardResolver.Context,
                        deadline: TimeInterval = deadline) async -> [CardDocument] {
        let weatherProposal = pending.weather
        let placesProposal = pending.places
        async let weather: CardDocument? = weatherProposal == nil ? nil : bounded(deadline) {
            await weatherDocument(for: weatherProposal!, context: context)
        }
        async let places: CardDocument? = placesProposal == nil ? nil : bounded(deadline) {
            await PlaceCardResolver.shared.resolve(placesProposal!)?.document
        }
        let resolved = [await weather, await places].compactMap { $0 } + pending.checked
        return resolved.prefix(maximumCards).enumerated().map { index, card in
            var card = card
            // Several model cards share an ID until they're placed.
            if card.id == "model-card" { card.id = "run-card-\(index)" }
            return card
        }
    }

    /// The forecast as a card, carrying how to rebuild it (`LiveCards`).
    static func weatherDocument(for proposal: WeatherBlockProposal, context: WeatherCardResolver.Context) async -> CardDocument? {
        guard let card = await WeatherCardResolver.resolve(proposal, context: context) else { return nil }
        var document = card.document
        let known = context.device ?? context.mac
        document.refresh = .init(kind: "weather", place: proposal.place, label: known?.label,
                                 latitude: known?.coordinate.latitude, longitude: known?.coordinate.longitude,
                                 note: known?.note, unit: context.unit)
        return document
    }

    /// The result of `work`, or nil once `seconds` pass first. The work isn't awaited past the
    /// deadline (a slow lookup can't hold anything up), and its late result is dropped.
    static func bounded<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T?) async -> T? {
        let once = OnceResult<T>()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { once.finish(await work()) }
            Task {
                try? await Task.sleep(for: .seconds(max(0, seconds)))
                once.finish(nil)
            }
        }
    }

    private final class OnceResult<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<T?, Never>?

        func finish(_ value: T?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

// MARK: - Live cards

/// Keeps resolver cards (forecasts) current while someone looks at them: each time a client reads
/// a card older than `staleAfter`, the Mac rebuilds it in the background (one rebuild per place at
/// a time, at most every `retryAfter`) and moves Home's revisions so clients fetch the new one. The
/// card's "Updated" time says how fresh it is. Only recent results stay live.
@MainActor
final class LiveCards {
    static let shared = LiveCards()
    static let staleAfter: TimeInterval = 15 * 60
    static let retryAfter: TimeInterval = 10 * 60
    /// Run results older than this keep the forecast they were given.
    static let liveWindow: TimeInterval = 24 * 3_600

    var rebuild: @Sendable (CardDocument.Refresh) async -> CardDocument? = { refresh in
        await LiveCards.rebuilt(refresh)
    }
    /// Called on the main actor after a rebuild; Home bumps its revisions.
    var onRefresh: (() -> Void)?
    private var fresh: [String: CardDocument] = [:]
    private var attempts: [String: Date] = [:]

    /// The newest version of `card` for a client, and a rebuild started when it's stale.
    func presented(_ card: CardDocument, live: Bool, now: Date = Date()) -> CardDocument {
        guard live, let refresh = card.refresh else { return card.presented }
        var best = card
        if let newer = fresh[refresh.key],
           (newer.source?.updatedAt ?? .distantPast) > (card.source?.updatedAt ?? .distantPast) {
            best = newer
            best.id = card.id
        }
        requestIfStale(best, refresh: refresh, now: now)
        return best.presented
    }

    /// Starts rebuilds for stale cards without building a snapshot (a client polling an unchanged revision).
    func check(_ cards: [CardDocument], now: Date = Date()) {
        for card in cards { _ = presented(card, live: true, now: now) }
    }

    private func requestIfStale(_ card: CardDocument, refresh: CardDocument.Refresh, now: Date) {
        let age = now.timeIntervalSince(card.source?.updatedAt ?? .distantPast)
        guard age >= Self.staleAfter,
              now.timeIntervalSince(attempts[refresh.key] ?? .distantPast) >= Self.retryAfter else { return }
        attempts[refresh.key] = now
        let rebuild = rebuild
        Task { @MainActor [weak self] in
            guard let rebuilt = await RunCards.bounded(RunCards.deadline, { await rebuild(refresh) }),
                  rebuilt.source?.updatedAt != nil, let self else { return }
            self.fresh[refresh.key] = rebuilt
            self.onRefresh?()
        }
    }

    func reset() {
        fresh = [:]
        attempts = [:]
    }

    nonisolated static func rebuilt(_ refresh: CardDocument.Refresh) async -> CardDocument? {
        guard refresh.kind == "weather" else { return nil }
        var known: WeatherCardResolver.KnownPlace?
        if let latitude = refresh.latitude, let longitude = refresh.longitude {
            known = .init(label: refresh.label, coordinate: .init(latitude: latitude, longitude: longitude),
                          note: refresh.note ?? "")
        }
        let context = WeatherCardResolver.Context(device: nil, mac: known, unit: refresh.unit)
        let proposal = WeatherBlockProposal(place: refresh.place)
        if refresh.from != nil {
            return await RecordCards.eventWeather(proposal: proposal, context: context,
                                                  from: refresh.from, to: refresh.to, now: Date())
        }
        return await RunCards.weatherDocument(for: proposal, context: context)
    }
}

// MARK: - Cards built from a workspace's records

/// A card a task workspace builds from its own records. A `list` card (bills due this week,
/// this week's interviews) sits above the workspace's list; `weather` and `map` cards sit on a
/// record's detail and look up the place the record names. Every value comes from Cantrip's
/// records or a resolver, never from a model.
struct CantripHomeTaskCardSpec: Codable, Equatable {
    enum Kind: String, Codable {
        case list
        case weather
        case map
    }

    let kind: Kind
    /// list: the card's title ("Due in the next 7 days").
    var title: String? = nil
    /// list: sorts records by this date (or date and time) field; weather: the event's first day.
    var dateField: String? = nil
    /// list: only records dated today through this many days ahead.
    var withinDays: Int? = nil
    /// list: with `withinDays`, also earlier dates (overdue bills).
    var includeOverdue: Bool? = nil
    /// list: choice field → the values a record needs to be listed.
    var filter: [String: [String]]? = nil
    var titleField: String? = nil
    var subtitleFields: [String]? = nil
    /// list: shown at the row's end (an amount, a time).
    var trailingField: String? = nil
    /// list: at most this many rows (default 8).
    var limit: Int? = nil
    /// weather, map: the field naming the place (a city for weather, a venue for a map).
    var placeField: String? = nil
    /// map: the city or area to look for the venue in.
    var nearField: String? = nil
    /// weather: the event's last day.
    var endDateField: String? = nil

    static let maximumCards = 4
    static let defaultLimit = 8

    var isRecordCard: Bool { kind != .list }

    func validated(fields: [CantripHomeTaskField]) throws -> Self {
        func field(_ key: String?, _ name: String) throws -> CantripHomeTaskField? {
            guard let key else { return nil }
            guard let found = fields.first(where: { $0.key == key }) else {
                throw CantripHomeError(400, "A workspace card's \(name) isn't one of its fields.")
            }
            return found
        }
        func dateKind(_ field: CantripHomeTaskField?, _ name: String) throws {
            if let field, field.kind != .date, field.kind != .dateTime {
                throw CantripHomeError(400, "A workspace card's \(name) must be a date field.")
            }
        }
        var copy = self
        copy.title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title = copy.title, title.isEmpty || title.count > 60 {
            throw CantripHomeError(400, "A workspace card's title must be 1 to 60 characters.")
        }
        try dateKind(try field(dateField, "dateField"), "dateField")
        try dateKind(try field(endDateField, "endDateField"), "endDateField")
        _ = try field(titleField, "titleField")
        _ = try field(trailingField, "trailingField")
        for key in subtitleFields ?? [] { _ = try field(key, "subtitleFields") }
        switch kind {
        case .list:
            guard placeField == nil, nearField == nil, endDateField == nil else {
                throw CantripHomeError(400, "A list card takes no place fields.")
            }
            if let withinDays {
                guard (0...60).contains(withinDays), dateField != nil else {
                    throw CantripHomeError(400, "withinDays needs a dateField and 0 to 60 days.")
                }
            }
            guard (subtitleFields ?? []).count <= 3, (limit ?? Self.defaultLimit).clamped(1, 20) == (limit ?? Self.defaultLimit) else {
                throw CantripHomeError(400, "A list card shows up to 3 subtitle fields and 1 to 20 rows.")
            }
            guard (filter ?? [:]).count <= 4 else {
                throw CantripHomeError(400, "A list card filters on up to 4 choice fields.")
            }
            for (key, values) in filter ?? [:] {
                guard let choice = try field(key, "filter"), choice.kind == .choice, let options = choice.options,
                      (1...50).contains(values.count), values.allSatisfy(options.contains) else {
                    throw CantripHomeError(400, "A list card filters choice fields by their own options.")
                }
            }
        case .weather, .map:
            guard withinDays == nil, includeOverdue == nil, filter == nil, limit == nil, trailingField == nil,
                  subtitleFields == nil, titleField == nil else {
                throw CantripHomeError(400, "Weather and map cards take only place and date fields.")
            }
            guard let place = try field(placeField, "placeField"), [.text, .longText].contains(place.kind) else {
                throw CantripHomeError(400, "Weather and map cards need a text placeField.")
            }
            if let near = try field(nearField, "nearField"), ![.text, .longText].contains(near.kind) {
                throw CantripHomeError(400, "A map card's nearField must be a text field.")
            }
            if kind == .map, dateField != nil || endDateField != nil {
                throw CantripHomeError(400, "A map card takes no dates.")
            }
            if kind == .weather, nearField != nil {
                throw CantripHomeError(400, "A weather card takes no nearField; point placeField at the city.")
            }
            if endDateField != nil, dateField == nil {
                throw CantripHomeError(400, "endDateField needs a dateField.")
            }
        }
        return copy
    }

    static func validated(_ specs: [CantripHomeTaskCardSpec]?, fields: [CantripHomeTaskField]) throws -> [CantripHomeTaskCardSpec]? {
        guard let specs else { return nil }
        guard specs.count <= maximumCards else {
            throw CantripHomeError(400, "A workspace shows at most \(maximumCards) cards.")
        }
        guard specs.filter({ $0.kind == .weather }).count <= 1, specs.filter({ $0.kind == .map }).count <= 1 else {
            throw CantripHomeError(400, "A record's detail shows at most one weather and one map card.")
        }
        let valid = try specs.map { try $0.validated(fields: fields) }
        return valid.isEmpty ? nil : valid
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(high, Swift.max(low, self)) }
}

enum WorkspaceCards {
    /// The workspace's list cards, newest values first: built when the snapshot is.
    static func documents(for task: CantripHomeTask, now: Date = Date(), calendar: Calendar = .current) -> [CardDocument] {
        guard let workspace = task.workspace, let specs = workspace.cards else { return [] }
        return specs.enumerated().compactMap { index, spec in
            spec.kind == .list ? list(spec, index: index, task: task, workspace: workspace, now: now, calendar: calendar) : nil
        }
    }

    /// A record field's day (a date, or a date and time's local day) and the time when it has one.
    static func day(_ value: String?, kind: CantripHomeTaskField.Kind?, calendar: Calendar) -> (day: Date, time: Date?)? {
        guard let value, !value.isEmpty else { return nil }
        if kind == .dateTime, let date = ISODate.date(from: value, allowFractionalSeconds: false) {
            return (calendar.startOfDay(for: date), date)
        }
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return (calendar.startOfDay(for: date), nil)
    }

    static func list(_ spec: CantripHomeTaskCardSpec, index: Int, task: CantripHomeTask,
                     workspace: CantripHomeTaskWorkspace, now: Date, calendar: Calendar) -> CardDocument {
        let today = calendar.startOfDay(for: now)
        let dateField = spec.dateField.flatMap { key in workspace.fields.first { $0.key == key } }
        let titleKey = spec.titleField ?? workspace.list.titleField
        let subtitleKeys = (spec.subtitleFields ?? workspace.list.subtitleFields)
            .filter { $0 != titleKey && $0 != spec.dateField && $0 != spec.trailingField }
        let plural = workspace.recordLabelPlural ?? workspace.recordLabel + "s"
        var rows = workspace.records.filter { record in
            (spec.filter ?? [:]).allSatisfy { key, values in record.values[key].map(values.contains) ?? false }
        }.map { record in (record, day(dateField.flatMap { record.values[$0.key] }, kind: dateField?.kind, calendar: calendar)) }
        if let days = spec.withinDays {
            let end = calendar.date(byAdding: .day, value: days + 1, to: today) ?? today
            rows = rows.filter { _, date in
                guard let date else { return false }
                return date.day < end && (spec.includeOverdue == true || date.day >= today)
            }
        }
        if dateField != nil {
            // Dated records soonest first; undated ones after them, in their saved order.
            rows = rows.enumerated().sorted { lhs, rhs in
                switch (lhs.element.1, rhs.element.1) {
                case let (left?, right?): return (left.time ?? left.day, lhs.offset) < (right.time ?? right.day, rhs.offset)
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return lhs.offset < rhs.offset
                }
            }.map(\.element)
        }
        let total = rows.count
        let shown = rows.prefix(spec.limit ?? CantripHomeTaskCardSpec.defaultLimit)
        let window = spec.withinDays.map { $0 == 0 ? "today" : $0 == 1 ? "today and tomorrow" : "in the next \($0) days" }

        var header = CardDocument.Block(type: "header")
        header.title = spec.title ?? plural
        let noun = total == 1 ? workspace.recordLabel.lowercased() : plural.lowercased()
        header.subtitle = ["\(total) \(noun)", window].compactMap { $0 }.joined(separator: " · ")
        header.symbol = workspace.icon
        var blocks = [header]
        if shown.isEmpty {
            var notice = CardDocument.Block(type: "notice")
            notice.symbol = "checkmark.circle"
            notice.tone = "positive"
            notice.title = "All clear"
            notice.text = window.map { "No \(plural.lowercased()) \($0)." } ?? "No \(plural.lowercased()) to show."
            blocks.append(notice)
        } else {
            var list = CardDocument.Block(type: "list")
            list.items = shown.map { record, date in
                item(record, date: date, dateKind: dateField?.kind, titleKey: titleKey, subtitleKeys: subtitleKeys,
                     spec: spec, workspace: workspace, today: today, calendar: calendar)
            }
            blocks.append(list)
            if total > shown.count {
                var more = CardDocument.Block(type: "notice")
                more.symbol = "ellipsis.circle"
                more.tone = "neutral"
                more.title = "\(total - shown.count) more"
                blocks.append(more)
            }
        }
        let updated = workspace.records.map(\.updatedAt).max()
        return CardDocument(id: "records-\(task.id.uuidString)-\(index)", type: "records",
                            accessibilityLabel: header.title.map { "\($0), \(header.subtitle ?? "")" },
                            source: .init(kind: "records", name: task.title, updatedAt: updated),
                            blocks: blocks).withFallbackText()
    }

    private static func item(_ record: CantripHomeTaskRecord, date: (day: Date, time: Date?)?,
                             dateKind: CantripHomeTaskField.Kind?, titleKey: String, subtitleKeys: [String],
                             spec: CantripHomeTaskCardSpec, workspace: CantripHomeTaskWorkspace,
                             today: Date, calendar: Calendar) -> CardDocument.Item {
        var item = CardDocument.Item()
        item.id = record.id.uuidString
        item.title = record.values[titleKey].flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        var parts: [String] = []
        if let date {
            var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
            style.timeZone = calendar.timeZone
            var text = date.day.formatted(style)
            if let time = date.time {
                var clock = Date.FormatStyle.dateTime.hour().minute()
                clock.timeZone = calendar.timeZone
                text += ", " + time.formatted(clock)
            }
            parts.append(text)
        }
        parts += subtitleKeys.compactMap { record.values[$0] }.filter { !$0.isEmpty }
        item.subtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        item.trailing = spec.trailingField.flatMap { record.values[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        var badges: [CardDocument.Badge] = []
        if let date {
            let days = calendar.dateComponents([.day], from: today, to: date.day).day ?? 0
            if days < 0 {
                badges.append(.init(text: days == -1 ? "1 day overdue" : "\(-days) days overdue", tone: "negative"))
            } else if days == 0 {
                badges.append(.init(text: "Today", tone: "warning"))
            } else if days == 1 {
                badges.append(.init(text: "Tomorrow", tone: "accent"))
            }
        }
        if let key = workspace.list.badgeField, key != titleKey, spec.filter?[key]?.count != 1,
           let value = record.values[key], !value.isEmpty {
            badges.append(.init(text: value, tone: "neutral"))
        }
        item.badges = badges.isEmpty ? nil : badges
        item.accessibilityLabel = ([item.title, item.subtitle, item.trailing].compactMap { $0 }
            + badges.map(\.text)).joined(separator: ", ")
        return item
    }
}

// MARK: - Record detail cards (weather, map)

/// A record's weather and map cards, looked up when a client opens its detail and cached
/// (forecasts for 10 minutes, maps for 12 hours), so a detail that stays open keeps current.
@MainActor
final class RecordCards {
    static let shared = RecordCards()
    static let forecastLifetime: TimeInterval = 10 * 60
    static let mapLifetime: TimeInterval = 12 * 3_600
    /// Clients ask again after this many seconds while the detail is open.
    static let refreshAfter = 300

    private var cache: [String: (card: CardDocument?, at: Date)] = [:]
    private var pending: [String: Task<CardDocument?, Never>] = [:]

    func reset() {
        cache = [:]
        pending = [:]
    }

    /// The record's cards, in the workspace's order. Each lookup has a deadline.
    func cards(task: CantripHomeTask, recordID: UUID, now: Date = Date()) async -> [CardDocument] {
        guard let workspace = task.workspace, let record = workspace.records.first(where: { $0.id == recordID }) else {
            return []
        }
        var result: [CardDocument] = []
        for (index, spec) in (workspace.cards ?? []).enumerated() where spec.isRecordCard {
            guard let place = spec.placeField.flatMap({ record.values[$0] })?.trimmingCharacters(in: .whitespaces),
                  !place.isEmpty else { continue }
            let near = spec.nearField.flatMap { record.values[$0] }
            let from = spec.dateField.flatMap { record.values[$0] }.map { String($0.prefix(10)) }
            let to = (spec.endDateField.flatMap { record.values[$0] } ?? spec.dateField.flatMap { record.values[$0] })
                .map { String($0.prefix(10)) }
            let key = [task.id.uuidString, recordID.uuidString, String(index), spec.kind.rawValue, place, near ?? "",
                       from ?? "", to ?? ""].joined(separator: "|")
            let lifetime = spec.kind == .map ? Self.mapLifetime : Self.forecastLifetime
            if let hit = cache[key], now.timeIntervalSince(hit.at) < lifetime {
                if var card = hit.card { card.id = "record-\(recordID.uuidString)-\(index)"; result.append(card.presented) }
                continue
            }
            let context = WeatherCardResolver.Context(device: nil, mac: WeatherCardResolver.macPlace(),
                                                      unit: WeatherCardResolver.preferredUnit)
            let lookup = pending[key] ?? Task { () -> CardDocument? in
                switch spec.kind {
                case .weather:
                    return await RunCards.bounded(RunCards.deadline) {
                        await Self.eventWeather(proposal: .init(place: place), context: context, from: from, to: to, now: now)
                    }
                case .map:
                    let proposal = PlaceBlockProposal(query: place, near: near,
                                                      places: [.init(name: place, query: [place, near].compactMap { $0 }.joined(separator: " "))])
                    return await RunCards.bounded(RunCards.deadline) {
                        await PlaceCardResolver.shared.resolve(proposal)?.document
                    }
                case .list:
                    return nil
                }
            }
            pending[key] = lookup
            let card = await lookup.value
            pending[key] = nil
            cache[key] = (card, now)
            if var card {
                card.id = "record-\(recordID.uuidString)-\(index)"
                result.append(card.presented)
            }
        }
        return result
    }

    /// The forecast for an event's days: just those days once they're within the 10-day forecast,
    /// with now and the next hours only while it's on; before that, when the forecast opens. Nil
    /// once the event is over.
    nonisolated static func eventWeather(proposal: WeatherBlockProposal, context: WeatherCardResolver.Context,
                                         from: String?, to: String?, now: Date) async -> CardDocument? {
        guard from != nil || to != nil else { return await RunCards.weatherDocument(for: proposal, context: context) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let format = DateFormatter()
        format.calendar = calendar
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = calendar.timeZone
        format.dateFormat = "yyyy-MM-dd"
        let today = format.string(from: now)
        let start = from ?? to!, end = max(to ?? start, start)
        guard end >= today else { return nil }
        let place = proposal.place.flatMap(WeatherBlock.clean) ?? "Weather"
        var dateStyle = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        dateStyle.timeZone = calendar.timeZone
        let label = [start, end].compactMap(format.date(from:)).map { $0.formatted(dateStyle) }
        let dates = label.count == 2 && start != end ? "\(label[0]) – \(label[1])" : (label.first ?? start)
        let refresh = CardDocument.Refresh(kind: "weather", place: proposal.place, label: context.mac?.label,
                                           latitude: context.mac?.coordinate.latitude,
                                           longitude: context.mac?.coordinate.longitude, note: context.mac?.note,
                                           unit: context.unit, from: start, to: end)
        let opens = format.date(from: start).flatMap { calendar.date(byAdding: .day, value: -(WeatherCard.dayCount - 1), to: $0) }
        if let opens, opens > now {
            var header = CardDocument.Block(type: "header")
            header.title = WeatherCardResolver.displayName(place)
            header.subtitle = dates
            header.subtitleSymbol = "calendar"
            var notice = CardDocument.Block(type: "notice")
            notice.symbol = "calendar.badge.clock"
            notice.tone = "accent"
            notice.title = "Forecast opens \(opens.formatted(dateStyle))"
            notice.text = "Open-Meteo forecasts 10 days ahead."
            var card = CardDocument(id: "event-weather", type: "weather", accessibilityLabel: "Weather for \(place), \(dates)",
                                    source: .init(kind: "resolver", name: "Open-Meteo", attribution: WeatherCard.attribution,
                                                  url: WeatherCard.attributionURL),
                                    blocks: [header, notice]).withFallbackText()
            card.refresh = refresh
            return card
        }
        guard var weather = await WeatherCardResolver.resolve(proposal, context: context) else { return nil }
        let days = weather.days.filter { $0.date >= start && $0.date <= end }
        if weather.isAvailable, !days.isEmpty { weather.days = days }
        let isOn = start <= today
        if !isOn { weather.hours = [] }
        var document = weather.document
        if weather.isAvailable, let index = document.blocks.firstIndex(where: { $0.type == "header" }) {
            document.blocks[index].subtitle = dates
            document.blocks[index].subtitleSymbol = "calendar"
            if !isOn {
                // Today's conditions aren't the event's.
                document.blocks[index].stat = nil
                document.blocks[index].lines = nil
            }
            if !isOn { document.blocks.removeAll { $0.type == "strip" } }
            // The forecast calls its first day "Today"; an event's first day may not be.
            if let chart = document.blocks.firstIndex(where: { $0.type == "chart" }) {
                var weekday = Date.FormatStyle.dateTime.weekday(.abbreviated)
                weekday.timeZone = calendar.timeZone
                var items = document.blocks[chart].items ?? []
                for (offset, day) in weather.days.enumerated() where offset < items.count {
                    let label = day.date == today ? "Today" : format.date(from: day.date).map { $0.formatted(weekday) } ?? day.date
                    guard let old = items[offset].label, old != label else { continue }
                    items[offset].label = label
                    items[offset].accessibilityLabel = items[offset].accessibilityLabel
                        .map { $0.hasPrefix(old) ? label + $0.dropFirst(old.count) : $0 }
                }
                document.blocks[chart].items = items
            }
            document = document.withFallbackText()
        }
        document.accessibilityLabel = "Weather for \(place), \(dates)"
        document.refresh = refresh
        return document
    }
}
