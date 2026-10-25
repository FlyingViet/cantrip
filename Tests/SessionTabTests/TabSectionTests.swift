import Foundation
import WebKit

extension SessionTabTests {
    @MainActor
    static func testTabSections() async throws {
        let manager = SessionManager()
        let a = manager.newSession(), b = manager.newSession(), c = manager.newSession(), d = manager.newSession()
        func order() -> [UUID] { manager.sessions.map(\.id).filter { [a.id, b.id, c.id, d.id].contains($0) } }

        let work = try manager.createSection(named: "  Work \n stuff ")
        precondition(work.name == "Work stuff", "names are trimmed and collapsed")
        for (name, error) in [("work STUFF", TabSectionError.duplicate), (" \n", .emptyName),
                              (String(repeating: "x", count: 41), .nameTooLong)] {
            do {
                try manager.createSection(named: name)
                preconditionFailure("\(name) must be rejected")
            } catch let thrown as TabSectionError { precondition(thrown == error) }
        }
        let personal = try manager.createSection(named: "Personal")
        precondition(manager.tabSections.map(\.id) == [work.id, personal.id])

        // Filing a tab puts it after the section's last tab.
        try manager.setSection(work.id, for: a.id)
        precondition(manager.sectionID(of: a) == work.id && order() == [a.id, b.id, c.id, d.id])
        try manager.setSection(work.id, for: c.id)
        precondition(order() == [a.id, c.id, b.id, d.id], "c follows a, the section's last tab")
        // Dropping a tab beside another adopts that tab's section; beside an unfiled one, none.
        try manager.moveSession(d.id, relativeTo: c.id, after: true)
        precondition(manager.sectionID(of: d) == work.id && order() == [a.id, c.id, d.id, b.id])
        try manager.moveSession(c.id, relativeTo: b.id, after: true)
        precondition(manager.sectionID(of: c) == nil && order() == [a.id, d.id, b.id, c.id])
        do {
            try manager.setSection(work.id, for: manager.homeSession.id)
            preconditionFailure("Home's reserved session can't be filed")
        } catch let error as TabSectionError { precondition(error == .notAllowed || error == .unavailable) }
        catch SessionTabError.unavailable {}
        do {
            try manager.setSection(UUID(), for: a.id)
            preconditionFailure("an unknown section is rejected")
        } catch TabSectionError.unavailable {}

        try manager.renameSection(personal.id, to: "Home stuff")
        do {
            try manager.renameSection(personal.id, to: "WORK STUFF")
            preconditionFailure("renaming to another section's name is rejected")
        } catch TabSectionError.duplicate {}
        try manager.moveSection(personal.id, to: 0)
        precondition(manager.tabSections.map(\.name) == ["Home stuff", "Work stuff"])
        try manager.moveSection(personal.id, to: 99)
        precondition(manager.tabSections.map(\.name) == ["Work stuff", "Home stuff"], "positions are clamped")

        let filed = try manager.newSession(inSection: personal.id)
        precondition(manager.sectionID(of: filed) == personal.id)

        // Sections and filing survive a relaunch.
        let restored = SessionManager()
        precondition(restored.tabSections == manager.tabSections)
        precondition(restored.sessions.first { $0.id == d.id }.map(restored.sectionID(of:)) == work.id)

        try manager.deleteSection(work.id)
        precondition(manager.sectionID(of: a) == nil && manager.sectionID(of: d) == nil && a.tabMetadata.sectionID == nil,
                     "deleting a section returns its tabs to Tabs")

        // Edit Sections drags: onMove's destination counts rows before the move.
        let one = try manager.createSection(named: "One"), two = try manager.createSection(named: "Two")
        let names = { manager.tabSections.map(\.name) }
        let start = manager.tabSections.firstIndex { $0.id == one.id }!
        try manager.moveSection(one.id, to: TabSectionStore.position(movingFrom: start, to: start + 2))
        precondition(names() == ["Home stuff", "Two", "One"], "dragging a row below the next one moves it down one: \(names())")
        let now = manager.tabSections.firstIndex { $0.id == one.id }!
        try manager.moveSection(one.id, to: TabSectionStore.position(movingFrom: now, to: now - 1))
        precondition(names() == ["Home stuff", "One", "Two"], "dragging a row above the previous one moves it up one: \(names())")
        precondition(TabSectionStore.position(movingFrom: 2, to: 2) == 2 && TabSectionStore.position(movingFrom: 2, to: 3) == 2,
                     "dropping a row on itself keeps its place")
        try manager.deleteSection(one.id)
        try manager.deleteSection(two.id)

        // An empty section persists across a relaunch, shows as its own group, and takes tabs later.
        let later = try manager.createSection(named: "Later")
        precondition(SessionManager().tabSections.contains(later), "an empty section persists")
        precondition(manager.tabSectionGroups()?.contains { $0.section == later && $0.sessions.isEmpty } == true,
                     "an empty section still shows as a group")
        let kept = manager.newSession()
        kept.messages = [ChatMessage(role: .user, text: "Keep this history")]
        try manager.setSection(later.id, for: kept.id)
        precondition(manager.sectionID(of: kept) == later.id)

        // The panel strip follows the groups (Tabs, then sections in order); a collapsed section
        // keeps only its open, working and waiting tabs; each Mac remembers what it collapsed.
        let groups = manager.tabSectionGroups()!
        precondition(groups.first?.section == nil && groups.dropFirst().map { $0.section?.id } == manager.tabSections.map(\.id))
        precondition(manager.panelTabs(collapsed: []).map(\.id) == groups.flatMap { $0.sessions.map(\.id) },
                     "the panel's order (and ⌘2-⌘9) follows the groups")
        manager.select(kept.id)
        precondition(manager.panelTabs(collapsed: [later.id.uuidString]).contains { $0.id == kept.id }, "the open tab stays visible")
        manager.select(a.id)
        precondition(!manager.panelTabs(collapsed: [later.id.uuidString]).contains { $0.id == kept.id }, "idle tabs fold away")
        kept.isStreaming = true
        precondition(manager.panelTabs(collapsed: [later.id.uuidString]).contains { $0.id == kept.id }, "working tabs stay visible")
        kept.isStreaming = false
        let collapseDefaults = UserDefaults(suiteName: "cantrip-tab-section-collapse-test")!
        collapseDefaults.removePersistentDomain(forName: "cantrip-tab-section-collapse-test")
        TabSectionCollapse(defaults: collapseDefaults).toggle(later.id.uuidString)
        precondition(TabSectionCollapse(defaults: collapseDefaults).collapsed == [later.id.uuidString], "collapse is remembered")
        collapseDefaults.removePersistentDomain(forName: "cantrip-tab-section-collapse-test")

        // Deleting a section never closes its tabs or loses their history.
        try manager.deleteSection(later.id)
        precondition(manager.sessions.contains { $0.id == kept.id } && manager.sectionID(of: kept) == nil
                     && kept.messages.map(\.text) == ["Keep this history"], "deleting a section keeps its tabs and history")
        manager.close(kept.id)

        // Remote API.
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        func call(_ path: String, method: String = "GET", body: Any? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            request.timeoutInterval = 3
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }
        func sectionNames(_ body: [String: Any]) -> [String] {
            (body["sections"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }

        let created = try await call("/api/v1/sections", method: "POST", body: ["name": "Clients"])
        precondition(created.0 == 201 && sectionNames(created.1) == ["Home stuff", "Clients"])
        let clientsID = (created.1["section"] as? [String: Any])?["id"] as? String
        precondition(clientsID.flatMap(UUID.init(uuidString:)) != nil)
        let status1 = try await call("/api/v1/sections", method: "POST", body: ["name": "clients"]).0
        precondition(status1 == 409)
        let status2 = try await call("/api/v1/sections", method: "POST", body: ["title": "x"]).0
        precondition(status2 == 400)
        let status3 = try await call("/api/v1/sections", method: "PUT").0
        precondition(status3 == 405)

        let listed = try await call("/api/v1/sessions")
        precondition(listed.1["supportsTabSections"] as? Bool == true && sectionNames(listed.1) == ["Home stuff", "Clients"])
        let rows = listed.1["sessions"] as? [[String: Any]] ?? []
        precondition(rows.first { $0["id"] as? String == filed.id.uuidString }?["sectionID"] as? String
                     == personal.id.uuidString)
        precondition(rows.first { $0["id"] as? String == a.id.uuidString }?["sectionID"] == nil)
        precondition(rows.allSatisfy { $0["supportsTabSections"] as? Bool == true })

        // File through tab metadata; null returns it to Tabs.
        let metadata = "/api/v1/sessions/\(b.id.uuidString)/metadata"
        let filedB = try await call(metadata, method: "POST", body: ["sectionID": clientsID!])
        precondition(filedB.0 == 200 && manager.sectionID(of: b)?.uuidString == clientsID)
        let status4 = try await call(metadata, method: "POST", body: ["sectionID": UUID().uuidString]).0
        precondition(status4 == 404)
        let status5 = try await call(metadata, method: "POST", body: ["sectionID": 7]).0
        precondition(status5 == 400)
        let cleared = try await call(metadata, method: "POST", body: ["sectionID": NSNull()]).0
        precondition(cleared == 200 && manager.sectionID(of: b) == nil)

        let newTab = try await call("/api/v1/sessions", method: "POST", body: ["sectionID": clientsID!])
        let newID = (newTab.1["session"] as? [String: Any])?["id"] as? String ?? newTab.1["id"] as? String
        precondition(newTab.0 == 201 && manager.sessions.first { $0.id.uuidString == newID }.map(manager.sectionID(of:))??
                     .uuidString == clientsID, "a new tab can start in a section")
        let status6 = try await call("/api/v1/sessions", method: "POST", body: ["sectionID": "nope"]).0
        precondition(status6 == 400)

        let renamed = try await call("/api/v1/sections/\(clientsID!)", method: "PATCH", body: ["name": "Clients 2", "position": 0])
        precondition(renamed.0 == 200 && sectionNames(renamed.1) == ["Clients 2", "Home stuff"])
        let status7 = try await call("/api/v1/sections/\(clientsID!)", method: "PATCH", body: ["position": true]).0
        precondition(status7 == 400)
        let status8 = try await call("/api/v1/sections/\(UUID().uuidString)", method: "PATCH", body: ["name": "x"]).0
        precondition(status8 == 404)

        let deleted = try await call("/api/v1/sections/\(clientsID!)", method: "DELETE")
        precondition(deleted.0 == 200 && sectionNames(deleted.1) == ["Home stuff"] && deleted.1["sessions"] != nil)
        precondition(manager.sessions.first { $0.id.uuidString == newID }.map(manager.sectionID(of:)) == .some(nil))
    }

    /// The browser Remote's tab list with sections (called for both the strip and sidebar layouts).
    @MainActor
    static func testRemoteTabSections(webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript("""
        const originalAPI=api,originalRefresh=refresh,settle=()=>new Promise(resolve=>setTimeout(resolve,20));
        let calls=[];
        refresh=()=>Promise.resolve();
        api=(path,options={})=>{calls.push({path,method:options.method||"GET",body:options.body?JSON.parse(options.body):null});
          if(path==="/api/v1/sections"&&options.method==="POST")return Promise.resolve({section:{id:"s-new",name:"Clients"},sections:[...tabSections,{id:"s-new",name:"Clients"}]});
          return Promise.resolve({sessions:[],sections:tabSections,session:{id:"t-new"}})};
        const tab=(id,extra={})=>({id,title:id.toUpperCase(),supportsTabMetadata:true,supportsTabReordering:true,supportsTabSections:true,...extra});
        const items=[{id:"h",title:"Home",isCantripHome:true},tab("a"),tab("b",{sectionID:"s1"}),tab("c",{sectionID:"s1",isStreaming:true}),tab("d",{sectionID:"gone"})];
        const keys=()=>Array.from(nav.children,node=>node.dataset.sessionId||"#"+node.dataset.sectionId).join();
        try{
          localStorage.removeItem("cantrip.collapsedSections");collapsedSections=new Set();sectionsSupported=true;
          tabSections=[];selected="a";renderSessions(items);
          check(keys()==="h,a,b,c,d"&&!nav.querySelector(".section-header"),"Without sections the list is unchanged");
          tabSections=[{id:"s1",name:"Work"},{id:"s2",name:"Empty"}];renderSessions(items);
          check(keys()==="h,#tabs,a,d,#s1,b,c,#s2","Home, then Tabs (with tabs of deleted sections), then sections in order: "+keys());
          const work=nav.querySelector('[data-section-id="s1"]'),buttonA=nav.querySelector('[data-session-id="a"]').children[0];
          check(work.querySelector(".section-name").textContent==="▾ Work"&&work.querySelector(".section-count").textContent==="2","Header shows name and count");
          work.children[0].click();
          check(keys()==="h,#tabs,a,d,#s1,c,#s2","Collapsing hides idle tabs and keeps working ones: "+keys());
          check(JSON.parse(localStorage.getItem("cantrip.collapsedSections")).includes("s1"),"Collapse is remembered on this device");
          check(work.children[0].getAttribute("aria-expanded")==="false"&&nav.querySelector('[data-session-id="a"]').children[0]===buttonA,"Header reports its state; other tabs stay mounted");
          renderSessions(items);check(nav.querySelector('[data-section-id="s1"]')===work,"Polling keeps headers mounted");
          selected="b";renderSessions(items);check(keys().includes("#s1,b,c"),"The open tab shows in a collapsed section");
          selected="a";work.children[0].click();check(keys()==="h,#tabs,a,d,#s1,b,c,#s2","Expanding shows every tab");

          const transfer=new DataTransfer();
          nav.querySelector('[data-session-id="a"]').dispatchEvent(new DragEvent("dragstart",{bubbles:true,cancelable:true,dataTransfer:transfer}));
          const empty=nav.querySelector('[data-section-id="s2"]'),over=new DragEvent("dragover",{bubbles:true,cancelable:true,dataTransfer:transfer});
          empty.dispatchEvent(over);check(over.defaultPrevented&&empty.classList.contains("drop-target"),"Headers accept dropped tabs");
          empty.dispatchEvent(new DragEvent("drop",{bubbles:true,cancelable:true,dataTransfer:transfer}));await settle();
          check(calls.some(call=>call.path==="/api/v1/sessions/a/metadata"&&call.body.sectionID==="s2"),"Dropping on a header files the tab there");

          calls=[];editTab(items[1]);
          check(!$("tabSectionLabel").classList.contains("hidden")&&Array.from($("tabSection").options,option=>option.textContent).join()==="Tabs,Work,Empty,New section…","Tab settings list the sections");
          $("tabSection").value="new";$("tabSection").dispatchEvent(new Event("change"));
          check(!$("tabNewSection").classList.contains("hidden"),"New section asks for a name");
          $("tabNewSection").value="Clients";$("tabForm").requestSubmit();await settle();
          check(calls[0]?.path==="/api/v1/sections"&&calls[0].body.name==="Clients"&&calls[1]?.path==="/api/v1/sessions/a/metadata"&&calls[1].body.sectionID==="s-new","A new section from tab settings files the tab in it");

          calls=[];tabSections=[{id:"s1",name:"Work"},{id:"s2",name:"Empty"}];renderSessions(items);
          nav.querySelector('[data-section-id="s1"] .section-menu').click();
          check($("sectionEditor").open&&$("sectionName").value==="Work"&&$("sectionUp").disabled&&!$("sectionDown").disabled,"The section menu opens with its order limits");
          $("sectionDown").click();await settle();
          check(calls[0]?.path==="/api/v1/sections/s1"&&calls[0].method==="PATCH"&&calls[0].body.position===1,"Move Down patches the position");

          calls=[];renderSessions(items);
          const s1=nav.querySelector('[data-section-id="s1"]'),s2=nav.querySelector('[data-section-id="s2"]'),loose=nav.querySelector('[data-section-id="tabs"]'),sectionDrag=new DataTransfer();
          check(s1.draggable&&s2.draggable&&!loose.draggable,"Sections drag; Tabs stays first");
          check(s1.children[0].getAttribute("aria-keyshortcuts")&&!loose.children[0].hasAttribute("aria-keyshortcuts"),"Section headers announce their move keys");
          s2.dispatchEvent(new DragEvent("dragstart",{bubbles:true,cancelable:true,dataTransfer:sectionDrag}));
          const ontoSection=new DragEvent("dragover",{bubbles:true,cancelable:true,dataTransfer:sectionDrag});s1.dispatchEvent(ontoSection);
          check(ontoSection.defaultPrevented&&s1.classList.contains("drop-target"),"Section headers accept a dragged section");
          const ontoTab=new DragEvent("dragover",{bubbles:true,cancelable:true,dataTransfer:sectionDrag});nav.querySelector('[data-session-id="b"]').dispatchEvent(ontoTab);
          check(!ontoTab.defaultPrevented,"Tabs don't accept a dragged section");
          renderSessions([...items,tab("e",{sectionID:"s2"})]);check(!keys().includes(",e"),"Polling waits while a section is dragged");
          s1.dispatchEvent(new DragEvent("drop",{bubbles:true,cancelable:true,dataTransfer:sectionDrag}));await settle();
          check(calls[0]?.path==="/api/v1/sections/s2"&&calls[0].method==="PATCH"&&calls[0].body.position===0,"Dropping a section on another takes its place");
          calls=[];s2.dispatchEvent(new DragEvent("dragstart",{bubbles:true,cancelable:true,dataTransfer:sectionDrag}));
          loose.dispatchEvent(new DragEvent("drop",{bubbles:true,cancelable:true,dataTransfer:sectionDrag}));await settle();
          check(calls[0]?.body.position===0,"Dropping a section on Tabs moves it first");
          calls=[];s1.children[0].dispatchEvent(new KeyboardEvent("keydown",{key:sidebarLayout?"ArrowDown":"ArrowRight",altKey:true,bubbles:true,cancelable:true}));await settle();
          check(calls[0]?.path==="/api/v1/sections/s1"&&calls[0].body.position===1,"Alt+arrow moves a section without dragging");
          check(document.activeElement===s1.children[0],"The moved header keeps keyboard focus");
          calls=[];s2.children[0].dispatchEvent(new KeyboardEvent("keydown",{key:sidebarLayout?"ArrowDown":"ArrowRight",altKey:true,bubbles:true,cancelable:true}));await settle();
          check(calls.length===0,"The last section can't move further down");
          nav.querySelector('[data-section-id="tabs"] .section-menu').click();
          check($("sectionEditorTitle").textContent==="New section"&&$("sectionActions").classList.contains("hidden"),"The Tabs header creates sections");
          $("sectionCancel").click();

          calls=[];check($("newSection").getAttribute("aria-label")==="New section","The tab list has a labeled New section button");
          $("newSection").click();
          check($("sectionEditor").open&&$("sectionEditorTitle").textContent==="New section"&&$("sectionName").value==="","New section opens an empty name prompt");
          $("sectionName").value="Later";$("sectionForm").requestSubmit();await settle();
          check(calls.length===1&&calls[0].path==="/api/v1/sections"&&calls[0].method==="POST"&&calls[0].body.name==="Later","New section creates an empty section without filing a tab");

          calls=[];renderSessions(items);nav.querySelector('[data-section-id="s1"] .section-menu').click();
          $("sectionDelete").click();await settle();
          check(calls.length===0&&$("sectionEditor").open&&$("sectionDelete").textContent==="Confirm Delete"&&$("sectionNote").textContent.includes("2 tabs move back to Tabs"),"Deleting a section with tabs asks first");
          $("sectionDelete").click();await settle();
          check(calls[0]?.path==="/api/v1/sections/s1"&&calls[0].method==="DELETE","Confirming deletes it");
          calls=[];renderSessions(items);nav.querySelector('[data-section-id="s2"] .section-menu').click();
          check($("sectionDelete").textContent==="Delete Section","The confirmation resets for the next section");
          $("sectionDelete").click();await settle();
          check(calls[0]?.path==="/api/v1/sections/s2"&&calls[0].method==="DELETE","An empty section deletes at once");
          editTab({...items[1],supportsTabSections:false});check($("tabSectionLabel").classList.contains("hidden"),"Tabs that can't be filed hide the picker");$("tabCancel").click();
        }finally{
          api=originalAPI;refresh=originalRefresh;tabSections=[];sectionsSupported=false;collapsedSections=new Set();localStorage.removeItem("cantrip.collapsedSections");
          if($("tabEditor").open)$("tabEditor").close();if($("sectionEditor").open)$("sectionEditor").close();editingTab=null;editingSection=null;selected=null;renderSessions([]);
        }
        """, arguments: [:], in: nil, contentWorld: .page)
    }
}
