import AppKit
import WebKit

@MainActor
private final class RemoteUpcomingDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { self.error = error }
}

extension SessionTabTests {
    /// The browser remote's Tasks → Upcoming (docs/cantrip-home.md "Upcoming") over synthetic items: when labels in a fixed
    /// time zone, groups with Show all, the collapsible heading with its count, Cancel asking first with the Mac's question
    /// (Keep sends nothing), Resume acting at once, the Mac's message, errors, and a Mac without the list.
    @MainActor
    static func testRemoteUpcoming(html: String, baseURL: URL) async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let delegate = RemoteUpcomingDelegate()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        webView.navigationDelegate = delegate
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer {
            webView.stopLoading()
            window.close()
        }
        webView.loadHTMLString(html, baseURL: baseURL)
        for _ in 0..<200 {
            if delegate.finished || delegate.error != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if let error = delegate.error { throw error }
        precondition(delegate.finished, "Remote web client failed to load within 10 seconds")
        _ = try await webView.callAsyncJavaScript("""
        const check=(value,message)=>{if(!value)throw Error(message)};
        const settle=(ms=80)=>new Promise(resolve=>setTimeout(resolve,ms));

        // When: the viewer's locale and time zone, relative to today (fixed here: en-US, Los Angeles, Wed Nov 18 2026 9:56 AM).
        const zone="America/Los_Angeles",now=new Date("2026-11-18T17:56:00Z"),at=text=>new Date(text).getTime()/1000;
        // ICU versions differ in the space before AM/PM (some use a narrow no-break space).
        const plain=value=>[8239,160].reduce((result,code)=>result.split(String.fromCharCode(code)).join(" "),value);
        for(const [time,label] of [["2026-11-19T06:35:00Z","Today 10:35 PM"],["2026-11-19T11:00:00Z","Tomorrow 3:00 AM"],["2026-11-20T17:50:00Z","Friday 9:50 AM"],
          ["2026-11-24T17:50:00Z","Tuesday 9:50 AM"],["2026-11-25T17:50:00Z","Nov 25, 9:50 AM"],["2027-01-05T17:50:00Z","Jan 5, 2027, 9:50 AM"],["2026-11-18T07:00:00Z","Yesterday 11:00 PM"]])
          check(plain(upcomingWhen(at(time),now,"en-US",zone))===label,`${time} should read ${label}, got ${upcomingWhen(at(time),now,"en-US",zone)}`);
        check(plain(upcomingWhen(at("2026-11-19T07:30:00Z"),now,"en-US","Asia/Tokyo"))==="Today 4:30 PM","Today is the viewer's day, not the Mac's");
        check(upcomingWhen(undefined,now,"en-US",zone)===""&&upcomingWhen(null,now,"en-US",zone)==="","No time, no label");
        check(plain(upcomingMeta({nextRunAt:at("2026-11-19T06:35:00Z"),schedule:"Once",owner:"Kitchen tab"},now,"en-US",zone))==="Today 10:35 PM · Once · Kitchen tab","When, schedule, owner");
        check(upcomingMeta({schedule:"Every 15 minutes",owner:"This Mac"},now,"en-US",zone)==="Every 15 minutes · This Mac","The schedule stands in for the time, once");
        check(upcomingMeta({schedule:"Cantrip Home",owner:"Cantrip Home"},now,"en-US",zone)==="Cantrip Home","Nothing repeats");

        // Groups: the Mac's order, empty groups hidden, Next up cut to 6 until Show all.
        const item=(id,extra={})=>({id,kind:"step",title:`Item ${id}`,schedule:"Once",owner:"Kitchen tab",state:"scheduled",group:"next",canResume:false,...extra});
        const grouped=upcomingSections([...Array.from({length:8},(_,i)=>item(`n${i}`)),item("w",{group:"waiting"}),item("odd",{group:"someday"})],false);
        check(grouped.map(section=>`${section.title}:${section.items.length}/${section.total}`).join()==="Next up:6/9,Waiting:1/1","Next up shows 6 of 9 (an unknown group counts as next), Waiting 1, no Repeating or Paused");
        check(upcomingSections([item("p",{group:"paused"})],true).map(section=>section.title).join()==="Paused"&&upcomingSections([],false).length===0,"Only groups with items");

        // Against a fake Mac.
        const originalAPI=api,originalToken=token,calls=[];const soon=Date.now()/1000+3600;
        let items=[...Array.from({length:8},(_,i)=>item(`step:S${i}`,{title:`Synthetic step ${i}`,nextRunAt:soon+i*600,cancelLabel:"Cancel",confirm:`Cancel “Synthetic step ${i}”? The Kitchen tab won't get this step.`,detail:i===0?"Once the oven is free":undefined})),
          item("wait:W1",{kind:"wait",title:"Wait for the laptop",group:"waiting",state:"waiting",schedule:"Waiting, until Fri Nov 20, 9:50 AM",cancelLabel:"Stop",confirm:"Stop “Wait for the laptop”? It won't do what it was waiting to do."}),
          item("mac:com.example.backup",{kind:"macJob",title:"Example backup",group:"repeating",schedule:"Every 15 minutes",owner:"This Mac",cancelLabel:"Pause",confirm:"Pause “Example backup”?"}),
          item("task:T1",{kind:"task",title:"Synthetic tracker",group:"paused",state:"paused",schedule:"Every day at 8:00 AM",owner:"Cantrip Home",canResume:true})];
        let upcomingStatus=200,actionError=null;
        const task=(id,title)=>({id,title,prompt:"Synthetic.",schedule:{summary:"Every day at 8:00 AM"},hasSchedule:true,enabled:true,state:"succeeded",runs:[],workspace:null});
        try{
          for(const key of ["cantrip.home.views.collapsed","cantrip.home.tasks.collapsed","cantrip.home.upcoming.collapsed"])localStorage.removeItem(key);
          token="upcoming";
          api=async(path,options={})=>{const method=options.method||"GET",bare=path.split("?")[0];calls.push([method,path,options.body||null]);
            if(bare==="/api/v1/home/tasks")return {tasks:[task("T1","Synthetic tracker")],revision:"tr-1",error:null};
            if(bare==="/api/v1/home/upcoming"){if(upcomingStatus!==200){const error=Error("not found");error.status=upcomingStatus;throw error}
              const revision=`ur-${items.length}-${items.map(entry=>entry.group).join("")}`;return path.includes(`revision=${revision}`)?{unchanged:true,revision}:{items:JSON.parse(JSON.stringify(items)),revision}}
            if(method==="POST"&&(bare==="/api/v1/home/upcoming/cancel"||bare==="/api/v1/home/upcoming/resume")){if(actionError){const error=Error(actionError);error.status=409;throw error}
              const id=JSON.parse(options.body).id,target=items.find(entry=>entry.id===id);
              if(bare.endsWith("/cancel"))items=items.filter(entry=>entry.id!==id);
              else items=[{...target,group:"next",state:"scheduled",canResume:false,cancelLabel:"Pause",nextRunAt:soon-60},...items.filter(entry=>entry.id!==id)];
              return {items:JSON.parse(JSON.stringify(items)),revision:"after",message:`${bare.endsWith("/cancel")?"Cancelled":"Resumed"} “${target.title}”.`}}
            throw Error(`unexpected ${method} ${path}`)};
          const body=$("tasksBody"),toggle=name=>body.querySelector(`[data-focus-key="section:${name}"]`),rows=()=>Array.from(body.querySelectorAll(".upcoming-row"));
          const posts=()=>calls.filter(([method])=>method==="POST");
          openTasks();await loadTasks();await settle(200);
          const heading=toggle("upcoming"),section=body.querySelector(".upcoming-section");
          check(heading&&section.nextElementSibling?.classList.contains("tasks-section"),"Upcoming sits right above Tasks");
          check(heading.getAttribute("aria-label")==="Upcoming, 11 items"&&heading.textContent.replace(/[^A-Za-z0-9·]/g,"")==="Upcoming·11"&&heading.getAttribute("aria-expanded")==="true","The heading shows its count and names it");
          check(toggle("tasks")?.getAttribute("aria-label")==="Tasks, 1 task","With Upcoming, Tasks gets its own heading");
          check(Array.from(body.querySelectorAll(".upcoming-group-title")).map(node=>node.textContent).join()==="Next up,Waiting,Repeating,Paused","Group headings in order");
          check(rows().length===9&&body.querySelector("#upcomingGroup-next + .upcoming-list").getAttribute("aria-labelledby")==="upcomingGroup-next","Next up shows 6 of 8, plus Waiting, Repeating and Paused");
          const first=rows()[0];
          check(first.querySelector(".upcoming-title").textContent==="Synthetic step 0"&&/^Today|^Tomorrow/.test(first.querySelector(".upcoming-meta").textContent)&&first.querySelector(".upcoming-meta").textContent.endsWith(" · Once · Kitchen tab")
                &&first.querySelector(".upcoming-detail").textContent==="Once the oven is free","A row: title, when · schedule · owner, then its detail");
          check(rows()[7].querySelector(".upcoming-meta").textContent==="Every 15 minutes · This Mac","Without a time the schedule leads");
          const buttons=rows().map(row=>row.querySelector(".upcoming-action")?.textContent||"").join();
          check(buttons==="Cancel,Cancel,Cancel,Cancel,Cancel,Cancel,Stop,Pause,Resume","Each row's button is its cancelLabel, or Resume");
          check(first.querySelector(".upcoming-action").getAttribute("aria-label")==="Cancel Synthetic step 0","Buttons name their item");
          const more=body.querySelector(".upcoming-more");
          check(more.textContent==="Show all 8"&&more.getAttribute("aria-label")==="Show all 8 in Next up","Show all N");
          more.click();await settle();
          check(rows().length===11&&!body.querySelector(".upcoming-more")&&document.activeElement===rows()[6],"Show all lists the rest and focuses the first new row");

          // Polling with the revision; an unchanged list redraws nothing.
          const before=calls.length;await loadTasks();await settle();
          check(calls.slice(before).some(([,path])=>path.startsWith("/api/v1/home/upcoming?revision=ur-11-")),"The poll sends the last revision");

          // Cancel asks first with the Mac's question; Keep sends nothing.
          const dialog=$("viewConfirm");rows()[1].querySelector(".upcoming-action").click();await settle();
          check(dialog.open&&$("viewConfirmTitle").textContent==="Cancel “Synthetic step 1”? The Kitchen tab won't get this step."&&$("viewConfirmGo").textContent==="Cancel"&&$("viewConfirmCancel").textContent==="Keep"
                &&document.activeElement===$("viewConfirmCancel"),"The dialog asks the Mac's question with Cancel and Keep, Keep focused");
          $("viewConfirmCancel").click();await settle();
          check(!dialog.open&&!posts().length&&rows().length===11&&$("viewConfirmCancel").textContent==="Cancel","Keep sends nothing and leaves the dialog as views use it");
          check(document.activeElement?.dataset.focusKey==="upcoming:step:S1","Focus returns to the button");
          rows()[1].querySelector(".upcoming-action").click();await settle();$("viewConfirmGo").click();await settle(200);
          check(posts().length===1&&posts()[0][1]==="/api/v1/home/upcoming/cancel"&&JSON.parse(posts()[0][2]).id==="step:S1","Cancel posts the item's id");
          check(rows().length===10&&!rows().some(row=>row.dataset.focusKey==="upcoming-row:step:S1")&&toggle("upcoming").textContent.includes("10"),"The list comes from the answer");
          check(body.querySelector(".upcoming-note")?.textContent==="Cancelled “Synthetic step 1”."&&$("tasksStatus").textContent==="Cancelled “Synthetic step 1”.","The Mac's message shows and is read out");
          check(document.activeElement?.dataset.focusKey==="upcoming-row:step:S2","Focus moves to the next item");

          // Stop on a wait: the same dialog with Stop.
          rows().find(row=>row.dataset.focusKey==="upcoming-row:wait:W1").querySelector(".upcoming-action").click();await settle();
          check($("viewConfirmGo").textContent==="Stop"&&$("viewConfirmTitle").textContent.startsWith("Stop “Wait for the laptop”?"),"Stop asks with Stop");
          $("viewConfirmCancel").click();await settle();check(posts().length===1,"Keep again sends nothing");

          // Resume acts at once.
          const resume=rows().find(row=>row.dataset.focusKey==="upcoming-row:task:T1").querySelector(".upcoming-action");resume.focus();resume.click();await settle(200);
          check(!dialog.open&&posts().length===2&&posts()[1][1]==="/api/v1/home/upcoming/resume"&&JSON.parse(posts()[1][2]).id==="task:T1","Resume posts without asking");
          check(rows()[0].dataset.focusKey==="upcoming-row:task:T1"&&rows()[0].querySelector(".upcoming-action").textContent==="Pause"&&!Array.from(body.querySelectorAll(".upcoming-group-title")).some(node=>node.textContent==="Paused"),
                "The resumed task moves to Next up with Pause; the empty Paused group goes");
          check(document.activeElement?.dataset.focusKey==="upcoming:task:T1","Focus follows the item's button");

          // An error shows and keeps the list.
          actionError="That step already ran.";rows()[1].querySelector(".upcoming-action").click();await settle();$("viewConfirmGo").click();await settle(200);
          check($("tasksError").textContent==="Couldn't cancel “Synthetic step 0”: That step already ran."&&rows().length===10,"Errors show; the list stays");
          actionError=null;setText($("tasksError"),"");

          // Collapsing is remembered; the count still shows.
          toggle("upcoming").click();await settle();
          check(localStorage.getItem("cantrip.home.upcoming.collapsed")==="1"&&$("upcomingSectionBody").hidden&&!rows().length&&toggle("upcoming").getAttribute("aria-expanded")==="false","Collapsing Upcoming stores it");
          $("tasksDone").click();await settle();openTasks();await loadTasks();await settle(200);
          check(toggle("upcoming").getAttribute("aria-expanded")==="false"&&!rows().length,"A fresh render reads it back");
          toggle("upcoming").click();await settle();
          check(localStorage.getItem("cantrip.home.upcoming.collapsed")==="0"&&rows().length===8&&body.querySelector(".upcoming-more")?.textContent==="Show all 8","Expanding shows it again, Next up cut to 6");

          // Nothing scheduled.
          items=[];await loadTasks();await settle(200);
          check(body.querySelector(".upcoming-empty")?.textContent==="Nothing scheduled"&&toggle("upcoming").getAttribute("aria-label")==="Upcoming, 0 items","Empty state");

          // A Mac without Upcoming: no section, no headings, and no more asking.
          $("tasksDone").click();await settle();upcomingStatus=404;openTasks();await loadTasks();await settle(200);
          check(!toggle("upcoming")&&!toggle("tasks")&&body.querySelectorAll(".task-card").length===1,"Without the list, Tasks shows as before");
          const asked=calls.filter(([,path])=>path.startsWith("/api/v1/home/upcoming")).length;await loadTasks();await settle();
          check(calls.filter(([,path])=>path.startsWith("/api/v1/home/upcoming")).length===asked,"A 404 isn't asked again while Tasks stays open");
        }finally{
          if($("viewConfirm").open)$("viewConfirm").close();if($("tasksPanel").open)$("tasksPanel").close();closeTasks();
          for(const key of ["cantrip.home.views.collapsed","cantrip.home.tasks.collapsed","cantrip.home.upcoming.collapsed"])localStorage.removeItem(key);
          api=originalAPI;token=originalToken;
        }
        """, arguments: [:], in: nil, contentWorld: .page)
        print("Remote upcoming: when labels, groups, Show all, confirm, cancel/resume and an older Mac passed")
    }
}
