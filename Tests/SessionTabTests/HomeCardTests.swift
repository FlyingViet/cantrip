import Foundation

extension SessionTabTests {
    /// Cards on Home: a run's weather, places and card blocks on its result (resolved by a
    /// deadline, never failing the run), workspace cards built from records, a record's weather
    /// and map cards, live forecasts and the specs Home may save.
    @MainActor
    static func testHomeCards() async throws {
        try testHomeCardSpecs()
        try testWorkspaceListCards()
        try await testRunCardResolution()
        try await testRecordDetailCards()
        try await testHomeRunCardsEndToEnd()
        print("Home cards: run results, deadlines, record cards, record detail cards, live forecasts and specs passed")
    }

    static var forecastFixture: Data {
        get throws {
            try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("RichCardTests/open-meteo-seattle.json"))
        }
    }

    static func billsWorkspace(cards: String = "null") throws -> CantripHomeTaskWorkspaceProposal {
        try JSONDecoder().decode(CantripHomeTaskWorkspaceProposal.self, from: Data("""
        {"recordLabel":"Bill","recordLabelPlural":"Bills","icon":"creditcard",
         "fields":[{"key":"name","label":"Name","kind":"text","required":true,"options":null},
                   {"key":"due","label":"Due","kind":"date","required":false,"options":null},
                   {"key":"amount","label":"Amount","kind":"text","required":false,"options":null},
                   {"key":"status","label":"Status","kind":"choice","required":false,"options":["Unpaid","Paid","Autopay"]},
                   {"key":"city","label":"City","kind":"text","required":false,"options":null},
                   {"key":"end","label":"Ends","kind":"date","required":false,"options":null},
                   {"key":"site","label":"Site","kind":"url","required":false,"options":null}],
         "list":{"titleField":"name","subtitleFields":["amount"],"badgeField":"status","dateField":"due"},
         "detailSections":[{"title":null,"fields":["name","due","amount","status","city","end"]}],
         "cards":\(cards)}
        """.utf8))
    }

    static func testHomeCardSpecs() throws {
        let workspace = try billsWorkspace()
        func spec(_ json: String) throws -> CantripHomeTaskCardSpec {
            try JSONDecoder().decode(CantripHomeTaskCardSpec.self, from: Data(json.utf8))
        }
        func rejects(_ json: String, _ why: String) throws {
            let candidate = try spec(json)
            do {
                _ = try candidate.validated(fields: workspace.fields)
                preconditionFailure("accepted \(json): \(why)")
            } catch is CantripHomeError {}
        }
        let list = try spec(#"{"kind":"list","title":"Due this week","dateField":"due","withinDays":7,"includeOverdue":true,"filter":{"status":["Unpaid"]},"trailingField":"amount"}"#)
        precondition((try? list.validated(fields: workspace.fields)) != nil)
        precondition((try? spec(#"{"kind":"weather","placeField":"city","dateField":"due","endDateField":"end"}"#)
            .validated(fields: workspace.fields)) != nil)
        precondition((try? spec(#"{"kind":"map","placeField":"name","nearField":"city"}"#).validated(fields: workspace.fields)) != nil)
        try rejects(#"{"kind":"list","withinDays":7}"#, "a window needs a date field")
        try rejects(#"{"kind":"list","dateField":"amount"}"#, "sorting needs a date field")
        try rejects(#"{"kind":"list","filter":{"name":["x"]}}"#, "filters are for choice fields")
        try rejects(#"{"kind":"list","filter":{"status":["Overdue"]}}"#, "filters use the field's own options")
        try rejects(#"{"kind":"list","limit":50}"#, "at most 20 rows")
        try rejects(#"{"kind":"list","titleField":"missing"}"#, "unknown fields")
        try rejects(#"{"kind":"weather","placeField":"site"}"#, "a place is a text field")
        try rejects(#"{"kind":"weather"}"#, "weather needs a place")
        try rejects(#"{"kind":"map","placeField":"name","dateField":"due"}"#, "maps take no dates")
        try rejects(#"{"kind":"weather","placeField":"city","endDateField":"end"}"#, "an end needs a start")
        let five = try (0..<5).map { _ in try spec(#"{"kind":"list"}"#) }
        precondition((try? CantripHomeTaskCardSpec.validated(five, fields: workspace.fields)) == nil, "at most four cards")
        let twoMaps = try [spec(#"{"kind":"map","placeField":"name"}"#), spec(#"{"kind":"map","placeField":"city"}"#)]
        precondition((try? CantripHomeTaskCardSpec.validated(twoMaps, fields: workspace.fields)) == nil, "one map per record")
        let none = try CantripHomeTaskCardSpec.validated([], fields: workspace.fields)
        precondition(none == nil, "[] removes the cards")
    }

    static func testWorkspaceListCards() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Sunday, November 1 2026, 3 PM in Los Angeles.
        let now = Date(timeIntervalSince1970: 1_793_570_400 + 3_600)
        var workspace = CantripHomeTaskWorkspace(
            recordLabel: "Bill", recordLabelPlural: "Bills", icon: "creditcard",
            fields: try billsWorkspace().fields,
            list: .init(titleField: "name", subtitleFields: ["amount"], badgeField: "status", dateField: "due"),
            detailSections: [], records: [])
        func record(_ name: String, _ due: String?, _ amount: String, _ status: String) -> CantripHomeTaskRecord {
            var values = ["name": name, "amount": amount, "status": status]
            values["due"] = due
            return CantripHomeTaskRecord(values: values, createdAt: now, updatedAt: now.addingTimeInterval(-600))
        }
        workspace.records = [
            record("Water", "2026-11-08", "$40.12", "Unpaid"),
            record("Rent", "2026-10-30", "$2,400.00", "Unpaid"),
            record("Phone", "2026-11-01", "$65.00", "Unpaid"),
            record("Power", "2026-11-02", "$88.10", "Unpaid"),
            record("Gym", "2026-11-03", "$30.00", "Paid"),
            record("Car", "2026-11-20", "$310.00", "Unpaid"),
            record("Undated", nil, "$1.00", "Unpaid"),
        ]
        workspace.cards = [CantripHomeTaskCardSpec(kind: .list, title: "Due in the next 7 days", dateField: "due",
                                                   withinDays: 7, includeOverdue: true, filter: ["status": ["Unpaid"]],
                                                   trailingField: "amount")]
        var task = CantripHomeTask(title: "Bills and subscriptions", prompt: "Track bills.",
                                   schedule: .init(kind: .once, summary: "No schedule", timeZone: "America/Los_Angeles", startAt: nil),
                                   hasSchedule: false, workspace: workspace)
        let card = try requireHome(WorkspaceCards.documents(for: task, now: now, calendar: calendar).first)
        let items = card.blocks.first { $0.type == "list" }?.items ?? []
        precondition(items.map(\.title) == ["Rent", "Phone", "Power", "Water"],
                     "unpaid bills due within 7 days, overdue first, soonest first: \(items.map(\.title))")
        precondition(card.blocks[0].title == "Due in the next 7 days" && card.blocks[0].subtitle == "4 bills · in the next 7 days"
                     && card.blocks[0].symbol == "creditcard")
        precondition(items[0].badges?.first?.text == "2 days overdue" && items[0].badges?.first?.tone == "negative"
                     && items[1].badges?.first?.text == "Today" && items[2].badges?.first?.text == "Tomorrow"
                     && items[3].badges == nil, "\(items.map { $0.badges?.map(\.text) ?? [] })")
        precondition(items[0].trailing == "$2,400.00" && items[0].subtitle == "Fri, Oct 30"
                     && items[0].accessibilityLabel == "Rent, Fri, Oct 30, $2,400.00, 2 days overdue", "\(items[0])")
        precondition(card.source?.kind == "records" && card.source?.name == "Bills and subscriptions"
                     && card.source?.updatedAt == now.addingTimeInterval(-600) && card.fallbackText?.contains("• Rent") == true)
        // Values come only from the records; nothing else can reach the card.
        let recordText = Set(workspace.records.flatMap { $0.values.values })
        precondition(items.allSatisfy { recordText.contains($0.title ?? "") && recordText.contains($0.trailing ?? "") })

        task.workspace?.cards = [CantripHomeTaskCardSpec(kind: .list, dateField: "due", withinDays: 7,
                                                         filter: ["status": ["Autopay"]])]
        let empty = try requireHome(WorkspaceCards.documents(for: task, now: now, calendar: calendar).first)
        precondition(empty.blocks.map(\.type) == ["header", "notice"] && empty.blocks[1].title == "All clear"
                     && empty.blocks[1].text == "No bills in the next 7 days." && empty.blocks[0].subtitle == "0 bills · in the next 7 days")
        task.workspace?.cards = [CantripHomeTaskCardSpec(kind: .list, dateField: "due", limit: 2)]
        let limited = try requireHome(WorkspaceCards.documents(for: task, now: now, calendar: calendar).first)
        precondition(limited.blocks.map(\.type) == ["header", "list", "notice"] && limited.blocks[2].title == "5 more"
                     && limited.blocks[1].items?.map(\.title) == ["Rent", "Phone"], "\(limited.blocks)")
        task.workspace?.cards = [CantripHomeTaskCardSpec(kind: .weather, placeField: "city")]
        precondition(WorkspaceCards.documents(for: task, now: now).isEmpty, "record cards aren't list cards")
    }

    actor SlowSwitch {
        var delay: Duration = .zero
        func set(_ value: Duration) { delay = value }
    }

    @MainActor
    static func testRunCardResolution() async throws {
        let fixture = try forecastFixture
        let slow = SlowSwitch()
        let fetchedAt = Date().addingTimeInterval(-20 * 60)
        try await Task.sleep(for: .milliseconds(200))
        let sources = WeatherCardResolver.Sources(
            geocode: { $0.lowercased().hasPrefix("seattle") ? .init(coordinate: .init(latitude: 47.6062, longitude: -122.3321)) : nil },
            forecast: { _, _ in
                try await Task.sleep(for: await slow.delay)
                return try WeatherForecast.parse(fixture, fetchedAt: fetchedAt)
            }
        )
        await WeatherCardResolver.shared.setSources(sources)
        let activities = [ToolActivity(id: "c", title: "calendar", toolName: "personal-calendar_events", state: .succeeded,
                                       input: nil, output: #"[{"title":"Standup","start":"9:30","end":"9:45"}]"#, fileChanges: [])]
        var text = """
        Morning briefing done.

        Summary: Clear skies, one meeting.

        ```weather
        {"place":"Seattle, WA"}
        ```
        ```card
        {"title":"Today","cite":{"tool":"calendar_events"},"blocks":[{"type":"list","items":[{"title":"Standup","subtitle":"9:30–9:45"}]}]}
        ```
        ```card
        {"title":"Invented","cite":{"tool":"calendar_events"},"blocks":[{"type":"keyValue","rows":[{"key":"Lunch","value":"12:15"}]}]}
        ```
        """
        let (pending, unshown) = RunCards.extract(from: &text, activities: activities)
        precondition(pending.weather?.place == "Seattle, WA" && pending.checked.count == 1 && unshown == ["Invented\nLunch: 12:15"]
                     && !text.contains("```") && text.hasSuffix("Summary: Clear skies, one meeting."), "\(text) \(unshown)")
        let context = WeatherCardResolver.Context(device: nil, mac: nil, unit: "F")
        let cards = await RunCards.resolve(pending, context: context)
        precondition(cards.map(\.type) == ["weather", "custom"] && cards.map(\.id) == ["weather-seattle, wa", "run-card-1"]
                     && cards[0].refresh?.place == "Seattle, WA" && cards[0].refresh?.unit == "F"
                     && cards[0].presented.refresh == nil && cards[1].source?.name == "calendar_events", "\(cards.map(\.id))")

        // A lookup that outlasts the deadline is dropped; the run's other cards still show.
        await slow.set(.seconds(3))
        await WeatherCardResolver.shared.setSources(sources)
        let started = Date()
        let late = await RunCards.resolve(pending, context: context, deadline: 0.3)
        precondition(Date().timeIntervalSince(started) < 2 && late.map(\.type) == ["custom"],
                     "a slow forecast can't hold a run's result: \(late.map(\.type))")
        await slow.set(.zero)
        await WeatherCardResolver.shared.setSources(nil)

        // Live cards: a stale forecast is rebuilt in the background while it's read.
        let live = LiveCards.shared
        let savedRebuild = live.rebuild
        let savedOnRefresh = live.onRefresh
        live.reset()
        var refreshed = 0
        live.onRefresh = { refreshed += 1 }
        defer {
            live.rebuild = savedRebuild
            live.onRefresh = savedOnRefresh
            live.reset()
        }
        live.rebuild = { refresh in
            var card = cards[0]
            card.source?.updatedAt = Date()
            card.blocks[0].title = "Rebuilt \(refresh.place ?? "")"
            return card
        }
        let first = live.presented(cards[0], live: true)
        precondition(first.refresh == nil && first.blocks[0].title == "Seattle, WA")
        try await waitForJournalTest { refreshed == 1 }
        let second = live.presented(cards[0], live: true)
        precondition(second.blocks[0].title == "Rebuilt Seattle, WA" && second.id == cards[0].id
                     && (second.source?.updatedAt ?? .distantPast) > fetchedAt, "the newer forecast is shown")
        _ = live.presented(cards[0], live: true)
        try await Task.sleep(for: .milliseconds(150))
        precondition(refreshed == 1, "one rebuild per place per retry interval")
        let frozen = live.presented(cards[0], live: false)
        precondition(frozen.blocks[0].title == "Seattle, WA" && frozen.refresh == nil, "old results keep their forecast")
    }

    @MainActor
    static func testRecordDetailCards() async throws {
        let fixture = try forecastFixture
        await WeatherCardResolver.shared.setSources(.init(
            geocode: { $0.lowercased().hasPrefix("seattle") ? .init(coordinate: .init(latitude: 47.6062, longitude: -122.3321)) : nil },
            forecast: { _, _ in try WeatherForecast.parse(fixture, fetchedAt: Date(timeIntervalSince1970: 1_793_571_300)) }
        ))
        let context = WeatherCardResolver.Context(device: nil, mac: nil, unit: "F")
        // Sunday November 1 2026, 3:15 PM in Los Angeles; the fixture's days run Nov 1 to Nov 10.
        let now = Date(timeIntervalSince1970: 1_793_571_300 + 1_800)
        let weekend = try requireHome(await RecordCards.eventWeather(proposal: .init(place: "Seattle, WA"), context: context,
                                                                     from: "2026-11-06", to: "2026-11-08", now: now))
        let chart = weekend.blocks.first { $0.type == "chart" }
        precondition(chart?.items?.map(\.label) == ["Fri", "Sat", "Sun"]
                     && chart?.items?.first?.accessibilityLabel?.hasPrefix("Fri, ") == true
                     && weekend.blocks.contains { $0.type == "strip" } == false
                     && weekend.blocks[0].stat == nil && weekend.blocks[0].subtitle == "Fri, Nov 6 – Sun, Nov 8"
                     && weekend.refresh?.from == "2026-11-06", "the event's days only: \(weekend.blocks.map(\.type))")
        let far = try requireHome(await RecordCards.eventWeather(proposal: .init(place: "Seattle, WA"), context: context,
                                                                 from: "2026-12-12", to: "2026-12-13", now: now))
        precondition(far.blocks.map(\.type) == ["header", "notice"] && far.blocks[1].title == "Forecast opens Thu, Dec 3"
                     && far.source?.updatedAt == nil, "\(far.blocks.map { $0.title ?? "" })")
        let over = await RecordCards.eventWeather(proposal: .init(place: "Seattle, WA"), context: context,
                                                  from: "2026-10-20", to: "2026-10-21", now: now)
        precondition(over == nil, "no forecast for an event that's over")
        await WeatherCardResolver.shared.setSources(nil)
    }

    /// A background run that ends with a weather block: the card is on its result in Background,
    /// the task's runs and the run's report; a forecast that can't resolve still leaves a
    /// successful run. Workspace and record cards reach clients through the tasks API.
    @MainActor
    static func testHomeRunCardsEndToEnd() async throws {
        let store = CantripHomeStore.shared
        let settings = AppSettings.shared
        let saved = (settings.cantripHomeEnabled, settings.memoryEnabled, settings.shareLocation, settings.backend)
        settings.memoryEnabled = false
        settings.shareLocation = false
        // The fixture backend stands in for Copilot's.
        settings.backend = .copilot
        defer { (settings.cantripHomeEnabled, settings.memoryEnabled, settings.shareLocation, settings.backend) = saved }
        for task in store.tasks where task.isScheduled && task.enabled {
            _ = try store.update(id: task.id, update: .init(title: nil, prompt: nil, enabled: false))
        }
        let fixture = try forecastFixture
        let slow = SlowSwitch()
        try await Task.sleep(for: .milliseconds(200))
        let sources = WeatherCardResolver.Sources(
            geocode: { $0.lowercased().hasPrefix("seattle") ? .init(coordinate: .init(latitude: 47.6062, longitude: -122.3321)) : nil },
            forecast: { _, _ in
                try await Task.sleep(for: await slow.delay)
                return try WeatherForecast.parse(fixture, fetchedAt: Date())
            }
        )
        await WeatherCardResolver.shared.setSources(sources)
        await PlaceCardResolver.shared.setCustomLookup { proposal, _ in
            PlaceCard(query: proposal.query ?? "", regionName: nil, centerLatitude: 34.07, centerLongitude: -117.27,
                      latitudeDelta: 0.04, longitudeDelta: 0.04,
                      places: [PlacePin(id: "v1", name: proposal.places.first?.name ?? "", latitude: 34.07, longitude: -117.27,
                                        category: "Venue", address: nil, phone: nil, website: nil, rating: nil, reviewCount: nil,
                                        priceLevel: nil, isOpenNow: nil, hoursSummary: nil)])
        }

        let home = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: CantripHomeBackendFixture())
        let log = ChatSession(id: ChatSession.cantripHomeBackgroundID, copilotBackend: CantripHomeBackendFixture())
        log.messages = []
        let manager = SessionManager(homeSession: home, homeBackgroundSession: log)
        var fixtures: [UUID: CantripHomeBackendFixture] = [:]
        let savedMake = store.runner.makeSession
        store.runner.makeSession = { id in
            let backend = CantripHomeBackendFixture()
            fixtures[id] = backend
            return ChatSession(id: id, copilotBackend: backend, cantripHomeRun: true, makeJournal: {
                try RunJournal(sessionID: $0, directory: CantripHomeStore.runsDirectory)
            })
        }
        defer { store.runner.makeSession = savedMake }
        store.attach(manager: manager)
        settings.cantripHomeEnabled = true

        // The background protocol teaches run cards on every backend.
        let probe = ChatSession(cantripHomeRun: true, makeJournal: { _ in
            try RunJournal(sessionID: UUID(), directory: CantripHomeStore.runsDirectory)
        })
        precondition(probe.cantripHomeInstructions.contains("Run result cards:")
                     && home.cantripHomeInstructions.contains("Workspace cards (up to 4)"))

        let zone = "America/Los_Angeles"
        let today = Date()
        func day(_ offset: Int) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let format = DateFormatter()
            format.calendar = calendar
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy-MM-dd"
            return format.string(from: calendar.date(byAdding: .day, value: offset, to: today)!)
        }
        let cards = #"[{"kind":"list","title":"Due in the next 7 days","dateField":"due","withinDays":7,"includeOverdue":true,"filter":{"status":["Unpaid"]},"trailingField":"amount"},{"kind":"weather","placeField":"city","dateField":"due","endDateField":"end"},{"kind":"map","placeField":"name","nearField":"city"}]"#
        let due = Date()
        var bills = try store.create(.init(
            id: nil, title: "Bills test", prompt: "Check the bills.",
            schedule: .init(kind: .once, summary: "Once", timeZone: zone, startAt: due),
            workspace: try billsWorkspace(cards: cards),
            initialRecords: [["name": "Water", "due": day(2), "amount": "$40.12", "status": "Unpaid", "city": "Seattle, WA"],
                             ["name": "Festival", "due": day(30), "end": day(31), "amount": "$0", "status": "Paid", "city": "Seattle, WA"]]
        ), now: due.addingTimeInterval(-30))
        precondition(bills.workspace?.cards?.map(\.kind) == [.list, .weather, .map])
        precondition(bills.workspace?.promptSchema.contains(#"; cards [{"dateField":"due""#) == true,
                     "Home sees the saved cards so it can edit them")

        func runFor(_ task: UUID) -> CantripHomeBackgroundRun? {
            store.backgroundRuns.first { $0.taskID == task && $0.status == "running" }
        }
        store.checkNow()
        let first = try requireHome(runFor(bills.id))
        try await waitForJournalTest { store.runner.session(forRun: first.id).flatMap { fixtures[$0.id]?.sink } != nil }
        let firstSession = try requireHome(store.runner.session(forRun: first.id))
        fixtures[firstSession.id]?.sink?(.textDelta("""
        Checked the bills.

        Summary: Water is due in two days.

        ```weather
        {"place":"Seattle, WA"}
        ```
        """))
        fixtures[firstSession.id]?.sink?(.done)
        try await waitForJournalTest { store.backgroundRuns.first { $0.id == first.id }?.status != "running" }
        let finished = try requireHome(store.backgroundRuns.first { $0.id == first.id })
        precondition(finished.status == "succeeded" && finished.summary == "Water is due in two days."
                     && finished.cards?.map(\.type) == ["weather"], "\(finished.summary) \(String(describing: finished.cards?.map(\.type)))")
        bills = try requireHome(store.tasks.first { $0.id == bills.id })
        precondition(bills.runs.first?.id == first.id && bills.runs.first?.cards?.first?.type == "weather"
                     && bills.runs.first?.summary == "Water is due in two days.", "the task's run keeps the same card")
        try await waitForJournalTest { log.messages.contains { !$0.cards.isEmpty } }
        let report = try requireHome(log.messages.last { $0.role == .assistant })
        precondition(report.cardDocuments(linkPreviews: false).first?.type == "weather" && !report.text.contains("```weather"),
                     "the run's report in Home's background log shows the card")

        // Clients get the cards without the Mac's refresh details, with ISO dates.
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 20_000...45_000)
        let token = "home-cards-" + UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ path: String) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.setValue("Bear" + "er \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await client.data(for: request)
            precondition((response as! HTTPURLResponse).statusCode == 200, "\(path): \(String(decoding: data, as: UTF8.self))")
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        let background = try await call("/api/v1/home/background")
        let runSnapshot = try requireHome((background["runs"] as? [[String: Any]])?.first { $0["id"] as? String == first.id.uuidString })
        let runCard = try requireHome((runSnapshot["cards"] as? [[String: Any]])?.first)
        precondition(runCard["type"] as? String == "weather" && runCard["refresh"] == nil
                     && ((runCard["source"] as? [String: Any])?["updatedAt"] as? String)?.hasSuffix("Z") == true,
                     "\(runCard.keys.sorted())")
        let tasks = try await call("/api/v1/home/tasks")
        let taskSnapshot = try requireHome((tasks["tasks"] as? [[String: Any]])?.first { $0["id"] as? String == bills.id.uuidString })
        let taskRun = try requireHome((taskSnapshot["runs"] as? [[String: Any]])?.first)
        precondition((taskRun["cards"] as? [[String: Any]])?.first?["type"] as? String == "weather"
                     && (taskRun["cards"] as? [[String: Any]])?.first?["refresh"] == nil && tasks["supportsRecordCards"] as? Bool == true)
        let listCard = try requireHome((tasks["workspaceCards"] as? [String: Any])?[bills.id.uuidString] as? [[String: Any]])
        let rows = ((listCard.first?["blocks"] as? [[String: Any]])?.first { $0["type"] as? String == "list" }?["items"] as? [[String: Any]]) ?? []
        precondition(rows.map { $0["title"] as? String } == ["Water"] && rows.first?["trailing"] as? String == "$40.12",
                     "the bills due card lists only unpaid bills due this week")
        let festival = try requireHome(bills.workspace?.records.first { $0.values["name"] == "Festival" })
        let recordCards = try await call("/api/v1/home/tasks/\(bills.id.uuidString)/records/\(festival.id.uuidString)/cards")
        let detail = recordCards["cards"] as? [[String: Any]] ?? []
        precondition(detail.map { $0["type"] as? String } == ["weather", "places"] && recordCards["refreshAfter"] as? Int == 300
                     && ((detail.first?["blocks"] as? [[String: Any]])?.last?["title"] as? String)?.hasPrefix("Forecast opens") == true
                     && detail.allSatisfy { $0["refresh"] == nil },
                     "a festival a month out: when its forecast opens, and its venue map: \(detail.map { $0["type"] ?? "" })")

        // A forecast that can't resolve by the deadline: the run still succeeds, without the card.
        let savedDeadline = RunCards.deadline
        RunCards.deadline = 0.5
        defer { RunCards.deadline = savedDeadline }
        await slow.set(.seconds(4))
        await WeatherCardResolver.shared.setSources(sources)
        _ = try store.create(.init(id: bills.id, title: nil, prompt: nil,
                                   schedule: .init(kind: .once, summary: "Once", timeZone: zone, startAt: Date())),
                             now: Date().addingTimeInterval(-30))
        store.checkNow()
        let second = try requireHome(runFor(bills.id))
        try await waitForJournalTest { store.runner.session(forRun: second.id).flatMap { fixtures[$0.id]?.sink } != nil }
        let secondSession = try requireHome(store.runner.session(forRun: second.id))
        let started = Date()
        fixtures[secondSession.id]?.sink?(.textDelta("Summary: Still due.\n\n```weather\n{\"place\":\"Seattle, WA\"}\n```"))
        fixtures[secondSession.id]?.sink?(.done)
        try await waitForJournalTest { store.backgroundRuns.first { $0.id == second.id }?.status != "running" }
        let slowRun = try requireHome(store.backgroundRuns.first { $0.id == second.id })
        precondition(slowRun.status == "succeeded" && slowRun.cards == nil && slowRun.summary == "Still due."
                     && Date().timeIntervalSince(started) < 3, "a card that can't resolve never fails or holds up a run")
        await slow.set(.zero)

        // Home edits only the cards; [] removes them.
        bills = try store.create(.init(id: bills.id, title: nil, prompt: nil, schedule: nil, cards: []), now: Date())
        precondition(bills.workspace?.cards == nil && bills.workspace?.records.count == 2)
        try store.delete(id: bills.id)
        try await waitForJournalTest { store.runner.liveRunIDs.isEmpty }
        await WeatherCardResolver.shared.setSources(nil)
        await PlaceCardResolver.shared.setCustomLookup(nil)
        RecordCards.shared.reset()
    }
}
