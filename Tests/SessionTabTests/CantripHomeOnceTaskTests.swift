import Foundation

extension SessionTabTests {
    /// A one-time task removes itself after a successful run; failed, skipped, workspace and
    /// unscheduled tasks stay, and nothing keeps waiting on a removed task.
    @MainActor
    static func testCantripHomeOnceTaskRemoval(homeChat: ChatSession) throws {
        let store = CantripHomeStore.shared
        let wasEnabled = AppSettings.shared.cantripHomeEnabled
        AppSettings.shared.cantripHomeEnabled = false
        defer { AppSettings.shared.cantripHomeEnabled = wasEnabled }
        let zone = "America/Los_Angeles"
        let now = Date()
        let due = now.addingTimeInterval(3_600)

        func once(_ title: String, workspace: CantripHomeTaskWorkspaceProposal? = nil,
                  runsAfter: [UUID]? = nil) throws -> CantripHomeTask {
            try store.create(.init(
                id: nil, title: title, prompt: "Remind me: \(title).",
                schedule: .init(kind: .once, summary: "Once", timeZone: zone, startAt: due),
                workspace: workspace, runsAfter: runsAfter
            ), now: now)
        }
        @discardableResult
        func run(_ task: CantripHomeTask, _ status: String, _ summary: String) -> UUID {
            let runID = UUID()
            precondition(store.beginTaskRun(taskID: task.id, runID: runID, at: now))
            store.insertBackgroundRun(.init(
                id: runID, kind: .task, label: task.title, taskID: task.id,
                startedAt: now, status: "running", summary: ""
            ))
            store.complete(runID: runID, status: status, summary: summary)
            return runID
        }
        func saved(_ id: UUID) -> Bool {
            let data = try! Data(contentsOf: CantripHomeStore.tasksFile)
            let list = try! JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            return list.contains { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) == id }
        }
        func task(_ id: UUID) -> CantripHomeTask? { store.tasks.first { $0.id == id } }
        let workspace = try JSONDecoder().decode(CantripHomeTaskWorkspaceProposal.self, from: Data(#"""
            {"recordLabel":"Call","recordLabelPlural":"Calls","icon":"phone",
             "fields":[{"key":"name","label":"Name","kind":"text","required":true,"options":null}],
             "list":{"titleField":"name","subtitleFields":[],"badgeField":null,"dateField":null},
             "detailSections":[{"title":null,"fields":["name"]}]}
            """#.utf8))

        precondition(homeChat.cantripHomeInstructions.contains(
            "When that run succeeds Cantrip removes"),
                     "Home's protocol says one-time tasks remove themselves after a successful run")

        // 1 + 4: a scheduled one-time reminder is removed after it succeeds; its Background
        // entry and summary stay, and tasks that ran after it stop waiting on it.
        let reminder = try once("Follow up with the dentist")
        let other = try once("Pay rent")
        let dependent = try once("Weekly digest", runsAfter: [reminder.id, other.id])
        let onlyAfter = try once("Reminder recap", runsAfter: [reminder.id])
        precondition(saved(reminder.id) && task(dependent.id)?.runsAfter == [reminder.id, other.id])
        let reminderRun = run(reminder, "succeeded", "Done.\n\nSummary:\nCalled the dentist; Tuesday at 3 PM.")
        let background = store.backgroundRuns.first { $0.id == reminderRun }
        precondition(task(reminder.id) == nil && !(saved(reminder.id)),
                     "A one-time task without a workspace is removed from tasks.json after it succeeds")
        precondition(background?.status == "succeeded" && background?.taskID == reminder.id
                     && background?.summary == "Called the dentist; Tuesday at 3 PM."
                     && background?.finishedAt != nil,
                     "The removed task's Background run and summary are kept")
        precondition(task(dependent.id)?.runsAfter == [other.id] && task(onlyAfter.id)?.runsAfter == nil,
                     "Tasks that listed the removed task in runsAfter no longer wait on it")

        // 2: a failed one-time run keeps the task, paused with its failure, so it can be retried.
        let flaky = try once("Check the parcel")
        run(flaky, "failed", "The carrier site timed out.")
        precondition(saved(flaky.id) && task(flaky.id)?.state == .failed
                     && task(flaky.id)?.enabled == false
                     && task(flaky.id)?.runs.first?.status == "failed",
                     "A failed one-time run keeps the task")

        // 3: a one-time task with a workspace keeps its records after it succeeds.
        let tracker = try once("Log the calls", workspace: workspace)
        run(tracker, "succeeded", "Logged.")
        precondition(saved(tracker.id) && task(tracker.id)?.workspace != nil
                     && task(tracker.id)?.state == .succeeded && task(tracker.id)?.enabled == false,
                     "A one-time task with a workspace is never removed")

        // An unscheduled workspace (stored as once without a start) is never removed either.
        let board = try store.create(.init(
            id: nil, title: "Reading list", prompt: "Track books.", schedule: nil, workspace: workspace
        ), now: now)
        precondition(board.schedule.kind == .once && !board.isScheduled)
        run(board, "succeeded", "Updated.")
        precondition(saved(board.id) && task(board.id)?.state == .ready,
                     "A task with no schedule is never removed")

        // A due run the user stopped before it started keeps the task, paused.
        let skipped = try once("Renew the passport")
        store.skipDueRun(taskID: skipped.id, now: now)
        precondition(saved(skipped.id) && task(skipped.id)?.state == .paused
                     && task(skipped.id)?.enabled == false,
                     "A skipped one-time run keeps the task")

        // Repeating tasks are untouched.
        let repeating = try store.create(.init(
            id: nil, title: "Hourly check", prompt: "Check.",
            schedule: .init(kind: .interval, summary: "Every hour", timeZone: zone,
                            startAt: due, intervalMinutes: 60)
        ), now: now)
        run(repeating, "succeeded", "Checked.")
        precondition(saved(repeating.id) && task(repeating.id)?.nextRunAt != nil,
                     "Repeating tasks stay after a successful run")

        // Deleting a task by hand also clears runsAfter references to it.
        try store.delete(id: other.id)
        precondition(task(dependent.id)?.runsAfter == nil,
                     "A deleted task is dropped from other tasks' runsAfter")

        for id in [dependent.id, onlyAfter.id, flaky.id, tracker.id, board.id, skipped.id, repeating.id] {
            try? store.delete(id: id)
        }
        print("Cantrip Home: one-time tasks remove themselves after a successful run")
    }
}
