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

    private static func requireSchedule<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing schedule value at line \(line)") }
        return value
    }
}
