import AppKit
import SwiftUI
import XCTest
@testable import Hermes

/// Tasks → Upcoming as Gateway Mac and the Mac's Home window draw it, against made-up items.
@MainActor
final class UpcomingMacRenderTests: XCTestCase {
    private let homeID = "00000000-0000-0000-0000-0000000000a2"

    private var homeSession: Data {
        Data(#"""
        {"session":{"id":"\#(homeID)","title":"Cantrip Home","workdir":"/tmp","isStreaming":false,"canResume":false,
         "councilMode":false,"queuedCount":0,"messages":[],"isLocked":true,"isCantripHome":true}}
        """#.utf8)
    }

    private var tasks: Data {
        let next = Date().addingTimeInterval(3_600).timeIntervalSinceReferenceDate
        return Data(#"""
        {"tasks":[{"id":"10000000-0000-0000-0000-000000000001","title":"Morning summary","prompt":"Summarize the night's builds.",
         "schedule":{"kind":"weekdays","summary":"Weekdays at 8:00 AM","timeZone":"America/Los_Angeles","startAt":null,
         "intervalMinutes":null,"weekdays":[2,3,4,5,6],"hour":8,"minute":0},"enabled":true,"createdAt":0,"updatedAt":0,
         "nextRunAt":\#(next),"lastRunAt":null,"state":"scheduled","activeRunID":null,"runs":[]}],"revision":"t1"}
        """#.utf8)
    }

    /// Eight steps and jobs up next (two past Show all), a wait, a repeating job and a paused task.
    private var upcoming: Data {
        let now = Date().timeIntervalSince1970
        let jobs = (1...6).map { index in
            #"{"id":"mac:com.example.job\#(index)","kind":"macJob","title":"Back up project folder \#(index)","nextRunAt":\#(now + Double(index) * 5_400),"schedule":"Daily at \#(index):00 AM","owner":"This Mac","state":"scheduled","group":"next","cancelLabel":"Pause","confirm":"Pause “Back up project folder \#(index)”? The Mac stops running it until you resume it.","canResume":false}"#
        }
        return Data(#"""
        {"revision":"u1","items":[
          {"id":"step:10000000-0000-0000-0000-000000000003","kind":"step","title":"Compare tonight's build times with last night's",
           "detail":"Once Home's background runs have finished","nextRunAt":\#(now + 1_800),"schedule":"Once","owner":"Release notes tab",
           "state":"scheduled","group":"next","cancelLabel":"Cancel","confirm":"Cancel “Compare tonight's build times”? The Release notes tab won't get this step.","canResume":false},
          {"id":"task:10000000-0000-0000-0000-000000000001","kind":"task","title":"Morning summary","nextRunAt":\#(now + 3_600),
           "schedule":"Weekdays at 8:00 AM","owner":"Cantrip Home","state":"scheduled","group":"next","cancelLabel":"Pause","canResume":false},
          \#(jobs.joined(separator: ",\n"))
          ,{"id":"wait:10000000-0000-0000-0000-000000000004","kind":"wait","title":"Waits for the laptop to wake, then installs the update",
           "schedule":"Waiting, until Fri 9:50 AM","owner":"A tab","state":"waiting","group":"waiting","cancelLabel":"Stop","canResume":false},
          {"id":"mac:com.example.photo-sync","kind":"macJob","title":"Sync the photo library","schedule":"Every 15 minutes",
           "owner":"This Mac","state":"scheduled","group":"repeating","cancelLabel":"Pause","canResume":false},
          {"id":"task:10000000-0000-0000-0000-000000000005","kind":"task","title":"Trip tracker","schedule":"Every day at 7:00 AM",
           "owner":"Cantrip Home","state":"paused","group":"paused","canResume":true}
        ]}
        """#.utf8)
    }

    private func home() async throws -> CantripRemoteModel {
        let model = try StartFreshFixture.model(for: self)
        let session = homeSession, tasks = tasks, upcoming = upcoming
        StartFreshRequestProtocol.handler = { request in
            switch request.url?.path {
            case "/api/v1/home": (200, session)
            case "/api/v1/home/tasks": (200, tasks)
            case "/api/v1/home/artifacts": (200, Data(#"{"artifacts":[],"revision":"a1"}"#.utf8))
            case "/api/v1/home/upcoming": (200, upcoming)
            default: (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        await model.selectHome()
        XCTAssertTrue(model.isHomeSelected, model.detailError ?? "Home not selected")
        return model
    }

    private func screen(_ model: CantripRemoteModel, width: CGFloat) -> some View {
        NavigationStack { CantripHomeTasksView(remote: model, openChat: { _ in }) }
            .frame(width: width, height: 940)
    }

    private func hosted(_ view: some View, _ appearance: NSAppearance.Name) async throws -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    /// The Tasks screen reads Upcoming as it appears (the poll keeps it current while it shows).
    func testTasksScreenReadsUpcomingAsItShows() async throws {
        let model = try await home()
        XCTAssertFalse(model.homeUpcomingSupported, "nothing read before a Tasks screen shows")
        let (window, _) = try await hosted(screen(model, width: 760), .aqua)
        defer { window.close() }
        for _ in 0..<100 where model.homeUpcoming.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.homeUpcomingSupported)
        XCTAssertEqual(model.homeUpcoming.map(\.group), [.next, .next, .next, .next, .next, .next, .next, .next, .waiting, .repeating, .paused])
    }

    /// Renders for review. Set TEST_RUNNER_UPCOMING_ARTIFACT_DIR (pass TEST_RUNNER_… to xcodebuild).
    func testUpcomingMacScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_UPCOMING_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_UPCOMING_ARTIFACT_DIR to render Upcoming on the Mac.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = try await home()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width in [760.0, 420] {
                let (window, host) = try await hosted(screen(model, width: width), appearance)
                for _ in 0..<100 where model.homeUpcoming.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("gatewaymac-upcoming-\(Int(width))-\(name).png"))
                window.close()
            }
        }
    }
}
