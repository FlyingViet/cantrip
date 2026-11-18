import Foundation

extension SessionTabTests {
    /// Views (docs/views.md): the `cantrip-view` block's schema, refusing typed values and numbers,
    /// checked rows, building cards from records, tasks and tool output, `run` sources, and actions
    /// that run only once confirmed.
    @MainActor
    static func testHomeViews() async throws {
        let views = HomeViews.shared
        let saved = (views.tasks, views.servers, views.callTool, views.policy, views.privateServers)
        defer {
            (views.tasks, views.servers, views.callTool, views.policy, views.privateServers) = saved
            views.reset()
        }
        let tasks = viewTestTasks()
        views.reset(loading: true)
        views.tasks = { tasks }
        views.servers = { [MCPServer(name: "homelab", command: "relay"), MCPServer(name: "bitwarden", command: "relay")] }
        views.policy = { _, tool in tool == "denied_status" ? "denied by test policy" : nil }
        views.privateServers = { ["personal"] }

        try testHomeViewProtocol()
        try testHomeViewSchema(tasks: tasks)
        try testHomeViewTypedNumbers(tasks: tasks)
        try testHomeViewCheckedRows(tasks: tasks)
        try await testHomeViewCards(tasks: tasks)
        try await testHomeViewRunCapture(tasks: tasks)
        try await testHomeViewActions(tasks: tasks)
        print("Views: schema, typed values and numbers, checked rows, cards, run capture and confirmed actions passed")
    }

    static let interviewsID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let labCheckID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let notesID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let firstRecordID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    static func viewTestTasks() -> [CantripHomeTask] {
        let fields = [
            CantripHomeTaskField(key: "company", label: "Company", kind: .text, required: true, options: nil),
            CantripHomeTaskField(key: "stage", label: "Stage", kind: .choice, required: false,
                                 options: ["Applied", "Interviewing", "Offer", "Rejected"]),
            CantripHomeTaskField(key: "appliedOn", label: "Applied", kind: .date, required: false, options: nil),
            CantripHomeTaskField(key: "salary", label: "Salary", kind: .number, required: false, options: nil),
        ]
        func record(_ company: String, _ stage: String, _ day: String?, _ salary: String, id: UUID = UUID()) -> CantripHomeTaskRecord {
            var values = ["company": company, "stage": stage, "salary": salary]
            values["appliedOn"] = day
            return CantripHomeTaskRecord(id: id, values: values)
        }
        let workspace = CantripHomeTaskWorkspace(
            recordLabel: "Application", recordLabelPlural: "Applications", icon: "person.2", fields: fields,
            list: .init(titleField: "company", subtitleFields: ["stage"], badgeField: "stage", dateField: "appliedOn"),
            detailSections: [],
            records: [record("Acme", "Applied", "2026-11-02", "100", id: firstRecordID), record("Globex", "Interviewing", "2026-11-01", "150"),
                      record("Initech", "Rejected", "2026-11-02", "120"), record("Umbrella", "Applied", nil, "90")])
        let hourly = CantripHomeSchedule(kind: .interval, summary: "Every hour", timeZone: "America/Los_Angeles", intervalMinutes: 60)
        var interviews = CantripHomeTask(id: interviewsID, title: "Interview tracker", prompt: "Track applications.",
                                         schedule: hourly, workspace: workspace)
        interviews.runs = [.init(startedAt: Date(), finishedAt: Date(), status: "succeeded", summary: "ok")]
        let labCheck = CantripHomeTask(id: labCheckID, title: "Homelab check", prompt: "Check the homelab.", schedule: hourly)
        let notes = CantripHomeTask(id: notesID, title: "Notes", prompt: "Notes.",
                                    schedule: .init(kind: .once, summary: "No schedule", timeZone: "America/Los_Angeles"),
                                    hasSchedule: false)
        return [interviews, labCheck, notes]
    }

    static func viewProposal(_ json: String) throws -> HomeViewProposal {
        try CantripHomeProtocol.decode(HomeViewProposal.self, from: json)
    }

