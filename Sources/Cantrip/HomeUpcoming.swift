import Darwin
import Foundation

/// Home's Upcoming list (docs/cantrip-home.md "Upcoming"): everything set to run later, in one
/// place. Home tasks' next runs; one-off steps tabs and Home register with `cantrip schedule add`,
/// which Cantrip delivers itself when they're due; waits started or registered with `cantrip
/// schedule wait`; background jobs tabs started without registering them (found by their Copilot
/// job wrapper, so nothing runs hidden); and this Mac's recurring LaunchAgents. Each item says what
/// it does, when it runs next and who set it up, and can be cancelled (a recurring one is paused,
/// with Resume).
@MainActor
final class HomeUpcoming {
    static let shared = HomeUpcoming()

    struct Item: Equatable {
        enum Kind: String { case task, step, wait, job, macJob }
        enum State: String { case scheduled, waiting, paused }

        var id: String
        var kind: Kind
        var title: String
        var detail: String?
        var nextRunAt: Date?
        var schedule: String
        /// Who set it up: a tab's title, "Cantrip Home" or "This Mac".
        var owner: String
        var ownerTabID: String?
        var state: State
        /// "Cancel", "Stop" or "Pause"; nil when it can't be cancelled from here.
        var cancelLabel: String?
        /// The question every client asks before cancelling, naming what will stop.
        var confirm: String?
        var canResume = false

        /// Where clients list it: "next" (has a next run time), "waiting" (waits, jobs, a step
        /// waiting for Home), "repeating" (runs every few minutes, no fixed time) or "paused".
        var group: String {
            if state == .paused { return "paused" }
            if state == .waiting { return "waiting" }
            return nextRunAt == nil ? "repeating" : "next"
        }

        var json: [String: Any] {
            var object: [String: Any] = [
                "id": id, "kind": kind.rawValue, "title": title, "schedule": schedule, "owner": owner,
                "state": state.rawValue, "canResume": canResume, "group": group,
            ]
            object["detail"] = detail
            object["nextRunAt"] = nextRunAt?.timeIntervalSince1970
            object["ownerTabID"] = ownerTabID
            object["cancelLabel"] = cancelLabel
            object["confirm"] = confirm
            return object
        }
    }

    struct Failure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    var store = UpcomingStore.standard
    private(set) var records = UpcomingRecords()
    private weak var manager: SessionManager?
    private var timer: Timer?
    /// When Home last had no background runs, for steps that wait for a quiet Home.
    private var homeQuietSince: Date?
    private var processCache: (at: Date, rows: [Int32: MachineJobs.ProcessRow])?
    private var macCache: (at: Date, jobs: [MacLaunchJobs.Job], state: MacLaunchJobs.State)?
    var now: () -> Date = Date.init

    func start(manager: SessionManager) {
        self.manager = manager
        records = store.load()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func persist() {
        do { try store.save(records, now: now()) } catch { Log.write("upcoming: couldn't save: \(error.localizedDescription)") }
    }

    // MARK: Delivering steps

    /// Delivers each step that's due. One waiting for a quiet Home goes once Home has had no
    /// background runs for a minute, or at its deadline (three hours after it was due if it set none).
    func tick() {
        let date = now()
        let homeBusy = !CantripHomeStore.shared.runner.jobs.isEmpty
        homeQuietSince = homeBusy ? nil : (homeQuietSince ?? date)
        let quiet = homeQuietSince.map { date.timeIntervalSince($0) >= 60 } ?? false
        var changed = false
        for index in records.steps.indices {
            let step = records.steps[index]
            guard step.status == .scheduled, step.runAt <= date else { continue }
            let deadline = step.deadline ?? step.runAt.addingTimeInterval(3 * 3_600)
            if step.whenHomeIsQuiet, !quiet, date < deadline { continue }
            records.steps[index].status = deliver(step, homeStillBusy: step.whenHomeIsQuiet && !quiet) ? .delivered : .failed
            records.steps[index].finishedAt = date
            changed = true
        }
        if changed { persist() }
    }

    private func deliver(_ step: ScheduledStep, homeStillBusy: Bool) -> Bool {
        guard let manager else { return false }
        var text = "(Automated: the step you scheduled for \(Self.clock(step.runAt)) is due: \(step.title).)\n\n\(step.message)"
        let session: ChatSession
        if let tab = manager.managedSession(id: step.tabID), !manager.homeRuns.contains(where: { $0.id == tab.id }) {
            session = tab
        } else {
            // Its tab (or the Home run that set it up) is gone: Home decides what to do with it.
            session = manager.homeSession
            text += "\n\n(The tab that scheduled this was closed, so it came to Home.)"
        }
        if homeStillBusy {
            text += "\n\n(Home background runs were still running at the deadline: check before acting.)"
        } else if !step.whenHomeIsQuiet, now().timeIntervalSince(step.runAt) > 300 {
            text += "\n\n(Delivered late: Cantrip wasn't running at \(Self.clock(step.runAt)).)"
        }
        session.submitRemote(text, mode: .queue)
        Log.write("upcoming: delivered scheduled step \(step.id.uuidString.prefix(8)) to \(session.id == manager.homeSession.id ? "Home" : "its tab")")
        return true
    }

    // MARK: Registering

    func addStep(_ step: ScheduledStep) throws -> ScheduledStep {
        guard !step.title.trimmingCharacters(in: .whitespaces).isEmpty,
              !step.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(status: 400, message: "A step needs a title and a message.")
        }
        guard step.runAt > now().addingTimeInterval(-60) else { throw Failure(status: 400, message: "That time has passed.") }
        guard step.title.count <= 200, step.message.count <= 20_000 else {
            throw Failure(status: 400, message: "Keep the title under 200 characters and the message under 20,000.")
        }
        if let manager, manager.managedSession(id: step.tabID) == nil {
            throw Failure(status: 404, message: "No tab \(step.tabID.uuidString).")
        }
        records.steps.append(step)
        persist()
        return step
    }

