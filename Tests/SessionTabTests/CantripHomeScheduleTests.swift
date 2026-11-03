import Foundation

extension SessionTabTests {
    static func testCantripHomeSchedules() throws {
        let zoneID = "America/Los_Angeles"
        let zone = TimeZone(identifier: zoneID)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute, second: 0
            ))!
        }
        func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        func time(_ hour: Int, _ minute: Int) -> CantripHomeScheduleTime {
            .init(hour: hour, minute: minute)
        }

        let twice = try CantripHomeSchedule(
            kind: .weekdays, summary: "model label", timeZone: zoneID,
            weekdays: [7, 1, 2, 3, 4, 5, 6], times: [time(22, 0), time(8, 30), time(22, 0)]
        ).validated(now: local(2026, 10, 1, 12, 0))
        precondition(twice.times == [time(8, 30), time(22, 0)]
                     && twice.hour == 8 && twice.minute == 30
                     && twice.weekdays == [1, 2, 3, 4, 5, 6, 7],
                     "Run times are deduplicated and sorted; hour/minute mirror the earliest")
        precondition(twice.summary == "Every day at 8:30 AM and 10:00 PM",
                     "Weekday summaries are written by Cantrip: \(twice.summary)")

        // Thursday, October 1 2026.
        precondition(twice.next(after: local(2026, 10, 1, 7, 0)) == local(2026, 10, 1, 8, 30))
        precondition(twice.next(after: local(2026, 10, 1, 8, 30)) == local(2026, 10, 1, 22, 0),
                     "The slot that just ran is never chosen again")
        precondition(twice.next(after: local(2026, 10, 1, 22, 0)) == local(2026, 10, 2, 8, 30))
        precondition(twice.next(after: local(2026, 10, 1, 23, 59)) == local(2026, 10, 2, 8, 30),
                     "After the last slot the next run is tomorrow's first")

        let overnight = try CantripHomeSchedule(
            kind: .weekdays, summary: "", timeZone: zoneID,
            weekdays: [2, 3, 4, 5, 6], times: [time(23, 30), time(0, 15)]
        ).validated()
        precondition(overnight.next(after: local(2026, 10, 1, 23, 40)) == local(2026, 10, 2, 0, 15),
                     "A slot after midnight belongs to the next calendar day")
        precondition(overnight.next(after: local(2026, 10, 2, 23, 40)) == local(2026, 10, 5, 0, 15),
                     "Each slot runs only on listed weekdays (Saturday and Sunday skipped)")

        // Fall back on Sunday, November 1 2026: 1:00-2:00 AM happens twice.
        let fallBack = try CantripHomeSchedule(
            kind: .weekdays, summary: "", timeZone: zoneID,
            weekdays: [1, 2, 3, 4, 5, 6, 7], times: [time(1, 30), time(22, 0)]
        ).validated()
        let firstFallRun = try requireSchedule(fallBack.next(after: local(2026, 11, 1, 0, 0)))
        precondition(firstFallRun == iso("2026-11-01T01:30:00-07:00"))
        precondition(fallBack.next(after: firstFallRun.addingTimeInterval(60))
                     == iso("2026-11-01T22:00:00-08:00"),
                     "A repeated hour runs once, and later slots keep their wall-clock time")
        // Spring forward on Sunday, March 14 2027: 2:00-3:00 AM does not exist.
        let springForward = try CantripHomeSchedule(
            kind: .weekdays, summary: "", timeZone: zoneID,
            weekdays: [1, 2, 3, 4, 5, 6, 7], times: [time(2, 30), time(8, 30)]
        ).validated()
        let skipped = try requireSchedule(springForward.next(after: local(2027, 3, 14, 1, 0)))
        precondition(skipped == iso("2027-03-14T03:30:00-07:00"),
                     "A skipped slot runs when clocks resume instead of being lost")
        precondition(springForward.next(after: skipped) == iso("2027-03-14T08:30:00-07:00"))
        precondition(springForward.next(after: local(2027, 3, 13, 8, 30))
                     == iso("2027-03-14T03:30:00-07:00")
                     && iso("2027-03-14T08:30:00-07:00")
                        .timeIntervalSince(local(2027, 3, 13, 8, 30)) == 23 * 3_600,
                     "DST-day slots stay at their local time")

        let legacyJSON = #"""
        {"kind":"weekdays","summary":"Every day at 8:30 AM","timeZone":"America/Los_Angeles",
         "weekdays":[1,2,3,4,5,6,7],"hour":8,"minute":30}
        """#
        let legacy = try JSONDecoder().decode(CantripHomeSchedule.self, from: Data(legacyJSON.utf8))
        precondition(legacy.times == nil && legacy.runTimes == [time(8, 30)]
                     && legacy.summary == "Every day at 8:30 AM"
                     && legacy.next(after: local(2026, 10, 1, 9, 0)) == local(2026, 10, 2, 8, 30),
                     "Schedules saved before multiple times keep running at their single time")
        let legacyTaskJSON = #"""
        [{"id":"D68FB234-FC0E-4E10-B27F-86B4C7DFF440","title":"Daily interview tracker",
          "prompt":"Refresh interviews.","schedule":\#(legacyJSON),"hasSchedule":true,
          "enabled":true,"createdAt":812470741.788342,"updatedAt":812598765.695533,
          "nextRunAt":812647800,"lastRunAt":812561404.892839,"state":"succeeded","runs":[]}]
        """#
        let legacyTask = try requireSchedule(try JSONDecoder().decode(
            [CantripHomeTask].self, from: Data(legacyTaskJSON.utf8)
        ).first)
        precondition(legacyTask.schedule.runTimes == [time(8, 30)]
                     && legacyTask.nextRunAt == Date(timeIntervalSinceReferenceDate: 812_647_800),
                     "tasks.json written by older builds still loads")

        let encoded = try JSONEncoder().encode(twice)
        let object = try requireSchedule(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedTimes = object["times"] as? [[String: Int]]
        precondition(object["hour"] as? Int == 8 && object["minute"] as? Int == 30
                     && encodedTimes == [["hour": 8, "minute": 30], ["hour": 22, "minute": 0]],
                     "Older clients still read hour/minute; newer ones read every time")
        let roundTrip = try JSONDecoder().decode(CantripHomeSchedule.self, from: encoded)
        precondition(roundTrip == twice)

        let modelJSON = #"""
        {"kind":"weekdays","summary":"weekday mornings and evenings","timeZone":"America/Los_Angeles",
         "startAt":null,"intervalMinutes":null,"weekdays":[2,3,4,5,6],"times":["19:30","07:00"]}
        """#
        let fromModel = try JSONDecoder()
            .decode(CantripHomeSchedule.self, from: Data(modelJSON.utf8)).validated()
        precondition(fromModel.runTimes == [time(7, 0), time(19, 30)]
                     && fromModel.summary == "Weekdays at 7:00 AM and 7:30 PM",
                     "Home's model may write run times as HH:mm strings")
        let onceJSON = #"""
        {"kind":"once","summary":"Tomorrow at 9 AM","timeZone":"America/Los_Angeles",
         "startAt":"2026-10-02T09:00:00-07:00","intervalMinutes":null,"weekdays":null,"times":null}
        """#
        let once = try JSONDecoder().decode(CantripHomeSchedule.self, from: Data(onceJSON.utf8))
        precondition(once.startAt == local(2026, 10, 2, 9, 0) && once.summary == "Tomorrow at 9 AM",
                     "The ISO-8601 start time the protocol asks for decodes")

        func summary(_ days: [Int], _ times: [CantripHomeScheduleTime],
                     zone: String = zoneID) -> String {
            CantripHomeSchedule.summary(weekdays: days, times: times, timeZone: zone, localZone: TimeZone(identifier: zoneID)!)
        }
        precondition(summary([1, 7], [time(10, 0)]) == "Weekends at 10:00 AM")
        precondition(summary([6, 2, 4], [time(7, 0)]) == "Every Monday, Wednesday and Friday at 7:00 AM")
        precondition(summary([3], [time(12, 0), time(0, 0)]) == "Every Tuesday at 12:00 AM and 12:00 PM")
        precondition(summary([1, 2, 3, 4, 5, 6], [time(18, 5)]) == "Every day except Saturday at 6:05 PM")
        precondition(summary(Array(1...7), (0..<6).map { time(6 + $0 * 3, 0) })
                     == "Every day, 6 times from 6:00 AM to 9:00 PM")
        precondition(summary(Array(1...7), [time(9, 0)], zone: "America/New_York")
                     == "Every day at 9:00 AM Eastern Time",
                     "A task in another zone says so: \(summary(Array(1...7), [time(9, 0)], zone: "America/New_York"))")

        for invalid in [
            CantripHomeSchedule(kind: .weekdays, summary: "", timeZone: zoneID, weekdays: [2]),
            CantripHomeSchedule(kind: .weekdays, summary: "", timeZone: zoneID, weekdays: [2],
                                times: [time(24, 0)]),
            CantripHomeSchedule(kind: .weekdays, summary: "", timeZone: zoneID, weekdays: [2],
                                times: (0..<25).map { time($0 % 24, $0 / 24) }),
        ] {
            do {
                _ = try invalid.validated()
                preconditionFailure("Invalid run times must be rejected: \(invalid.runTimes)")
            } catch is CantripHomeError {}
        }
        do {
            _ = try JSONDecoder().decode(
                CantripHomeScheduleTime.self, from: Data(#""8:30 PM""#.utf8)
            )
            preconditionFailure("Run times must be 24-hour HH:mm")
        } catch {}
        print("Cantrip Home schedules: multiple daily times, midnight, DST, legacy and model formats passed")
    }

    /// Monthly schedules: a chosen day (29–31 fall back to a shorter month's last day) or the
    /// last day, at one or more local times; month lengths, leap years, DST, catch-up, summaries
    /// and the JSON clients from before monthly schedules still decode.
    static func testCantripHomeMonthlySchedules() throws {
        let zoneID = "America/Los_Angeles"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneID)!
        func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute, second: 0
            ))!
        }
        func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        func time(_ hour: Int, _ minute: Int) -> CantripHomeScheduleTime {
            .init(hour: hour, minute: minute)
        }
        func monthly(_ day: CantripHomeMonthDay, _ times: [CantripHomeScheduleTime],
                     zone: String = zoneID) throws -> CantripHomeSchedule {
            try CantripHomeSchedule(
                kind: .monthly, summary: "model label", timeZone: zone, times: times, monthDay: day
            ).validated(now: local(2026, 10, 1, 12, 0))
        }
        /// Every run from `start` on, the way the store chains them.
        func runs(_ schedule: CantripHomeSchedule, from start: Date, count: Int) -> [Date] {
            var dates: [Date] = []
            var cursor = start
            while dates.count < count, let next = schedule.next(after: cursor) {
                dates.append(next)
                cursor = next
            }
            return dates
        }

        // Last day of the month at 9:30 PM across month lengths, a year end, February in a
        // common and a leap year, and both DST changes.
        let monthEnd = try monthly(.last, [time(21, 30)])
        precondition(monthEnd.summary.hasPrefix("Last day of every month at 9:30 PM")
                     && monthEnd.times == [time(21, 30)] && monthEnd.hour == 21
                     && monthEnd.minute == 30 && monthEnd.weekdays == nil,
                     "Cantrip writes the monthly summary: \(monthEnd.summary)")
        let monthEnds = runs(monthEnd, from: local(2026, 10, 15, 12, 0), count: 18)
        let expectedMonthEnds = [
            "2026-10-31T21:30:00-07:00", "2026-11-30T21:30:00-08:00", "2026-12-31T21:30:00-08:00",
            "2027-01-31T21:30:00-08:00", "2027-02-28T21:30:00-08:00", "2027-03-31T21:30:00-07:00",
            "2027-04-30T21:30:00-07:00", "2027-05-31T21:30:00-07:00", "2027-06-30T21:30:00-07:00",
            "2027-07-31T21:30:00-07:00", "2027-08-31T21:30:00-07:00", "2027-09-30T21:30:00-07:00",
            "2027-10-31T21:30:00-07:00", "2027-11-30T21:30:00-08:00", "2027-12-31T21:30:00-08:00",
            "2028-01-31T21:30:00-08:00", "2028-02-29T21:30:00-08:00", "2028-03-31T21:30:00-07:00",
        ].map(iso)
        precondition(monthEnds == expectedMonthEnds,
                     "Last-day runs land on every month's last day at 9:30 PM local: \(monthEnds)")
        precondition(monthEnd.next(after: local(2026, 10, 31, 9, 0)) == local(2026, 10, 31, 21, 30),
                     "Earlier on the last day, the run is still that evening")
        precondition(monthEnd.next(after: local(2026, 10, 31, 21, 30)) == local(2026, 11, 30, 21, 30),
                     "The slot that just ran is never chosen again")
        precondition(monthEnd.next(after: local(2027, 2, 28, 21, 31)) == local(2027, 3, 31, 21, 30)
                     && monthEnd.next(after: local(2028, 2, 28, 21, 31)) == local(2028, 2, 29, 21, 30),
                     "February ends on the 28th, or the 29th in a leap year")
        // The Mac slept from October 20 to December 2: the missed October 31 and November 30
        // slots aren't queued; the store runs the overdue task once and then waits for this one.
        precondition(monthEnd.next(after: local(2026, 12, 2, 10, 0)) == local(2026, 12, 31, 21, 30),
                     "After missed months the next run is the next future month end")

        // Days 29-31 run on a shorter month's last day instead of skipping it.
        let thirtyFirst = try monthly(.day(31), [time(9, 0)])
        precondition(runs(thirtyFirst, from: local(2026, 9, 1, 0, 0), count: 7).map {
            calendar.dateComponents([.month, .day], from: $0)
        }.map { "\($0.month!)/\($0.day!)" } == ["9/30", "10/31", "11/30", "12/31", "1/31", "2/28", "3/31"],
                     "Day 31 falls back to the 30th and February's last day")
        for (day, common, leap) in [(29, 28, 29), (30, 28, 29), (31, 28, 29)] {
            let schedule = try monthly(.day(day), [time(9, 0)])
            precondition(schedule.next(after: local(2027, 2, 1, 0, 0)) == local(2027, 2, common, 9, 0)
                         && schedule.next(after: local(2028, 2, 1, 0, 0)) == local(2028, 2, leap, 9, 0)
                         && schedule.next(after: local(2028, 3, 1, 0, 0)) == local(2028, 3, day, 9, 0),
                         "Day \(day) in February is the 28th, or the 29th in a leap year")
        }
        let first = try monthly(.day(1), [time(9, 0)])
        precondition(runs(first, from: local(2026, 12, 15, 0, 0), count: 3)
                     == [local(2027, 1, 1, 9, 0), local(2027, 2, 1, 9, 0), local(2027, 3, 1, 9, 0)])

        // Several times on the 15th: each one runs, then next month's first.
        let fifteenth = try monthly(.day(15), [time(20, 0), time(8, 0), time(20, 0)])
        precondition(fifteenth.times == [time(8, 0), time(20, 0)]
                     && fifteenth.summary.hasPrefix("15th of every month at 8:00 AM and 8:00 PM"),
                     "Monthly run times are deduplicated and sorted")
        precondition(runs(fifteenth, from: local(2026, 10, 15, 8, 0), count: 3)
                     == [local(2026, 10, 15, 20, 0), local(2026, 11, 15, 8, 0), local(2026, 11, 15, 20, 0)])

        // Fall back on Sunday, November 1 2026: 1:00-2:00 AM happens twice.
        let fallBack = try monthly(.day(1), [time(1, 30)])
        let fallRun = try requireSchedule(fallBack.next(after: local(2026, 10, 2, 0, 0)))
        precondition(fallRun == iso("2026-11-01T01:30:00-07:00")
                     && fallBack.next(after: fallRun) == iso("2026-12-01T01:30:00-08:00"),
                     "A repeated hour runs once, at its first occurrence")
        // Spring forward on Sunday, March 14 2027: 2:00-3:00 AM does not exist.
        let springForward = try monthly(.day(14), [time(2, 30)])
        let springRun = try requireSchedule(springForward.next(after: local(2027, 2, 14, 3, 0)))
        precondition(springRun == iso("2027-03-14T03:30:00-07:00")
                     && springForward.next(after: springRun) == iso("2027-04-14T02:30:00-07:00"),
                     "A skipped slot runs when clocks resume, and the next month keeps its time")

        // Summaries.
        func summary(_ day: CantripHomeMonthDay, _ times: [CantripHomeScheduleTime],
                     zone: String = zoneID) -> String {
            CantripHomeSchedule.summary(
                monthDay: day, times: times, timeZone: zone, localZone: TimeZone(identifier: zoneID)!
            )
        }
        precondition(summary(.last, [time(21, 30)]) == "Last day of every month at 9:30 PM")
        precondition(summary(.day(1), [time(9, 0)]) == "1st of every month at 9:00 AM")
        precondition(summary(.day(22), [time(0, 0), time(12, 0)])
                     == "22nd of every month at 12:00 AM and 12:00 PM")
        precondition(summary(.day(30), [time(8, 0)]) == "30th (or last day) of every month at 8:00 AM",
                     "Days a month may not have say where they run instead")
        precondition(summary(.last, (0..<6).map { time(6 + $0 * 3, 0) })
                     == "Last day of every month, 6 times from 6:00 AM to 9:00 PM")
        precondition(summary(.last, [time(21, 30)], zone: "America/New_York")
                     == "Last day of every month at 9:30 PM Eastern Time")
        precondition([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31].map(CantripHomeSchedule.ordinal)
                     == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st"])
        precondition(monthEnd.protocolDetail == " (times 21:30; monthDay last; America/Los_Angeles)"
                     && fifteenth.protocolDetail == " (times 08:00,20:00; monthDay 15; America/Los_Angeles)",
                     "Home's task list gives the exact day and times to send back")

        // What Home's model writes.
        func decode(_ json: String) throws -> CantripHomeSchedule {
            try JSONDecoder().decode(CantripHomeSchedule.self, from: Data(json.utf8))
        }
        let fromModel = try decode(#"""
            {"kind":"monthly","summary":"month end","timeZone":"America/Los_Angeles","startAt":null,
             "intervalMinutes":null,"weekdays":null,"monthDay":"last","times":["21:30"]}
            """#).validated()
        precondition(fromModel.kind == .monthly && fromModel.monthDay == .last
                     && fromModel.runTimes == [time(21, 30)]
                     && fromModel.summary.hasPrefix("Last day of every month at 9:30 PM"),
                     "Home's model writes monthDay \"last\" and HH:mm times")
        let minusOne = try decode(#"{"kind":"monthly","summary":"","timeZone":"UTC","monthDay":-1,"times":["09:00"]}"#)
        let quoted = try decode(#"{"kind":"monthly","summary":"","timeZone":"UTC","monthDay":"15","times":["09:00"]}"#)
        let number = try decode(#"{"kind":"monthly","summary":"","timeZone":"UTC","monthDay":15,"times":["09:00"]}"#)
        precondition(minusOne.monthDay == .last && quoted.monthDay == .day(15) && number.monthDay == .day(15),
                     "monthDay also decodes -1 as the last day and a quoted day number")
        let notMonthly = try decode(#"{"kind":"interval","summary":"Hourly","timeZone":"UTC","intervalMinutes":60,"monthDay":5}"#)
        precondition(notMonthly.kind == .interval && notMonthly.monthDay == nil,
                     "monthDay only makes weekdays and monthly schedules monthly")
        for invalid in [
            CantripHomeSchedule(kind: .monthly, summary: "", timeZone: zoneID, times: [time(9, 0)]),
            CantripHomeSchedule(kind: .monthly, summary: "", timeZone: zoneID, times: [time(9, 0)],
                                monthDay: .day(0)),
            CantripHomeSchedule(kind: .monthly, summary: "", timeZone: zoneID, times: [time(9, 0)],
                                monthDay: .day(32)),
            CantripHomeSchedule(kind: .monthly, summary: "", timeZone: zoneID, monthDay: .last),
            CantripHomeSchedule(kind: .monthly, summary: "", timeZone: zoneID, times: [time(24, 0)],
                                monthDay: .last),
            CantripHomeSchedule(kind: .monthly, summary: "", timeZone: "Mars/Olympus", times: [time(9, 0)],
                                monthDay: .last),
        ] {
            do {
                _ = try invalid.validated()
                preconditionFailure("Invalid monthly schedules must be rejected: \(invalid)")
            } catch is CantripHomeError {}
        }
        do {
            _ = try decode(#"{"kind":"monthly","summary":"","timeZone":"UTC","monthDay":"first","times":["09:00"]}"#)
            preconditionFailure("monthDay is a day number or \"last\"")
        } catch {}

        // Stored and sent as weekdays + monthDay, so older Cantrip Agent and Gateway builds
        // (which reject unknown kinds) still list the task and show its summary.
        let encoded = try JSONEncoder().encode(monthEnd)
        let object = try requireSchedule(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        precondition(object["kind"] as? String == "weekdays" && object["monthDay"] as? String == "last"
                     && object["weekdays"] == nil && object["hour"] as? Int == 21
                     && (object["times"] as? [[String: Int]]) == [["hour": 21, "minute": 30]],
                     "Monthly schedules use a kind every client already decodes: \(object)")
        let reloaded = try JSONDecoder().decode(CantripHomeSchedule.self, from: encoded)
        precondition(reloaded == monthEnd && reloaded.kind == .monthly,
                     "A saved monthly schedule loads back as monthly")
        let dayEncoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fifteenth)) as? [String: Any]
        precondition(dayEncoded?["monthDay"] as? Int == 15)
        struct OlderClientSchedule: Decodable {
            enum Kind: String, Decodable { case once, interval, weekdays }
            let kind: Kind
            let summary: String
            let timeZone: String
            let weekdays: [Int]?
            let hour: Int?
            let minute: Int?
        }
        let older = try JSONDecoder().decode(OlderClientSchedule.self, from: encoded)
        precondition(older.kind == .weekdays && older.summary == monthEnd.summary && older.weekdays == nil,
                     "A client from before monthly schedules decodes it and shows its summary")
        var weekly = try CantripHomeSchedule(
            kind: .weekdays, summary: "", timeZone: zoneID, weekdays: [2], times: [time(9, 0)]
        ).validated()
        weekly.monthDay = .day(3)
        let weeklyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(weekly)) as? [String: Any]
        let revalidated = try weekly.validated()
        precondition(weeklyObject?["monthDay"] == nil && weeklyObject?["kind"] as? String == "weekdays"
                     && revalidated.monthDay == nil && revalidated.kind == .weekdays,
                     "Only monthly schedules carry monthDay")
        print("Cantrip Home monthly schedules: month lengths, leap years, DST, catch-up, summaries and JSON passed")
    }

    private static func requireSchedule<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing schedule value at line \(line)") }
        return value
    }
}