    @MainActor
    static func viewContext(_ tasks: [CantripHomeTask], activities: [ToolActivity] = []) -> HomeViewValidation.Context {
        .init(tasks: tasks, activities: activities, servers: HomeViews.shared.servers(), policy: HomeViews.shared.policy)
    }

    /// A small valid view: records counted, grouped and listed, a homelab tool table.
    static let validView = """
    {"name":"Week","icon":"rectangle.3.group","refresh":{"everyMinutes":15,"afterTasks":["\(labCheckID)"]},
     "data":{"jobs":{"records":"\(interviewsID)","filter":{"stage":["Applied","Interviewing"]}},
             "all":{"records":"\(interviewsID)"},
             "lab":{"tool":{"server":"homelab","name":"homelab_status","arguments":{}}},
             "trackers":{"tasks":["\(interviewsID)","\(labCheckID)"]}},
     "blocks":[
      {"type":"tabs","tabs":[
        {"title":"Overview","blocks":[
          {"type":"stat","label":"Open applications","value":{"from":"jobs","count":true}},
          {"type":"keyValue","rows":[{"key":"Total salary","value":{"from":"all","sum":"salary","prefix":"$"}},
                                     {"key":"NAS documents","value":{"from":"lab","path":"nas.documents"}}]},
          {"type":"table","title":"Trackers","from":"trackers","columns":[{"title":"Tracker","field":"title"},{"title":"Records","field":"records"}]}]},
        {"title":"Stages","blocks":[
          {"type":"chart","kind":"pie","title":"By stage","from":"all","groupBy":"stage","tones":{"Rejected":"negative"}},
          {"type":"chart","kind":"line","title":"Per day","from":"all","groupBy":"appliedOn","sort":"label"}]}]},
      {"type":"section","title":"Services","blocks":[
        {"type":"table","from":"lab","columns":[{"title":"Service","field":"key"},
          {"title":"Status","field":"ok","labels":{"true":"Up","false":"Down"},"tones":{"true":"positive","false":"negative"}}]}]},
      {"type":"list","title":"Applications","from":"all","titleField":"company","subtitleFields":["stage"],"trailingField":"appliedOn","limit":2},
      {"type":"actions","buttons":[{"kind":"refresh","label":"Refresh"},{"kind":"runTask","label":"Check now","taskID":"\(labCheckID)"},
                                   {"kind":"open","label":"Open status page","url":"https://status.example.com/"},
                                   {"kind":"ask","label":"Summarize","prompt":"Summarize my applications this week."}]}]}
    """

    @MainActor
    static func testHomeViewProtocol() throws {
        precondition(CantripHomeProtocol.kind(forTag: "cantrip-view") == .view)
        precondition(CantripHomeProtocol.kind(forTag: "json cantrip_views") == nil, "tags are matched after json is dropped")
        var reply = "Here's your view.\n\n```cantrip-view\n{\"name\":\"X\"}\n```"
        let blocks = CantripHomeProtocol.extractBlocks(from: &reply)
        precondition(blocks.map(\.kind) == [.view] && !reply.contains("cantrip-view"), "the block is hidden from the reply")
        precondition(CantripHomeProtocol.schema(for: .view).contains("\"data\""))
        precondition(HomeViews.protocolGuidance.contains("cantrip-view"))
    }