    func addWait(_ wait: RegisteredWait) throws -> RegisteredWait {
        guard !wait.title.trimmingCharacters(in: .whitespaces).isEmpty, wait.title.count <= 200 else {
            throw Failure(status: 400, message: "A wait needs a title under 200 characters.")
        }
        guard let start = Self.processStart(wait.pid), abs(start - wait.processStart) < 2 else {
            throw Failure(status: 404, message: "Process \(wait.pid) isn't running.")
        }
        guard Self.processOwner(wait.pid) == getuid() else { throw Failure(status: 403, message: "That process isn't this user's.") }
        records.waits.removeAll { $0.pid == wait.pid }
        records.waits.append(wait)
        persist()
        return wait
    }

    func describeMacJob(label: String, note: MacJobNote) throws {
        guard macJobs().jobs.contains(where: { $0.label == label }) else {
            throw Failure(status: 404, message: "No recurring LaunchAgent \(label) in ~/Library/LaunchAgents.")
        }
        guard !note.title.trimmingCharacters(in: .whitespaces).isEmpty, note.title.count <= 120 else {
            throw Failure(status: 400, message: "Give a title under 120 characters.")
        }
        records.macJobs[label] = note
        persist()
    }

    // MARK: Listing

    func items() -> [Item] {
        let date = now()
        var items: [Item] = []
        let tabTitles = Dictionary((manager?.sessions ?? []).map { ($0.id.uuidString, $0.title) }) { first, _ in first }
        func owner(_ tabID: UUID?) -> String {
            guard let tabID else { return "A tab" }
            if tabID == manager?.homeSession.id || manager?.homeRuns.contains(where: { $0.id == tabID }) == true { return "Cantrip Home" }
            return tabTitles[tabID.uuidString].map { "\($0) tab" } ?? "A closed tab"
        }

        for task in CantripHomeStore.shared.tasks where task.isScheduled {
            let paused = !task.enabled
            if !paused && task.nextRunAt == nil { continue }
            items.append(Item(
                id: "task:\(task.id.uuidString)", kind: .task, title: task.title, detail: nil,
                nextRunAt: paused ? nil : task.nextRunAt, schedule: task.schedule.summary, owner: "Cantrip Home",
                state: paused ? .paused : .scheduled, cancelLabel: paused ? nil : "Pause",
                confirm: paused ? nil : "Pause the Home task “\(task.title)”? It won't run until you resume it.",
                canResume: paused))
        }

        for step in records.steps where step.status == .scheduled {
            let waitingForHome = step.whenHomeIsQuiet && step.runAt <= date
            let who = owner(step.tabID)
            items.append(Item(
                id: "step:\(step.id.uuidString)", kind: .step, title: step.title,
                detail: waitingForHome ? "Waiting for Home's background runs to finish" : step.whenHomeIsQuiet
                    ? "Once Home's background runs have finished" : nil,
                nextRunAt: step.runAt, schedule: "Once", owner: who, ownerTabID: step.tabID.uuidString,
                state: waitingForHome ? .waiting : .scheduled, cancelLabel: "Cancel",
                confirm: "Cancel “\(step.title)”? \(who == "Cantrip Home" ? "Cantrip Home" : "The \(who)") won't get this step at \(Self.clock(step.runAt))."))
        }

        let rows = processes()
        var shown: Set<Int32> = []
        records.waits.removeAll { wait in
            guard let start = Self.processStart(wait.pid), abs(start - wait.processStart) < 2 else { return true }
            return false
        }
        for wait in records.waits {
            shown.insert(wait.pid)
            items.append(Item(
                id: "wait:\(wait.id.uuidString)", kind: .wait, title: wait.title, detail: wait.detail,
                nextRunAt: nil, schedule: wait.until.map { "Waiting, until \(Self.clock($0))" } ?? "Waiting",
                owner: owner(wait.tabID), ownerTabID: wait.tabID?.uuidString, state: .waiting, cancelLabel: "Stop",
                confirm: "Stop “\(wait.title)”? It stops waiting and won't do its next step."))
        }
        for job in Self.detachedJobs(in: rows) where !shown.contains(job.pid) {
            let tab = Self.tabID(of: job.pid, rows: rows)
            let title = UpcomingNames.commandTitle(job.arguments) ?? UpcomingNames.humanize(job.name)
            items.append(Item(
                id: "job:\(job.pid):\(Int(Self.processStart(job.pid) ?? 0))", kind: .job, title: title,
                detail: "A background job a tab started without registering it",
                nextRunAt: nil, schedule: "Running for \(Self.duration(job.age))", owner: owner(tab),
                ownerTabID: tab?.uuidString, state: .waiting, cancelLabel: "Stop",
                confirm: "Stop “\(title)”? The job ends now and won't do whatever it was waiting to do."))
        }

        let mac = macJobs()
        for job in mac.jobs {
            let paused = mac.state.disabled.contains(job.label) || !mac.state.loaded.contains(job.label)
            let note = records.macJobs[job.label]
            let title = note?.title ?? UpcomingNames.macJobTitle(label: job.label, ownNames: Self.ownNames)
            items.append(Item(
                id: "mac:\(job.label)", kind: .macJob, title: title, detail: note?.detail,
                nextRunAt: paused ? nil : MacLaunchJobs.nextRun(job.calendar, after: date),
                schedule: MacLaunchJobs.scheduleText(job), owner: "This Mac", state: paused ? .paused : .scheduled,
                cancelLabel: paused ? nil : "Pause",
                confirm: paused ? nil : "Pause “\(title)”? The Mac stops running it until you resume it. Its setup stays on the Mac.",
                canResume: paused))
        }
        return Self.sorted(items)
    }

