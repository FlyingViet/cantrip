import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}()

private func date(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

// MARK: Mac jobs: which plists count

do {
    let daily = MacLaunchJobs.job(plist: ["Label": "com.example.nightly-sync", "ProgramArguments": ["/bin/true", "--token", "x"],
                                          "StartCalendarInterval": ["Hour": 3, "Minute": 15]], path: "/tmp/a.plist")
    expect(daily?.calendar == [["Hour": 3, "Minute": 15]], "a calendar job: \(String(describing: daily))")
    let several = MacLaunchJobs.job(plist: ["Label": "com.example.twice", "StartCalendarInterval": [["Hour": 9, "Minute": 0], ["Hour": 21, "Minute": 30]]],
                                    path: "/tmp/b.plist")
    expect(several?.calendar.count == 2, "a list of calendar entries")
    expect(MacLaunchJobs.job(plist: ["Label": "com.example.poll", "StartInterval": 900], path: "/tmp/c.plist")?.interval == 900,
           "an interval job")
    expect(MacLaunchJobs.job(plist: ["Label": "com.example.server", "KeepAlive": true], path: "/tmp/d.plist") == nil,
           "an always-on service isn't scheduled")
    for label in ["actions.runner.Owner-Repo.mini-1", "com.apple.something", "homebrew.mxcl.postgresql"] {
        expect(MacLaunchJobs.job(plist: ["Label": label, "StartInterval": 60], path: "/tmp/e.plist") == nil, "\(label) is left out")
    }
}

// MARK: Mac jobs: next run

do {
    let now = date("2026-11-18 09:30")
    expect(MacLaunchJobs.nextRun([["Hour": 3, "Minute": 15]], after: now, calendar: calendar) == date("2026-11-19 03:15"),
           "daily at 3:15 runs tomorrow once today's is past")
    expect(MacLaunchJobs.nextRun([["Hour": 22, "Minute": 0]], after: now, calendar: calendar) == date("2026-11-18 22:00"),
           "later today")
    expect(MacLaunchJobs.nextRun([["Minute": 45]], after: now, calendar: calendar) == date("2026-11-18 09:45"),
           "hourly at :45")
    // 2026-11-18 is a Wednesday; launchd's Weekday 1 is Monday, 0 and 7 Sunday.
    expect(MacLaunchJobs.nextRun([["Weekday": 1, "Hour": 9, "Minute": 0]], after: now, calendar: calendar) == date("2026-11-23 09:00"),
           "next Monday")
    expect(MacLaunchJobs.nextRun([["Weekday": 7, "Hour": 8, "Minute": 0]], after: now, calendar: calendar) == date("2026-11-22 08:00"),
           "Weekday 7 is Sunday")
    expect(MacLaunchJobs.nextRun([["Day": 1, "Hour": 4, "Minute": 0]], after: now, calendar: calendar) == date("2026-12-01 04:00"),
           "monthly on the 1st")
    expect(MacLaunchJobs.nextRun([["Hour": 21, "Minute": 30], ["Hour": 9, "Minute": 0]], after: now, calendar: calendar)
           == date("2026-11-18 21:30"), "the soonest of several entries")
}

// MARK: Mac jobs: words

do {
    func text(_ plist: [String: Any]) -> String {
        MacLaunchJobs.scheduleText(MacLaunchJobs.job(plist: plist.merging(["Label": "com.example.x"]) { $1 }, path: "/tmp/x.plist")!)
    }
    expect(text(["StartCalendarInterval": ["Hour": 3, "Minute": 15]]) == "Daily at 3:15 AM", text(["StartCalendarInterval": ["Hour": 3, "Minute": 15]]))
    expect(text(["StartCalendarInterval": ["Minute": 5]]) == "Every hour at :05", "hourly")
    expect(text(["StartCalendarInterval": ["Weekday": 1, "Hour": 21, "Minute": 0]]) == "Mondays at 9:00 PM", "weekly")
    expect(text(["StartCalendarInterval": [["Hour": 21, "Minute": 30], ["Hour": 9, "Minute": 0]]]) == "Daily at 9:00 AM and 9:30 PM",
           "twice a day, in order")
    expect(text(["StartInterval": 900]) == "Every 15 minutes", "interval")
    expect(text(["StartInterval": 7_200]) == "Every 2 hours", "hours")
    expect(UpcomingNames.macJobTitle(label: "com.example.classify-artists", ownNames: []) == "Example · Classify artists",
           UpcomingNames.macJobTitle(label: "com.example.classify-artists", ownNames: []))
    expect(UpcomingNames.macJobTitle(label: "com.someone.flight-status", ownNames: ["someone"]) == "Flight status",
           "the account's own name is left out")
}

// MARK: Launchd's state

do {
    let disabled = MacLaunchJobs.disabled(fromPrintDisabled: """
    disabled services = {
    \t"com.example.paused" => disabled
    \t"com.example.running" => enabled
    \t"com.example.old" => true
    }
    """)
    expect(disabled == ["com.example.paused", "com.example.old"], "\(disabled)")
    let loaded = MacLaunchJobs.loaded(fromList: "PID\tStatus\tLabel\n-\t0\tcom.example.running\n123\t0\tcom.example.server\n")
    expect(loaded == ["com.example.running", "com.example.server"], "\(loaded)")
}

// MARK: When a step runs

do {
    let now = date("2026-11-18 09:30")
    expect(UpcomingTime.parse("22:35", now: now, calendar: calendar) == date("2026-11-18 22:35"), "later today")
    expect(UpcomingTime.parse("08:00", now: now, calendar: calendar) == date("2026-11-19 08:00"), "tomorrow once it's past")
    expect(UpcomingTime.parse("2026-11-20 08:00", now: now, calendar: calendar) == date("2026-11-20 08:00"), "a date and time")
    expect(UpcomingTime.parse("+2h", now: now, calendar: calendar) == now.addingTimeInterval(7_200), "+2h")
    expect(UpcomingTime.parse("+90m", now: now, calendar: calendar) == now.addingTimeInterval(5_400), "+90m")
    for bad in ["", "soon", "25:00", "+2x", "+-1h"] {
        expect(UpcomingTime.parse(bad, now: now, calendar: calendar) == nil, "\"\(bad)\" isn't a time")
    }
}

// MARK: Naming a job a tab left running

do {
    expect(UpcomingNames.commandTitle("/bin/bash /tmp/code-mode-trial/wake.sh") == "Wake", "a script")
    expect(UpcomingNames.commandTitle("/bin/bash --norc --noprofile -c python3 ~/watch-first-run.py > out.log 2>&1") == "Watch first run",
           "a command run by -c")
    expect(UpcomingNames.commandTitle("/bin/bash /tmp/deploy/deploy-when-idle.sh v1.2.3-4-gabc") == "Deploy when idle",
           "arguments never show")
    expect(UpcomingNames.commandTitle("/opt/homebrew/bin/node /tmp/duo-watch.mjs") == "Duo watch", "node")
    expect(UpcomingNames.commandTitle("TOKEN=secret /bin/bash x.sh") == "X", "an environment assignment is skipped")
    expect(UpcomingNames.commandTitle("/bin/zsh -c sleep 600 && python3 ~/notify-tab.py ID msg") == "Notify tab",
           "a sleeping waker is named by what it runs next")
    expect(UpcomingNames.commandTitle("/bin/bash -c command -v git > /dev/null") == "Git", "a shell builtin is skipped")
}

// MARK: Jobs nobody registered

do {
    let ps = """
      100     1   100   501 Ss    01:00:00   0.0   1000 sh -c __copilot_pid_path=$1; __copilot_exit_path=$2; wait copilot-detached-supervisor /tmp/a.pid /tmp/a.exit /bin/bash /tmp/check.sh
      101   100   100   501 S     01:00:00   0.0   1000 /bin/bash /tmp/check.sh
      200     1   200   501 Ss    01:00:00   0.0   1000 sh -c __copilot_pid_path=$1; __copilot_exit_path=$2; wait copilot-detached-supervisor /tmp/b.pid /tmp/b.exit /bin/bash /tmp/waker.sh
      201   200   200   501 S     01:00:00   0.0   1000 /bin/bash /tmp/waker.sh
      301   300   300   501 S     01:00:00   0.0   1000 /bin/bash /tmp/not-detached.sh
      401   100   100     0 S     01:00:00   0.0   1000 /bin/bash /tmp/root-owned.sh
    """
    let rows = MachineJobs.parse(ps: ps)
    expect(UpcomingJobs.unregistered(in: rows, registered: [], uid: 501).map(\.pid) == [101, 201],
           "the wrappers' own jobs, this user's only")
    expect(UpcomingJobs.unregistered(in: rows, registered: [100], uid: 501).map(\.pid) == [201],
           "a wait registered on the wrapper hides its job")
    expect(UpcomingJobs.unregistered(in: rows, registered: [201], uid: 501).map(\.pid) == [101],
           "a wait registered on the job hides it")
}

// MARK: The store

do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("upcoming-tests-\(UUID().uuidString)")
    let store = UpcomingStore(url: folder.appendingPathComponent("home/upcoming.json"))
    let now = date("2026-11-18 09:30")
    var records = UpcomingRecords()
    records.steps.append(ScheduledStep(title: "Compare tonight's runs", message: "Run the comparison.", tabID: UUID(), runAt: date("2026-11-18 22:35")))
    var old = ScheduledStep(title: "Old", message: "Done.", tabID: UUID(), runAt: date("2026-11-16 08:00"))
    old.status = .delivered
    old.finishedAt = date("2026-11-16 08:00")
    records.steps.append(old)
    records.macJobs["com.example.x"] = MacJobNote(title: "Sync the photo library", detail: nil)
    try! store.save(records, now: now)
    let loaded = store.load()
    expect(loaded.steps.map(\.title) == ["Compare tonight's runs"], "finished steps older than a day are dropped: \(loaded.steps.map(\.title))")
    expect(loaded.steps.first?.runAt == date("2026-11-18 22:35"), "dates survive")
    expect(loaded.macJobs["com.example.x"]?.title == "Sync the photo library", "Mac job notes survive")
    let mode = (try? FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int) ?? 0
    expect(mode == 0o600, "the file is private: \(String(mode, radix: 8))")
    try? FileManager.default.removeItem(at: folder)
}

if failures > 0 {
    fputs("\(failures) upcoming test(s) failed\n", stderr)
    exit(1)
}
print("Upcoming tests passed")
