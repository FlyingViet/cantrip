import AppKit
import WebKit

@MainActor
private final class RemoteViewsGridDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { self.error = error }
}

extension SessionTabTests {
    /// The browser remote's Tasks → Views grid: the shared column function, previews chosen from flat resolved cards
    /// (shapes from the views QA host), collapsible Views/Tasks sections remembered in localStorage, and the thumbnail
    /// fetch policy (GET only, at most 2 at a time, cached until the view changes or its refreshAfter passes).
    @MainActor
    static func testRemoteViewsGrid(html: String, baseURL: URL) async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let delegate = RemoteViewsGridDelegate()
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
        for(const [width,columns] of [[320,1],[375,2],[599,3],[600,2],[700,2],[1000,4],[1600,6],[2000,6]])
          check(viewsGridColumns(width)===columns,`columns(${width}) should be ${columns}, got ${viewsGridColumns(width)}`);

        // previewBlocks over flat resolved cards (the views QA host's synthetic This week, Homelab, Bills and Trips).
        const stat=(label,value)=>({type:"stat",label,value,accessibilityLabel:`${label}, ${value}`});
        const items=n=>Array.from({length:n},(_,i)=>({label:`Item ${i+1}`,high:i+1,highText:String(i+1),low:0}));
        const rows=n=>Array.from({length:n},(_,i)=>({id:`row-${i}`,cells:[{text:`Trip ${i+1}`},{text:"Scheduled"}]}));
        const table={type:"table",title:"Trips",columns:[{title:"Trip"},{title:"Status"}],tableRows:rows(5)};
        const actions={type:"actions",buttons:[{id:"a1",kind:"refresh",label:"Refresh"}]};
        const week={blocks:[{type:"header",title:"This week"},{type:"tabs",tabs:[{title:"Overview",count:3},{title:"Interviews",count:2},{title:"Bills",count:1}]},
          stat("Active interview loops","6"),{type:"keyValue",rows:[{key:"Follow-ups",value:"3"}]},table,
          {type:"chart",kind:"pie",title:"By stage",items:items(4)},{type:"chart",kind:"line",title:"Per day",items:items(5)},{type:"chart",kind:"bar",title:"By category",items:items(3)},actions]};
        const homelab={blocks:[{type:"header",title:"Homelab"},stat("Services up","2"),{type:"section",title:"Services"},table,{type:"keyValue",rows:[{key:"NAS documents",value:"1,234"}]},actions]};
        const bills={blocks:[{type:"header",title:"Bills"},stat("Due soon","6"),stat("Active","13"),{type:"chart",kind:"bar",title:"By category",items:items(3)}]};
        const shape=blocks=>blocks.map(block=>block.label||block.title||block.type).join("|");
        check(shape(viewPreviewBlocks(week))==="Active interview loops","This week shows only its first tab's stat: the charts belong to other tabs");
        check(shape(viewPreviewBlocks(homelab))==="Services up","Homelab shows its stat");
        check(shape(viewPreviewBlocks(bills))==="Due soon|Active|By category","Two stats and the first chart");
        check(shape(viewPreviewBlocks({blocks:[{type:"chart",kind:"line",title:"Line",items:items(2)},stat("A","1"),stat("B","2"),stat("C","3"),{type:"chart",kind:"pie",title:"Pie",items:items(2)}]}))==="Line|A|B",
              "At most 2 stats and the first chart, in document order");
        const trips=viewPreviewBlocks({blocks:[{type:"header",title:"Trips"},table]});
        check(trips.length===1&&trips[0].type==="table"&&trips[0].tableRows.length===3&&table.tableRows.length===5,"Without stats or charts, the first table trimmed to 3 rows (the card itself unchanged)");
        const listed=viewPreviewBlocks({blocks:[{type:"section",title:"People"},{type:"list",items:Array.from({length:6},(_,i)=>({title:`Person ${i}`}))},{type:"keyValue",rows:[{key:"k",value:"v"}]}]});
        check(listed.length===1&&listed[0].type==="list"&&listed[0].items.length===3,"A section's contents are its following blocks: the list, trimmed to 3 items");
        const pairs=viewPreviewBlocks({blocks:[{type:"notice",title:"Note"},{type:"keyValue",rows:[1,2,3,4].map(n=>({key:`Key ${n}`,value:String(n)}))}]});
        check(pairs.length===1&&pairs[0].rows.length===3,"keyValue fallback trimmed to 3 rows");
        check(shape(viewPreviewBlocks({blocks:[{type:"tabs",tabs:[{title:"First",count:1},{title:"Second",count:2}]},table,stat("Hidden","9"),{type:"chart",kind:"bar",items:items(2)}]}))==="Trips",
              "Later tabs' stats and charts never show; the first tab's table does");
        check(viewPreviewBlocks({blocks:["header","section","actions","notice","badges","progress","image","map"].map(type=>({type,title:"x"}))}).length===0&&viewPreviewBlocks({}).length===0,
              "Header, section, actions, notice, badges, progress, image and map are skipped");

