import XCTest
@testable import Hermes

/// Task schedules from the Mac: shared by Cantrip Agent and Cantrip Gateway Mac.
final class CantripHomeScheduleDecodingTests: XCTestCase {
    /// Macs send monthly schedules as `weekdays` plus `monthDay`; a kind this app doesn't know
    /// still decodes, and every task shows the Mac's summary.
    func testMonthlyAndUnknownScheduleKindsDecode() throws {
        func task(_ schedule: String) throws -> CantripHomeTask {
            try JSONDecoder().decode(CantripHomeTask.self, from: Data("""
            {"id":"10000000-0000-0000-0000-000000000003","title":"Monthly expenses",
            "prompt":"Sync the month's expenses.","schedule":{\(schedule)},
            "enabled":true,"createdAt":0,"updatedAt":0,"nextRunAt":null,
            "lastRunAt":null,"state":"scheduled","activeRunID":null,"runs":[]}
            """.utf8))
        }
        let monthEnd = try task(#"""
            "kind":"weekdays","summary":"Last day of every month at 9:30 PM",
            "timeZone":"America/Los_Angeles","hour":21,"minute":30,
            "times":[{"hour":21,"minute":30}],"monthDay":"last"
            """#)
        XCTAssertEqual(monthEnd.schedule.kind, .monthly)
        XCTAssertEqual(monthEnd.schedule.monthDay, .last)
        XCTAssertEqual(monthEnd.schedule.summary, "Last day of every month at 9:30 PM")
        let fifteenth = try task(#"""
            "kind":"monthly","summary":"15th of every month at 8:00 AM",
            "timeZone":"America/Los_Angeles","monthDay":15
            """#)
        XCTAssertEqual(fifteenth.schedule.kind, .monthly)
        XCTAssertEqual(fifteenth.schedule.monthDay, .day(15))
        let future = try task(#"""
            "kind":"quarterly","summary":"First day of every quarter at 9:00 AM",
            "timeZone":"America/Los_Angeles"
            """#)
        XCTAssertEqual(future.schedule.kind, .other)
        XCTAssertEqual(future.schedule.summary, "First day of every quarter at 9:00 AM")
        XCTAssertNil(future.schedule.monthDay)
        let weekly = try task(#"""
            "kind":"weekdays","summary":"Weekdays at 8:00 AM","timeZone":"America/Los_Angeles",
            "startAt":null,"intervalMinutes":null,"weekdays":[2,3,4,5,6],"hour":8,"minute":0
            """#)
        XCTAssertEqual(weekly.schedule.kind, .weekdays)
        XCTAssertEqual(weekly.schedule.weekdays, [2, 3, 4, 5, 6])
        XCTAssertNil(weekly.schedule.monthDay)
    }
}