    /// Next up (soonest first), then waiting, repeating and paused.
    static func sorted(_ items: [Item]) -> [Item] {
        func rank(_ item: Item) -> Int { ["next": 0, "waiting": 1, "repeating": 2, "paused": 3][item.group] ?? 4 }
        return items.sorted { lhs, rhs in
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            if let left = lhs.nextRunAt, let right = rhs.nextRunAt, left != right { return left < right }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    // MARK: Cancel and resume

    /// Cancels, stops or pauses one item, then says what happened.
    func cancel(_ id: String) throws -> String {
        let (kind, value) = Self.split(id)
        switch kind {
        case "task":
            guard let taskID = UUID(uuidString: value) else { break }
            let task = try CantripHomeStore.shared.update(id: taskID, update: CantripHomeTaskUpdate(title: nil, prompt: nil, enabled: false))
            return "Paused the Home task “\(task.title)”."
        case "step":
            guard let index = records.steps.firstIndex(where: { $0.id.uuidString == value && $0.status == .scheduled }) else { break }
            records.steps[index].status = .cancelled
            records.steps[index].finishedAt = now()
            persist()
            Log.write("upcoming: cancelled scheduled step \(value.prefix(8))")
            return "Cancelled “\(records.steps[index].title)”."
        case "wait":
            guard let wait = records.waits.first(where: { $0.id.uuidString == value }) else { break }
            guard let start = Self.processStart(wait.pid), abs(start - wait.processStart) < 2 else {
                records.waits.removeAll { $0.id == wait.id }
                persist()
                return "“\(wait.title)” had already finished."
            }
            Self.stop(pid: wait.pid, ownGroup: wait.ownGroup, rows: processes(fresh: true))
            records.waits.removeAll { $0.id == wait.id }
            persist()
            Log.write("upcoming: stopped a registered wait")
            return "Stopped “\(wait.title)”."
        case "job":
            let parts = value.split(separator: ":")
            guard parts.count == 2, let pid = Int32(parts[0]), let start = Double(parts[1]) else { break }
            let rows = processes(fresh: true)
            guard let job = Self.detachedJobs(in: rows).first(where: { $0.pid == pid }),
                  let current = Self.processStart(pid), abs(current - start) < 2 else {
                throw Failure(status: 404, message: "That job has already finished.")
            }
            Self.stop(pid: pid, ownGroup: false, rows: rows)
            Log.write("upcoming: stopped a tab's background job")
            return "Stopped “\(UpcomingNames.commandTitle(job.arguments) ?? job.name)”."
        case "mac":
            guard let job = macJobs(fresh: true).jobs.first(where: { $0.label == value }) else { break }
            try MacLaunchJobs.pause(job)
            macCache = nil
            Log.write("upcoming: paused LaunchAgent \(job.label)")
            return "Paused “\(records.macJobs[job.label]?.title ?? UpcomingNames.macJobTitle(label: job.label, ownNames: Self.ownNames))”."
        default:
            break
        }
        throw Failure(status: 404, message: "That item isn't in Upcoming any more.")
    }

    func resume(_ id: String) throws -> String {
        let (kind, value) = Self.split(id)
        switch kind {
        case "task":
            guard let taskID = UUID(uuidString: value) else { break }
            let task = try CantripHomeStore.shared.update(id: taskID, update: CantripHomeTaskUpdate(title: nil, prompt: nil, enabled: true))
            return "Resumed the Home task “\(task.title)”."
        case "mac":
            guard let job = macJobs(fresh: true).jobs.first(where: { $0.label == value }) else { break }
            try MacLaunchJobs.resume(job)
            macCache = nil
            Log.write("upcoming: resumed LaunchAgent \(job.label)")
            return "Resumed “\(records.macJobs[job.label]?.title ?? UpcomingNames.macJobTitle(label: job.label, ownNames: Self.ownNames))”."
        default:
            break
        }
        throw Failure(status: 404, message: "Only paused Home tasks and Mac jobs can be resumed.")
    }

    private static func split(_ id: String) -> (String, String) {
        guard let colon = id.firstIndex(of: ":") else { return ("", "") }
        return (String(id[..<colon]), String(id[id.index(after: colon)...]))
    }

    // MARK: Processes and launchd

    private func processes(fresh: Bool = false) -> [Int32: MachineJobs.ProcessRow] {
        if !fresh, let cache = processCache, now().timeIntervalSince(cache.at) < 10 { return cache.rows }
        let rows = MachineJobs.parse(ps: Self.run("/bin/ps", MachineJobs.psArguments))
        processCache = (now(), rows)
        return rows
    }

    private func macJobs(fresh: Bool = false) -> (jobs: [MacLaunchJobs.Job], state: MacLaunchJobs.State) {
        if !fresh, let cache = macCache, now().timeIntervalSince(cache.at) < 30 { return (cache.jobs, cache.state) }
        let jobs = MacLaunchJobs.scan()
        let state = MacLaunchJobs.currentState()
        macCache = (now(), jobs, state)
        return (jobs, state)
    }

    /// The account's own names, left out of LaunchAgent titles.
    static var ownNames: Set<String> {
        Set(([NSUserName()] + NSFullUserName().split(separator: " ").map(String.init)).map { $0.lowercased() })
    }

    /// Jobs a tab's Copilot shell started in the background (`detach`): a job wrapper's own
    /// command, skipping the wrappers themselves.
    static func detachedJobs(in rows: [Int32: MachineJobs.ProcessRow]) -> [MachineJobs.ProcessRow] {
        let marker = "__copilot_pid_path="
        let wrappers = Set(rows.values.filter { $0.arguments.contains(marker) }.map(\.pid))
        return rows.values.filter { wrappers.contains($0.ppid) && !$0.arguments.contains(marker) && $0.uid == getuid() }
            .sorted { $0.pid < $1.pid }
    }

    /// The tab whose agent started a job: the nearest ancestor with `CANTRIP_TAB_ID` (Copilot keeps
    /// it; its job wrappers don't). Nil once the agent that started it has exited.
    static func tabID(of pid: Int32, rows: [Int32: MachineJobs.ProcessRow]) -> UUID? {
        var current = pid
        for _ in 0..<6 {
            if let value = MachineJobs.environmentValue(MachineJobs.tabIDVariable, pid: current), let id = UUID(uuidString: value) {
                return id
            }
            guard let parent = rows[current]?.ppid, parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    /// SIGTERM to the process, everything it started and, for a wait Cantrip started, its group.
    static func stop(pid: Int32, ownGroup: Bool, rows: [Int32: MachineJobs.ProcessRow]) {
        var family = [pid]
        var index = 0
        while index < family.count {
            family += rows.values.filter { $0.ppid == family[index] }.map(\.pid)
            index += 1
        }
        if ownGroup { kill(-pid, SIGTERM) }
        for member in family.reversed() { kill(member, SIGTERM) }
    }

    static func processStart(_ pid: Int32) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    static func processOwner(_ pid: Int32) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE MMM d, h:mm a"
        return formatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        if minutes < 48 * 60 { return "\(minutes / 60) h" }
        return "\(minutes / 1_440) days"
    }

    // MARK: CLI (`cantrip schedule`)

    func handle(_ request: [String: Any]) -> [String: Any] {
        do {
            switch request["action"] as? String {
            case "add":
                guard let title = request["title"] as? String, let message = request["message"] as? String,
                      let at = request["at"] as? Double, let rawTab = request["tab"] as? String,
                      let tab = UUID(uuidString: rawTab) else {
                    throw Failure(status: 400, message: "Give --at, --title, the message and the tab.")
                }
                var step = ScheduledStep(title: title, message: message, tabID: tab, runAt: Date(timeIntervalSince1970: at))
                step.whenHomeIsQuiet = request["whenHomeIsQuiet"] as? Bool ?? false
                step.deadline = (request["deadline"] as? Double).map(Date.init(timeIntervalSince1970:))
                let saved = try addStep(step)
                return ["id": "step:\(saved.id.uuidString)",
                        "text": "Scheduled “\(saved.title)” for \(Self.clock(saved.runAt)) (step:\(saved.id.uuidString)). It's listed in Home's Upcoming; cancel it there or with `cantrip schedule cancel step:\(saved.id.uuidString)`."]
            case "wait":
                guard let title = request["title"] as? String, let pid = request["pid"] as? Int,
                      let start = Self.processStart(Int32(pid)) else {
                    throw Failure(status: 400, message: "Give --title and a running process.")
                }
                var wait = RegisteredWait(title: title, pid: Int32(pid), processStart: start)
                wait.detail = request["detail"] as? String
                wait.ownGroup = request["ownGroup"] as? Bool ?? false
                wait.tabID = (request["tab"] as? String).flatMap(UUID.init(uuidString:))
                wait.until = (request["until"] as? Double).map(Date.init(timeIntervalSince1970:))
                let saved = try addWait(wait)
                return ["id": "wait:\(saved.id.uuidString)",
                        "text": "Listed “\(saved.title)” (process \(pid)) in Home's Upcoming as wait:\(saved.id.uuidString)."]
            case "describe":
                guard let label = request["label"] as? String, let title = request["title"] as? String else {
                    throw Failure(status: 400, message: "Give the LaunchAgent's label and --title.")
                }
                try describeMacJob(label: label, note: MacJobNote(title: title, detail: request["detail"] as? String))
                return ["text": "“\(label)” shows as “\(title)” in Upcoming."]
            case "cancel":
                return ["text": try cancel(request["id"] as? String ?? "")]
            case "resume":
                return ["text": try resume(request["id"] as? String ?? "")]
            case "list", nil:
                let items = items()
                let lines = items.map { item in
                    let when = item.nextRunAt.map { Self.clock($0) } ?? item.state.rawValue
                    return "\(item.id)\t\(when)\t\(item.title)\t\(item.schedule)\t\(item.owner)"
                }
                return ["text": lines.isEmpty ? "Nothing is scheduled." : lines.joined(separator: "\n"),
                        "items": items.map(\.json)]
            default:
                throw Failure(status: 400, message: "Unknown schedule action.")
            }
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    // MARK: Agent guidance

    /// Appended to every tab's system message (each backend) and Home's.
    nonisolated static func agentGuidance(command: String) -> String {
        """
        Future steps go through Cantrip, never a hidden timer. To do something later (check \
        tonight's results, report in the morning), schedule it: `\(command) schedule add --at 22:35 \
        --title "Compare tonight's runs with last night's" -- "what your future self should do"` \
        (also "+2h" or "2026-11-20 08:00"; add `--when-home-quiet --deadline 23:50` to wait for \
        Home's background runs). When it's due, Cantrip queues that message in this tab. Don't start \
        detached `sleep` scripts or wakers that post to a tab yourself. To wait for something to \
        happen (a Mac waking up, a deploy, a first event), start the waiter through Cantrip: \
        `\(command) schedule wait --title "Waits for the laptop to wake, then installs the update" \
        --until +48h -- /bin/bash waiter.sh`, or list one that's already running with `--pid PID`. \
        Titles say what it will do in plain words, without commands, paths or secrets. Everything \
        shows in Home's Upcoming list (Tasks) with when and who set it up, where the user can \
        cancel it; `\(command) schedule list` and `\(command) schedule cancel ID` do the same here.
        """
    }
}
