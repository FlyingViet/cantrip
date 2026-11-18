import Foundation
import XCTest
@testable import Hermes

/// Tasks → Upcoming: reading the Mac's list, its groups, the time each row shows, and Cancel and
/// Resume. Every item here is made up.
@MainActor
final class CantripHomeUpcomingTests: XCTestCase {
    private let homeID = "00000000-0000-0000-0000-0000000000a1"
    private let stepID = "step:10000000-0000-0000-0000-000000000001"
    private let pausedTaskID = "task:20000000-0000-0000-0000-000000000002"

    /// Wednesday Nov 18, 2026, 9:56 AM in Los Angeles.
    private let now = Date(timeIntervalSince1970: 1_795_024_560)

    private var pacific: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private let english = Locale(identifier: "en_US")

    private func item(_ id: String, group: String, at nextRunAt: Double? = nil, extra: String = "") -> String {
        let time = nextRunAt.map { #","nextRunAt":\#($0)"# } ?? ""
        return #"{"id":"\#(id)","kind":"macJob","title":"Job \#(id)","schedule":"Daily at 3:00 AM","owner":"This Mac","state":"scheduled","group":"\#(group)","canResume":false\#(time)\#(extra)}"#
    }

    /// Two steps and five Mac jobs up next, a wait, a repeating job, a paused task, one item from a
    /// newer Mac and one this app can't read.
    private var listJSON: String {
        let jobs = (1...5).map { item("mac:com.example.job\($0)", group: "next", at: 1_795_086_000 + Double($0) * 3_600) }
        return #"""
        {"revision":"r1","items":[
          {"id":"\#(stepID)","kind":"step","title":"Compare tonight's build times","nextRunAt":1795070100,
           "schedule":"Once","owner":"Release notes tab","ownerTabID":"30000000-0000-0000-0000-000000000003",
           "state":"scheduled","group":"next","cancelLabel":"Cancel",
           "confirm":"Cancel “Compare tonight's build times”? The Release notes tab won't get this step at 10:35 PM.","canResume":false},
          {"id":"step:10000000-0000-0000-0000-000000000004","kind":"step","title":"Post the weekly summary","nextRunAt":1795070400.5,
           "schedule":"Once","owner":"Cantrip Home","state":"scheduled","group":"next","cancelLabel":"Cancel","canResume":false},
          \#(jobs.joined(separator: ",\n"))
          ,{"id":"wait:40000000-0000-0000-0000-000000000005","kind":"wait","title":"Waits for the laptop to wake, then installs the update",
           "detail":"Checks every 5 minutes","schedule":"Waiting, until Fri Nov 20, 9:50 AM","owner":"A tab","state":"waiting",
           "group":"waiting","cancelLabel":"Stop","confirm":"Stop “Waits for the laptop to wake”?","canResume":false},
          {"id":"mac:com.example.photo-sync","kind":"macJob","title":"Sync the photo library","schedule":"Every 15 minutes",
           "owner":"This Mac","state":"scheduled","group":"repeating","cancelLabel":"Pause","canResume":false},
          {"id":"\#(pausedTaskID)","kind":"task","title":"Morning summary","nextRunAt":null,"schedule":"Every day at 8:00 AM",
           "owner":"Cantrip Home","state":"paused","group":"paused","canResume":true},
          {"id":"later:1","kind":"reminder","title":"A kind from a newer Mac","schedule":"Someday","owner":"Cantrip Home",
           "state":"scheduled","group":"later","priority":3},
          {"kind":"step","title":"No id, so it can't be cancelled"}
        ]}
        """#
    }

    private func decodeList(_ json: String? = nil) throws -> [CantripHomeUpcomingItem] {
        let response = try JSONDecoder().decode(CantripHomeUpcomingResponse.self, from: Data((json ?? listJSON).utf8))
        return try XCTUnwrap(response.items).compactMap(\.value)
    }

    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testItemsDecodeUnixSecondsAndSkipWhatTheyCantRead() throws {
        let items = try decodeList()
        XCTAssertEqual(items.count, 11, "the item without an id is left out; the rest stay")
        let step = try XCTUnwrap(items.first)
        XCTAssertEqual(step.id, stepID)
        XCTAssertEqual(step.nextRunAt, Date(timeIntervalSince1970: 1_795_070_100), "seconds since 1970, not 2001")
        XCTAssertEqual(step.group, .next)
        XCTAssertEqual(step.cancelLabel, "Cancel")
        XCTAssertEqual(step.ownerTabID, "30000000-0000-0000-0000-000000000003")
        XCTAssertFalse(step.canResume)
        XCTAssertEqual(items[1].nextRunAt?.timeIntervalSince1970, 1_795_070_400.5)
        XCTAssertEqual(items[1].confirmQuestion, "Cancel “Post the weekly summary”?", "no question from the Mac: ask by name")
        XCTAssertEqual(step.confirmParts.title, "Cancel “Compare tonight's build times”?")
        XCTAssertEqual(step.confirmParts.message, "The Release notes tab won't get this step at 10:35 PM.")
        XCTAssertNil(items[1].confirmParts.message)
        let asking = CantripHomeUpcomingItem(id: "wait:1", kind: "wait", title: "Ready?", schedule: "", owner: "",
                                             cancelLabel: "Stop", confirm: "Stop “Ready?”? It stops waiting.")
        XCTAssertEqual(asking.confirmParts.title, "Stop “Ready?”?", "a question inside the title stays in it")
        XCTAssertEqual(asking.confirmParts.message, "It stops waiting.")

        let wait = try XCTUnwrap(items.first { $0.kind == "wait" })
        XCTAssertNil(wait.nextRunAt)
        XCTAssertEqual(wait.detail, "Checks every 5 minutes")
        XCTAssertEqual(wait.group, .waiting)
        let paused = try XCTUnwrap(items.first { $0.id == pausedTaskID })
        XCTAssertNil(paused.nextRunAt)
        XCTAssertNil(paused.cancelLabel)
        XCTAssertTrue(paused.canResume)
        let newer = try XCTUnwrap(items.last)
        XCTAssertEqual(newer.kind, "reminder")
        XCTAssertEqual(newer.group, .repeating, "an unknown group falls back to the Mac's rule: no time, not paused")
        XCTAssertFalse(newer.canResume)
    }

    func testGroupsKeepTheMacsOrderAndShowSixUpNextUntilShowAll() throws {
        let items = try decodeList()
        let folded = CantripHomeUpcoming.groups(items, showsAllNext: false)
        XCTAssertEqual(folded.map(\.group), [.next, .waiting, .repeating, .paused])
        let next = try XCTUnwrap(folded.first)
        XCTAssertEqual(next.items.map(\.id), Array(items.prefix(6)).map(\.id), "the soonest six, as sent")
        XCTAssertEqual(next.total, 7)
        XCTAssertTrue(next.canShowAll)
        XCTAssertEqual(folded[2].items.map(\.id), ["mac:com.example.photo-sync", "later:1"])
        XCTAssertFalse(folded[2].canShowAll, "only Next up folds")

        let all = CantripHomeUpcoming.groups(items, showsAllNext: true)
        XCTAssertEqual(all.first?.items.count, 7)
        XCTAssertTrue(all.first?.canShowAll == true, "still offers Show fewer")

        let six = CantripHomeUpcoming.groups(Array(items.prefix(6)), showsAllNext: false)
        XCTAssertEqual(six.map(\.group), [.next], "empty groups are left out")
        XCTAssertFalse(six[0].canShowAll)
        XCTAssertTrue(CantripHomeUpcoming.groups([], showsAllNext: false).isEmpty)
    }

    func testTimesReadRelativeToToday() throws {
        let calendar = pacific
        func label(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> String {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
            return plain(CantripHomeUpcoming.timeLabel(date, now: now, calendar: calendar, locale: english))
        }
        XCTAssertEqual(try label(2026, 11, 18, 22, 35), "Today 10:35 PM")
        XCTAssertEqual(try label(2026, 11, 18, 0, 5), "Today 12:05 AM")
        XCTAssertEqual(try label(2026, 11, 19, 3, 0), "Tomorrow 3:00 AM")
        XCTAssertEqual(try label(2026, 11, 17, 23, 59), "Yesterday 11:59 PM")
        XCTAssertEqual(try label(2026, 11, 20, 9, 50), "Fri 9:50 AM")
        XCTAssertEqual(try label(2026, 11, 24, 9, 50), "Tue 9:50 AM", "six days ahead is still this week")
        XCTAssertEqual(try label(2026, 11, 25, 9, 50), "Nov 25, 9:50 AM", "a week ahead gets its date")
        XCTAssertEqual(try label(2027, 1, 5, 7, 0), "Jan 5, 2027, 7:00 AM", "another year says which")

        // The device's time zone decides the day: at 6 AM in Los Angeles, 10:35 PM there is tomorrow in Tokyo.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let early = Date(timeIntervalSince1970: 1_795_010_400)
        let tonight = Date(timeIntervalSince1970: 1_795_070_100)
        XCTAssertEqual(plain(CantripHomeUpcoming.timeLabel(tonight, now: early, calendar: calendar, locale: english)),
                       "Today 10:35 PM")
        XCTAssertEqual(plain(CantripHomeUpcoming.timeLabel(tonight, now: early, calendar: tokyo, locale: english)),
                       "Tomorrow 3:35 PM")
    }

    func testRowsSayWhenWhatScheduleAndWhoSetItUp() throws {
        let items = try decodeList()
        func line(_ item: CantripHomeUpcomingItem) -> String {
            plain(CantripHomeUpcoming.secondaryLine(item, now: now, calendar: pacific, locale: english))
        }
        func spoken(_ item: CantripHomeUpcomingItem) -> String {
            plain(CantripHomeUpcoming.spokenLabel(item, now: now, calendar: pacific, locale: english))
        }
        XCTAssertEqual(line(items[0]), "Today 10:35 PM · Release notes tab", "\"Once\" adds nothing beside a time")
        XCTAssertEqual(line(items[2]), "Tomorrow 4:00 AM · Daily at 3:00 AM · This Mac")
        let wait = try XCTUnwrap(items.first { $0.kind == "wait" })
        XCTAssertEqual(line(wait), "Waiting, until Fri Nov 20, 9:50 AM · A tab", "no time: the schedule says when, once")
        XCTAssertEqual(spoken(items[0]), "Compare tonight's build times, Today 10:35 PM, set up by Release notes tab")
        XCTAssertEqual(spoken(wait), "Waits for the laptop to wake, then installs the update, Waiting, until Fri Nov 20, 9:50 AM, "
                       + "set up by A tab, Checks every 5 minutes")
        let paused = try XCTUnwrap(items.first { $0.id == pausedTaskID })
        XCTAssertEqual(spoken(paused), "Morning summary, Paused, Every day at 8:00 AM, set up by Cantrip Home")
        XCTAssertEqual(CantripHomeListSection.upcoming.headerText(count: 12, collapsed: false), "Upcoming · 12")
        XCTAssertEqual(CantripHomeListSection.upcoming.spokenLabel(count: 1), "Upcoming, 1 item")
        XCTAssertEqual(CantripHomeListSection.upcoming.defaultsKey, "home.tasks.upcomingCollapsed")
    }

    // MARK: The model

    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var homeSession: Data {
        Data(#"""
        {"session":{"id":"\#(homeID)","title":"Cantrip Home","workdir":"/tmp","isStreaming":false,"canResume":false,
         "councilMode":false,"queuedCount":0,"messages":[],"isLocked":true,"isCantripHome":true}}
        """#.utf8)
    }

    func testCancelAndResumePostTheItemAndShowTheMacsNewList() async throws {
        let model = try StartFreshFixture.model(for: self)
        let after = try decodeList().filter { $0.id != stepID }
        var reads: [String?] = []
        var posts: [(path: String, body: [String: Any])] = []
        var refuse = false
        var gone = false
        StartFreshRequestProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let revision = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "revision" }?.value
            switch (request.httpMethod ?? "GET", url.path) {
            case ("GET", "/api/v1/home"):
                return (200, self.homeSession)
            case ("GET", "/api/v1/home/tasks"):
                return (200, Data(#"{"tasks":[],"revision":"t1"}"#.utf8))
            case ("GET", "/api/v1/home/artifacts"):
                return (200, Data(#"{"artifacts":[],"revision":"a1"}"#.utf8))
            case ("GET", "/api/v1/home/upcoming"):
                reads.append(revision)
                if gone { return (404, Data(#"{"error":"not found"}"#.utf8)) }
                if revision == "r1" { return (200, Data(#"{"unchanged":true,"revision":"r1"}"#.utf8)) }
                return (200, Data(self.listJSON.utf8))
            case ("POST", "/api/v1/home/upcoming/cancel"), ("POST", "/api/v1/home/upcoming/resume"):
                posts.append((url.path, try self.body(request)))
                if refuse { return (404, Data(#"{"error":"That item isn't in Upcoming any more."}"#.utf8)) }
                let message = url.path.hasSuffix("cancel") ? "Cancelled “Compare tonight's build times”." : "Resumed the Home task “Morning summary”."
                let items = try JSONSerialization.jsonObject(with: Data(self.listJSON.utf8)) as? [String: Any]
                let kept = (items?["items"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != self.stepID }
                return (200, try JSONSerialization.data(withJSONObject: ["items": kept, "revision": "r2", "message": message]))
            default:
                return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        await model.selectHome()
        XCTAssertTrue(model.isHomeSelected, model.detailError ?? "Home not selected")
        XCTAssertTrue(reads.isEmpty, "Upcoming is read only while a Tasks screen shows")
        XCTAssertFalse(model.homeUpcomingSupported)

        await model.refreshHomeUpcoming()
        XCTAssertTrue(model.homeUpcomingSupported)
        XCTAssertEqual(model.homeUpcoming.count, 11)
        await model.refreshHomeUpcoming()
        XCTAssertEqual(reads, [nil, "r1"], "the next read sends the revision it has")
        XCTAssertEqual(model.homeUpcoming.count, 11)

        let cancelled = await model.cancelHomeUpcoming(id: stepID)
        XCTAssertEqual(cancelled, "Cancelled “Compare tonight's build times”.")
        XCTAssertEqual(posts.last?.path, "/api/v1/home/upcoming/cancel")
        XCTAssertEqual(posts.last?.body as? [String: String], ["id": stepID])
        XCTAssertEqual(model.homeUpcoming.map(\.id), after.map(\.id), "the Mac's answer is the new list")
        XCTAssertNil(model.homeUpcomingChangingID)

        let resumed = await model.resumeHomeUpcoming(id: pausedTaskID)
        XCTAssertEqual(resumed, "Resumed the Home task “Morning summary”.")
        XCTAssertEqual(posts.last?.path, "/api/v1/home/upcoming/resume")
        XCTAssertEqual(posts.last?.body as? [String: String], ["id": pausedTaskID])
        XCTAssertEqual(posts.count, 2, "each change is sent once")

        refuse = true
        let failed = await model.cancelHomeUpcoming(id: stepID)
        XCTAssertNil(failed)
        XCTAssertEqual(model.homeUpcomingError, "That item isn't in Upcoming any more.", "the Mac's reason, as written")
        XCTAssertEqual(model.homeUpcoming.map(\.id), after.map(\.id), "a refused change keeps the list")

        // While a Tasks screen shows, the poll reads Upcoming with the rest of Home.
        let before = reads.count
        model.setHomeUpcomingShown(true)
        for _ in 0..<100 where model.homeUpcomingError != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.homeUpcomingError, "showing reads at once, and a good read clears the last problem")
        XCTAssertEqual(reads.count, before + 1)
        await model.refreshHomeData()
        XCTAssertEqual(reads.count, before + 2, "the poll reads it too")
        model.setHomeUpcomingShown(false)
        await model.refreshHomeData()
        XCTAssertEqual(reads.count, before + 2, "not read once the screen has gone")

        gone = true
        await model.refreshHomeUpcoming()
        XCTAssertFalse(model.homeUpcomingSupported, "an older Mac has no Upcoming: the section hides")
        XCTAssertTrue(model.homeUpcoming.isEmpty)
    }
}