    @MainActor
    static func testHomeViewSchema(tasks: [CantripHomeTask]) throws {
        let template = try HomeViewValidation.validated(viewProposal(validView), context: viewContext(tasks))
        precondition(template.name == "Week" && template.data.count == 4 && template.blocks.count == 4)

        func rejects(_ change: (inout [String: Any]) -> Void, _ why: String, status: Int? = nil) throws {
            var object = try JSONSerialization.jsonObject(with: Data(validView.utf8)) as! [String: Any]
            change(&object)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            do {
                _ = try HomeViewValidation.validated(viewProposal(json), context: viewContext(tasks))
                preconditionFailure("accepted a view that \(why)")
            } catch let error as CantripHomeError {
                if let status { precondition(error.status == status, "\(why): got \(error.status) \(error.message)") }
                precondition(CantripHomeProtocol.isCorrectable(error) || error.status == 403, "\(why) gets a repair turn")
            } catch is DecodingError {}
        }
        func setBlocks(_ blocks: [[String: Any]]) -> (inout [String: Any]) -> Void { { $0["blocks"] = blocks } }
        func setSource(_ name: String, _ source: [String: Any]) -> (inout [String: Any]) -> Void {
            { object in var data = object["data"] as! [String: Any]; data[name] = source; object["data"] = data }
        }
        try rejects({ $0["name"] = "" }, "has no name")
        try rejects({ $0["data"] = [String: Any]() }, "has no sources")
        try rejects(setBlocks([["type": "carousel"]]), "uses an unknown block")
        try rejects(setBlocks([["type": "list", "from": "nowhere", "titleField": "company"]]), "reads a source it doesn't define")
        try rejects(setBlocks([["type": "list", "from": "all", "titleField": "ceo"]]), "reads a field the records don't have")
        try rejects(setSource("both", ["records": interviewsID.uuidString, "tasks": [interviewsID.uuidString]]), "gives a source two kinds")
        try rejects(setSource("bad", ["records": UUID().uuidString]), "reads a task that doesn't exist")
        try rejects(setSource("bad", ["records": interviewsID.uuidString, "filter": ["company": ["Acme"]]]), "filters a text field")
        try rejects(setSource("bad", ["tool": ["server": "homelab", "name": "create_issue"]]), "calls a tool that writes")
        try rejects(setSource("bad", ["tool": ["server": "bitwarden", "name": "list_items"]]), "reads a password server")
        try rejects(setSource("bad", ["tool": ["server": "nowhere", "name": "get_status"]]), "calls a server Cantrip doesn't have")
        try rejects(setSource("bad", ["tool": ["server": "homelab", "name": "denied_status"]]), "calls a tool the policy denies", status: 403)
        try rejects(setBlocks([["type": "tabs", "tabs": [["title": "Only", "blocks": [["type": "notice", "title": "Hi"]]]]]]), "has one tab")
        try rejects(setBlocks([["type": "actions", "buttons": [["kind": "open", "label": "Go", "url": "file:///etc/passwd"]]]]), "opens a file URL")
        try rejects(setBlocks([["type": "actions", "buttons": [["kind": "open", "label": "Go", "url": "http://127.0.0.1:8123/"]]]]), "opens a private address")
        try rejects(setBlocks([["type": "actions", "buttons": [["kind": "runTask", "label": "Run", "taskID": notesID.uuidString]]]]),
                    "runs a task with no schedule")
        try rejects(setBlocks([["type": "actions", "buttons": [["kind": "ask", "label": "Ask", "prompt": "Do what we discussed above."]]]]),
                    "asks a question that points back at the chat")
        try rejects(setBlocks([["type": "actions", "buttons": [["kind": "delete", "label": "Delete"]]]]), "has a write action")
        try rejects({ $0["refresh"] = ["everyMinutes": 1] }, "refreshes every minute")
    }