        // Fetch policy: cache hit, updatedAt/refreshedAt changes, refreshAfter elapsed, and 30 s after a failure.
        const summary={id:"v1",updatedAt:"2026-11-17T20:00:00Z",refreshedAt:"2026-11-17T20:05:00Z"},now=5000000;
        const cached={data:{view:{...summary},card:{blocks:[]},refreshAfter:60},fetchedAt:now-10000,failed:false};
        check(viewThumbDue(undefined,summary,now),"No cached detail: fetch");
        check(!viewThumbDue(cached,summary,now),"Cached and unchanged: no fetch");
        check(viewThumbDue(cached,{...summary,updatedAt:"2026-11-17T21:00:00Z"},now),"A changed updatedAt fetches again");
        check(viewThumbDue(cached,{...summary,refreshedAt:"2026-11-17T21:00:00Z"},now),"A changed refreshedAt fetches again");
        check(!viewThumbDue(cached,summary,now+49000)&&viewThumbDue(cached,summary,now+50000),"refreshAfter (60 s) elapsed fetches again");
        const failed={data:null,fetchedAt:now,failed:true},stale={...cached,fetchedAt:now,failed:true};
        check(!viewThumbDue(failed,summary,now+29000)&&viewThumbDue(failed,summary,now+30000),"A failed fetch waits 30 s");
        check(!viewThumbDue(stale,{...summary,updatedAt:"2026-11-17T21:00:00Z"},now+29000),"A failed fetch waits 30 s even when the view changed");

        // The grid against a fake Mac.
        const originalAPI=api,originalToken=token,calls=[];let inFlight=0,maxInFlight=0;
        const view=(id,name,extra={})=>({id,name,subtitle:null,icon:"server.rack",pinned:false,private:false,sources:["tool"],createdAt:"2026-11-17T20:00:00Z",updatedAt:"2026-11-17T20:00:00Z",refreshedAt:"2026-11-17T20:00:00Z",refreshing:false,problems:[],...extra});
        let views=[view("V1","Homelab",{pinned:true,private:true,subtitle:"Service health"}),view("V2","Bills",{icon:"creditcard"})],revision="vr-1";
        const cards={V1:homelab,V2:bills,V3:{blocks:[{type:"header",title:"Follow-ups"},stat("Waiting on me","3")]}};
        const task=(id,title)=>({id,title,prompt:"Synthetic.",schedule:{summary:"Every day at 8:00 AM"},hasSchedule:true,enabled:true,state:"succeeded",runs:[],workspace:null});
        let tasks=[task("T1","Morning briefing"),task("T2","Bill check"),task("T3","Trip check")];
        try{
          for(const key of ["cantrip.home.views.collapsed","cantrip.home.tasks.collapsed"])localStorage.removeItem(key);
          token="views-grid";viewThumbs.clear();
          api=async(path,options={})=>{const method=options.method||"GET";calls.push([method,path]);
            if(path.startsWith("/api/v1/home/tasks"))return {tasks:JSON.parse(JSON.stringify(tasks)),revision:`tr-${tasks.length}`,supportsViews:true,error:null};
            if(path.startsWith("/api/v1/home/views?")&&path.endsWith(encodeURIComponent(revision)))return {unchanged:true,revision};
            if(path.startsWith("/api/v1/home/views?")||path==="/api/v1/home/views")return {views:JSON.parse(JSON.stringify(views)),revision};
            const id=decodeURIComponent(path.split("/").pop()),summary=views.find(item=>item.id===id);
            if(method!=="GET"||!summary)throw Error(`unexpected ${method} ${path}`);
            inFlight++;maxInFlight=Math.max(maxInFlight,inFlight);await settle(30);inFlight--;
            return {view:JSON.parse(JSON.stringify(summary)),card:{version:1,id:`view-${id}`,type:"view",blocks:cards[id].blocks},refreshAfter:30}};
          const details=()=>calls.filter(([,path])=>/^[/]api[/]v1[/]home[/]views[/][^?]+$/.test(path)).map(([,path])=>path.split("/").pop());
          const toggle=name=>$("tasksBody").querySelector(`[data-focus-key="section:${name}"]`);
          const thumbs=()=>Array.from($("tasksBody").querySelectorAll(".view-thumb"));
          openTasks();await loadTasks();await settle(300);
          const grid=$("tasksBody").querySelector(".views-grid");
          check(grid&&thumbs().length===2&&$("tasksPanel").classList.contains("views-wide"),"Views show as a grid of thumbnails in the widened panel");
          check(getComputedStyle(grid).gridTemplateColumns.split(" ").length===viewsGridColumns(grid.clientWidth),`The grid uses the column function (${getComputedStyle(grid).gridTemplateColumns} for ${grid.clientWidth})`);
          const views0=toggle("views"),tasks0=toggle("tasks");
          check(views0.closest("h3")&&views0.getAttribute("aria-expanded")==="true"&&$(views0.getAttribute("aria-controls"))===grid&&views0.getAttribute("aria-label")==="Views, 2 views","The Views heading is a disclosure button named with its count");
          check(tasks0.getAttribute("aria-label")==="Tasks, 3 tasks"&&!tasks0.textContent.includes("·")&&$("tasksBody").querySelectorAll(".task-card").length===3,"Tasks has its own heading; counts show only when collapsed");
          const homelabThumb=thumbs()[0],open=homelabThumb.querySelector(".view-thumb-open"),preview=homelabThumb.querySelector(".view-thumb-preview");
          check(open.dataset.focusKey==="view:V1"&&open.getAttribute("aria-label")==="Homelab, Pinned, Private, Service health","One label for the whole card");
          check(homelabThumb.querySelector(".view-thumb-body").getAttribute("aria-hidden")==="true"&&preview.inert&&getComputedStyle(preview).pointerEvents==="none","The preview is inert and hidden from assistive tech");
          check(preview.querySelector(".cd-stat-value")?.textContent==="2"&&!preview.querySelector(".cd-table,.cd-head"),"Homelab's preview is its stat, drawn by the card renderer");
          check(thumbs()[1].querySelectorAll(".view-thumb-preview .cd-statblock").length===2&&thumbs()[1].querySelector(".view-thumb-preview .cd-chart"),"Bills' preview shows two stats and its chart");
          check(homelabThumb.querySelector(".view-thumb-name").textContent==="Homelab"&&homelabThumb.querySelectorAll(".view-thumb-badge").length===2,"Pinned and private badges");
          check(details().sort().join()==="V1,V2"&&maxInFlight<=2&&!calls.some(([method])=>method!=="GET"),"Each view's detail is fetched once with GET, never refreshed");

          // Polling: a cache hit fetches nothing; a changed view fetches only itself; a newly saved view appears.
          open.focus();await loadTasks();await settle(200);
          check(details().length===2,"Unchanged views are not fetched again");
          check(document.activeElement?.dataset.focusKey==="view:V1","Polling keeps focus on the thumbnail");
          views=views.map(item=>item.id==="V2"?{...item,updatedAt:"2026-11-17T21:00:00Z",problems:["homelab is down"]}:item);revision="vr-2";
          await loadTasks();await settle(300);
          check(details().join()==="V1,V2,V2","Only the changed view is fetched again");
          check(thumbs()[1].querySelector(".view-thumb-note.warning")?.textContent==="homelab is down"&&thumbs()[1].querySelector(".view-thumb-open").getAttribute("aria-label").endsWith("1 problem"),"Problems show under the preview");
          views=[...views,view("V3","Follow-ups",{icon:"unknown.symbol",refreshing:true})];revision="vr-3";
          await loadTasks();await settle(300);
          check(thumbs().length===3&&thumbs()[2].querySelector(".view-thumb-preview .cd-stat-value")?.textContent==="3","A view saved while Tasks is open appears on the next poll");
          check(thumbs()[2].querySelector(".view-thumb-note").textContent==="Refreshing…"&&thumbs()[2].querySelector(".view-thumb-icon svg"),"Refreshing shows; unknown symbols fall back to an icon");
          check(details().join()==="V1,V2,V2,V3","Only the new view is fetched");
          const entry=viewThumbs.get("V1");entry.fetchedAt-=31000;
          await loadTasks();await settle(300);
          check(details().join()==="V1,V2,V2,V3,V1","A thumbnail is fetched again once its refreshAfter passes");

          // Collapsing: stored per browser, read back on a fresh render, and no thumbnail fetches while hidden.
          toggle("views").click();await settle();
          check(localStorage.getItem("cantrip.home.views.collapsed")==="1"&&toggle("views").getAttribute("aria-expanded")==="false"
                &&toggle("views").textContent.replace(/[^A-Za-z0-9·]/g,"")==="Views·3"&&$("viewsSectionBody").hidden&&!thumbs().length,"Collapsing Views stores it and shows the count");
          check(document.activeElement===toggle("views"),"The heading keeps focus");
          viewThumbs.get("V2").fetchedAt-=31000;await loadTasks();await settle(200);
          check(details().length===5,"No thumbnail fetches while Views is collapsed");
          toggle("tasks").click();await settle();
          check(localStorage.getItem("cantrip.home.tasks.collapsed")==="1"&&toggle("tasks").textContent.replace(/[^A-Za-z0-9·]/g,"")==="Tasks·3"&&$("tasksSectionBody").hidden,"Collapsing Tasks stores it");
          $("tasksDone").click();await settle();check(tasksState===null,"Done closes Tasks");tasks=[task("T1","Morning briefing")];
          openTasks();await loadTasks();await settle(200);
          check(toggle("views").getAttribute("aria-expanded")==="false"&&toggle("tasks").getAttribute("aria-expanded")==="false"&&toggle("tasks").getAttribute("aria-label")==="Tasks, 1 task","A fresh render reads both back");
          toggle("views").click();await settle(300);toggle("tasks").click();await settle();
          check(localStorage.getItem("cantrip.home.views.collapsed")==="0"&&localStorage.getItem("cantrip.home.tasks.collapsed")==="0"&&thumbs().length===3&&$("tasksBody").querySelectorAll(".task-card").length===1,"Expanding stores 0 and shows both again");
          check(details().join()==="V1,V2,V2,V3,V1,V2","Expanding fetches only the stale thumbnail");

          // Opening a view uses the same cache; back returns focus to its thumbnail.
          thumbs()[1].querySelector(".view-thumb-open").click();await settle(200);
          check(tasksState.viewID==="V2"&&!$("tasksPanel").classList.contains("views-wide")&&$("tasksBody").querySelector(".view-card .cd-card"),"A thumbnail opens its view");
          check(viewThumbs.get("V2").fetchedAt>=Date.now()-1000,"The view screen's fetch updates the thumbnail cache");
          $("tasksBack").click();await settle();
          check(document.activeElement?.dataset.focusKey==="view:V2","Back focuses the thumbnail");
          check(!calls.some(([method,path])=>method!=="GET"||path.endsWith("/refresh")),"Thumbnails never refresh");
        }finally{
          if($("tasksPanel").open)$("tasksPanel").close();closeTasks();viewThumbs.clear();
          for(const key of ["cantrip.home.views.collapsed","cantrip.home.tasks.collapsed"])localStorage.removeItem(key);
          api=originalAPI;token=originalToken;
        }
        """, arguments: [:], in: nil, contentWorld: .page)
        print("Remote views grid: columns, previews, collapsible sections and thumbnail fetches passed")
    }
}