    @MainActor
    static func testHomeViewTypedNumbers(tasks: [CantripHomeTask]) throws {
        func check(_ blocks: String, data: String = #"{"all":{"records":"\#(interviewsID)"}}"#) throws -> HomeViewTemplate {
            try HomeViewValidation.validated(viewProposal(#"{"name":"Typed","data":\#(data),"blocks":\#(blocks)}"#), context: viewContext(tasks))
        }
        func refusesTyped(_ blocks: String, _ why: String) throws {
            do {
                _ = try check(blocks)
                preconditionFailure("accepted a typed value: \(why)")
            } catch let error as CantripHomeError {
                precondition(error.status == 422, "\(why): \(error.message)")
            }
        }
        try refusesTyped(#"[{"type":"stat","label":"Open","value":"42"}]"#, "a stat's value typed as text")
        try refusesTyped(#"[{"type":"stat","label":"Open","value":42}]"#, "a stat's value typed as a number")
        try refusesTyped(#"[{"type":"keyValue","rows":[{"key":"Open","value":"12 jobs"}]}]"#, "a key-value row typed")
        try refusesTyped(#"[{"type":"header","title":"42 open applications"}]"#, "a number in a title")
        try refusesTyped(#"[{"type":"notice","title":"Note","text":"Spent $1,200 so far"}]"#, "a number in a notice")
        try refusesTyped(#"[{"type":"table","from":"all","columns":[{"title":"Company","field":"company","labels":{"Acme":"Acme (3 offers)"}}]}]"#,
                         "a number in a value label")
        // A label may repeat the view's own settings.
        _ = try check(#"[{"type":"list","title":"Next 7 days","from":"soon","titleField":"company"}]"#,
                      data: #"{"soon":{"records":"\#(interviewsID)","dateField":"appliedOn","withinDays":7}}"#)
        _ = try check(#"[{"type":"list","title":"Top 5","from":"all","titleField":"company","limit":5}]"#)
    }

    @MainActor
    static func testHomeViewCheckedRows(tasks: [CantripHomeTask]) throws {
        let output = #"{"results":[{"model":"Laptop A","price":"$1,299","battery":"18 h"},{"model":"Laptop B","price":"$999","battery":"12 h"}]}"#
        let activity = ToolActivity(id: "w1", title: "fetch", toolName: "mcp__web__fetch_page", state: .succeeded,
                                    input: nil, output: output, fileChanges: [])
        let good = #"{"name":"Laptops","data":{"cmp":{"checked":{"tool":"fetch_page"},"rows":[{"model":"Laptop A","price":"$1,299","battery":"18 h"},{"model":"Laptop B","price":"$999","battery":"12 h"}]}},"blocks":[{"type":"table","from":"cmp","columns":[{"title":"Model","field":"model"},{"title":"Price","field":"price"},{"title":"Battery","field":"battery"}]}]}"#
        _ = try HomeViewValidation.validated(viewProposal(good), context: viewContext(tasks, activities: [activity]))
        let invented = good.replacingOccurrences(of: "$999", with: "$899")
        do {
            _ = try HomeViewValidation.validated(viewProposal(invented), context: viewContext(tasks, activities: [activity]))
            preconditionFailure("accepted a price the tool never returned")
        } catch let error as CantripHomeError { precondition(error.status == 422) }
        do {
            _ = try HomeViewValidation.validated(viewProposal(good), context: viewContext(tasks))
            preconditionFailure("accepted rows citing a tool that wasn't called")
        } catch let error as CantripHomeError { precondition(error.status == 422) }
    }

    @MainActor
    static func testHomeViewCards(tasks: [CantripHomeTask]) async throws {
        let views = HomeViews.shared
        let calls = Counter()
        views.callTool = { call in
            await calls.add()
            precondition(call.server == "homelab" && call.name == "homelab_status")
            return #"{"grafana":{"ok":true,"version":"11.2.0"},"nas":{"ok":true,"documents":1234},"router":{"ok":false}}"#
        }
        let saved = try views.apply(viewProposal(validView), activities: [])
        let view = try requireHome(saved.view)
        precondition(saved.notice.contains("View saved") && views.listPayload()["views"] != nil)
        // Before the tool answers, its blocks say so instead of showing anything stale.
        var card = views.card(for: view).card
        precondition(card.blocks.contains { $0.type == "notice" && $0.title == "Loading…" })
        await views.refresh(view.id)
        let firstCalls = await calls.value
        precondition(firstCalls == 1)
        let current = try requireHome(views.find(view.id))
        card = views.card(for: current).card
        precondition(card.id == "view-\(view.id)" && card.type == "view" && card.source?.kind == "view")
        let types = card.blocks.map(\.type)
        precondition(types.first == "header" && types.contains("tabs") && types.contains("section") && types.contains("actions"))
        let tabs = try requireHome(card.blocks.first { $0.type == "tabs" }?.tabs)
        precondition(tabs.map(\.title) == ["Overview", "Stages"] && tabs.map(\.count) == [3, 2], "\(tabs)")
        precondition(card.blocks.first { $0.type == "stat" }?.value == "3", "open = Applied (2) + Interviewing (1)")
        let rows = try requireHome(card.blocks.first { $0.type == "keyValue" }?.rows)
        precondition(rows[0].value == "$460" && rows[1].value == "1,234", "\(rows)")
        let pie = try requireHome(card.blocks.first { $0.kind == "pie" })
        precondition(pie.items?.map(\.label) == ["Applied", "Interviewing", "Rejected"] && pie.items?.map(\.high) == [2, 1, 1]
                     && pie.items?.last?.tone == "negative" && pie.items?.allSatisfy { $0.low == 0 } == true,
                     "choice options order the groups; bars-only clients get low 0")
        let line = try requireHome(card.blocks.first { $0.kind == "line" })
        precondition(line.items?.count == 2 && line.items?.first?.high == 1 && line.items?.last?.high == 2,
                     "records without a date are left out of a line, and days sort in order")
        let services = try requireHome(card.blocks.last { $0.type == "table" })
        precondition(services.tableRows?.map { $0.cells.map(\.text) } == [["grafana", "Up"], ["nas", "Up"], ["router", "Down"]]
                     && services.tableRows?[2].cells[1].tone == "negative", "\(String(describing: services.tableRows))")
        let list = try requireHome(card.blocks.first { $0.type == "list" })
        precondition(list.items?.count == 2 && list.items?.first?.trailing?.contains("Nov") == true)
        let buttons = try requireHome(card.blocks.first { $0.type == "actions" }?.buttons)
        precondition(buttons.map(\.id) == ["a1", "a2", "a3", "a4"] && buttons[1].confirmTitle == "Run Homelab check now?"
                     && buttons[2].confirmTitle == "Open status.example.com?")
        precondition(!views.summary(current).private, "homelab isn't private in this test's Privacy Gate list")
        let preview = views.preview(current)
        precondition(!preview.blocks.contains { $0.type == "actions" } && preview.blocks.count <= 12, "previews carry no buttons")
        precondition(card.plainText.contains("NAS documents: 1,234"))
        // A failing tool shows a warning where its blocks were; the rest of the view still draws.
        views.callTool = { _ in throw HomeViews.Failure(message: "homelab is down") }
        await views.refresh(view.id)
        let failed = views.card(for: try requireHome(views.find(view.id)))
        precondition(failed.problems.isEmpty == false || views.find(view.id)?.fetched["lab"]?.error == "homelab is down")
        // Private servers mark the view.
        views.privateServers = { ["homelab"] }
        let marked = try requireHome(views.find(view.id))
        precondition(views.summary(marked).private)
        views.privateServers = { ["personal"] }
        try views.delete(view.id)
        precondition(views.find(view.id) == nil)
    }

    @MainActor
    static func testHomeViewRunCapture(tasks: [CantripHomeTask]) async throws {
        let views = HomeViews.shared
        let calls = Counter()
        views.callTool = { _ in await calls.add(); return #"{"items":[{"name":"a"}]}"# }
        let json = #"{"name":"Run board","data":{"lab":{"run":{"taskID":"\#(labCheckID)","tool":"homelab_status"}},"svc":{"tool":{"server":"homelab","name":"homelab_status"},"path":"items"}},"refresh":{"afterTasks":["\#(labCheckID)"]},"blocks":[{"type":"stat","label":"Documents","value":{"from":"lab","path":"nas.documents"}},{"type":"list","from":"svc","titleField":"name"}]}"#
        let view = try requireHome(views.apply(viewProposal(json), activities: []).view)
        precondition(views.card(for: view).card.blocks.contains { $0.title == "Waiting for the task's next run." })
        let activity = ToolActivity(id: "r1", title: "status", toolName: "mcp__homelab__homelab_status", state: .succeeded,
                                    input: nil, output: #"{"nas":{"ok":true,"documents":1235}}"#, fileChanges: [])
        views.taskRunFinished(taskID: labCheckID, status: "succeeded", activities: [activity])
        let captured = try requireHome(views.find(view.id))
        precondition(views.card(for: captured).card.blocks.first { $0.type == "stat" }?.value == "1,235")
        var refreshed = await calls.value
        for _ in 0..<50 where refreshed == 0 {
            try await Task.sleep(for: .milliseconds(20))
            refreshed = await calls.value
        }
        precondition(refreshed == 1, "afterTasks refreshes the tool sources once the task's run finishes")
        try views.delete(view.id)
    }

    @MainActor
    static func testHomeViewActions(tasks: [CantripHomeTask]) async throws {
        let views = HomeViews.shared
        let calls = Counter()
        views.callTool = { _ in await calls.add(); return #"{"grafana":{"ok":true}}"# }
        let view = try requireHome(views.apply(viewProposal(validView), activities: []).view)
        await views.refresh(view.id)
        let before = await calls.value
        // Nothing happens until the client confirms.
        do {
            _ = try views.action(viewID: view.id, actionID: "a1", confirmed: false)
            preconditionFailure("an unconfirmed action ran")
        } catch let needed as HomeViews.ConfirmationRequired {
            precondition(needed.button.confirmTitle == "Refresh Week?" && needed.button.kind == "refresh")
        }
        do {
            _ = try views.action(viewID: view.id, actionID: "a9", confirmed: true)
            preconditionFailure("ran a button the view doesn't have")
        } catch let error as CantripHomeError { precondition(error.status == 404) }
        let confirmed = try views.action(viewID: view.id, actionID: "a2", confirmed: true)
        precondition(confirmed.button.kind == "runTask" && confirmed.button.taskID == labCheckID.uuidString)

        // Over the API: 428 without `confirmed` (and no tool call), the refresh with it.
        let previousEnabled = AppSettings.shared.cantripHomeEnabled
        AppSettings.shared.cantripHomeEnabled = true
        defer { AppSettings.shared.cantripHomeEnabled = previousEnabled }
        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager), port = Int.random(in: 20_000...45_000), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        try await waitForRemoteServer(port: port, client: client)
        func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/home/views\(path)")!, timeoutInterval: 30)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }
        let (listed, list) = try await request("")
        precondition(listed == 200 && (list["views"] as? [[String: Any]])?.first?["name"] as? String == "Week")
        let (unchanged, same) = try await request("?revision=\(list["revision"] as! String)")
        precondition(unchanged == 200 && same["unchanged"] as? Bool == true)
        let (detailStatus, detail) = try await request("/\(view.id)")
        precondition(detailStatus == 200 && (detail["card"] as? [String: Any])?["type"] as? String == "view"
                     && detail["refreshAfter"] as? Int == HomeViews.refreshAfter)
        let (refused, confirmation) = try await request("/\(view.id)/actions/a1", method: "POST", body: [:])
        precondition(refused == 428 && (confirmation["confirmation"] as? [String: Any])?["title"] as? String == "Refresh Week?")
        let afterRefusal = await calls.value
        precondition(afterRefusal == before, "an unconfirmed refresh never calls the tool")
        let (done, refreshed) = try await request("/\(view.id)/actions/a1", method: "POST", body: ["confirmed": true])
        precondition(done == 200 && refreshed["result"] as? String == "refreshed" && refreshed["card"] != nil)
        let afterConfirm = await calls.value
        precondition(afterConfirm == before + 1)
        let (opened, link) = try await request("/\(view.id)/actions/a3", method: "POST", body: ["confirmed": true])
        precondition(opened == 200 && link["result"] as? String == "open" && link["url"] as? String == "https://status.example.com/")
        let (pinned, summary) = try await request("/\(view.id)/pin", method: "POST", body: ["pinned": true])
        precondition(pinned == 200 && summary["pinned"] as? Bool == true)
        let pageURL = URL(string: "http://localhost:\(port)/")!
        let (page, _) = try await client.data(from: pageURL)
        try await testRemoteViewsGrid(html: String(decoding: page, as: UTF8.self), baseURL: pageURL)
        let (deleted, _) = try await request("/\(view.id)", method: "DELETE")
        let (gone, _) = try await request("/\(view.id)")
        precondition(deleted == 200 && gone == 404)
    }

    actor Counter {
        private(set) var value = 0
        func add() { value += 1 }
    }
}
